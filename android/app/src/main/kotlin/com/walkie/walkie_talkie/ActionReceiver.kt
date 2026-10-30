package com.walkie.walkie_talkie

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Notification buttons that don't open the app: Stop, Dismiss, Play. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Notifier.ACTION_STOP -> {
                ListenService.stop(context)
                BgBridge.deliver(context, mapOf("type" to "stop"))
            }
            Notifier.ACTION_DISMISS -> {
                val from = intent.getLongExtra("from", 0)
                val id = intent.getLongExtra("id", 0)
                Notifier.stopRing(context, from, id)
                BgBridge.deliver(context, mapOf("type" to "dismiss", "from" to from, "id" to id))
            }
            Notifier.ACTION_WX_DISMISS -> {
                Notifier.stopWx(context, intent.getLongExtra("id", 0).toInt())
            }
            Notifier.ACTION_STOP_AUDIO -> {
                BgBridge.deliver(context, mapOf("type" to "stopAudio"))
            }
            Notifier.ACTION_TALK -> {
                BgBridge.deliver(context, mapOf("type" to "hwKey", "src" to "notif", "down" to true))
            }
            Notifier.ACTION_PLAY -> {
                BgBridge.deliver(
                    context,
                    mapOf("type" to "play", "key" to (intent.getStringExtra("key") ?: "")),
                )
            }
        }
    }
}
