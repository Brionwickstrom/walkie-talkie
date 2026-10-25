package com.walkie.walkie_talkie

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Small "walkie/net" platform channel for the LAN transport:
 *  - acquire/release a WifiManager.MulticastLock. Without it Android (and
 *    Samsung in particular) filters incoming broadcast/multicast UDP, so
 *    discovery beacons from other phones never reach the app.
 *  - list IPv4 interfaces with their real subnet broadcast address, which
 *    dart:io cannot provide (it has no netmask).
 *
 *  - hold a low-latency Wi-Fi lock so Wi-Fi power save does not batch
 *    voice packets into bursts.
 *  - watch the Wi-Fi network. If it has no internet (offline router, a
 *    phone hotspot without data) Android keeps mobile data as the default
 *    network and would send our LAN packets there, so the process is bound
 *    to the Wi-Fi network instead. Nothing here needs internet.
 *
 * And "walkie/update" for in-app updates: a cache folder to download the APK
 * into, the "install unknown apps" check / settings page, and launching the
 * system package installer through a FileProvider.
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var wifiNetwork: Network? = null
    @Volatile private var wifiValidated = false
    @Volatile private var boundNetwork: Network? = null
    @Volatile private var bindGeneration = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "walkie/net")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquireMulticastLock" -> result.success(acquireLock())
                        "releaseMulticastLock" -> {
                            releaseLock()
                            result.success(null)
                        }
                        "interfaces" -> result.success(listInterfaces())
                        "netState" -> result.success(netState())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("net", e.toString(), null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "walkie/update")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "updateDir" -> result.success(updateDir().absolutePath)
                        "canInstall" -> result.success(canInstall())
                        "openInstallSettings" -> {
                            openInstallSettings()
                            result.success(null)
                        }
                        "install" -> {
                            val path = call.argument<String>("path")
                            if (path == null) {
                                result.error("update", "missing path", null)
                            } else {
                                install(File(path))
                                result.success(null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("update", e.toString(), null)
                }
            }
    }

    /** cache/updates, matching res/xml/update_paths.xml. Old APKs are removed. */
    private fun updateDir(): File {
        val dir = File(cacheDir, "updates")
        if (!dir.exists()) dir.mkdirs()
        dir.listFiles()?.forEach { it.delete() }
        return dir
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        startActivity(intent)
    }

    private fun install(apk: File) {
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun acquireLock(): Boolean {
        val lock = multicastLock ?: run {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifi.createMulticastLock("walkie_talkie_lan").also {
                it.setReferenceCounted(false)
                multicastLock = it
            }
        }
        if (!lock.isHeld) lock.acquire()
        acquireWifiLock()
        startWifiWatch()
        return lock.isHeld
    }

    private fun releaseLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        stopWifiWatch()
    }

    @Suppress("DEPRECATION")
    private fun acquireWifiLock() {
        try {
            val lock = wifiLock ?: run {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifi.createWifiLock(mode, "walkie_talkie_voice").also {
                    it.setReferenceCounted(false)
                    wifiLock = it
                }
            }
            if (!lock.isHeld) lock.acquire()
        } catch (_: Exception) {
        }
    }

    private fun connectivity(): ConnectivityManager =
        applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    /** Track the Wi-Fi network, with or without internet. */
    private fun startWifiWatch() {
        if (wifiCallback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                wifiNetwork = network
                wifiValidated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                updateBinding()
            }

            override fun onLost(network: Network) {
                if (network == wifiNetwork) {
                    wifiNetwork = null
                    wifiValidated = false
                    updateBinding()
                }
            }
        }
        try {
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            // requestNetwork (not just register) also stops Android from
            // dropping a no-internet Wi-Fi in favour of mobile data.
            connectivity().requestNetwork(req, cb)
            wifiCallback = cb
        } catch (_: Exception) {
            try {
                val req = NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .build()
                connectivity().registerNetworkCallback(req, cb)
                wifiCallback = cb
            } catch (_: Exception) {
            }
        }
    }

    private fun stopWifiWatch() {
        val cb = wifiCallback ?: return
        try {
            connectivity().unregisterNetworkCallback(cb)
        } catch (_: Exception) {
        }
        wifiCallback = null
        wifiNetwork = null
        wifiValidated = false
        updateBinding()
    }

    /** Bind to Wi-Fi only while it has no internet (else it is the default). */
    @Synchronized
    private fun updateBinding() {
        val want = if (wifiNetwork != null && !wifiValidated) wifiNetwork else null
        if (want == boundNetwork) return
        try {
            connectivity().bindProcessToNetwork(want)
            boundNetwork = want
            bindGeneration++
        } catch (_: Exception) {
        }
    }

    private fun netState(): Map<String, Any?> = mapOf(
        "wifi" to (wifiNetwork != null),
        "validated" to wifiValidated,
        "bound" to (boundNetwork != null),
        "wifiLock" to (wifiLock?.isHeld == true),
        "generation" to bindGeneration,
    )

    private fun listInterfaces(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val ifaces = NetworkInterface.getNetworkInterfaces() ?: return out
        for (ni in ifaces) {
            try {
                if (!ni.isUp || ni.isLoopback) continue
            } catch (_: Exception) {
                continue
            }
            for (ia in ni.interfaceAddresses) {
                val addr = ia.address
                if (addr !is Inet4Address) continue
                out.add(
                    mapOf(
                        "name" to ni.name,
                        "address" to addr.hostAddress,
                        "broadcast" to ia.broadcast?.hostAddress,
                        "prefix" to ia.networkPrefixLength.toInt(),
                    )
                )
            }
        }
        return out
    }

    override fun onDestroy() {
        releaseLock()
        super.onDestroy()
    }
}
