package com.walkie.walkie_talkie

import android.content.Context
import android.content.Intent
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
 * And "walkie/update" for in-app updates: a cache folder to download the APK
 * into, the "install unknown apps" check / settings page, and launching the
 * system package installer through a FileProvider.
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
