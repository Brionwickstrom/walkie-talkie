package com.walkie.walkie_talkie

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Optional: start listening after a reboot or an app update. */
class BootReceiver : BroadcastReceiver() {
    companion object {
        const val PREFS = "walkie_bg"
        const val KEY_BOOT = "start_on_boot"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val a = intent.action
        if (a != Intent.ACTION_BOOT_COMPLETED && a != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val on = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_BOOT, false)
        if (!on) return
        try {
            ListenService.start(context, "Stalkie Talkie is listening", "Starting up...", false, false, false)
        } catch (_: Exception) {
        }
    }
}
