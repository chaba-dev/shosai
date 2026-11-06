package dev.shosai.shosai

import android.content.ComponentName
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Packaged routing contract; physical-device tests cover browser task reuse. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DropboxBrowserAuthorizationTest {
    @Test
    fun `browser callback activities share the initiating app task affinity`() {
        val app = RuntimeEnvironment.getApplication()
        for (activity in listOf(
            "dev.shosai.shosai.MainActivity",
            "net.openid.appauth.AuthorizationManagementActivity",
            "net.openid.appauth.RedirectUriReceiverActivity",
        )) {
            val info = app.packageManager.getActivityInfo(ComponentName(app, activity), 0)
            assertEquals(activity, app.packageName, info.taskAffinity)
        }
    }
}
