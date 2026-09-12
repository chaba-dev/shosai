package dev.shosai.shosai_flutter

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
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

private const val CHANNEL = "dev.shosai/document_import"
private const val PICK_DOCUMENTS = 4104
private const val MAX_BYTES = 512L * 1024L * 1024L
private const val MAX_ACQUISITIONS = 2
private const val MAX_SELECTIONS = 256
private const val SESSION_PREFIX = "provider-"

private data class Owner(
    val id: String = UUID.randomUUID().toString(),
    val active: AtomicBoolean = AtomicBoolean(true),
)
private data class Selection(val ownerId: String, val uri: Uri, val displayName: String)
private data class Acquisition(
    val owner: Owner,
    val result: MethodChannel.Result,
    val cancelled: AtomicBoolean = AtomicBoolean(false),
    val signal: CancellationSignal = CancellationSignal(),
    val input: AtomicReference<FileInputStream?> = AtomicReference(null),
)
private sealed interface AcquisitionOutcome {
    data class Success(val path: String, val releaseToken: String) : AcquisitionOutcome
    data class Failure(val code: String) : AcquisitionOutcome
}

/** Keeps the Dart import continuation alive while Android recreates its Activity. */
private object ShosaiFlutterEngine {
    private var engine: FlutterEngine? = null

    @Synchronized
    fun get(context: Context): FlutterEngine = engine ?: FlutterEngine(
        context.applicationContext,
    ).also { created ->
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        engine = created
    }
}

/** Process-owned storage and workers survive activity recreation without losing cleanup ownership. */
private object DocumentImportManager {
    val owner = Owner()
    private val selections = ConcurrentHashMap<String, Selection>()
    private val ownership = ResourceOwnership()
    private val acquisitions = ConcurrentHashMap<String, Acquisition>()
    private val slots = Semaphore(MAX_ACQUISITIONS)
    private val executor = Executors.newFixedThreadPool(MAX_ACQUISITIONS)
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var resolver: ContentResolver
    private lateinit var cacheDir: File
    private var initialized = false
    private var cleanupDiscoveryFailed = false

    @Synchronized
    fun initialize(context: Context) {
        if (!initialized) {
            val application = context.applicationContext
            resolver = application.contentResolver
            cacheDir = application.cacheDir.absoluteFile
            initialized = true
        }
        discoverOwnedSessions()
        retryPendingCleanups()
    }

    fun addSelections(owner: Owner, uris: List<Uri>): List<Map<String, String>> =
        uris.mapIndexed { index, uri ->
            val token = UUID.randomUUID().toString()
            val name = selectionName(uri, index)
            selections[token] = Selection(owner.id, uri, name)
            mapOf("token" to token, "name" to name)
        }

    fun discardSelection(token: String) {
        selections.remove(token)
    }

    fun acquire(owner: Owner, token: String?, operationId: String?, result: MethodChannel.Result) {
        val selection = token?.let(selections::get)
        if (operationId == null || selection == null || selection.ownerId != owner.id) {
            result.error("invalid_request", null, null)
            return
        }
        if (!slots.tryAcquire()) {
            result.error("busy", null, null)
            return
        }
        val acquisition = Acquisition(owner, result)
        if (acquisitions.putIfAbsent(operationId, acquisition) != null) {
            slots.release()
            result.error("invalid_request", null, null)
            return
        }
        selections.remove(token, selection)
        executor.execute { copySelection(operationId, selection, acquisition) }
    }

    fun cancel(operationId: String) {
        acquisitions[operationId]?.let(::cancelAcquisition)
    }

    fun beginUse(owner: Owner, token: String): Boolean {
        return ownership.beginUse(owner.id, token)
    }

    fun release(token: String): Boolean {
        val resource = ownership.requestRelease(token) ?: return true
        if (!deleteOwnedSession(resource.file)) return false
        ownership.removed(token, resource)
        return true
    }

    fun destroyOwner(owner: Owner) {
        owner.active.set(false)
        selections.entries.removeIf { it.value.ownerId == owner.id }
        acquisitions.values.filter { it.owner.id == owner.id }.forEach(::cancelAcquisition)
        ownership.abandonOwner(owner.id).forEach { (token, _) -> release(token) }
    }

    fun retryPendingCleanups(): Int {
        discoverOwnedSessions()
        ownership.retryable().forEach { (token, _) -> release(token) }
        return ownership.pendingCount() + if (cleanupDiscoveryFailed) 1 else 0
    }

    @Synchronized
    private fun discoverOwnedSessions() {
        val entries = cacheDir.listFiles()
        if (entries == null) {
            cleanupDiscoveryFailed = true
            return
        }
        cleanupDiscoveryFailed = false
        entries.filter { isOwnedName(it.name) }.forEach { resource ->
            ownership.restore(resource.name.removePrefix(SESSION_PREFIX), resource)
        }
    }

    private fun copySelection(operationId: String, selection: Selection, acquisition: Acquisition) {
        var outcome: AcquisitionOutcome
        var releaseToken: String? = null
        try {
            checkCancelled(acquisition)
            releaseToken = UUID.randomUUID().toString()
            val session = File(cacheDir, "$SESSION_PREFIX$releaseToken")
            ownership.register(releaseToken, session, acquisition.owner.id)
            if (!session.mkdir()) throw IOException()
            val stagedFile = File(session, selection.displayName)
            resolver.openAssetFileDescriptor(selection.uri, "r", acquisition.signal).use { descriptor ->
                if (descriptor == null) throw IOException()
                descriptor.createInputStream().use { input ->
                    acquisition.input.set(input)
                    FileOutputStream(stagedFile).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var copied = 0L
                        while (true) {
                            checkCancelled(acquisition)
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
            checkCancelled(acquisition)
            outcome = AcquisitionOutcome.Success(stagedFile.absolutePath, releaseToken)
        } catch (_: AcquisitionTooLarge) {
            outcome = AcquisitionOutcome.Failure("too_large")
        } catch (_: SecurityException) {
            outcome = AcquisitionOutcome.Failure("permission_denied")
        } catch (_: Exception) {
            outcome = AcquisitionOutcome.Failure(
                if (acquisition.cancelled.get() || !acquisition.owner.active.get()) "cancelled"
                else "read_failed",
            )
        } finally {
            acquisition.input.set(null)
            slots.release()
        }
        mainHandler.post { finalizeAcquisition(operationId, acquisition, outcome, releaseToken) }
    }

    private fun finalizeAcquisition(
        operationId: String,
        acquisition: Acquisition,
        workerOutcome: AcquisitionOutcome,
        releaseToken: String?,
    ) {
        acquisitions.remove(operationId, acquisition)
        val cancelled = acquisition.cancelled.get() || !acquisition.owner.active.get()
        val outcome = if (cancelled) AcquisitionOutcome.Failure("cancelled") else workerOutcome
        if (outcome is AcquisitionOutcome.Success) {
            if (acquisition.owner.active.get()) {
                acquisition.result.success(
                    mapOf("path" to outcome.path, "releaseToken" to outcome.releaseToken),
                )
                return
            }
        }
        releaseToken?.let(::release)
        if (acquisition.owner.active.get()) {
            acquisition.result.error((outcome as AcquisitionOutcome.Failure).code, null, null)
        }
    }

    private fun checkCancelled(acquisition: Acquisition) {
        if (acquisition.cancelled.get() || !acquisition.owner.active.get()) {
            throw AcquisitionCancelled()
        }
    }

    private fun cancelAcquisition(acquisition: Acquisition) {
        acquisition.cancelled.set(true)
        acquisition.signal.cancel()
        try {
            acquisition.input.getAndSet(null)?.close()
        } catch (_: IOException) {
            // Closing is only a cancellation signal; the worker owns terminal cleanup.
        }
    }

    private fun deleteOwnedSession(resource: File): Boolean {
        val owned = resource.absoluteFile
        if (owned.parentFile != cacheDir || !isOwnedName(owned.name)) return false
        try {
            if (OsConstants.S_ISLNK(Os.lstat(owned.path).st_mode)) {
                return owned.delete()
            }
        } catch (error: ErrnoException) {
            return error.errno == OsConstants.ENOENT
        }
        val children = owned.listFiles() ?: return false
        // Sessions contain one flat staged file. Delete direct children only: never follow links.
        if (children.any { !it.delete() }) return false
        return owned.delete()
    }

    private fun isOwnedName(name: String): Boolean =
        name.startsWith(SESSION_PREFIX) &&
            try {
                UUID.fromString(name.removePrefix(SESSION_PREFIX))
                true
            } catch (_: IllegalArgumentException) {
                false
            }

    private fun selectionName(uri: Uri, index: Int): String {
        val candidate = uri.lastPathSegment
            ?.substringAfterLast(':')
            ?.substringAfterLast('/')
            ?: return "Document ${index + 1}"
        val extension = candidate.substringAfterLast('.', "").lowercase()
        if (extension !in setOf("pdf", "epub", "cbz")) return "Document ${index + 1}"
        val stem = candidate.dropLast(extension.length + 1)
            .take(60)
            .map { character ->
                if (character.isLetterOrDigit() || character in " _-") character else '_'
            }
            .joinToString("")
            .trim(' ', '_')
        return if (stem.isEmpty()) "Document ${index + 1}" else "$stem.$extension"
    }

    private class AcquisitionCancelled : Exception()
    private class AcquisitionTooLarge : Exception()
}

class MainActivity : FlutterActivity() {
    private val owner: Owner
        get() = DocumentImportManager.owner
    private var pendingSelection: MethodChannel.Result? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        ShosaiFlutterEngine.get(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DocumentImportManager.initialize(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(
                mapOf(
                    "files" to true,
                    "multipleFiles" to true,
                    "folders" to false,
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
                    DocumentImportManager.discardSelection(token)
                    result.success(null)
                }
            }
            "acquire" -> DocumentImportManager.acquire(
                owner,
                call.argument("token"),
                call.argument("operationId"),
                result,
            )
            "beginUse" -> {
                val token = call.argument<String>("releaseToken")
                if (token == null) result.error("invalid_request", null, null)
                else if (DocumentImportManager.beginUse(owner, token)) result.success(null)
                else result.error("invalid_request", null, null)
            }
            "cancel" -> {
                val operationId = call.argument<String>("operationId")
                if (operationId == null) result.error("invalid_request", null, null)
                else {
                    DocumentImportManager.cancel(operationId)
                    result.success(null)
                }
            }
            "release" -> {
                val token = call.argument<String>("releaseToken")
                if (token == null) result.error("invalid_request", null, null)
                else if (DocumentImportManager.release(token)) result.success(null)
                else result.error("read_failed", null, null)
            }
            "retryCleanup" -> result.success(
                mapOf("pending" to DocumentImportManager.retryPendingCleanups()),
            )
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
                    "application/octet-stream",
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
        pendingSelection = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(mapOf("cancelled" to true))
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        } ?: data.data?.let(uris::add)
        val distinctUris = uris.distinct()
        if (distinctUris.size > MAX_SELECTIONS) {
            result.error("too_large", null, null)
            return
        }
        result.success(
            mapOf(
                "cancelled" to false,
                "documents" to DocumentImportManager.addSelections(owner, distinctUris),
            ),
        )
    }

    override fun onDestroy() {
        pendingSelection = null
        super.onDestroy()
    }
}
