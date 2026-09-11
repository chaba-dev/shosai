package dev.shosai.shosai_flutter

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "dev.shosai/document_import"
        const val PICK_DOCUMENTS = 4104
        const val MAX_BYTES = 512L * 1024L * 1024L
        const val MAX_ACQUISITIONS = 2
    }

    private data class Selection(val uri: Uri, val displayName: String)
    private data class Acquisition(
        val cancelled: AtomicBoolean,
        val signal: CancellationSignal,
        val input: AtomicReference<FileInputStream?>,
    )

    private val selections = ConcurrentHashMap<String, Selection>()
    private val releases = ConcurrentHashMap<String, File>()
    private val acquisitions = ConcurrentHashMap<String, Acquisition>()
    private val acquisitionSlots = Semaphore(MAX_ACQUISITIONS)
    private val executor = Executors.newFixedThreadPool(MAX_ACQUISITIONS)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ownershipLock = Any()
    private val destroyed = AtomicBoolean(false)
    private var pendingSelection: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sweepAbandonedAcquisitions()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "files" to true,
                    "multipleFiles" to true,
                    // We do not recursively traverse arbitrary DocumentsContract providers.
                    "folders" to false,
                    // Acquisitions are disposable cache files, never durable capabilities.
                    "referencedImports" to false,
                    "managedImports" to true,
                    "maximumAcquisitions" to MAX_ACQUISITIONS,
                    "maximumBytesPerFile" to MAX_BYTES,
                ),
            )
            "selectFiles" -> selectFiles(result)
            "discardSelection" -> {
                val token = call.argument<String>("token")
                if (token == null) result.error("invalid_request", null, null)
                else {
                    selections.remove(token)
                    result.success(null)
                }
            }
            "acquire" -> acquire(call, result)
            "cancel" -> {
                val operationId = call.argument<String>("operationId")
                if (operationId == null) result.error("invalid_request", null, null)
                else {
                    acquisitions[operationId]?.let(::cancelAcquisition)
                    result.success(null)
                }
            }
            "release" -> {
                val token = call.argument<String>("releaseToken")
                if (token == null) result.error("invalid_request", null, null)
                else {
                    val resource = releases[token]
                    if (resource == null || resource.deleteRecursively()) {
                        if (resource != null) releases.remove(token, resource)
                        result.success(null)
                    } else {
                        result.error("read_failed", null, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun selectFiles(result: MethodChannel.Result) {
        if (pendingSelection != null) {
            result.error("busy", null, null)
            return
        }
        pendingSelection = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/pdf",
                    "application/epub+zip",
                    "application/zip",
                    "application/x-cbz",
                    "application/vnd.comicbook+zip",
                    "application/x-comicbook+zip",
                ),
            )
        }
        try {
            startActivityForResult(intent, PICK_DOCUMENTS)
        } catch (_: RuntimeException) {
            pendingSelection = null
            result.error("unavailable", null, null)
        }
    }

    @Deprecated("Deprecated by Android, retained for FlutterActivity result forwarding")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_DOCUMENTS) return
        val result = pendingSelection ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingSelection = null
            result.success(mapOf("cancelled" to true))
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        } ?: data.data?.let(uris::add)
        val distinctUris = uris.distinct()
        if (distinctUris.size > 256) {
            pendingSelection = null
            result.error("too_large", null, null)
            return
        }
        executor.execute {
            val documents = distinctUris.map { uri ->
                val token = UUID.randomUUID().toString()
                val name = displayName(uri)
                selections[token] = Selection(uri, name)
                mapOf("token" to token, "name" to name)
            }
            mainHandler.post {
                pendingSelection = null
                if (!destroyed.get()) {
                    result.success(mapOf("cancelled" to false, "documents" to documents))
                }
            }
        }
    }

    private fun acquire(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val operationId = call.argument<String>("operationId")
        val selection = token?.let(selections::get)
        if (operationId == null || selection == null || acquisitions.containsKey(operationId)) {
            result.error("invalid_request", null, null)
            return
        }
        if (!acquisitionSlots.tryAcquire()) {
            result.error("busy", null, null)
            return
        }
        val acquisition = Acquisition(
            AtomicBoolean(false),
            CancellationSignal(),
            AtomicReference<FileInputStream?>(null),
        )
        if (acquisitions.putIfAbsent(operationId, acquisition) != null) {
            acquisitionSlots.release()
            result.error("invalid_request", null, null)
            return
        }
        selections.remove(token, selection)
        executor.execute {
            var temporary: File? = null
            try {
                val session = File(cacheDir, "provider-${UUID.randomUUID()}")
                if (!session.mkdir()) throw IOException()
                temporary = session
                val outputFile = File(session, safeFileName(selection.displayName))
                contentResolver.openAssetFileDescriptor(
                    selection.uri,
                    "r",
                    acquisition.signal,
                ).use { descriptor ->
                    if (descriptor == null) throw IOException()
                    descriptor.createInputStream().use { input ->
                        acquisition.input.set(input)
                        FileOutputStream(outputFile).use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var copied = 0L
                            while (true) {
                                if (acquisition.cancelled.get()) throw AcquisitionCancelled()
                                val count = input.read(buffer)
                                if (count < 0) break
                                copied += count
                                if (copied > MAX_BYTES) throw AcquisitionTooLarge()
                                output.write(buffer, 0, count)
                            }
                            output.fd.sync()
                        }
                        acquisition.input.set(null)
                    }
                }
                if (acquisition.cancelled.get()) throw AcquisitionCancelled()
                val releaseToken = UUID.randomUUID().toString()
                synchronized(ownershipLock) {
                    if (destroyed.get() || acquisition.cancelled.get()) {
                        throw AcquisitionCancelled()
                    }
                    releases[releaseToken] = session
                    temporary = null
                }
                succeed(result, mapOf("path" to outputFile.absolutePath, "releaseToken" to releaseToken))
            } catch (_: AcquisitionCancelled) {
                fail(result, "cancelled")
            } catch (_: AcquisitionTooLarge) {
                fail(result, "too_large")
            } catch (_: SecurityException) {
                fail(result, "permission_denied")
            } catch (_: Exception) {
                // Provider exceptions can contain private URIs and account details. Never log or return them.
                fail(result, "read_failed")
            } finally {
                acquisition.input.set(null)
                temporary?.deleteRecursively()
                acquisitions.remove(operationId)
                acquisitionSlots.release()
            }
        }
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor != null && cursor.moveToFirst()) cursor.getString(0)?.take(255) ?: "Document"
            else "Document"
        } catch (_: Exception) {
            "Document"
        } finally {
            cursor?.close()
        }
    }

    private fun safeFileName(name: String): String {
        val cleaned = name
            .take(120)
            .map { character ->
                if (character.isLetterOrDigit() || character in " ._-") character else '_'
            }
            .joinToString("")
            .trim(' ', '.')
        val extension = name.substringAfterLast('.', "").lowercase()
        return if (cleaned.isNotEmpty() && extension in setOf("pdf", "epub", "cbz")) {
            if (cleaned.lowercase().endsWith(".$extension")) cleaned else "$cleaned.$extension"
        } else {
            "Document.document"
        }
    }

    private fun cancelAcquisition(acquisition: Acquisition) {
        acquisition.cancelled.set(true)
        acquisition.signal.cancel()
        try {
            acquisition.input.getAndSet(null)?.close()
        } catch (_: IOException) {
            // Closing is only a cancellation signal; the worker reports the terminal result.
        }
    }

    private fun sweepAbandonedAcquisitions() {
        cacheDir.listFiles { file -> file.isDirectory && file.name.startsWith("provider-") }
            ?.forEach(File::deleteRecursively)
    }

    private fun succeed(result: MethodChannel.Result, value: Any?) =
        mainHandler.post { result.success(value) }
    private fun fail(result: MethodChannel.Result, code: String) =
        mainHandler.post { result.error(code, null, null) }

    override fun onDestroy() {
        synchronized(ownershipLock) {
            destroyed.set(true)
            acquisitions.values.forEach(::cancelAcquisition)
            selections.clear()
            releases.values.forEach(File::deleteRecursively)
            releases.clear()
        }
        executor.shutdownNow()
        super.onDestroy()
    }

    private class AcquisitionCancelled : Exception()
    private class AcquisitionTooLarge : Exception()
}
