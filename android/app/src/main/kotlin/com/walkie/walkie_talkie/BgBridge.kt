package com.walkie.walkie_talkie

import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
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
                result.success(ListenService.start(ctx, str(call, "title"), str(call, "text")))
            }
            "updateService" -> {
                ListenService.update(ctx, str(call, "title"), str(call, "text"))
                result.success(null)
            }
            "stopService" -> {
                ListenService.stop(ctx)
                result.success(null)
            }
            "serviceRunning" -> result.success(ListenService.running)
            "showRing" -> {
                Notifier.showRing(
                    ctx, long(call, "from"), long(call, "id"), str(call, "name"), int(call, "channel"),
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
                Notifier.showTalking(ctx, long(call, "peer"), str(call, "name"), int(call, "channel"))
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
