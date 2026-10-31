package dev.shosai.shosai

import android.os.Build
import android.view.Window
import android.view.WindowManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
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
                when {
                    call.method == "getStableInsets" -> {
                        val insets = host.get()?.window?.decorView
                            ?.let(ViewCompat::getRootWindowInsets)
                            ?.getInsetsIgnoringVisibility(
                                WindowInsetsCompat.Type.systemBars() or
                                    WindowInsetsCompat.Type.displayCutout(),
                            )
                        // Physical pixels, in LTRB order. Never include the IME.
                        result.success(insets?.let { listOf(it.left, it.top, it.right, it.bottom) })
                    }
                    call.method == "setShown" && call.arguments is Boolean -> {
                        shown = call.arguments as Boolean
                        host.get()?.let(::restore)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        restore(activity)
    }

    fun restore(activity: MainActivity) {
        if (host.get() !== activity) return
        apply(activity.window, shown)
    }

    /** Visibility must never change the Flutter surface's bounds, including
     * on pre-Android-15 devices where edge-to-edge is not enforced by the OS.
     * Reapply after focus/resume because Flutter's platform plugin also writes
     * the window's system UI policy. Insets are handled inside Flutter.
     */
    @Suppress("DEPRECATION")
    internal fun apply(window: Window, shown: Boolean) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (shown) show(WindowInsetsCompat.Type.systemBars())
            else hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    fun detach(activity: MainActivity) {
        if (host.get() === activity) host.clear()
    }
}
