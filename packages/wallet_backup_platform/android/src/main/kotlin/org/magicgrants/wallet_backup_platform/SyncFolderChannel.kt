package org.magicgrants.wallet_backup_platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/**
 * The sync folder on Android: a folder the user picks with the system picker
 * (ACTION_OPEN_DOCUMENT_TREE), kept with a persisted grant. Nothing else is
 * needed: the grant reads every file in the tree, whichever app wrote it.
 *
 * `ref` is the tree URI. Each wallet's files sit in a subfolder of it. Every
 * listing is one DocumentsContract query (never DocumentFile, which asks the
 * provider once per property), after asking the provider to refresh, since
 * some answer from a cache. Names are checked on the way in and out: a
 * provider can store a file under another name ("name (1)") when one is
 * already there, and such a file would never be found.
 *
 * All file work runs on one worker thread, in order; providers for network
 * folders block for seconds. Results return on the main thread.
 */
internal class SyncFolderChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, PluginRegistry.ActivityResultListener {

    private val methods = MethodChannel(messenger, "org.magicgrants.wallet_backup_platform/folder")
    private val events = EventChannel(messenger, "org.magicgrants.wallet_backup_platform/folder_changes")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val resolver get() = context.contentResolver

    private var activity: ActivityPluginBinding? = null
    private var picking: MethodChannel.Result? = null

    /** The open listing whose changes are being reported ([onListen]). */
    private var watched: Cursor? = null
    private var observer: ContentObserver? = null

    private class FolderError(val code: String, message: String) : Exception(message)

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun attach(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    fun detach() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    fun dispose() {
        detach()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        worker.execute { stopWatching() }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "choose") {
            choose(call.argument<String>("current"), result)
            return
        }
        worker.execute {
            try {
                val reply = handle(call)
                main.post { result.success(reply) }
            } catch (e: NotImplementedError) {
                main.post { result.notImplemented() }
            } catch (e: FolderError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: SecurityException) {
                // The grant is gone (storage cleared, folder moved, app removed).
                main.post { result.error("unavailable", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("io", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun handle(call: MethodCall): Any? {
        val tree = Uri.parse(call.argument<String>("ref") ?: throw FolderError("bad_args", "ref missing"))
        return when (call.method) {
            "available" -> mapOf("available" to available(tree))
            "list" -> list(tree, folderArg(call))
            "read" -> read(tree, folderArg(call), nameArg(call))
            "create" -> {
                val data = call.argument<ByteArray>("data") ?: throw FolderError("bad_args", "data missing")
                create(tree, folderArg(call), nameArg(call), data)
                null
            }
            "deleteFolder" -> {
                deleteFolder(tree, folderArg(call))
                null
            }
            "release" -> {
                release(tree)
                null
            }
            else -> throw NotImplementedError()
        }
    }

    private fun folderArg(call: MethodCall) = safeName(call.argument<String>("folder"))

    private fun nameArg(call: MethodCall) = safeName(call.argument<String>("name"))

    private fun safeName(value: String?): String {
        if (value.isNullOrEmpty() || value.contains('/') || value.startsWith('.')) {
            throw FolderError("bad_args", "bad name")
        }
        return value
    }

    // ----- Choosing -----

    private fun choose(current: String?, result: MethodChannel.Result) {
        val binding = activity
        if (binding == null) {
            result.error("unavailable", "No activity to show the folder picker", null)
            return
        }
        if (picking != null) {
            result.error("busy", "The folder picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            if (current != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, rootUri(Uri.parse(current)))
                } catch (_: IllegalArgumentException) {
                    // Not a tree URI: start wherever the picker starts.
                }
            }
        }
        picking = result
        binding.activity.startActivityForResult(intent, REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = picking ?: return true
        picking = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            resolver.takePersistableUriPermission(tree, flags)
        } catch (e: SecurityException) {
            result.error("unavailable", e.message, null)
            return true
        }
        worker.execute {
            try {
                // A folder that cannot take new files is no use: give it back.
                if ((rootFlags(tree) and Document.FLAG_DIR_SUPPORTS_CREATE) == 0) {
                    release(tree)
                    main.post { result.error("read_only", "The folder cannot take new files", null) }
                    return@execute
                }
                val name = displayName(tree)
                main.post { result.success(mapOf("ref" to tree.toString(), "name" to name)) }
            } catch (e: Exception) {
                release(tree)
                main.post { result.error("unavailable", e.message, null) }
            }
        }
        return true
    }

    private fun release(tree: Uri) {
        try {
            resolver.releasePersistableUriPermission(
                tree,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // Not held any more.
        }
    }

    /** "Documents/Skylight Backup" on the phone's own storage; the folder's name elsewhere. */
    private fun displayName(tree: Uri): String {
        val docId = DocumentsContract.getTreeDocumentId(tree)
        if (tree.authority == EXTERNAL_STORAGE && docId.startsWith("primary:")) {
            val path = docId.removePrefix("primary:")
            if (path.isNotEmpty()) return path
        }
        resolver.query(rootUri(tree), arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0) ?: docId
        }
        return docId
    }

    // ----- The folder -----

    private fun rootUri(tree: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun rootFlags(tree: Uri): Int {
        resolver.query(rootUri(tree), arrayOf(Document.COLUMN_FLAGS), null, null, null)?.use {
            if (it.moveToFirst()) return it.getInt(0)
        }
        throw FolderError("unavailable", "The folder could not be read")
    }

    /** Whether the grant is still held and the folder answers. */
    private fun available(tree: Uri): Boolean {
        val held = resolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }
        if (!held) return false
        return try {
            resolver.query(rootUri(tree), arrayOf(Document.COLUMN_DOCUMENT_ID), null, null, null)
                ?.use { it.moveToFirst() } ?: false
        } catch (e: Exception) {
            // Moved, deleted, or a network folder out of reach.
            false
        }
    }

    private class Child(val id: String, val name: String, val isDir: Boolean, val size: Long)

    private fun children(tree: Uri, parentId: String): List<Child> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                resolver.refresh(uri, null, null)
            } catch (_: Exception) {
                // Most providers have nothing to refresh.
            }
        }
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
        )
        val cursor = resolver.query(uri, columns, null, null, null)
            ?: throw FolderError("unavailable", "The folder could not be listed")
        return cursor.use {
            buildList {
                while (it.moveToNext()) {
                    val id = it.getString(0) ?: continue
                    val name = it.getString(1) ?: continue
                    val size = if (it.isNull(3)) -1L else it.getLong(3)
                    add(Child(id, name, it.getString(2) == Document.MIME_TYPE_DIR, size))
                }
            }
        }
    }

    private fun child(tree: Uri, parentId: String, name: String, isDir: Boolean): Child? =
        children(tree, parentId).firstOrNull { it.name == name && it.isDir == isDir }

    private fun documentUri(tree: Uri, id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)

    /** The wallet's subfolder, made when [make] and missing; null when missing. */
    private fun folderId(tree: Uri, folder: String, make: Boolean): String? {
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        child(tree, rootId, folder, isDir = true)?.let { return it.id }
        if (!make) return null
        val made = DocumentsContract.createDocument(resolver, rootUri(tree), Document.MIME_TYPE_DIR, folder)
            ?: throw FolderError("io", "The folder could not be made")
        return checkName(made, folder)
    }

    /** The new document's id, if the provider kept [name]; otherwise it is removed. */
    private fun checkName(made: Uri, name: String): String {
        val stored = resolver.query(made, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
        if (stored != name) {
            try {
                DocumentsContract.deleteDocument(resolver, made)
            } catch (_: Exception) {
                // Left behind under a name nothing reads.
            }
            throw FolderError("renamed", "Stored as \"$stored\" instead of \"$name\"")
        }
        return DocumentsContract.getDocumentId(made)
    }

    private fun list(tree: Uri, folder: String): List<String> {
        val id = folderId(tree, folder, make = false) ?: return emptyList()
        return children(tree, id).filter { !it.isDir }.map { it.name }
    }

    private fun read(tree: Uri, folder: String, name: String): ByteArray? {
        val id = folderId(tree, folder, make = false) ?: return null
        val file = child(tree, id, name, isDir = false) ?: return null
        if (file.size > MAX_FILE_BYTES) throw FolderError("too_large", name)
        return readDocument(documentUri(tree, file.id), name)
    }

    /** Never past [MAX_FILE_BYTES]; null when gone since the listing. */
    private fun readDocument(uri: Uri, name: String): ByteArray? {
        val input = try {
            resolver.openInputStream(uri)
        } catch (_: FileNotFoundException) {
            return null
        } ?: return null
        return input.use {
            val out = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            while (true) {
                val n = it.read(buf)
                if (n < 0) break
                out.write(buf, 0, n)
                if (out.size() > MAX_FILE_BYTES) throw FolderError("too_large", name)
            }
            out.toByteArray()
        }
    }

    /**
     * Create-only, as every location: the same bytes already there is a safe
     * retry, and different bytes are a conflict, never overwritten. The one
     * exception is a start of these very bytes (an empty file, or a write cut
     * short), which is completed.
     */
    private fun create(tree: Uri, folder: String, name: String, data: ByteArray) {
        val folderId = folderId(tree, folder, make = true)!!
        val existing = child(tree, folderId, name, isDir = false)
        if (existing != null) {
            val uri = documentUri(tree, existing.id)
            val there = readDocument(uri, name) ?: ByteArray(0)
            if (there.contentEquals(data)) return
            if (there.size < data.size && data.copyOf(there.size).contentEquals(there)) {
                write(uri, data, "wt")
                return
            }
            throw FolderError("conflict", name)
        }
        val made = DocumentsContract.createDocument(resolver, documentUri(tree, folderId), MIME_TYPE, name)
            ?: throw FolderError("io", "The file could not be made")
        val uri = documentUri(tree, checkName(made, name))
        try {
            write(uri, data, "w")
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(resolver, uri)
            } catch (_: Exception) {
                // Completed by the next attempt, as a start of the same bytes.
            }
            throw e
        }
    }

    private fun write(uri: Uri, data: ByteArray, mode: String) {
        val out = resolver.openOutputStream(uri, mode) ?: throw FolderError("io", "The file could not be written")
        out.use {
            it.write(data)
            it.flush()
        }
    }

    private fun deleteFolder(tree: Uri, folder: String) {
        val id = folderId(tree, folder, make = false) ?: return
        DocumentsContract.deleteDocument(resolver, documentUri(tree, id))
    }

    // ----- Watching -----

    /**
     * Reports changes in the wallet's subfolder while the stream is listened
     * to. A provider reports changes on the listing, and only while it is
     * open (the phone's own storage watches the directory meanwhile), so one
     * stays open. Some providers never report: the backup also checks on a
     * timer.
     */
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        val args = arguments as? Map<*, *>
        val ref = args?.get("ref") as? String
        val folder = args?.get("folder") as? String
        worker.execute {
            stopWatching()
            try {
                if (ref == null) throw FolderError("bad_args", "ref missing")
                val tree = Uri.parse(ref)
                val id = folderId(tree, safeName(folder), make = true)!!
                val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                val cursor = resolver.query(uri, arrayOf(Document.COLUMN_DOCUMENT_ID), null, null, null)
                    ?: throw FolderError("unavailable", "The folder could not be listed")
                val changed = object : ContentObserver(main) {
                    override fun onChange(selfChange: Boolean) {
                        sink.success(null)
                    }
                }
                cursor.registerContentObserver(changed)
                watched = cursor
                observer = changed
            } catch (e: Exception) {
                val code = (e as? FolderError)?.code ?: "unavailable"
                main.post { sink.error(code, e.message, null) }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        worker.execute { stopWatching() }
    }

    private fun stopWatching() {
        observer?.let { watched?.unregisterContentObserver(it) }
        watched?.close()
        watched = null
        observer = null
    }

    private companion object {
        const val REQUEST_CODE = 0x5B4C
        const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"

        /** Stored with no extension added: names are matched exactly. */
        const val MIME_TYPE = "application/octet-stream"

        /** The largest backup file there is (wallet_backup's maxFileSize). */
        const val MAX_FILE_BYTES = 64 * 1024
    }
}
