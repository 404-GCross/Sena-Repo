package com.github.senarepo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import net.sf.sevenzipjbinding.*
import net.sf.sevenzipjbinding.impl.RandomAccessFileInStream
import java.io.File
import java.io.FileOutputStream
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
        val inArchive: IInArchive = SevenZip.openInArchive(null, RandomAccessFileInStream(raf))
        try {
            val count = inArchive.numberOfItems
            val indices = IntArray(count) { it }
            val paths = Array(count) { idx ->
                var p = inArchive.getStringProperty(idx, PropID.PATH)
                if (p != null && p.contains("\\")) p = p.replace("\\", "/")
                p
            }

            inArchive.extract(indices, false, object : IArchiveExtractCallback {
                override fun getStream(index: Int, askExtract: ExtractAskMode?): ISequentialOutStream? {
                    val path = paths[index] ?: return null
                    if (path.endsWith("/") || path.isEmpty()) return null
                    val outFile = File(outDir, path)
                    outFile.parentFile?.mkdirs()
                    val fos = FileOutputStream(outFile)
                    return object : ISequentialOutStream {
                        override fun write(data: ByteArray?): Int {
                            if (data != null) fos.write(data)
                            return data?.size ?: 0
                        }
                    }
                }

                override fun prepareOperation(askExtractMode: ExtractAskMode?) {}
                override fun setOperationResult(operationResult: ExtractOperationResult?) {}
                override fun setTotal(total: Long) {}
                override fun setCompleted(complete: Long) {}
            })
            inArchive.close()
        } finally {
            raf.close()
        }
    }

    private fun testArchive(filePath: String) {
        val raf = RandomAccessFile(filePath, "r")
        val inArchive: IInArchive = SevenZip.openInArchive(null, RandomAccessFileInStream(raf))
        try {
            val count = inArchive.numberOfItems
            val indices = IntArray(1) { 0 }
            // Try extracting first item to validate archive integrity
            if (count > 0) {
                inArchive.extract(indices, false, object : IArchiveExtractCallback {
                    override fun getStream(index: Int, askExtract: ExtractAskMode?): ISequentialOutStream? {
                        return object : ISequentialOutStream {
                            override fun write(data: ByteArray?): Int = data?.size ?: 0
                        }
                    }
                    override fun prepareOperation(askExtractMode: ExtractAskMode?) {}
                    override fun setOperationResult(operationResult: ExtractOperationResult?) {
                        if (operationResult != ExtractOperationResult.OK) {
                            throw Exception("Archive integrity check failed: $operationResult")
                        }
                    }
                    override fun setTotal(total: Long) {}
                    override fun setCompleted(complete: Long) {}
                })
            }
            inArchive.close()
        } finally {
            raf.close()
        }
    }
}
