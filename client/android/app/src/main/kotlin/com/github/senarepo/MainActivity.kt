package com.github.senarepo

import android.content.Intent
import android.os.Build
import android.os.StatFs
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // APK installer channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.github.senarepo/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath")!!
                        try {
                            val file = File(filePath)
                            val uri = FileProvider.getUriForFile(
                                this@MainActivity,
                                "${applicationContext.packageName}.fileprovider",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Foreground service channel for background downloads
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.github.senarepo/foreground")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this@MainActivity, DownloadForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this@MainActivity, DownloadForegroundService::class.java))
                        result.success(true)
                    }
                    "isRunning" -> {
                        result.success(DownloadForegroundService.isRunning)
                    }
                    else -> result.notImplemented()
                }
            }

        // Storage channel for pre-download free-space checks
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.github.senarepo/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("STORAGE_ERROR", "empty path", null)
                        } else {
                            try {
                                result.success(StatFs(path).availableBytes)
                            } catch (e: Exception) {
                                result.error("STORAGE_ERROR", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
