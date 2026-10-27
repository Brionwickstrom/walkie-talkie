package com.walkie.walkie_talkie

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.NotificationCompat

/** Notification channels, notifications and the ring / chirp sounds. */
object Notifier {
    const val CH_LISTEN = "listen_v1"
    const val CH_RING = "ring_v1"
    const val CH_TALK = "talk_v1"
    const val CH_MSG = "msg_v1"
    const val CH_URGENT = "urgent_v1"
    const val CH_URGENT_DND = "urgent_dnd_v1"

    const val ACTION_STOP = "com.walkie.walkie_talkie.STOP"
    const val ACTION_DISMISS = "com.walkie.walkie_talkie.DISMISS"
    const val ACTION_PLAY = "com.walkie.walkie_talkie.PLAY"
    const val ACTION_ANSWER = "com.walkie.walkie_talkie.ANSWER"
    const val ACTION_RING_OPEN = "com.walkie.walkie_talkie.RING_OPEN"
    const val ACTION_OPEN_INBOX = "com.walkie.walkie_talkie.OPEN_INBOX"
    const val ACTION_OPEN_CHANNEL = "com.walkie.walkie_talkie.OPEN_CHANNEL"
    const val ACTION_OPEN_FRIEND = "com.walkie.walkie_talkie.OPEN_FRIEND"
    const val ACTION_TALK = "com.walkie.walkie_talkie.TALK"
    const val ACTION_STOP_AUDIO = "com.walkie.walkie_talkie.STOP_AUDIO"
    const val ACTION_SOS_OPEN = "com.walkie.walkie_talkie.SOS_OPEN"
    private const val SOS_MS = 5 * 60000L
    private const val SOS_KEY_BIT = 1L shl 40

    private const val RING_MS = 15000L
    private const val URGENT_MS = 60000L
    private var ringMs = RING_MS
    private val main = Handler(Looper.getMainLooper())
    private var ringPlayer: MediaPlayer? = null
    private var ringKey: Pair<Long, Long>? = null
    private val stopRingTask = Runnable { stopRingSound() }

    private const val FLAGS = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_LISTEN, "Listening in background", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while the app stays reachable after you close it"
                setShowBadge(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_RING, "Rings", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "When someone rings you (the app plays its own ring tone)"
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 400, 600, 400, 600)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_URGENT, "Urgent rings", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Urgent rings repeat for up to a minute (the app plays its own alarm tone)"
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = URGENT_PATTERN
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
        // Created only once Do Not Disturb access is granted: then Android
        // lets this channel through DND.
        if (nm.isNotificationPolicyAccessGranted && nm.getNotificationChannel(CH_URGENT_DND) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CH_URGENT_DND, "Urgent rings (through Do Not Disturb)", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Urgent rings while Do Not Disturb is on"
                    setSound(null, null)
                    enableVibration(true)
                    vibrationPattern = URGENT_PATTERN
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                },
            )
        }
        nm.createNotificationChannel(
            NotificationChannel(CH_TALK, "Someone is talking", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Live push-to-talk while the app is closed"
                setSound(null, null)
                enableVibration(false)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_MSG, "Voice messages and beeps", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Voice messages and beeps from other phones"
            },
        )
    }

    private fun nm(ctx: Context): NotificationManager =
        ctx.getSystemService(NotificationManager::class.java)

    private fun post(ctx: Context, id: Int, n: Notification) {
        try {
            nm(ctx).notify(id, n)
        } catch (_: Exception) {
            // No notification permission: sounds still play.
        }
    }

    fun cancel(ctx: Context, id: Int) {
        try {
            nm(ctx).cancel(id)
        } catch (_: Exception) {
        }
    }

    private fun activityIntent(ctx: Context, action: String, code: Int, extras: Intent.() -> Unit = {}): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            this.action = action
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            extras()
        }
        return PendingIntent.getActivity(ctx, code, i, FLAGS)
    }

    private fun broadcastIntent(ctx: Context, action: String, code: Int, extras: Intent.() -> Unit = {}): PendingIntent {
        val i = Intent(ctx, ActionReceiver::class.java).apply {
            this.action = action
            extras()
        }
        return PendingIntent.getBroadcast(ctx, code, i, FLAGS)
    }

    private fun openApp(ctx: Context): PendingIntent {
        val i = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent(ctx, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(ctx, 1, i, FLAGS)
    }

    fun listening(ctx: Context, title: String, text: String, talk: Boolean = false, talking: Boolean = false): Notification {
        ensureChannels(ctx)
        val b = NotificationCompat.Builder(ctx, CH_LISTEN)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle(if (talking) "You are talking - others hear you" else title)
            .setContentText(if (talking) "Tap \"Stop talking\" when done" else text)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(openApp(ctx))
        if (talk) {
            b.addAction(0, if (talking) "Stop talking" else "Talk", broadcastIntent(ctx, ACTION_TALK, 3))
        }
        b.addAction(0, "Stop audio", broadcastIntent(ctx, ACTION_STOP_AUDIO, 4))
        return b.addAction(0, "Stop", broadcastIntent(ctx, ACTION_STOP, 2))
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun ringId(from: Long, id: Long): Int = (2000000 + ((from xor id) and 0xFFFFF)).toInt()

    fun showRing(ctx: Context, from: Long, id: Long, name: String, channel: Int, urgent: Boolean = false, loud: Boolean = true) {
        ensureChannels(ctx)
        val nid = ringId(from, id)
        val put: Intent.() -> Unit = {
            putExtra("from", from)
            putExtra("id", id)
            putExtra("channel", channel)
        }
        val full = activityIntent(ctx, ACTION_RING_OPEN, nid, put)
        val answer = activityIntent(ctx, ACTION_ANSWER, nid + 1, put)
        val dismiss = broadcastIntent(ctx, ACTION_DISMISS, nid + 2, put)
        val dnd = nm(ctx).isNotificationPolicyAccessGranted
        val chId = if (!urgent) CH_RING else if (dnd && loud) CH_URGENT_DND else CH_URGENT
        val ms = if (urgent) URGENT_MS else RING_MS
        val n = NotificationCompat.Builder(ctx, chId)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle(if (urgent) "URGENT: $name is ringing you" else "$name is ringing you")
            .setContentText("Channel $channel - tap Answer to talk")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setTimeoutAfter(ms + 5000)
            .setContentIntent(full)
            .setFullScreenIntent(full, true)
            .setDeleteIntent(dismiss)
            .addAction(0, "Answer", answer)
            .addAction(0, "Dismiss", dismiss)
            .build()
        post(ctx, nid, n)
        startRingSound(ctx, from to id, urgent, loud)
    }

    fun stopRing(ctx: Context, from: Long, id: Long) {
        cancel(ctx, ringId(from, id))
        if (ringKey == null || ringKey == (from to id)) stopRingSound()
    }

    private fun sosId(from: Long, id: Long): Int = (7000000 + ((from xor id) and 0xFFFFF)).toInt()

    /**
     * Trip SOS (v1.8.0): full-screen alert and the alarm tone at alarm
     * volume (through silent mode, and through Do Not Disturb when access
     * was granted) for up to [SOS_MS], until the user acknowledges in the
     * app or the sender cancels.
     */
    fun showSos(ctx: Context, from: Long, id: Long, name: String, text: String) {
        ensureChannels(ctx)
        val nid = sosId(from, id)
        val put: Intent.() -> Unit = {
            putExtra("from", from)
            putExtra("id", id)
        }
        val full = activityIntent(ctx, ACTION_SOS_OPEN, nid, put)
        val dnd = nm(ctx).isNotificationPolicyAccessGranted
        val n = NotificationCompat.Builder(ctx, if (dnd) CH_URGENT_DND else CH_URGENT)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle("SOS from $name")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(full)
            .setFullScreenIntent(full, true)
            .addAction(0, "Open", full)
            .build()
        post(ctx, nid, n)
        startRingSound(ctx, from to (id or SOS_KEY_BIT), urgent = true, loud = true, ms = SOS_MS)
    }

    fun stopSos(ctx: Context, from: Long, id: Long) {
        cancel(ctx, sosId(from, id))
        if (ringKey == (from to (id or SOS_KEY_BIT))) stopRingSound()
    }

    /** Silence the alarm only (the alert stays on screen). */
    fun silenceSos() {
        val k = ringKey ?: return
        if (k.second and SOS_KEY_BIT != 0L) stopRingSound()
    }

    fun showBeep(ctx: Context, from: Long, name: String, notify: Boolean) {
        playOnce(ctx, R.raw.chirp)
        if (!notify) return
        ensureChannels(ctx)
        val n = NotificationCompat.Builder(ctx, CH_MSG)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle("$name beeped you")
            .setContentText("Tap to open Walkie Talkie")
            .setAutoCancel(true)
            .setSilent(true)
            .setTimeoutAfter(5 * 60 * 1000L)
            .setContentIntent(openApp(ctx))
            .build()
        post(ctx, (3000000 + (from and 0xFFFFF)).toInt(), n)
    }

    private fun talkId(peer: Long): Int = (4000000 + (peer and 0xFFFFF)).toInt()

    fun showTalking(ctx: Context, peer: Long, name: String, channel: Int, friend: Boolean = false) {
        ensureChannels(ctx)
        // Private talk from a friend opens that friend's chat (reply
        // privately there), never the channel.
        val open = if (friend) {
            activityIntent(ctx, ACTION_OPEN_FRIEND, 6000 + (peer and 0xFFFF).toInt()) { putExtra("friend", peer) }
        } else {
            activityIntent(ctx, ACTION_OPEN_CHANNEL, 5) { putExtra("channel", channel) }
        }
        val n = NotificationCompat.Builder(ctx, CH_TALK)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle(if (friend) "\uD83D\uDD12 $name is talking to you privately" else "$name is talking")
            .setContentText(if (friend) "Tap to reply privately" else "Channel $channel")
            .setOngoing(true)
            .setSilent(true)
            .setTimeoutAfter(2 * 60 * 1000L)
            .setContentIntent(open)
            .build()
        post(ctx, talkId(peer), n)
    }

    fun cancelTalking(ctx: Context, peer: Long) = cancel(ctx, talkId(peer))

    fun showVoiceMessage(ctx: Context, key: String, nid: Int, name: String, duration: String, silent: Boolean = false) {
        ensureChannels(ctx)
        val id = 5000000 + (nid and 0xFFFFF)
        val n = NotificationCompat.Builder(ctx, CH_MSG)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle("Voice message from $name ($duration)")
            .setContentText("Tap Play to listen")
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setSilent(silent)
            .setContentIntent(activityIntent(ctx, ACTION_OPEN_INBOX, id) { putExtra("key", key) })
            .addAction(0, "Play", broadcastIntent(ctx, ACTION_PLAY, id) { putExtra("key", key) })
            .addAction(0, "Stop audio", broadcastIntent(ctx, ACTION_STOP_AUDIO, id + 1))
            .build()
        post(ctx, id, n)
    }

    fun showInfo(ctx: Context, nid: Int, title: String, text: String) {
        ensureChannels(ctx)
        val n = NotificationCompat.Builder(ctx, CH_MSG)
            .setSmallIcon(R.drawable.ic_stat_walkie)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setSilent(true)
            .setContentIntent(openApp(ctx))
            .build()
        post(ctx, 6000000 + (nid and 0xFFFFF), n)
    }

    private fun resUri(ctx: Context, res: Int): Uri =
        Uri.parse("android.resource://${ctx.packageName}/$res")

    private val URGENT_PATTERN = longArrayOf(0, 250, 120, 250, 120, 250, 500, 900, 400)
    private var savedFilter: Int? = null
    private var savedAlarmVolume: Int? = null

    /** Urgent + loud: through Do Not Disturb (if allowed) and at a
     *  reasonable alarm volume, both put back when the ring stops. */
    private fun overrideQuiet(ctx: Context) {
        try {
            val nm = nm(ctx)
            if (nm.isNotificationPolicyAccessGranted &&
                nm.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL &&
                nm.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
            ) {
                savedFilter = nm.currentInterruptionFilter
                nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL)
            }
        } catch (_: Exception) {
        }
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_ALARM)
            val cur = am.getStreamVolume(android.media.AudioManager.STREAM_ALARM)
            val want = (max * 0.7).toInt().coerceAtLeast(1)
            if (cur < want) {
                savedAlarmVolume = cur
                am.setStreamVolume(android.media.AudioManager.STREAM_ALARM, want, 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun restoreQuiet() {
        val ctx = appCtx ?: return
        savedAlarmVolume?.let {
            try {
                val am = ctx.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                am.setStreamVolume(android.media.AudioManager.STREAM_ALARM, it, 0)
            } catch (_: Exception) {
            }
        }
        savedAlarmVolume = null
        savedFilter?.let {
            try {
                nm(ctx).setInterruptionFilter(it)
            } catch (_: Exception) {
            }
        }
        savedFilter = null
    }

    private var urgentNow = false

    private fun startRingSound(ctx: Context, key: Pair<Long, Long>, urgent: Boolean, loud: Boolean, ms: Long? = null) {
        main.post {
            stopRingSound()
            ringKey = key
            appCtx = ctx.applicationContext
            val alarm = urgent && loud
            urgentNow = urgent
            ringMs = ms ?: if (urgent) URGENT_MS else RING_MS
            if (alarm) overrideQuiet(ctx)
            try {
                val mp = MediaPlayer()
                mp.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(
                            if (alarm) AudioAttributes.USAGE_ALARM
                            else AudioAttributes.USAGE_NOTIFICATION_RINGTONE,
                        )
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                mp.setDataSource(ctx.applicationContext, resUri(ctx, R.raw.ring))
                mp.isLooping = true
                mp.prepare()
                mp.start()
                ringPlayer = mp
            } catch (_: Exception) {
            }
            vibrate(ctx, true)
            main.postDelayed(stopRingTask, ringMs)
        }
    }

    private var appCtx: Context? = null

    private fun stopRingSound() {
        main.removeCallbacks(stopRingTask)
        ringKey = null
        try {
            ringPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            ringPlayer?.release()
        } catch (_: Exception) {
        }
        ringPlayer = null
        appCtx?.let { vibrate(it, false) }
        restoreQuiet()
        urgentNow = false
    }

    @Suppress("DEPRECATION")
    private fun vibrate(ctx: Context, on: Boolean) {
        try {
            appCtx = ctx.applicationContext
            val v = ctx.applicationContext.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
            if (!on) {
                v.cancel()
                return
            }
            val pattern = if (urgentNow) URGENT_PATTERN else longArrayOf(0, 700, 500)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (urgentNow) {
                    // Alarm usage: vibrates even in silent mode.
                    v.vibrate(
                        VibrationEffect.createWaveform(pattern, 0),
                        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
                    )
                } else {
                    v.vibrate(VibrationEffect.createWaveform(pattern, 0))
                }
            } else {
                v.vibrate(pattern, 0)
            }
        } catch (_: Exception) {
        }
    }

    private fun playOnce(ctx: Context, res: Int) {
        main.post {
            try {
                val mp = MediaPlayer()
                mp.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                mp.setDataSource(ctx.applicationContext, resUri(ctx, res))
                mp.setOnCompletionListener { it.release() }
                mp.prepare()
                mp.start()
            } catch (_: Exception) {
            }
        }
    }
}
