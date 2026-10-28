package dev.shosai.shosai

import android.content.Intent
import android.net.Uri
import com.dropbox.core.android.AuthActivity
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** Real SDK callback entry point, without authorizing an account or exchanging
 * tokens. A matching but incomplete response ends the SDK flow; an old response
 * must not end the current Activity. This is not installed-app acceptance.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class DropboxAuthorizationTest {
    @Test
    fun `late browser and native callbacks cannot cancel a new attempt`() {
        val controller = Robolectric.buildActivity(DropboxAuthActivity::class.java)
        val activity = controller.get()
        activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(
            "https://www.dropbox.com/1/connect?state=current-attempt",
        )))
        controller.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(
            "db-${BuildConfig.DROPBOX_APP_KEY}://1/connect?state=previous-attempt",
        )))
        controller.newIntent(Intent().putExtra("ACCESS_TOKEN", "oauth2code:")
            .putExtra("AUTH_STATE", "previous-attempt"))
        controller.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(
            "db-${BuildConfig.DROPBOX_APP_KEY}://1/connect?state=current-attempt&state=other",
        )))
        assertFalse(activity.isFinishing)

        // No live SDK session exists in this test: forwarding this matching
        // response is rejected by the actual SDK and finishes the Activity.
        controller.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(
            "db-${BuildConfig.DROPBOX_APP_KEY}://1/connect?state=current-attempt",
        )))
        assertTrue(activity.isFinishing)
        AuthActivity.result = null
    }

    @Test
    fun `native state is captured and explicit cancellation still retires`() {
        val controller = Robolectric.buildActivity(DropboxAuthActivity::class.java)
        val activity = controller.get()
        activity.startActivity(Intent(AuthActivity.ACTION_AUTHENTICATE_V2)
            .setPackage("com.dropbox.android").putExtra("AUTH_STATE", "current-native"))
        controller.newIntent(Intent().putExtra("ACCESS_TOKEN", "oauth2code:")
            .putExtra("AUTH_STATE", "old-native"))
        assertFalse(activity.isFinishing)
        activity.cancelAuthorization()
        assertTrue(activity.isFinishing)
        AuthActivity.result = null
    }
}
