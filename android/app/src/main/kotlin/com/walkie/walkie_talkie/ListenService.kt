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
        private var talkAction = false
        private var talking = false

        /** Mic allowed for this service run (talk from notification /
         *  headset / volume key while the app is in the background). */
        @Volatile
        var micType = false
            private set
        private var wantMic = false

        /**
         * Returns false if Android refused to start it. [mic]: also claim
         * the microphone type; only allowed while the app is on screen
         * (Android 11+), so pass it from the foreground.
         */
        fun start(ctx: Context, t: String, x: String, mic: Boolean, talk: Boolean, isTalking: Boolean): Boolean {
            if (t.isNotEmpty()) title = t
            text = x
            talkAction = talk
            talking = isTalking
            val micOk = mic && ContextCompat.checkSelfPermission(
                ctx, android.Manifest.permission.RECORD_AUDIO,
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (running && (!micOk || micType)) {
                update(ctx, t, x, talk, isTalking)
                return true
            }
            wantMic = micOk
            return try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, ListenService::class.java))
                true
            } catch (_: Exception) {
                false
            }
        }

        fun update(ctx: Context, t: String, x: String, talk: Boolean, isTalking: Boolean) {
            if (t.isNotEmpty()) title = t
            text = x
            talkAction = talk
            talking = isTalking
            if (!running) return
            try {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                nm.notify(NOTIF_ID, Notifier.listening(ctx, title, text, talkAction, talking))
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
        val n = Notifier.listening(this, title, text, talkAction, talking)
        var ok = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (wantMic) {
                // Microphone type: lets you talk with the app in the
                // background. Android refuses it unless the app is on screen.
                try {
                    ServiceCompat.startForeground(
                        this, NOTIF_ID, n,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                    )
                    micType = true
                    ok = true
                } catch (_: Exception) {
                }
            }
            if (!ok) {
                try {
                    ServiceCompat.startForeground(
                        this, NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                    )
                    if (!running) micType = false
                    ok = true
                } catch (_: Exception) {
                }
            }
        } else {
            try {
                startForeground(NOTIF_ID, n)
                micType = true
                ok = true
            } catch (_: Exception) {
            }
        }
        if (!ok) {
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        acquireWakeLock()
        PttKeys.updateSession(this)
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
        micType = false
        PttKeys.updateSession(this)
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        super.onDestroy()
    }
}
