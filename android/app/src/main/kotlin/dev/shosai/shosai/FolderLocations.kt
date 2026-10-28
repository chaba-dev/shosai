package dev.shosai.shosai

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.Executors

/** SAF tree grants, independent of the temporary single-document importer.
 * Keys are opaque document IDs. Provider streams stay native and are read in
 * 64 KiB steps; listing never opens a document. The process-owned manager
 * survives Activity recreation, just like the Flutter engine.
 */
internal object FolderLocations {
    const val PICK_FOLDER = 4105
    private const val FLAGS = Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var host = WeakReference<MainActivity>(null)
    private var pending: MethodChannel.Result? = null
    private lateinit var resolver: ContentResolver
    // Only the serial worker touches handles.
    private data class Handle(
        val input: FileInputStream? = null,
        val output: FileOutputStream? = null,
        val temporary: Uri? = null,
        val name: String? = null,
    )
    private val handles = mutableMapOf<String, Handle>()

    fun attach(activity: MainActivity, engine: FlutterEngine) {
        host = WeakReference(activity)
        resolver = activity.applicationContext.contentResolver
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.shosai/library_folders")
            .setMethodCallHandler { call, result ->
                if (call.method == "pick") pick(result)
                else worker.execute {
                    try {
                        val value = perform(call)
                        main.post { result.success(value) }
                    } catch (_: SecurityException) {
                        main.post { result.error("revoked", "Folder permission was revoked.", null) }
                    } catch (_: FileNotFoundException) {
                        main.post { result.error("missing", "The document is missing.", null) }
                    } catch (_: UnsupportedOperationException) {
                        main.post { result.error("unsupported", "Provider operation unavailable.", null) }
                    } catch (_: Exception) {
                        // Provider I/O can fail while its cloud account is offline.
                        main.post { result.error("offline", "The provider could not be reached.", null) }
                    }
                }
            }
    }

    fun detach(activity: MainActivity, changingConfiguration: Boolean) {
        if (host.get() !== activity) return
        host.clear()
        if (!changingConfiguration) {
            pending?.error("revoked", "The picker was closed.", null)
            pending = null
        }
    }

    private fun pick(result: MethodChannel.Result) {
        val activity = host.get()
        if (activity == null || pending != null) {
            result.error("busy", "A folder picker is already open.", null)
            return
        }
        pending = result
        try {
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                    FLAGS or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                ), PICK_FOLDER,
            )
        } catch (_: Exception) {
            pending = null
            result.error("unsupported", "No folder picker is available.", null)
        }
    }

    fun onActivityResult(resultCode: Int, data: Intent?) {
        val result = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        worker.execute {
            try {
                val flags = data.flags and FLAGS
                if (flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0) throw SecurityException()
                resolver.takePersistableUriPermission(uri, flags)
                val root = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
                // A cloud provider can grant a tree while its metadata is
                // offline. Keep that lasting grant rather than leaking it or
                // forcing a second picker just to obtain a display label.
                val label = runCatching { metadata(root)["name"] as String }.getOrDefault("Folder")
                main.post { result.success(mapOf("grant" to uri.toString(), "label" to label)) }
            } catch (_: Exception) {
                main.post { result.error("revoked", "The provider did not grant lasting access.", null) }
            }
        }
    }

    private fun root(grant: String): Uri {
        val tree = Uri.parse(grant)
        if (!DocumentsContract.isTreeUri(tree) || resolver.persistedUriPermissions.none {
                it.uri == tree && it.isReadPermission
            }) throw SecurityException()
        return tree
    }

    private fun document(tree: Uri, key: String?): Uri {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        // DocumentsProvider enforces ancestry for every tree URI. Never build
        // a plain document URI from a stored key. The extra public ancestry
        // RPC (isChildDocument) is only available on API 29+, not our API 24.
        return DocumentsContract.buildDocumentUriUsingTree(tree, key ?: rootId)
    }

    private val columns = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )

    private fun row(cursor: android.database.Cursor): Map<String, Any?> = mapOf(
        "key" to cursor.getString(0), "name" to (cursor.getString(1) ?: "Document"),
        "isDirectory" to (cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
        "size" to if (cursor.isNull(3)) null else cursor.getLong(3),
        "revision" to if (cursor.isNull(4)) null else cursor.getLong(4).toString(),
    )

    private fun metadata(uri: Uri): Map<String, Any?> =
        resolver.query(uri, columns, null, null, null)?.use {
            if (!it.moveToFirst()) throw FileNotFoundException()
            row(it)
        } ?: throw FileNotFoundException()

    private fun perform(call: MethodCall): Any? {
        val args = call.arguments as Map<*, *>
        val token = args["token"] as String?
        if (call.method == "close") {
            handles.remove(token)?.let { close(it, delete = true) }
            return null
        }
        if (call.method == "read") {
            val input = handles[token]?.input ?: throw FileNotFoundException()
            val count = (args["count"] as Number).toInt()
            require(count in 1..65536)
            val bytes = ByteArray(count)
            val length = input.read(bytes)
            return if (length < 0) ByteArray(0) else bytes.copyOf(length)
        }
        if (call.method == "write") {
            val bytes = args["bytes"] as ByteArray
            require(bytes.size <= 65536)
            (handles[token]?.output ?: throw FileNotFoundException()).write(bytes)
            return null
        }
        if (call.method == "commit") {
            val handle = handles.remove(token) ?: throw FileNotFoundException()
            val published: Uri
            try {
                // Cloud providers may back their descriptor with a pipe, for
                // which fsync is not meaningful; close signals EOF to them.
                handle.output!!.close()
                published = DocumentsContract.renameDocument(resolver, handle.temporary!!, handle.name!!)
                    ?: throw UnsupportedOperationException()
            } catch (error: Exception) {
                close(handle, delete = true)
                throw error
            }
            // Metadata failure after publication must not delete the now
            // complete source book (rename may preserve its document ID).
            return metadata(published)
        }
        if (call.method == "release") {
            val tree = Uri.parse(args["grant"] as String)
            val permission = resolver.persistedUriPermissions.firstOrNull { it.uri == tree } ?: return null
            val flags = (if (permission.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
            resolver.releasePersistableUriPermission(tree, flags)
            return null
        }
        val tree = root(args["grant"] as String)
        when (call.method) {
            "stat" -> return metadata(document(tree, args["key"] as String))
            "list" -> {
                val parent = document(tree, args["directory"] as String?)
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(
                    tree, DocumentsContract.getDocumentId(parent),
                )
                val offset = (args["offset"] as Number).toInt()
                val limit = (args["limit"] as Number).toInt()
                require(offset >= 0 && limit in 1..500)
                val entries = mutableListOf<Map<String, Any?>>()
                var next: String? = null
                resolver.query(children, columns, null, null, null)?.use { cursor ->
                    var seen = 0
                    while (cursor.moveToNext()) {
                        val item = row(cursor)
                        if ((item["name"] as String).startsWith(".shosai-write-")) continue
                        if (seen++ < offset) continue
                        if (entries.size == limit) { next = (offset + limit).toString(); break }
                        entries.add(item)
                    }
                } ?: throw FileNotFoundException()
                return mapOf("entries" to entries, "nextCursor" to next)
            }
            "openRead" -> {
                require(handles.size < 8)
                val uri = document(tree, args["key"] as String)
                val descriptor = resolver.openFileDescriptor(uri, "r") ?: throw FileNotFoundException()
                val input = android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor)
                try {
                    val start = (args["start"] as Number).toLong()
                    require(start >= 0)
                    if (start != 0L) {
                        try { input.channel.position(start) }
                        catch (_: java.io.IOException) { throw UnsupportedOperationException() }
                    }
                    val id = UUID.randomUUID().toString()
                    handles[id] = Handle(input = input)
                    return id
                } catch (error: Exception) { input.close(); throw error }
            }
            "openWrite" -> {
                require(handles.size < 8)
                val parent = document(tree, args["directory"] as String?)
                val name = args["name"] as String
                require(name.isNotEmpty() && name != "." && name != ".." &&
                    !name.contains('/') && !name.contains('\\') && !name.contains('\u0000'))
                // SAF has no atomic replace primitive. Never destroy an existing
                // book: a provider lacking safe replacement must reject it.
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
                resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                    while (it.moveToNext()) if (it.getString(0) == name) throw UnsupportedOperationException()
                }
                val temporary = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", ".shosai-write-${UUID.randomUUID()}")
                    ?: throw UnsupportedOperationException()
                try {
                    val descriptor = resolver.openFileDescriptor(temporary, "w") ?: throw FileNotFoundException()
                    val output = android.os.ParcelFileDescriptor.AutoCloseOutputStream(descriptor)
                    val id = UUID.randomUUID().toString()
                    handles[id] = Handle(output = output, temporary = temporary, name = name)
                    return id
                } catch (error: Exception) {
                    DocumentsContract.deleteDocument(resolver, temporary)
                    throw error
                }
            }
            else -> throw UnsupportedOperationException()
        }
    }

    private fun close(handle: Handle, delete: Boolean) {
        try { handle.input?.close() } finally {
            try { handle.output?.close() } finally {
                if (delete && handle.temporary != null) {
                    DocumentsContract.deleteDocument(resolver, handle.temporary)
                }
            }
        }
    }
}
