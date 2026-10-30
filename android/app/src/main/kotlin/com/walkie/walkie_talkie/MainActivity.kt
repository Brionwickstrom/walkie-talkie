package com.walkie.walkie_talkie

import android.content.Context
import android.content.Intent
import android.os.Build
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Uses the process-wide engine from [EngineHolder] and leaves it running when
 * the screen closes, so the app stays reachable in the background.
 * Platform channels live in [NetUpdateBridge] and [BgBridge].
 */
class MainActivity : FlutterActivity() {
    companion object {
        /** Largest file taken from a share (MBTiles up to 1.5 GB). */
        const val MAX_IMPORT_BYTES = 1610612736L
    }

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
        // v1.8.7: invite link walkietalkie://join?... -> confirm in Dart.
        if (i.action == Intent.ACTION_VIEW && i.data?.scheme == "walkietalkie") {
            BgBridge.deliver(this, mapOf("type" to "joinLink", "url" to i.data.toString()))
            return
        }
        when (i.action) {
            Intent.ACTION_VIEW, Intent.ACTION_SEND -> importShared(i)
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
            Notifier.ACTION_WX_OPEN -> {
                showOverLockScreen()
                Notifier.stopWx(this, i.getLongExtra("id", 0).toInt())
                BgBridge.deliver(this, mapOf("type" to "wxOpen"))
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

    /**
     * A trail / map file opened with or shared to the app: copy it into the
     * cache (content URIs are only readable for a while) and hand the path
     * to Dart, which imports it on the Trip tab and deletes the copy.
     */
    private fun importShared(i: Intent) {
        @Suppress("DEPRECATION")
        val uri: Uri = (if (i.action == Intent.ACTION_SEND) {
            if (Build.VERSION.SDK_INT >= 33) {
                i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                i.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            }
        } else i.data) ?: return
        val app = applicationContext
        Thread {
            try {
                var name = "import"
                if (uri.scheme == "content") {
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                        if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
                    }
                } else {
                    name = uri.lastPathSegment ?: name
                }
                val safe = name.replace(Regex("[^\\w.\\- ]"), "_").take(80)
                val dir = File(cacheDir, "imports").apply { mkdirs() }
                val out = File(dir, "${System.currentTimeMillis()}_$safe")
                var total = 0L
                contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { o ->
                        val buf = ByteArray(1 shl 16)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            total += n
                            if (total > MAX_IMPORT_BYTES) throw IllegalStateException("too big")
                            o.write(buf, 0, n)
                        }
                    }
                } ?: return@Thread
                BgBridge.deliver(app, mapOf("type" to "importFile", "path" to out.absolutePath, "name" to name))
            } catch (e: Exception) {
                BgBridge.deliver(app, mapOf("type" to "importFailed", "name" to (uri.lastPathSegment ?: ""), "error" to (e.message ?: "")))
            }
        }.start()
    }

    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }
}
