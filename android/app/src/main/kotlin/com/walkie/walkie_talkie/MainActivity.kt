package com.walkie.walkie_talkie

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Uses the process-wide engine from [EngineHolder] and leaves it running when
 * the screen closes, so the app stays reachable in the background.
 * Platform channels live in [NetUpdateBridge] and [BgBridge].
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = EngineHolder.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notifier.ensureChannels(this)
        // Voices play on the media stream: make the volume buttons change
        // that (not the ringer) while the app is open, on every phone.
        volumeControlStream = android.media.AudioManager.STREAM_MUSIC
        if (savedInstanceState == null) handle(intent)
    }

    // Hold volume-down to talk (setting). The accessibility service, when
    // enabled, sees the key first and handles it everywhere.
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (!PttKeys.a11yConnected && PttKeys.onVolumeKey(this, event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        val i = intent ?: return
        val from = i.getLongExtra("from", 0)
        val id = i.getLongExtra("id", 0)
        val channel = i.getIntExtra("channel", 0)
        when (i.action) {
            Notifier.ACTION_ANSWER -> {
                showOverLockScreen()
                Notifier.stopRing(this, from, id)
                BgBridge.deliver(
                    this,
                    mapOf("type" to "answer", "from" to from, "id" to id, "channel" to channel),
                )
            }
            Notifier.ACTION_RING_OPEN -> {
                showOverLockScreen()
                BgBridge.deliver(
                    this,
                    mapOf("type" to "ringOpen", "from" to from, "id" to id, "channel" to channel),
                )
            }
            Notifier.ACTION_SOS_OPEN -> {
                showOverLockScreen()
                BgBridge.deliver(this, mapOf("type" to "sosOpen", "from" to from, "id" to id))
            }
            Notifier.ACTION_OPEN_INBOX -> {
                BgBridge.deliver(this, mapOf("type" to "openInbox", "key" to (i.getStringExtra("key") ?: "")))
            }
            Notifier.ACTION_OPEN_FRIEND -> {
                BgBridge.deliver(this, mapOf("type" to "openFriend", "friend" to i.getLongExtra("friend", 0)))
            }
            Notifier.ACTION_OPEN_CHANNEL -> {
                BgBridge.deliver(this, mapOf("type" to "openChannel", "channel" to channel))
            }
        }
    }

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }
}
