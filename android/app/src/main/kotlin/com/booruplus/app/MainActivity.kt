package com.booruplus.app

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import net.kodehawa.lib.imageboards.ImageBoard
import net.kodehawa.lib.imageboards.ImageBoards
import net.kodehawa.lib.imageboards.entities.BoardImage
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.random.Random

class MainActivity : FlutterActivity() {
    private val executor = Executors.newFixedThreadPool(3)
    private val client = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS)
        .followSslRedirects(false).build()
    private val boards by lazy { ImageBoards(client) }
    private var directoryResult: MethodChannel.Result? = null
    private val pending = ConcurrentHashMap.newKeySet<MethodChannel.Result>()
    private val discoveryWindows = ConcurrentHashMap<Int, Int>()
    private val providerCursors = ConcurrentHashMap<String, ProviderCursor>()
    @Volatile private var closing = false

    private data class ProviderCursor(val page: Int, val offset: Int)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ImageBoard.setUserAgent("BooruPlus/1.0 Android (imageboard browser)")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "booruplus/platform")
            .setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "fetch" -> fetch(call, result)
            "pickDownloadDirectory" -> pickDirectory(result)
            "download" -> download(call, result)
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, operation: () -> Any?) {
        if (closing) { result.error("CANCELLED", "Activity closed", null); return }
        pending.add(result)
        executor.execute {
            try {
                val value = operation()
                runOnUiThread { if (pending.remove(result)) result.success(value) }
            } catch (error: Exception) {
                val code = when (error) {
                    is SecurityException -> "DIRECTORY_ACCESS"
                    is IllegalArgumentException -> "INVALID_REQUEST"
                    else -> "REQUEST_FAILED"
                }
                // Never expose exception messages: upstream errors may contain authenticated URLs.
                runOnUiThread { if (pending.remove(result)) result.error(code, "Request failed. Check the connection, credentials, or folder access.", null) }
            } catch (_: LinkageError) {
                runOnUiThread { if (pending.remove(result)) result.error("COMPATIBILITY", "The API library is not compatible with this Android runtime.", null) }
            }
        }
    }

    private fun fetch(call: MethodCall, result: MethodChannel.Result) {
        val board = call.argument<String>("board")
        if (board !in HOSTS) { result.error("INVALID_BOARD", "Unsupported imageboard", null); return }
        val tags = call.argument<List<String>>("tags") ?: emptyList()
        val limit = (call.argument<Number>("limit") ?: 50).toInt().coerceIn(1, 200)
        val page = (call.argument<Number>("page") ?: 0).toInt().coerceIn(0, 10000)
        val random = call.argument<Boolean>("random") ?: false
        // Older callers do not send a seed. Keep those requests random while allowing
        // newer callers to make a discovery session reproducible.
        val seed = call.argument<Number>("randomSeed")?.toInt() ?: Random.nextInt()
        val key = call.argument<String>("apiKey")
        val user = call.argument<String>("userId")
        if (board in setOf("rule34", "gelbooru") && (key.isNullOrBlank() || user.isNullOrBlank())) {
            result.error("AUTH_REQUIRED", "A user ID and API key are required", null); return
        }
        background(result) {
            val api = when (board) {
                "rule34" -> ImageBoards.createRule34(key!!, user!!, client)
                "gelbooru" -> ImageBoards.createGelbooru(key!!, user!!, client)
                "e621" -> boards.E621
                "e926" -> boards.E926
                "konachan" -> boards.KONACHAN
                "yandere" -> boards.YANDERE
                "danbooru" -> boards.DANBOORU
                else -> boards.SAFEBOORU
            }
            val window = if (random) discoveryWindows.getOrPut(seed) { Random(seed).nextInt(21) } else 0
            val cursorKey = makeCursorKey(board!!, tags, limit, random, seed)
            if (page == 0) providerCursors.remove(cursorKey)
            var images = fetchWindow(api, board, tags, page, limit, window, cursorKey)
            if (random && page == 0 && images.isEmpty() && window > 0) {
                discoveryWindows[seed] = 0
                providerCursors.remove(cursorKey)
                images = fetchWindow(api, board, tags, page, limit, 0, cursorKey)
            }
            if (discoveryWindows.size > 128) discoveryWindows.keys.filter { it != seed }.take(64).forEach { discoveryWindows.remove(it) }
            if (providerCursors.size > 256) providerCursors.keys.take(128).forEach { providerCursors.remove(it) }
            val ordered = if (random) images.shuffled(Random(seed xor page)) else images
            ordered.map { mapImage(it, board, key, user) }
        }
    }

    private fun makeCursorKey(board: String, tags: List<String>, limit: Int, random: Boolean, seed: Int): String =
        listOf(board, tags.joinToString("\u0001"), limit.toString(), random.toString(), seed.toString()).joinToString("\u0002")

    private fun fetchWindow(
        api: ImageBoard<*>,
        board: String,
        tags: List<String>,
        page: Int,
        limit: Int,
        window: Int,
        cursorKey: String,
    ): List<BoardImage> {
        // Danbooru is page-based (and one-based), unlike pid-based boorus. Use a
        // stable provider page size so a Flutter page can span multiple responses.
        val size = minOf(limit, 100)
        val offset = page.toLong() * limit
        val fallback = ProviderCursor((offset / size).toInt() + window, (offset % size).toInt())
        val start = if (page == 0) ProviderCursor(window, 0) else providerCursors[cursorKey] ?: fallback
        var providerPage = start.page
        var skip = start.offset
        val result = ArrayList<BoardImage>()
        var requests = 0
        while (result.size < limit && requests++ < MAX_WINDOW_REQUESTS) {
            if (closing || Thread.currentThread().isInterrupted) throw IOException("Cancelled")
            // pid-based boards are zero based; page-based boards are one based.
            val number = providerPage + if (board in setOf("rule34", "gelbooru", "safebooru")) 0 else 1
            val batch = if (tags.isEmpty()) {
                api.get(number, size).blocking()
            } else {
                api.search(number, size, tags.joinToString(" ")).blocking()
            }
            val take = minOf(limit - result.size, (batch.size - skip).coerceAtLeast(0))
            if (take > 0) result.addAll(batch.drop(skip).take(take))
            // A non-empty short page is not an end marker. Some providers (notably
            // Danbooru searches) can return fewer rows than requested and still have
            // later pages. Only an empty response ends the window.
            if (batch.isEmpty()) {
                providerCursors[cursorKey] = ProviderCursor(providerPage, batch.size)
                break
            }
            if (result.size >= limit) {
                val consumed = skip + take
                providerCursors[cursorKey] = if (consumed < batch.size) {
                    ProviderCursor(providerPage, consumed)
                } else {
                    ProviderCursor(providerPage + 1, 0)
                }
                break
            }
            skip = 0
            providerPage++
            providerCursors[cursorKey] = ProviderCursor(providerPage, 0)
        }
        return result
    }

    private fun mapImage(image: BoardImage, board: String, apiKey: String?, userId: String?): Map<String, Any?> {
        val original = authorizeMediaUrl(normalizeUrl(image.getURL(), board), board, apiKey, userId)
        val preview = authorizeMediaUrl(
            normalizeUrl(value(image, "getParsedPreviewFileUrl", "getPreview_url", "getPreviewUrl")?.toString(), board),
            board, apiKey, userId
        )
        return mapOf(
            "id" to (value(image, "getId")?.toString() ?: "0"),
            "url" to original, "previewUrl" to preview,
            "tags" to (image.getTags() ?: emptyList<String>()),
            "rating" to (image.getRating()?.toString() ?: "Unknown"),
            "uploader" to (value(image, "getUploader_name", "getOwner", "getAuthor", "getUploader_id")?.toString() ?: ""),
            "source" to sourceValue(image), "width" to image.getWidth(), "height" to image.getHeight(),
            "score" to image.getScore(), "description" to (value(image, "getDescription")?.toString() ?: "")
        )
    }

    private fun normalizeUrl(value: String?, board: String): String {
        if (value.isNullOrBlank()) return ""
        return try {
            val uri = URI("https://${HOSTS[board]}/").resolve(value)
            if (uri.userInfo != null || uri.host.isNullOrBlank() || uri.scheme !in setOf("http", "https")) ""
            else URI("https", null, uri.host, if (uri.port == 80) -1 else uri.port, uri.path, uri.query, null).toASCIIString()
        } catch (_: Exception) { "" }
    }

    private fun authorizeMediaUrl(url: String, board: String, apiKey: String?, userId: String?): String {
        if (board != "gelbooru" || url.isBlank() || apiKey.isNullOrBlank() || userId.isNullOrBlank()) return url
        return try {
            val parsed = url.toHttpUrlOrNull() ?: return url
            val host = parsed.host
            if (host != "gelbooru.com" && !host.endsWith(".gelbooru.com")) return url
            parsed.newBuilder()
                .setQueryParameter("api_key", apiKey)
                .setQueryParameter("user_id", userId)
                .build()
                .toString()
        } catch (_: IllegalArgumentException) { url }
    }

    private fun sourceValue(image: BoardImage): String {
        val source = value(image, "getSource")?.toString()
        if (!source.isNullOrBlank()) return source
        return (value(image, "getSources") as? List<*>)?.filterIsInstance<String>()?.joinToString("\n") ?: ""
    }

    private fun value(target: Any, vararg names: String): Any? {
        for (name in names) {
            try {
                val found = target.javaClass.getMethod(name).invoke(target)
                if (found != null && found.toString().isNotBlank()) return found
            } catch (_: ReflectiveOperationException) { }
        }
        return null
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        if (directoryResult != null) { result.error("DIRECTORY_PICKER_BUSY", "Directory picker is already open", null); return }
        directoryResult = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), PICKER)
        } catch (_: Exception) { directoryResult = null; result.error("PICKER_UNAVAILABLE", "No folder picker is available", null) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICKER) return
        val result = directoryResult ?: return
        directoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0) throw SecurityException("Read-only folder")
            contentResolver.takePersistableUriPermission(uri, flags)
            result.success(uri.toString())
        } catch (_: Exception) { result.error("DIRECTORY_ACCESS", "The folder cannot retain write access. Choose another folder.", null) }
    }

    private fun download(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")?.trim()
        val directory = call.argument<String>("directory")
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS download URLs are allowed", null); return }
        if (name.isNullOrEmpty() || name.length > 180 || name.contains('/') || name.contains('\\') || name.any { it.code < 32 }) {
            result.error("INVALID_NAME", "Invalid download name", null); return
        }
        if (Build.VERSION.SDK_INT < 29 && directory == null) { result.error("DIRECTORY_REQUIRED", "Choose a download folder in Settings", null); return }
        background(result) {
            var uri: Uri? = null
            try {
                // Open the network first; an HTTP failure must not leave a target stream open.
                openSecureDownload(url!!).use { input ->
                    uri = createTarget(name, directory)
                    (contentResolver.openOutputStream(uri!!, "w") ?: throw IOException("Cannot open target")).use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            if (closing || Thread.currentThread().isInterrupted) throw IOException("Cancelled")
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                }
                if (directory == null && Build.VERSION.SDK_INT >= 29) {
                    contentResolver.update(uri!!, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                }
                uri.toString()
            } catch (error: Exception) {
                uri?.let { try {
                    if (directory != null) DocumentsContract.deleteDocument(contentResolver, it) else contentResolver.delete(it, null, null)
                } catch (_: Exception) { } }
                throw error
            }
        }
    }

    private fun openSecureDownload(value: String): InputStream {
        var current = URI(value)
        repeat(6) {
            if (!secureHttps(current.toString())) throw IOException("Insecure URL")
            val connection = current.toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 15000
                connection.readTimeout = 30000
                connection.setRequestProperty("User-Agent", "BooruPlus/1.0 Android")
                val code = connection.responseCode
                if (code in 300..399) {
                    val location = connection.getHeaderField("Location") ?: throw IOException("Invalid redirect")
                    connection.disconnect()
                    current = current.resolve(location)
                } else {
                    if (code !in 200..299) throw IOException("HTTP failure")
                    return object : FilterInputStream(connection.inputStream) {
                        override fun close() { try { super.close() } finally { connection.disconnect() } }
                    }
                }
            } catch (error: Exception) { connection.disconnect(); throw error }
        }
        throw IOException("Too many redirects")
    }

    private fun createTarget(name: String, directory: String?): Uri {
        if (directory != null) {
            val tree = Uri.parse(directory)
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            return DocumentsContract.createDocument(contentResolver, parent, mimeType(name), name) ?: throw IOException("Cannot create document")
        }
        check(Build.VERSION.SDK_INT >= 29)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mimeType(name))
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/BooruPlus")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        return contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IOException("Cannot create download")
    }

    private fun mimeType(name: String) = when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "mp4" -> "video/mp4"
        "webm" -> "video/webm"
        else -> "application/octet-stream"
    }

    private fun secureHttps(value: String?): Boolean = try {
        val uri = URI(value ?: "")
        uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null
    } catch (_: Exception) { false }

    override fun onDestroy() {
        closing = true
        directoryResult?.success(null)
        directoryResult = null
        pending.toList().forEach { if (pending.remove(it)) it.error("CANCELLED", "Activity closed", null) }
        client.dispatcher.cancelAll()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val PICKER = 4101
        private const val MAX_WINDOW_REQUESTS = 32
        private val HOSTS = mapOf("rule34" to "rule34.xxx", "e621" to "e621.net", "konachan" to "konachan.com", "yandere" to "yande.re", "danbooru" to "danbooru.donmai.us", "safebooru" to "safebooru.org", "gelbooru" to "gelbooru.com", "e926" to "e926.net")
    }
}
