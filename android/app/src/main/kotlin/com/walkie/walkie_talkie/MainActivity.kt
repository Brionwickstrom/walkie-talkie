package com.walkie.walkie_talkie

import android.content.Context
import android.net.wifi.WifiManager
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
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

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
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("net", e.toString(), null)
                }
            }
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
        return lock.isHeld
    }

    private fun releaseLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
    }

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
