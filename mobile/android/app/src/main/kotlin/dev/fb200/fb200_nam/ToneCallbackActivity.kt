package dev.fb200.fb200_nam

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel

// Transient only. No authorization codes, PKCE verifiers or tokens are stored.
internal object ToneAuthSession {
    var pending: MethodChannel.Result? = null
    fun complete(callback: String) {
        val result = pending ?: return
        pending = null
        result.success(callback)
    }
    fun cancel(code: String) {
        val result = pending ?: return
        pending = null
        result.error(code, "Authorization did not complete", null)
    }
}

class ToneCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uri = intent?.data
        val pending = ToneAuthSession.pending != null
        if (pending && uri?.scheme == "fb200nam" && uri.host == "oauth" &&
            uri.path == "/callback" && uri.userInfo == null && uri.port == -1) {
            // Dart verifies state, PKCE and the complete callback before exchange.
            ToneAuthSession.complete(uri.toString())
        } else if (pending) {
            ToneAuthSession.cancel("INVALID_CALLBACK")
        }
        if (pending) {
            startActivity(Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        }
        finish()
    }
}
