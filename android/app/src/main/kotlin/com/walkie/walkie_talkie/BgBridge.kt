package com.walkie.walkie_talkie

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "walkie/bg" platform channel: the listening foreground service, ring /
 * beep / talking / voice message notifications, battery optimization and
 * full-screen-intent settings. User actions on notifications come back to
 * Dart as `action` calls (queued until Dart says it is `ready`).
 */
object BgBridge {
    private var channel: MethodChannel? = null
    private var ready = false
    private val pending = mutableListOf<Map<String, Any?>>()
    private val main = Handler(Looper.getMainLooper())
    private var app: Context? = null

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "walkie/bg")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                handle(context.applicationContext, call, result)
            } catch (e: Exception) {
                result.error("bg", e.toString(), null)
            }
        }
    }

    /** Hand a user action (notification button, launch intent) to Dart. */
    fun deliver(context: Context, action: Map<String, Any?>) {
        main.post {
            EngineHolder.get(context)
            val ch = channel
            if (ready && ch != null) {
                ch.invokeMethod("action", action)
            } else {
                pending.add(action)
            }
        }
    }

    private fun long(call: MethodCall, key: String): Long =
        (call.argument<Any>(key) as? Number)?.toLong() ?: 0L

    private fun int(call: MethodCall, key: String): Int =
        (call.argument<Any>(key) as? Number)?.toInt() ?: 0

    private fun bool(call: MethodCall, key: String): Boolean =
        call.argument<Boolean>(key) ?: false

    private fun str(call: MethodCall, key: String): String =
        call.argument<String>(key) ?: ""

    private fun handle(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                ready = true
                val list = ArrayList(pending)
                pending.clear()
                result.success(list)
            }
            "startService" -> {
                result.success(
                    ListenService.start(
                        ctx, str(call, "title"), str(call, "text"),
                        bool(call, "mic"), bool(call, "talk"), bool(call, "talking"),
                    ),
                )
            }
            "updateService" -> {
                ListenService.update(
                    ctx, str(call, "title"), str(call, "text"), bool(call, "talk"), bool(call, "talking"),
                )
                result.success(null)
            }
            "stopService" -> {
                ListenService.stop(ctx)
                result.success(null)
            }
            "serviceRunning" -> result.success(ListenService.running)
            "micInBackground" -> result.success(ListenService.running && ListenService.micType)
            "setPttConfig" -> {
                PttKeys.configure(ctx, bool(call, "volume"), bool(call, "headset"))
                result.success(null)
            }
            "a11yEnabled" -> result.success(PttKeys.a11yEnabled(ctx))
            "openA11ySettings" -> {
                open(ctx, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                result.success(null)
            }
            "dndAccess" -> {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                result.success(nm.isNotificationPolicyAccessGranted)
            }
            "openDndSettings" -> {
                open(ctx, Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
                result.success(null)
            }
            "showRing" -> {
                Notifier.showRing(
                    ctx, long(call, "from"), long(call, "id"), str(call, "name"), int(call, "channel"),
                    bool(call, "urgent"), call.argument<Boolean>("loud") ?: true,
                )
                result.success(null)
            }
            "stopRing" -> {
                Notifier.stopRing(ctx, long(call, "from"), long(call, "id"))
                result.success(null)
            }
            "beep" -> {
                Notifier.showBeep(ctx, long(call, "from"), str(call, "name"), call.argument<Boolean>("notify") ?: true)
                result.success(null)
            }
            "showTalking" -> {
                Notifier.showTalking(ctx, long(call, "peer"), str(call, "name"), int(call, "channel"), bool(call, "friend"))
                result.success(null)
            }
            "cancelTalking" -> {
                Notifier.cancelTalking(ctx, long(call, "peer"))
                result.success(null)
            }
            "showVoiceMessage" -> {
                Notifier.showVoiceMessage(
                    ctx, str(call, "key"), int(call, "nid"), str(call, "name"), str(call, "duration"),
                )
                result.success(null)
            }
            "showInfo" -> {
                Notifier.showInfo(ctx, int(call, "nid"), str(call, "title"), str(call, "text"))
                result.success(null)
            }
            "cancel" -> {
                Notifier.cancel(ctx, int(call, "nid"))
                result.success(null)
            }
            "filesDir" -> result.success(ctx.filesDir.absolutePath)
            "manufacturer" -> result.success(Build.MANUFACTURER ?: "")
            // Walkie audio plays on the media stream (STREAM_MUSIC, loud
            // speaker). Fraction 0..1 of its volume, for the "volume low" hint.
            "mediaVolume" -> {
                val am = ctx.getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
                val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                val cur = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                result.success(if (max > 0) cur.toDouble() / max else 1.0)
            }
            "batteryLevel" -> {
                // 0..100 and whether it is charging (v1.8.3); -1 if unknown.
                val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
                val pct = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
                result.success(mapOf("pct" to (if (pct in 0..100) pct else -1), "chg" to bm.isCharging))
            }
            "ignoringBattery" -> {
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(ctx.packageName))
            }
            "requestIgnoreBattery" -> {
                result.success(requestIgnoreBattery(ctx))
            }
            "openAppSettings" -> {
                open(
                    ctx,
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${ctx.packageName}"),
                    ),
                )
                result.success(null)
            }
            "canFullScreen" -> {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                result.success(
                    if (Build.VERSION.SDK_INT >= 34) nm.canUseFullScreenIntent() else true,
                )
            }
            "openFullScreenSettings" -> {
                if (Build.VERSION.SDK_INT >= 34) {
                    open(
                        ctx,
                        Intent(
                            Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                            Uri.parse("package:${ctx.packageName}"),
                        ),
                    )
                }
                result.success(null)
            }
            "getLocation" -> getLocation(ctx, result)
            "startLocationUpdates" -> result.success(startLocationUpdates(ctx, long(call, "interval")))
            "stopLocationUpdates" -> {
                stopLocationUpdates(ctx)
                result.success(null)
            }
            "setServiceLocation" -> {
                ListenService.setLocation(ctx, bool(call, "on"))
                result.success(null)
            }
            "showSos" -> {
                Notifier.showSos(ctx, long(call, "from"), long(call, "id"), str(call, "name"), str(call, "text"))
                result.success(null)
            }
            "stopSos" -> {
                Notifier.stopSos(ctx, long(call, "from"), long(call, "id"))
                result.success(null)
            }
            "silenceSos" -> {
                Notifier.silenceSos()
                result.success(null)
            }
            "shareFile" -> result.success(shareFile(ctx, str(call, "path"), str(call, "mime"), str(call, "title")))
            "openUrl" -> {
                try {
                    open(ctx, Intent(Intent.ACTION_VIEW, Uri.parse(str(call, "url"))))
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
            "setBootStart" -> {
                ctx.getSharedPreferences(BootReceiver.PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(BootReceiver.KEY_BOOT, call.argument<Boolean>("on") ?: false)
                    .apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * One location fix: {lat, lng, acc}, or null (no permission, location
     * off, or nothing within 20 s). Prefers a fresh fix, falls back to the
     * newest last-known one.
     */
    @SuppressLint("MissingPermission")
    private fun getLocation(ctx: Context, result: MethodChannel.Result) {
        val fine = ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        val coarse = ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            result.success(null)
            return
        }
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = lm.getProviders(true)
        fun last(): Location? = providers
            .mapNotNull { p -> try { lm.getLastKnownLocation(p) } catch (_: Exception) { null } }
            .maxByOrNull { it.time }
        fun map(l: Location?): Map<String, Any?>? = l?.let {
            mapOf("lat" to it.latitude, "lng" to it.longitude, "acc" to it.accuracy.toDouble(), "t" to it.time)
        }
        val provider = when {
            fine && providers.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            providers.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            providers.contains(LocationManager.FUSED_PROVIDER) -> LocationManager.FUSED_PROVIDER
            providers.isNotEmpty() -> providers.first()
            else -> null
        }
        if (provider == null) {
            result.success(map(last()))
            return
        }
        var done = false
        fun finish(l: Location?) {
            main.post {
                if (done) return@post
                done = true
                result.success(map(l ?: last()))
            }
        }
        main.postDelayed({ finish(null) }, 20_000)
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                lm.getCurrentLocation(provider, null, ctx.mainExecutor) { finish(it) }
            } else {
                @Suppress("DEPRECATION")
                lm.requestSingleUpdate(provider, object : LocationListener {
                    override fun onLocationChanged(location: Location) = finish(location)
                    @Deprecated("old API")
                    override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
                    override fun onProviderEnabled(p: String) {}
                    override fun onProviderDisabled(p: String) = finish(null)
                }, Looper.getMainLooper())
            }
        } catch (_: Exception) {
            finish(null)
        }
    }

    private var locListener: LocationListener? = null

    /**
     * Continuous fixes for the Trip tab (live location, trail recording):
     * each one goes to Dart as an action {type: loc, lat, lng, acc, t, alt,
     * spd}. GPS when allowed, else network. False without permission.
     */
    @SuppressLint("MissingPermission")
    private fun startLocationUpdates(ctx: Context, intervalMs: Long): Boolean {
        val fine = ctx.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        val coarse = ctx.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return false
        stopLocationUpdates(ctx)
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = lm.getProviders(true)
        val provider = when {
            fine && providers.contains(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            providers.contains(LocationManager.FUSED_PROVIDER) -> LocationManager.FUSED_PROVIDER
            providers.contains(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> return false
        }
        val l = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                deliver(
                    ctx,
                    mapOf(
                        "type" to "loc",
                        "lat" to location.latitude,
                        "lng" to location.longitude,
                        "acc" to (if (location.hasAccuracy()) location.accuracy.toDouble() else null),
                        "t" to location.time,
                        "alt" to (if (location.hasAltitude()) location.altitude else null),
                        "spd" to (if (location.hasSpeed()) location.speed.toDouble() else null),
                    ),
                )
            }
            @Deprecated("old API")
            override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
            override fun onProviderEnabled(p: String) {}
            override fun onProviderDisabled(p: String) {}
        }
        return try {
            lm.requestLocationUpdates(provider, intervalMs.coerceAtLeast(1000L), 0f, l, Looper.getMainLooper())
            locListener = l
            // Hand over the last known fix right away.
            try {
                lm.getLastKnownLocation(provider)?.let { l.onLocationChanged(it) }
            } catch (_: Exception) {
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopLocationUpdates(ctx: Context) {
        val l = locListener ?: return
        locListener = null
        try {
            (ctx.getSystemService(Context.LOCATION_SERVICE) as LocationManager).removeUpdates(l)
        } catch (_: Exception) {
        }
    }

    /** Share a file (GPX trail) with another app through the FileProvider. */
    private fun shareFile(ctx: Context, path: String, mime: String, title: String): Boolean {
        return try {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                ctx, "${ctx.packageName}.updates", java.io.File(path),
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, title)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            open(ctx, Intent.createChooser(send, title).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            true
        } catch (_: Exception) {
            false
        }
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBattery(ctx: Context): Boolean {
        return try {
            open(
                ctx,
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${ctx.packageName}"),
                ),
            )
            true
        } catch (_: Exception) {
            try {
                open(ctx, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun open(ctx: Context, intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }
}
