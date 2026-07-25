package com.translate.livekit.livekit_translate

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android's native on-device STT, offered to Dart as a drop-in for the
        // Whisper recogniser — the Android analogue of iOS's SwayAppleStt
        // registration in SceneDelegate.
        SwayAndroidStt.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
