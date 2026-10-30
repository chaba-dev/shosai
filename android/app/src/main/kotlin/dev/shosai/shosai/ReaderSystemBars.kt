package dev.shosai.shosai

import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Immersive reading is independent of Android 16's mandatory edge-to-edge layout.
 * Flutter's legacy SystemUiMode.manual does not support our target SDK (36).
 * The reader controller owns visibility and IME restoration timing.
 */
internal object ReaderSystemBars {
    private var host = WeakReference<MainActivity>(null)
    private var shown = true

    fun attach(activity: MainActivity, engine: FlutterEngine) {
        host = WeakReference(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.shosai/reader_system_bars")
            .setMethodCallHandler { call, result ->
                if (call.method != "setShown" || call.arguments !is Boolean) {
                    result.notImplemented()
                } else {
                    shown = call.arguments as Boolean
                    host.get()?.let(::restore)
                    result.success(null)
                }
            }
    }

    fun restore(activity: MainActivity) {
        if (host.get() !== activity) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.window.insetsController?.apply {
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                if (shown) show(WindowInsets.Type.systemBars())
                else hide(WindowInsets.Type.systemBars())
            }
        } else {
            @Suppress("DEPRECATION")
            val hiddenFlags = View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            @Suppress("DEPRECATION")
            activity.window.decorView.systemUiVisibility =
                (activity.window.decorView.systemUiVisibility and hiddenFlags.inv()) or
                    if (shown) 0 else hiddenFlags
        }
    }

    fun detach(activity: MainActivity) {
        if (host.get() === activity) host.clear()
    }
}
