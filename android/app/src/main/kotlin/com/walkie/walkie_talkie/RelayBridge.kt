package com.walkie.walkie_talkie

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * Internet relay sockets for Android ("walkie/relay" + "walkie/relay/events").
 *
 * Dart's own WebSocket follows the process network binding. When the phone is
 * on a Wi-Fi without internet, [NetUpdateBridge] binds the whole process to
 * that Wi-Fi (so LAN UDP goes there), which used to cut the relay off even
 * with mobile data available. Here every relay socket is created with
 * [Network.getSocketFactory] of a network that actually reaches the internet
 * (the system default network if validated, else any validated network,
 * mobile data first), independent of the process binding. LAN stays on
 * Wi-Fi, the relay runs over whatever has internet, at the same time.
 *
 * When that "internet network" changes (left Wi-Fi, mobile data came back,
 * ...) a `net` event is sent so Dart reconnects immediately instead of
 * waiting for the old socket to time out.
 */
class RelayBridge(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val sockets = ConcurrentHashMap<Int, WebSocket>()
    private val caps = ConcurrentHashMap<Network, NetworkCapabilities>()
    @Volatile private var defaultNet: Network? = null
    @Volatile private var picked: Network? = null
    private var started = false
    private val notify = Runnable { checkPick() }

    private val baseClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .pingInterval(15, TimeUnit.SECONDS)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build()
    }

    fun attach(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "walkie/relay/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
        MethodChannel(messenger, "walkie/relay").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "open" -> {
                        startWatch()
                        val id = call.argument<Int>("id")!!
                        val url = call.argument<String>("url")!!
                        result.success(open(id, url))
                    }
                    "send" -> {
                        val id = call.argument<Int>("id")!!
                        val data = call.argument<ByteArray>("data")!!
                        result.success(sockets[id]?.send(data.toByteString()) ?: false)
                    }
                    "text" -> {
                        val id = call.argument<Int>("id")!!
                        val text = call.argument<String>("text")!!
                        result.success(sockets[id]?.send(text) ?: false)
                    }
                    "close" -> {
                        val id = call.argument<Int>("id")!!
                        sockets.remove(id)?.let { ws ->
                            if (!ws.close(1000, "bye")) ws.cancel()
                        }
                        result.success(null)
                    }
                    "network" -> {
                        startWatch()
                        result.success(label(pick()))
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("relay", e.toString(), null)
            }
        }
    }

    private fun cm(): ConnectivityManager =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private fun emit(m: Map<String, Any?>) {
        main.post { sink?.success(m) }
    }

    private fun open(id: Int, url: String): String {
        sockets.remove(id)?.cancel()
        val net = pick()
        val client = if (net == null) {
            baseClient
        } else {
            baseClient.newBuilder()
                .socketFactory(net.socketFactory)
                .dns(
                    object : Dns {
                        override fun lookup(hostname: String): List<InetAddress> =
                            net.getAllByName(hostname).toList()
                    },
                )
                .build()
        }
        val ws = client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    emit(mapOf("id" to id, "t" to "open", "net" to label(net)))
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    emit(mapOf("id" to id, "t" to "bin", "data" to bytes.toByteArray()))
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    emit(mapOf("id" to id, "t" to "text", "data" to text))
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(1000, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    sockets.remove(id, webSocket)
                    emit(mapOf("id" to id, "t" to "closed", "reason" to "closed $code $reason".trim()))
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    sockets.remove(id, webSocket)
                    val why = response?.let { "HTTP ${it.code}" } ?: (t.message ?: t.javaClass.simpleName)
                    emit(mapOf("id" to id, "t" to "fail", "reason" to why))
                }
            },
        )
        sockets[id] = ws
        return label(net)
    }

    // ------------------------------------------------------------ networks

    private fun validated(n: Network?): Boolean {
        val c = n?.let { caps[it] ?: try { cm().getNetworkCapabilities(it) } catch (_: Exception) { null } }
            ?: return false
        return c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun isCell(n: Network): Boolean =
        caps[n]?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true

    /** Network the relay should use: one that really reaches the internet. */
    private fun pick(): Network? {
        val def = defaultNet ?: try { cm().activeNetwork } catch (_: Exception) { null }
        if (def != null && validated(def)) return def
        val ok = caps.keys.filter { validated(it) }
        return ok.firstOrNull { isCell(it) } ?: ok.firstOrNull() ?: def
    }

    private fun label(n: Network?): String {
        if (n == null) return "default network"
        val c = caps[n] ?: try { cm().getNetworkCapabilities(n) } catch (_: Exception) { null }
        return when {
            c == null -> "network"
            c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile data"
            c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
            else -> "network"
        }
    }

    private fun checkPick() {
        val now = pick()
        if (now != picked) {
            picked = now
            emit(
                mapOf(
                    "id" to -1,
                    "t" to "net",
                    "net" to label(now),
                    "online" to (now != null && validated(now)),
                ),
            )
        }
    }

    private fun changed() {
        main.removeCallbacks(notify)
        main.postDelayed(notify, 250) // v1.9.8: was 700 ms
    }

    @Synchronized
    private fun startWatch() {
        if (started) return
        val cm = cm()
        try {
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    defaultNet = network
                    changed()
                }

                override fun onCapabilitiesChanged(network: Network, c: NetworkCapabilities) {
                    defaultNet = network
                    caps[network] = c
                    changed()
                }

                override fun onLost(network: Network) {
                    if (defaultNet == network) defaultNet = null
                    changed()
                }
            })
        } catch (_: Exception) {
        }
        try {
            val req = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(req, object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, c: NetworkCapabilities) {
                    val before = caps[network]?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                    caps[network] = c
                    if (before != c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) changed()
                }

                override fun onLost(network: Network) {
                    caps.remove(network)
                    changed()
                }
            })
        } catch (_: Exception) {
        }
        picked = pick()
        started = true
    }
}
