package com.walkie.walkie_talkie

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent

/**
 * Hardware talk buttons:
 *  - volume-down (in the app via [MainActivity.dispatchKeyEvent]; with the
 *    screen on and the app in the background via [PttAccessibilityService]),
 *  - headset play/pause / hook buttons via a [MediaSession] that lives while
 *    the listening service runs.
 * Presses go to Dart as `hwKey` actions: {src: vol|headset|notif, down}.
 */
object PttKeys {
    @Volatile
    var volumeEnabled = false

    @Volatile
    var headsetEnabled = false

    /** Accessibility service connected (it then sees keys first). */
    @Volatile
    var a11yConnected = false

    private var volDown = false
    private val main = Handler(Looper.getMainLooper())
    private var session: MediaSession? = null

    fun configure(ctx: Context, volume: Boolean, headset: Boolean) {
        volumeEnabled = volume
        headsetEnabled = headset
        if (!volume && volDown) {
            volDown = false
            send(ctx, "vol", false)
        }
        updateSession(ctx)
    }

    /** Returns true if the event was used (so the volume does not change). */
    fun onVolumeKey(ctx: Context, event: KeyEvent): Boolean {
        if (!volumeEnabled || event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return false
        when (event.action) {
            KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0 && !volDown) {
                volDown = true
                send(ctx, "vol", true)
            }
            KeyEvent.ACTION_UP -> if (volDown) {
                volDown = false
                send(ctx, "vol", false)
            }
        }
        return true
    }

    fun send(ctx: Context, src: String, down: Boolean) {
        BgBridge.deliver(ctx, mapOf("type" to "hwKey", "src" to src, "down" to down))
    }

    fun a11yEnabled(ctx: Context): Boolean {
        val want = ComponentName(ctx, PttAccessibilityService::class.java).flattenToString()
        val list = Settings.Secure.getString(
            ctx.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return list.split(':').any { it.equals(want, ignoreCase = true) }
    }

    /** MediaSession for headset buttons while listening in the background. */
    fun updateSession(ctx: Context) {
        main.post {
            val want = headsetEnabled && ListenService.running
            if (!want) {
                session?.let {
                    try {
                        it.isActive = false
                        it.release()
                    } catch (_: Exception) {
                    }
                }
                session = null
                return@post
            }
            val s = session ?: try {
                MediaSession(ctx.applicationContext, "walkie_ptt").also { ms ->
                    ms.setCallback(object : MediaSession.Callback() {
                        override fun onMediaButtonEvent(intent: android.content.Intent): Boolean {
                            @Suppress("DEPRECATION")
                            val ev = intent.getParcelableExtra<KeyEvent>(android.content.Intent.EXTRA_KEY_EVENT)
                                ?: return false
                            return onMediaKey(ctx.applicationContext, ev)
                        }
                    })
                    session = ms
                }
            } catch (_: Exception) {
                return@post
            }
            try {
                // "Playing" makes Android send headset buttons here (until
                // another app plays media).
                s.setPlaybackState(
                    PlaybackState.Builder()
                        .setActions(
                            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or
                                PlaybackState.ACTION_PAUSE,
                        )
                        .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                        .build(),
                )
                s.isActive = true
            } catch (_: Exception) {
            }
        }
    }

    private var mediaDown = false

    private fun onMediaKey(ctx: Context, ev: KeyEvent): Boolean {
        when (ev.keyCode) {
            KeyEvent.KEYCODE_HEADSETHOOK, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE,
            -> {
                if (ev.action == KeyEvent.ACTION_DOWN && ev.repeatCount == 0 && !mediaDown) {
                    mediaDown = true
                    send(ctx, "headset", true)
                } else if (ev.action == KeyEvent.ACTION_UP && mediaDown) {
                    mediaDown = false
                    send(ctx, "headset", false)
                }
                return true
            }
        }
        return false
    }
}
