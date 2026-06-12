package com.github.senarepo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import net.sf.sevenzipjbinding.*
import net.sf.sevenzipjbinding.impl.RandomAccessFileInStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    companion object {
        const val CHANNEL = "com.github.senarepo/extractor"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "extract" -> {
                        val filePath = call.argument<String>("filePath")!!
                        val outDir = call.argument<String>("outDir")!!
                        val password = call.argument<String>("password")
                        executor.execute {
                            try {
                                extractArchive(filePath, outDir, password)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("EXTRACT_ERROR", e.message, null) }
                            }
                        }
                    }
                    "testArchive" -> {
                        val filePath = call.argument<String>("filePath")!!
                        executor.execute {
                            try {
                                testArchive(filePath)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("TEST_ERROR", e.message, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun extractArchive(filePath: String, outDir: String, password: String? = null) {
        RandomAccessFile(filePath, "r").use { raf ->
            val stream = RandomAccessFileInStream(raf)
            val openCallback = if (password != null) object : IArchiveOpenCallback, ICryptoGetTextPassword {
                override fun cryptoGetTextPassword(): String = password
                override fun setCompleted(files: Long?, bytes: Long?) {}
                override fun setTotal(files: Long?, bytes: Long?) {}
            } else null
            val inArchive: IInArchive = SevenZip.openInArchive(null, stream, openCallback)
            val count = inArchive.numberOfItems
            if (count == 0) return

            val toExtract = IntArray(count) { it }
            val paths = Array(count) { idx ->
                inArchive.getStringProperty(idx, PropID.PATH)
                    ?.replace("\\", "/")
                    ?.let { if (it.endsWith("/")) null else it }
            }

            var totalBytes = 0L
            var lastReported = -1L
            inArchive.extract(toExtract, false, object : IArchiveExtractCallback {
                override fun getStream(index: Int, mode: ExtractAskMode?): ISequentialOutStream? {
                    val path = paths[index] ?: return null
                    val outFile = File(outDir, path)
                    outFile.parentFile!!.mkdirs()
                    val fos = FileOutputStream(outFile)
                    return ISequentialOutStream { data ->
                        fos.write(data)
                        data.size
                    }
                }
                override fun prepareOperation(mode: ExtractAskMode?) {}
                override fun setOperationResult(result: ExtractOperationResult?) {}
                override fun setTotal(total: Long) {
                    totalBytes = total
                }
                override fun setCompleted(complete: Long) {
                    if (totalBytes > 0 && complete - lastReported > totalBytes / 20) {
                        lastReported = complete
                        val progress = complete.toDouble() / totalBytes
                        runOnUiThread {
                            channel?.invokeMethod("onProgress", mapOf("progress" to progress))
                        }
                    }
                }
            })
            // Final 100% progress
            runOnUiThread {
                channel?.invokeMethod("onProgress", mapOf("progress" to 1.0))
            }
            inArchive.close()
        }
    }

    private fun testArchive(filePath: String) {
        RandomAccessFile(filePath, "r").use { raf ->
            val inArchive: IInArchive = SevenZip.openInArchive(null, RandomAccessFileInStream(raf))
            if (inArchive.numberOfItems > 0) {
                inArchive.extract(intArrayOf(0), false, object : IArchiveExtractCallback {
                    override fun getStream(idx: Int, mode: ExtractAskMode?) =
                        ISequentialOutStream { data -> data.size }
                    override fun prepareOperation(mode: ExtractAskMode?) {}
                    override fun setOperationResult(result: ExtractOperationResult?) {
                        if (result != ExtractOperationResult.OK)
                            throw Exception("Archive integrity check failed: $result")
                    }
                    override fun setTotal(total: Long) {}
                    override fun setCompleted(complete: Long) {}
                })
            }
            inArchive.close()
        }
    }
}
