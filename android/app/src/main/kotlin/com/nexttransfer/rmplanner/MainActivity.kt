package com.nexttransfer.rmplanner

import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // One-tap backup: writes the portable backup into the user-visible
        // Downloads folder via MediaStore, with no storage permission.
        BackupDownloadsWriter.register(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                BackupDownloadsWriter.CHANNEL,
            ),
            this,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.nexttransfer.rmplanner/social_app_home",
        ).setMethodCallHandler { call, result ->
            if (call.method != "launchAppHome") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val packageName = call.argument<String>("packageName")
            if (packageName.isNullOrBlank()) {
                result.success(false)
                return@setMethodCallHandler
            }
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent == null) {
                result.success(false)
                return@setMethodCallHandler
            }
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                result.success(true)
            } catch (_: ActivityNotFoundException) {
                result.success(false)
            }
        }
    }
}
