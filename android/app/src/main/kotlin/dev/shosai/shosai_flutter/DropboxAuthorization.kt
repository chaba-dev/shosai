package dev.shosai.shosai_flutter

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.dropbox.core.DbxRequestConfig
import com.dropbox.core.android.Auth
import com.dropbox.core.android.AuthActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** Observe real SDK retirement, not an unrelated resume of Flutter's Activity.
 * The manifest alias lets the unmodified SDK launch this AuthActivity subclass.
 */
class DropboxAuthActivity : AuthActivity() {
    private var expectedState: String? = null

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        expectedState = state?.getString("dropboxAuthState")
        DropboxAuthorization.started(this)
    }

    override fun onSaveInstanceState(state: Bundle) {
        state.putString("dropboxAuthState", expectedState)
        super.onSaveInstanceState(state)
    }

    override fun startActivity(intent: Intent) {
        // Public SDK wire protocol: native uses AUTH_STATE, browser uses state.
        expectedState = intent.getStringExtra("AUTH_STATE")
            ?: intent.data?.let { uri ->
                if (uri.isHierarchical) uri.getQueryParameter("state") else null
            } ?: expectedState
        super.startActivity(intent)
    }

    override fun onNewIntent(intent: Intent) {
        val state = if (intent.hasExtra("ACCESS_TOKEN")) {
            intent.getStringExtra("AUTH_STATE")
        } else {
            intent.data?.let { uri ->
                if (uri.isHierarchical) uri.getQueryParameters("state").singleOrNull() else null
            }
        }
        // Let the SDK validate/exchange only this attempt's response. Its own
        // state-mismatch path finishes the session, which would cancel a newer
        // attempt if an old browser/app callback arrived after a timeout.
        if (expectedState != null && state == expectedState) super.onNewIntent(intent)
    }

    internal fun cancelAuthorization() {
        // The SDK's public callback entry point rejects this empty result and
        // retires its process-global PKCE session before calling finish().
        super.onNewIntent(Intent())
    }

    override fun onDestroy() {
        if (isFinishing) {
            // A singleTask launcher can clear this Activity without invoking
            // the SDK's normal callback. Explicitly retire that abandoned flow.
            if (AuthActivity.result == null) cancelAuthorization()
            DropboxAuthorization.retired(this)
        }
        super.onDestroy()
    }
}

/** Only the short-lived SDK handshake is native. Dart owns each vault entry.
 * The SDK has process-global state, so serialize across Activity recreation.
 */
internal object DropboxAuthorization {
    private val main = Handler(Looper.getMainLooper())
    private var host = WeakReference<MainActivity>(null)
    private var sdk = WeakReference<DropboxAuthActivity>(null)
    private var pending: MethodChannel.Result? = null
    private var active = false
    private val timeout = Runnable {
        // Do not launch another SDK session until this external flow returns.
        pending?.error("timeout", null, null)
        pending = null
        sdk.get()?.cancelAuthorization()
    }

    fun attach(activity: MainActivity, engine: FlutterEngine) {
        host = WeakReference(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.shosai/dropbox_authorization")
            .setMethodCallHandler { call, result ->
                if (call.method != "authorize") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val key = call.argument<String>("clientId")
                val current = host.get()
                if (active || current == null) {
                    result.error("busy", null, null)
                } else if (key.isNullOrEmpty() || key != BuildConfig.DROPBOX_APP_KEY) {
                    result.error("configuration", null, null)
                } else {
                    try {
                        @Suppress("DEPRECATION")
                        val valid = AuthActivity.checkAppBeforeAuth(current, key, false)
                        if (!valid) {
                            result.error("configuration", null, null)
                            return@setMethodCallHandler
                        }
                        AuthActivity.result = null
                        pending = result
                        active = true
                        main.postDelayed(timeout, 5 * 60 * 1000L)
                        Auth.startOAuth2PKCE(
                            current, key, DbxRequestConfig("shosai"),
                            listOf("files.metadata.read", "files.content.read", "files.content.write"),
                        )
                    } catch (_: Exception) {
                        if (pending == null) result.error("configuration", null, null)
                        else finishError()
                    }
                }
            }
    }

    fun started(activity: DropboxAuthActivity) {
        sdk = WeakReference(activity)
        if (!active || pending == null) main.post { activity.cancelAuthorization() }
    }

    fun retired(activity: DropboxAuthActivity) {
        if (sdk.get() !== activity) return
        sdk.clear()
        val result = pending
        pending = null
        active = false
        main.removeCallbacks(timeout)
        try {
            val credential = Auth.getDbxCredential()
            val refresh = credential?.refreshToken
            val expires = credential?.expiresAt
            if (credential == null) {
                // SDK cancellation, invalid callback and exchange failure are
                // indistinguishable; never fabricate a detailed OAuth error.
                result?.success(null)
            } else if (refresh.isNullOrEmpty() || expires == null ||
                credential.accessToken.isEmpty() || expires <= System.currentTimeMillis()) {
                result?.error("incomplete", null, null)
            } else {
                // Browser auth can finish in a separate task while Chrome
                // remains foreground. Reveal the existing Flutter task before
                // handing it the result; never resurrect an expired operation.
                if (result != null) activity.startActivity(
                    Intent(activity, MainActivity::class.java).addFlags(
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    ),
                )
                result?.success(mapOf(
                    "access_token" to credential.accessToken,
                    "refresh_token" to refresh,
                    "expires_in" to (expires - System.currentTimeMillis()) / 1000,
                ))
            }
        } finally {
            AuthActivity.result = null
        }
    }

    fun detach(activity: MainActivity, recreating: Boolean) {
        if (host.get() !== activity) return
        host.clear()
        if (!recreating) {
            pending?.success(null)
            pending = null
            sdk.get()?.cancelAuthorization()
        }
    }

    private fun finishError() {
        main.removeCallbacks(timeout)
        val result = pending
        pending = null
        active = false
        AuthActivity.result = null
        result?.error("authorization", null, null)
    }
}
