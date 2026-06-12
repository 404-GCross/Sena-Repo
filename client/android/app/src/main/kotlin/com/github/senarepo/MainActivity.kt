package com.github.senarepo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import net.sf.sevenzipjbinding.*
import net.sf.sevenzipjbinding.impl.RandomAccessFileInStream
import net.sf.sevenzipjbinding.simple.SimpleInArchive
import java.io.File
import java.io.RandomAccessFile

class MainActivity: FlutterActivity() {
    companion object {
        const val CHANNEL = "com.github.senarepo/extractor"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "extract") {
                    try {
                        val filePath = call.argument<String>("filePath")!!
                        val outDir = call.argument<String>("outDir")!!
                        extractArchive(filePath, outDir)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("EXTRACT_ERROR", e.message, null)
                    }
                } else if (call.method == "testArchive") {
                    try {
                        val filePath = call.argument<String>("filePath")!!
                        testArchive(filePath)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("TEST_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun extractArchive(filePath: String, outDir: String) {
        val raf = RandomAccessFile(filePath, "r")
        try {
            val inArchive = SevenZip.openInArchive(null, RandomAccessFileInStream(raf))
            val simple = inArchive.simpleInterface
            for (item in simple.archiveItems) {
                if (!item.isFolder) {
                    val outFile = File(outDir, item.path ?: "")
                    outFile.parentFile?.mkdirs()
                    item.extractSlow { data ->
                        outFile.writeBytes(data)
                        data.size // consumed
                    }
                }
            }
        } finally {
            raf.close()
        }
    }

    private fun testArchive(filePath: String) {
        val raf = RandomAccessFile(filePath, "r")
        try {
            val inArchive = SevenZip.openInArchive(null, RandomAccessFileInStream(raf))
            val simple = inArchive.simpleInterface
            // Iterate items to verify integrity
            for (item in simple.archiveItems) {
                if (!item.isFolder) {
                    item.extractSlow { data -> data.size } // consume and check
                }
            }
        } finally {
            raf.close()
        }
    }
}
