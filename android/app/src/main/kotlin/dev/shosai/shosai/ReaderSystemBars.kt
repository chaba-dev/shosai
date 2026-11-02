package dev.shosai.shosai

import android.graphics.Rect
import android.os.Build
import android.view.View
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
    private var turnEdges = false
    private val relayout = View.OnLayoutChangeListener { view, _, _, _, _, _, _, _, _ ->
        applyTurnEdges(view, turnEdges)
    }

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
                    call.method == "setTurnEdges" && call.arguments is Boolean -> {
                        turnEdges = call.arguments as Boolean
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
        val view = activity.window.decorView
        view.removeOnLayoutChangeListener(relayout)
        view.addOnLayoutChangeListener(relayout)
        applyTurnEdges(view, turnEdges)
    }

    /** A drag that turns the page may start at the very edge of the screen,
     * inside the back gesture's zone. While the page is quiet, the middle of
     * each side edge belongs to the page instead. Android honours at most
     * 200 dp of each edge, so the rest of it still goes back.
     */
    internal fun applyTurnEdges(view: View, enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val gestures = ViewCompat.getRootWindowInsets(view)
            ?.getInsets(WindowInsetsCompat.Type.systemGestures())
        view.systemGestureExclusionRects = if (enabled && gestures != null) {
            turnEdgeRects(
                view.width,
                view.height,
                view.resources.displayMetrics.density,
                gestures.left,
                gestures.right,
            )
        } else {
            emptyList()
        }
    }

    /** The middle 200 dp of each side's gesture zone, in [width] × [height]. */
    internal fun turnEdgeRects(
        width: Int,
        height: Int,
        density: Float,
        left: Int,
        right: Int,
    ): List<Rect> {
        if (width <= 0 || height <= 0) return emptyList()
        val band = minOf(height, (200 * density).toInt())
        val top = (height - band) / 2
        return listOfNotNull(
            Rect(0, top, left, top + band).takeIf { left > 0 },
            Rect(width - right, top, width, top + band).takeIf { right > 0 },
        )
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
        activity.window.decorView.removeOnLayoutChangeListener(relayout)
        if (host.get() === activity) host.clear()
    }
}
