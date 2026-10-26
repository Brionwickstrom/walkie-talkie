package com.walkie.walkie_talkie

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * "walkie/wifidirect": Wi-Fi Direct (Wi-Fi P2P) for the off-grid
 * transport (v1.6.0).
 *
 *  - Advertises a DNS-SD service "_walkietalkie._udp" whose TXT record holds
 *    our node id, and runs service discovery every [intervalMs]; every app
 *    phone found is reported to Dart as {t: found, addr, id}.
 *  - Dart decides when to connect (only with phones we share no network
 *    with); [connect] asks the system to form or join a group.
 *  - Group changes are reported as {t: conn, formed, owner, go}; Dart then
 *    exchanges the normal UDP frames inside the group.
 *
 * Engine scoped like the other bridges so it keeps working in the
 * background. Needs NEARBY_WIFI_DEVICES (Android 13+) or fine location
 * (older); without it start() returns "permission".
 */
@SuppressLint("MissingPermission")
class WifiDirectBridge(private val context: Context) : EventChannel.StreamHandler {
    companion object {
        const val SERVICE_TYPE = "_walkietalkie._udp"
    }

    private val main = Handler(Looper.getMainLooper())
    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null
    private var request: WifiP2pDnsSdServiceRequest? = null
    private var running = false
    private var intervalMs = 30_000L

    private val discoverTask = object : Runnable {
        override fun run() {
            if (!running) return
            discover()
            main.postDelayed(this, intervalMs)
        }
    }

    private val noop = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {}
        override fun onFailure(reason: Int) {}
    }

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "walkie/wifidirect")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            val id = call.argument<Number>("id")?.toLong() ?: 0L
                            result.success(start(id))
                        }
                        "stop" -> {
                            stop()
                            result.success(null)
                        }
                        "connect" -> {
                            val addr = call.argument<String>("addr")
                            val intent = call.argument<Number>("intent")?.toInt() ?: 0
                            if (addr != null) connect(addr, intent)
                            result.success(null)
                        }
                        "interval" -> {
                            val ms = call.argument<Number>("ms")?.toLong() ?: 30_000L
                            intervalMs = ms.coerceAtLeast(10_000L)
                            if (running) {
                                main.removeCallbacks(discoverTask)
                                main.postDelayed(discoverTask, intervalMs)
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("wifidirect", e.message, null)
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, "walkie/wifidirect/events")
            .setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(m: Map<String, Any?>) {
        main.post { sink?.success(m) }
    }

    private fun granted(p: String) =
        ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    private fun hasPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= 33) {
            granted(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            granted(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    @SuppressLint("MissingPermission")
    private fun start(id: Long): String? {
        if (running) return null
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)) {
            return "unsupported"
        }
        if (!hasPermission()) return "permission"
        val m = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
            ?: return "unsupported"
        val ch = m.initialize(context, Looper.getMainLooper(), null) ?: return "unsupported"
        manager = m
        channel = ch
        running = true
        registerReceiver()

        m.setDnsSdResponseListeners(
            ch,
            { _, _, _ -> },
            { fullDomain, txt, device ->
                if (fullDomain.contains(SERVICE_TYPE)) {
                    val hex = txt["id"]
                    val peerId = hex?.toLongOrNull(16)
                    if (peerId != null) {
                        emit(mapOf("t" to "found", "addr" to device.deviceAddress, "id" to peerId))
                    }
                }
            },
        )
        val hex = java.lang.Long.toHexString(id and 0xFFFFFFFFL)
        val info = WifiP2pDnsSdServiceInfo.newInstance(
            "wt-$hex",
            SERVICE_TYPE,
            mapOf("id" to hex, "v" to "1"),
        )
        m.clearLocalServices(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                m.addLocalService(ch, info, noop)
            }

            override fun onFailure(reason: Int) {
                m.addLocalService(ch, info, noop)
            }
        })
        val req = WifiP2pDnsSdServiceRequest.newInstance()
        request = req
        m.addServiceRequest(ch, req, noop)
        main.removeCallbacks(discoverTask)
        main.post(discoverTask)
        m.requestConnectionInfo(ch) { info2 -> onConnectionInfo(info2) }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun discover() {
        val m = manager ?: return
        val ch = channel ?: return
        if (!hasPermission()) return
        try {
            // Peer discovery first: some phones only answer service
            // discovery while they are discoverable themselves.
            m.discoverPeers(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    m.discoverServices(ch, noop)
                }

                override fun onFailure(reason: Int) {
                    m.discoverServices(ch, noop)
                }
            })
        } catch (_: SecurityException) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String, ownerIntent: Int) {
        val m = manager ?: return
        val ch = channel ?: return
        if (!hasPermission()) return
        val config = WifiP2pConfig().apply {
            deviceAddress = address
            groupOwnerIntent = ownerIntent.coerceIn(0, 15)
        }
        try {
            m.connect(ch, config, noop)
        } catch (_: SecurityException) {
        }
    }

    private fun onConnectionInfo(info: WifiP2pInfo?) {
        val formed = info?.groupFormed == true
        emit(
            mapOf(
                "t" to "conn",
                "formed" to formed,
                "owner" to (formed && info?.isGroupOwner == true),
                "go" to info?.groupOwnerAddress?.hostAddress,
            ),
        )
    }

    private fun registerReceiver() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        emit(
                            mapOf(
                                "t" to "state",
                                "enabled" to (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED),
                            ),
                        )
                    }
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        val m = manager ?: return
                        val ch = channel ?: return
                        m.requestConnectionInfo(ch) { info -> onConnectionInfo(info) }
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        }
        ContextCompat.registerReceiver(context, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        receiver = r
    }

    private fun stop() {
        running = false
        main.removeCallbacks(discoverTask)
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null
        val m = manager
        val ch = channel
        if (m != null && ch != null) {
            try {
                m.stopPeerDiscovery(ch, noop)
                m.clearServiceRequests(ch, noop)
                m.clearLocalServices(ch, noop)
                m.removeGroup(ch, noop)
            } catch (_: Exception) {
            }
            if (Build.VERSION.SDK_INT >= 27) {
                try {
                    ch.close()
                } catch (_: Exception) {
                }
            }
        }
        manager = null
        channel = null
        request = null
    }
}
