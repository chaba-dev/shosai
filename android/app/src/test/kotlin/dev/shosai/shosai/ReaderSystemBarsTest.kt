package dev.shosai.shosai

import android.app.Activity
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.view.View
import android.view.WindowManager.LayoutParams
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Window-policy regression, not a device/window-manager geometry test. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 28, 29, 30, 34, 35])
class ReaderSystemBarsTest {
    @Suppress("DEPRECATION")
    @Test
    fun `both bar states draw behind the cutout and system bars`() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val window = controller.get().window
        window.statusBarColor = Color.BLUE
        window.navigationBarColor = Color.RED
        val statusBarColor = window.statusBarColor
        val navigationBarColor = window.navigationBarColor
        val layoutFlags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        for (shown in listOf(false, true, false, true)) {
            ReaderSystemBars.apply(window, shown)
            if (Build.VERSION.SDK_INT >= 28) {
                assertEquals(
                    if (Build.VERSION.SDK_INT >= 30) LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    else LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES,
                    window.attributes.layoutInDisplayCutoutMode,
                )
            }
            // WindowCompat uses flags through API 29 and setDecorFits... on 30+.
            if (Build.VERSION.SDK_INT < 30) {
                assertEquals(layoutFlags, window.decorView.systemUiVisibility and layoutFlags)
                assertEquals(
                    !shown,
                    window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN != 0,
                )
                assertEquals(
                    !shown,
                    window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION != 0,
                )
            }
            // Layout policy does not take over the app's overlay styling.
            assertEquals(statusBarColor, window.statusBarColor)
            assertEquals(navigationBarColor, window.navigationBarColor)
        }
        controller.pause().stop().destroy()
    }

    @Test
    fun `turn edges are the middle 200 dp of each gesture zone`() {
        // A 1080 × 2400 px phone at 2.625 density with 63 px gesture zones.
        assertEquals(
            listOf(Rect(0, 937, 63, 1462), Rect(1017, 937, 1080, 1462)),
            ReaderSystemBars.turnEdgeRects(1080, 2400, 2.625f, 63, 63),
        )
        // Three-button navigation has no side zones to take over.
        assertEquals(emptyList<Rect>(), ReaderSystemBars.turnEdgeRects(1080, 2400, 2.625f, 0, 0))
        // A window shorter than 200 dp gives all of its height.
        assertEquals(
            listOf(Rect(0, 0, 40, 300), Rect(460, 0, 500, 300)),
            ReaderSystemBars.turnEdgeRects(500, 300, 2f, 40, 40),
        )
        assertEquals(emptyList<Rect>(), ReaderSystemBars.turnEdgeRects(0, 0, 2f, 40, 40))
    }
}
