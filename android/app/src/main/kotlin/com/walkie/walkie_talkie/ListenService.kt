package com.walkie.walkie_talkie

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the process (and so the Flutter engine with
 * all its links) alive after the app is closed, with a low-priority
 * "listening on CH n" notification. Type connectedDevice: it keeps Wi-Fi /
 * Bluetooth links to the other phones open (allowed from boot, no time
 * limit on Android 15+). Holds a partial wake lock so beacons and incoming
 * audio are handled with the screen off.
 */
class ListenService : Service() {
    companion object {
        const val NOTIF_ID = 1001

        @Volatile
        var running = false
            private set

        private var title = "Walkie Talkie is listening"
        private var text = "Tap to open"

        /** Returns false if Android refused to start it. */
        fun start(ctx: Context, t: String, x: String): Boolean {
            if (t.isNotEmpty()) title = t
            text = x
            if (running) {
                update(ctx, t, x)
                return true
            }
            return try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, ListenService::class.java))
                true
            } catch (_: Exception) {
                false
            }
        }

        fun update(ctx: Context, t: String, x: String) {
            if (t.isNotEmpty()) title = t
            text = x
            if (!running) return
            try {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                nm.notify(NOTIF_ID, Notifier.listening(ctx, title, text))
            } catch (_: Exception) {
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, ListenService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Notifier.ensureChannels(this)
        // Started from boot / restarted by Android: bring Dart up.
        EngineHolder.get(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = Notifier.listening(this, title, text)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this,
                    NOTIF_ID,
                    n,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (_: Exception) {
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        acquireWakeLock()
        return START_STICKY
    }

    private fun acquireWakeLock() {
        try {
            val lock = wakeLock ?: run {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "walkie:listen").also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
            }
            if (!lock.isHeld) lock.acquire()
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        running = false
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
