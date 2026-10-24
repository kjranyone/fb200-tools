package dev.fb200.fb200_nam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent

class MainActivity : FlutterActivity() {
    private var authPaused = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.fb200/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "requestBluetoothEnable" -> try {
                        // Needs BLUETOOTH_CONNECT on API 31+, granted before the picker asks.
                        startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.fb200/tone3000")
            .setMethodCallHandler { call, result ->
                if (call.method != "select") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val uri = call.argument<String>("url")?.let { Uri.parse(it) }
                if (uri == null || uri.scheme != "https" ||
                    uri.host != "www.tone3000.com" || uri.path != "/api/v1/oauth/authorize" ||
                    uri.userInfo != null || (uri.port != -1 && uri.port != 443)) {
                    result.error("INVALID_URL", "Invalid authorization endpoint", null)
                } else if (ToneAuthSession.pending != null) {
                    result.error("BUSY", "Authorization already in progress", null)
                } else {
                    ToneAuthSession.pending = result
                    authPaused = false
                    try {
                        CustomTabsIntent.Builder().build().launchUrl(this, uri)
                    } catch (_: android.content.ActivityNotFoundException) {
                        ToneAuthSession.cancel("NO_BROWSER")
                    }
                }
            }
    }

    override fun onPause() {
        if (ToneAuthSession.pending != null) authPaused = true
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        cancelReturnedAuth()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) cancelReturnedAuth()
    }

    private fun cancelReturnedAuth() {
        if (authPaused) {
            val pending = ToneAuthSession.pending
            // A valid callback clears the pending result before returning here.
            // A plain browser-back resumes this activity without a callback.
            Handler(Looper.getMainLooper()).postDelayed({
                if (pending != null && ToneAuthSession.pending === pending && hasWindowFocus()) {
                    authPaused = false
                    ToneAuthSession.cancel("CANCELED")
                }
            }, 350)
        }
    }
}
