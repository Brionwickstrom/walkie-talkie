package com.walkie.walkie_talkie

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * One Flutter engine for the whole process, independent of the Activity.
 *
 * The Activity borrows it while it is open; closing the app (back button or
 * swiping it from recents) only detaches the screen, so the Dart side keeps
 * the Wi-Fi / Bluetooth links, rings and voice messages alive while the
 * [ListenService] keeps the process running.
 */
object EngineHolder {
    const val ENGINE_ID = "walkie_main"

    @Volatile
    private var engine: FlutterEngine? = null

    /** Must be called on the main thread. */
    @Synchronized
    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val e = FlutterEngine(app)
        NetUpdateBridge(app).attach(e)
        RelayBridge(app).attach(e)
        WifiDirectBridge(app).attach(e)
        BgBridge.attach(app, e)
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, e)
        engine = e
        return e
    }
}
