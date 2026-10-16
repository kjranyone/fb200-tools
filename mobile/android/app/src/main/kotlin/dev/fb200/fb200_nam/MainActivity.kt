package dev.fb200.fb200_nam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Build

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.fb200/platform")
            .setMethodCallHandler { call, result ->
                if (call.method == "androidSdkInt") result.success(Build.VERSION.SDK_INT)
                else result.notImplemented()
            }
    }
}
