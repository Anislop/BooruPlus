package com.booruplus.app

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.drawable.Icon
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import net.kodehawa.lib.imageboards.ImageBoard
import net.kodehawa.lib.imageboards.ImageBoards
import net.kodehawa.lib.imageboards.boards.KonachanBoard
import net.kodehawa.lib.imageboards.entities.BoardImage
import net.kodehawa.lib.imageboards.entities.impl.KonachanImage
import net.kodehawa.lib.imageboards.entities.impl.autocomplete.IAutoComplete
import okhttp3.Call
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import java.nio.ByteBuffer
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.LinkedHashMap
import kotlin.random.Random

class MainActivity : FlutterActivity() {
    // Feed, autocomplete, and sign-in requests never queue behind media
    // bytes or downloads: a grid of authenticated thumbnails would otherwise
    // hold every thread and stall a newly selected board's first page.
    private val executor = Executors.newFixedThreadPool(4)
    private val mediaExecutor = Executors.newFixedThreadPool(4)
    // Downloads have their own threads, so a queue of large files never
    // holds back thumbnails; Dart runs at most this many at once.
    private val downloadExecutor = Executors.newFixedThreadPool(4)
    // Downloads Dart asked to pause, by progress id; each keeps its partial
    // file. Only ids of running downloads are accepted.
    private val pausedDownloads = ConcurrentHashMap.newKeySet<Long>()
    private val activeDownloads = ConcurrentHashMap.newKeySet<Long>()
    // The feed fetch running on this thread, if any. Set only while a feed
    // task runs, so other requests on the same client are never cancelled.
    private val currentFeed = ThreadLocal<FeedTask?>()
    // The latest feed fetch; touched only on the UI thread.
    private var feedTask: FeedTask? = null
    private val baseClient = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS)
        .addInterceptor(Interceptor(::trackFeedCall))
        .addInterceptor(RateLimitInterceptor())
        .followSslRedirects(false).build()
    // Provider responses are parsed whole, so their size is capped; media
    // bytes have their own bound in readMedia.
    private val client = baseClient.newBuilder()
        .addInterceptor(ResponseLimitInterceptor(MAX_RESPONSE_BYTES))
        .build()
    private val mediaClient = baseClient.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()
    private val gelbooruTagClient = client.newBuilder()
        .connectTimeout(TAG_LOOKUP_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(TAG_LOOKUP_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .callTimeout(TAG_LOOKUP_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build()
    private val boards by lazy { ImageBoards(client) }
    private val konachanCom by lazy { ImageBoard(client, KonachanBoard.COM, KonachanImage::class.java) }
    private val konachanNet by lazy { ImageBoard(client, KonachanBoard.NET, KonachanImage::class.java) }
    private val sankaku by lazy { SankakuApi(client, USER_AGENT) }
    private val idolComplex by lazy { SankakuApi.idolComplex(client, USER_AGENT) }
    private val hybooruClient = lazy { HybooruApi(client, USER_AGENT) }
    // Boards with their own HTTP clients (ExtraBoards.kt, MoreBoards.kt),
    // created on first use.
    private val boardClients: Map<String, Lazy<BoardClient>> = mapOf(
        "tbib" to lazy { Gelbooru02Api(client, USER_AGENT, Gelbooru02Api.TBIB_HOST) },
        "aibooru" to lazy { AiBooruApi(client, USER_AGENT) },
        "sakugabooru" to lazy { SakugabooruApi(client, USER_AGENT) },
        "xbooru" to lazy { Gelbooru02Api(client, USER_AGENT, Gelbooru02Api.XBOORU_HOST) },
        "mspabooru" to lazy { Gelbooru02Api(client, USER_AGENT, Gelbooru02Api.MSPABOORU_HOST, keepsThumbnailExtension = true) },
        "eshuushuu" to lazy { EShuushuuApi(client, USER_AGENT) },
        "mikubooru" to hybooruClient,
        "nanbooru" to lazy { ShimmieApi(client, USER_AGENT) },
        "derpibooru" to lazy { DerpibooruApi(client, USER_AGENT) },
        "realbooru" to lazy { RealbooruApi(client, USER_AGENT) },
    )
    private val nozomiClient = lazy { NozomiApi(client, USER_AGENT) }
    private val nozomi by nozomiClient
    private var directoryResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportContent: String? = null
    private var importResult: MethodChannel.Result? = null
    private var authResult: MethodChannel.Result? = null
    private var channel: MethodChannel? = null
    // Native-to-Dart download progress, kept apart from the main channel's handler.
    private var downloadChannel: MethodChannel? = null
    // A launcher shortcut that opened the app, until Dart takes it.
    private var pendingShortcut: Map<String, String>? = null
    private val pending = ConcurrentHashMap.newKeySet<MethodChannel.Result>()
    private val discoveryWindows = ConcurrentHashMap<Int, Int>()
    private val providerCursors = ConcurrentHashMap<String, ProviderCursor>()
    private val gelbooruTagCache = object : LinkedHashMap<String, String>(TAG_CACHE_LIMIT, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean = size > TAG_CACHE_LIMIT
    }
    private val gelbooruTagCacheLock = Any()
    @Volatile private var closing = false

    private data class ProviderCursor(val page: Int, val offset: Int)

    /**
     * A `fetch` sent with `feed: true`. A newer feed fetch supersedes it: its
     * window loop stops and its in-flight HTTP call is cancelled, so a board
     * switch, search, or refresh does not leave the previous feed holding an
     * API thread for up to [MAX_WINDOW_REQUESTS] calls.
     */
    private class FeedTask(val result: MethodChannel.Result) {
        @Volatile var cancelled = false
        @Volatile var call: Call? = null

        fun cancel() {
            cancelled = true
            call?.cancel()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ImageBoard.setUserAgent("BooruPlus/1.0 Android (imageboard browser)")
        pendingShortcut = shortcutFrom(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "booruplus/platform")
            .also { it.setMethodCallHandler(::handle) }
        downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "booruplus/downloads")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val shortcut = shortcutFrom(intent) ?: return
        // Dart takes it from here, or asks for it with takeShortcut on startup.
        pendingShortcut = shortcut
        channel?.invokeMethod("shortcut", shortcut)
    }

    private fun shortcutFrom(intent: Intent?): Map<String, String>? {
        // A link handed over by LinkActivity; Dart decides what it names. It
        // opens once: not again when the activity is recreated, or reopened
        // from Recents with the intent that first started it.
        intent?.getStringExtra(LINK_TEXT)?.let { text ->
            intent.removeExtra(LINK_TEXT)
            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
            text.take(MAX_LINK_TEXT).takeIf { it.isNotBlank() }?.let {
                return mapOf("kind" to "link", "url" to it)
            }
            return null
        }
        val kind = intent?.getStringExtra(SHORTCUT_KIND)?.takeIf { it == "favorites" || it == "search" || it == "downloads" } ?: return null
        return buildMap {
            put("kind", kind)
            intent.getStringExtra(SHORTCUT_BOARD)?.let { put("board", it) }
            intent.getStringExtra(SHORTCUT_TAGS)?.let { put("tags", it) }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "fetch" -> fetch(call, result)
            "autocomplete" -> autocomplete(call, result)
            "fetchMedia" -> fetchMedia(call, result)
            "pickDownloadDirectory" -> pickDirectory(result)
            "download" -> download(call, result)
            "pauseDownload" -> {
                // Only a download still running; a late pause must not linger.
                call.argument<Number>("id")?.toLong()?.takeIf(activeDownloads::contains)?.let(pausedDownloads::add)
                result.success(null)
            }
            "discardDownload" -> discardDownload(call, result)
            "setDownloadsActive" -> setDownloadsActive(call, result)
            "moveToBack" -> result.success(moveTaskToBack(true))
            "setAs" -> setAs(call, result)
            "copyImage" -> copyImage(call, result)
            "saveFrame" -> saveFrame(call, result)
            "mediaSize" -> mediaSize(call, result)
            "setKeepScreenOn" -> setKeepScreenOn(call, result)
            "signIn" -> signIn(call, result)
            "refreshSignIn" -> refreshSignIn(call, result)
            "setSecureScreen" -> setSecureScreen(call, result)
            "authenticate" -> authenticate(call, result)
            "share" -> share(call, result)
            "exportFile" -> exportFile(call, result)
            "importFile" -> importFile(result)
            "pools" -> pools(call, result)
            "isMeteredNetwork" -> result.success(
                getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered ?: false
            )
            "cacheSize" -> background(result, mediaExecutor) {
                cacheDir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
            }
            "clearCache" -> background(result, mediaExecutor) {
                // Files written in the last few minutes may still be in use,
                // such as media just handed to the share sheet.
                val recent = System.currentTimeMillis() - 5 * 60 * 1000L
                cacheDir.walkBottomUp().filter { it != cacheDir }.forEach { file ->
                    if (file.isDirectory) file.delete() else if (file.lastModified() < recent) file.delete()
                }
                null
            }
            "setPictureInPicture" -> setPictureInPicture(call, result)
            "enterPictureInPicture" -> enterPictureInPicture(call, result)
            "setShortcuts" -> setShortcuts(call, result)
            "takeShortcut" -> {
                result.success(pendingShortcut)
                pendingShortcut = null
            }
            "appVersion" -> {
                val info = installedPackage()
                result.success(mapOf("name" to (info.versionName ?: ""), "build" to versionCode(info)))
            }
            "installUpdate" -> installUpdate(call, result)
            else -> result.notImplemented()
        }
    }

    private fun setKeepScreenOn(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            result.success(null)
        }
    }

    // booruShorts asks to shrink into picture-in-picture when the user
    // leaves the app (Home) while a video plays.
    private var pipAuto = false
    private var pipRatio = Rational(9, 16)

    /** A ratio within the limits Android accepts for picture-in-picture. */
    private fun pipRatio(call: MethodCall): Rational {
        val width = (call.argument<Int>("width") ?: 9).coerceAtLeast(1)
        val height = (call.argument<Int>("height") ?: 16).coerceAtLeast(1)
        val ratio = width.toDouble() / height
        return when {
            ratio > 2.39 -> Rational(239, 100)
            ratio < 1 / 2.39 -> Rational(100, 239)
            else -> Rational(width, height)
        }
    }

    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipRatio)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipAuto).setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun setPictureInPicture(call: MethodCall, result: MethodChannel.Result) {
        val auto = call.argument<Boolean>("auto") ?: false
        val ratio = pipRatio(call)
        runOnUiThread {
            pipAuto = auto
            pipRatio = ratio
            try {
                setPictureInPictureParams(pipParams())
            } catch (_: Exception) {
                // Picture-in-picture is unavailable on this device.
            }
            result.success(null)
        }
    }

    private fun enterPictureInPicture(call: MethodCall, result: MethodChannel.Result) {
        val ratio = pipRatio(call)
        runOnUiThread {
            pipRatio = ratio
            val entered = try {
                packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) &&
                    enterPictureInPictureMode(pipParams())
            } catch (_: Exception) { false }
            result.success(entered)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ enters by itself through setAutoEnterEnabled.
        if (pipAuto && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            try {
                enterPictureInPictureMode(pipParams())
            } catch (_: Exception) {
                // Picture-in-picture is unavailable on this device.
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pictureInPicture", isInPictureInPictureMode)
    }

    /** Hides the window from the recent-apps screen and screenshots. */
    private fun setSecureScreen(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            result.success(null)
        }
    }

    /**
     * Shows the biometric prompt with the screen lock as an alternative
     * (API 29+), or the screen-lock confirmation below that. Answers true when
     * verified and false when dismissed; `UNAVAILABLE` means the device has no
     * screen lock to verify with. A prompt that cannot start is
     * `AUTH_FAILED`, which never counts as verified.
     */
    private fun authenticate(call: MethodCall, result: MethodChannel.Result) {
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard == null || !keyguard.isDeviceSecure) {
            result.error("UNAVAILABLE", "No screen lock is set up", null); return
        }
        if (authResult != null) { result.error("BUSY", "Already verifying", null); return }
        val title = call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: "Unlock BooruPlus"
        authResult = result
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val builder = BiometricPrompt.Builder(this).setTitle(title)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    builder.setAllowedAuthenticators(
                        BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL
                    )
                } else {
                    @Suppress("DEPRECATION") builder.setDeviceCredentialAllowed(true)
                }
                builder.build().authenticate(CancellationSignal(), mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authentication: BiometricPrompt.AuthenticationResult?) = finishAuth(true)
                    // A rejected fingerprint keeps the prompt open; only errors (including cancel) end it.
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) = finishAuth(false)
                })
            } else {
                @Suppress("DEPRECATION")
                val intent = keyguard.createConfirmDeviceCredentialIntent(title, null)
                if (intent == null) finishAuth(false) else startActivityForResult(intent, CONFIRM_CREDENTIAL)
            }
        } catch (_: Exception) {
            if (authResult === result) authResult = null
            result.error("AUTH_FAILED", "Verification could not start", null)
        }
    }

    private fun finishAuth(verified: Boolean) {
        val result = authResult ?: return
        authResult = null
        result.success(verified)
    }

    /**
     * Opens the share sheet with `text`, or with the media at `url` saved as
     * `name` in a private cache served by [SharedMediaProvider].
     */
    private fun share(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.takeIf { it.isNotBlank() }
        val url = call.argument<String>("url")
        if (url == null) {
            if (text == null) { result.error("INVALID_REQUEST", "Nothing to share", null); return }
            val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
            try {
                startActivity(Intent.createChooser(intent, null))
                result.success(null)
            } catch (_: Exception) { result.error("SHARE_UNAVAILABLE", "No app can share this", null) }
            return
        }
        val name = call.argument<String>("name")?.trim()
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS media can be shared", null); return }
        if (!validFileName(name)) { result.error("INVALID_NAME", "Invalid file name", null); return }
        background(result, mediaExecutor) {
            val file = saveShared(url!!, name!!)
            val uri = SharedMediaProvider.uriFor(this, file)
            val intent = Intent(Intent.ACTION_SEND)
                .setType(mediaMimeType(file.name))
                .putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData.newRawUri(file.name, uri)
            if (text != null) intent.putExtra(Intent.EXTRA_TEXT, text)
            runOnUiThread {
                try { startActivity(Intent.createChooser(intent, null)) } catch (_: Exception) { }
            }
            null
        }
    }

    /** Downloads [url] into a new share-cache file named [name] ([newSharedFile]). */
    private fun saveShared(url: String, name: String): File {
        val file = newSharedFile(name)
        try {
            openSecureDownload(url).use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    val deadline = System.nanoTime() + TRANSFER_DEADLINE_NANOS
                    var total = 0L
                    while (true) {
                        if (closing || Thread.currentThread().isInterrupted) throw IOException("Cancelled")
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_SHARE_BYTES) throw IOException("Too large to share")
                        if (System.nanoTime() > deadline) throw IOException("Share timed out")
                        output.write(buffer, 0, count)
                    }
                }
            }
        } catch (error: Exception) {
            file.parentFile?.deleteRecursively()
            throw error
        }
        return file
    }

    /**
     * Opens Android's "Set as" chooser (wallpaper, contact photo, and so on)
     * with the image at `url`, saved to the share cache first.
     */
    private fun setAs(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")?.trim()
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS media can be used", null); return }
        if (!validFileName(name)) { result.error("INVALID_NAME", "Invalid file name", null); return }
        background(result, mediaExecutor) {
            val file = saveShared(url!!, name!!)
            val uri = SharedMediaProvider.uriFor(this, file)
            val intent = Intent(Intent.ACTION_ATTACH_DATA)
                .setDataAndType(uri, mediaMimeType(file.name))
                .putExtra("mimeType", mediaMimeType(file.name))
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val opened = FutureTask {
                try { startActivity(Intent.createChooser(intent, null)); true } catch (_: Exception) { false }
            }
            runOnUiThread(opened)
            if (!opened.get()) {
                file.parentFile?.deleteRecursively()
                throw IOException("No app can use this image")
            }
            null
        }
    }

    /** Puts the image at `url` on the clipboard, served from the share cache. */
    private fun copyImage(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")?.trim()
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS media can be copied", null); return }
        if (!validFileName(name)) { result.error("INVALID_NAME", "Invalid file name", null); return }
        background(result, mediaExecutor) {
            val file = saveShared(url!!, name!!)
            val uri = SharedMediaProvider.uriFor(this, file)
            val clip = ClipData.newUri(contentResolver, file.name, uri)
            val copied = FutureTask {
                try {
                    getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip) != null
                } catch (_: Exception) { false }
            }
            runOnUiThread(copied)
            if (!copied.get()) throw IOException("Clipboard unavailable")
            null
        }
    }

    /**
     * Saves the video frame at `positionMs` of the video at `url` as a JPEG
     * named `name` to the download folder, like [download]. Redirects are
     * followed first through [openSecureConnection] (HTTPS, public hosts),
     * and the retriever reads the final URL; it gets [FRAME_TIMEOUT_SECONDS]
     * on a thread of its own, so a stalled video holds up no other media work.
     */
    private fun saveFrame(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")?.trim()
        val directory = call.argument<String>("directory")
        val position = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS videos are allowed", null); return }
        if (!validFileName(name) || !name!!.endsWith(".jpg")) { result.error("INVALID_NAME", "Invalid file name", null); return }
        if (Build.VERSION.SDK_INT < 29 && directory == null) { result.error("DIRECTORY_REQUIRED", "Choose a download folder in Settings", null); return }
        background(result, mediaExecutor) {
            val probe = openSecureConnection(url!!) { it.setRequestProperty("Range", "bytes=0-0") }
            val final = try { probe.url.toString() } finally { probe.disconnect() }
            val host = URI(final).host
            val headers = HashMap<String, String>().apply {
                put("User-Agent", USER_AGENT)
                when {
                    isGelbooruHost(host) -> put("Referer", GELBOORU_REFERER)
                    NozomiApi.isMediaHost(host) -> put("Referer", NozomiApi.REFERER)
                    RealbooruApi.isMediaHost(host) -> put("Referer", RealbooruApi.REFERER)
                }
            }
            val retriever = MediaMetadataRetriever()
            val grab = FutureTask {
                try {
                    retriever.setDataSource(final, headers)
                    retriever.getFrameAtTime(position * 1000L, MediaMetadataRetriever.OPTION_CLOSEST)
                } finally { try { retriever.release() } catch (_: Exception) { } }
            }
            Thread(grab, "booruplus-frame").apply { isDaemon = true }.start()
            val frame = try {
                grab.get(FRAME_TIMEOUT_SECONDS, TimeUnit.SECONDS) ?: throw IOException("No frame at this position")
            } catch (_: java.util.concurrent.TimeoutException) {
                grab.cancel(true)
                throw IOException("Frame timed out")
            } catch (error: java.util.concurrent.ExecutionException) {
                throw IOException("Cannot read the video", error.cause)
            }
            var uri: Uri? = null
            try {
                uri = createTarget(name, directory)
                (contentResolver.openOutputStream(uri, "w") ?: throw IOException("Cannot open target")).use { output ->
                    if (!frame.compress(Bitmap.CompressFormat.JPEG, 95, output)) throw IOException("Cannot encode frame")
                }
                if (directory == null && Build.VERSION.SDK_INT >= 29) {
                    contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                }
                uri.toString()
            } catch (error: Exception) {
                uri?.let { deleteTarget(it, directory) }
                throw error
            } finally { frame.recycle() }
        }
    }

    /**
     * A new file named [name] in its own unguessable folder of the share
     * cache, so every share and update gets a content URI of its own: an app
     * granted an earlier file cannot read a later one of the same name, and
     * nothing overwrites a file a receiving app may still be reading. Folders
     * untouched for an hour are pruned first.
     */
    private fun newSharedFile(name: String): File {
        val directory = File(cacheDir, SharedMediaProvider.DIRECTORY).apply { mkdirs() }
        val stale = System.currentTimeMillis() - SHARE_CACHE_MILLIS
        directory.listFiles()?.forEach { entry ->
            if (entry.walkBottomUp().all { it.lastModified() < stale }) entry.deleteRecursively()
        }
        val folder = File(directory, SharedMediaProvider.newToken())
        if (!folder.mkdirs()) throw IOException("Cannot create share folder")
        return File(folder, name)
    }

    /** Asks where to save [content] (a backup), then writes it there. */
    private fun exportFile(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")?.trim()
        val content = call.argument<String>("content")
        if (!validFileName(name) || content == null) { result.error("INVALID_REQUEST", "Invalid export", null); return }
        if (exportResult != null || importResult != null) { result.error("PICKER_BUSY", "A file picker is already open", null); return }
        exportResult = result
        exportContent = content
        try {
            startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(if (call.argument<String>("mimeType") == "text/plain") "text/plain" else "application/json")
                    .putExtra(Intent.EXTRA_TITLE, name),
                EXPORT
            )
        } catch (_: Exception) {
            exportResult = null
            exportContent = null
            result.error("PICKER_UNAVAILABLE", "No file picker is available", null)
        }
    }

    /** Lets the user pick a text file (a backup) and returns its contents. */
    private fun importFile(result: MethodChannel.Result) {
        if (exportResult != null || importResult != null) { result.error("PICKER_BUSY", "A file picker is already open", null); return }
        importResult = result
        try {
            startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                    .putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream")),
                IMPORT
            )
        } catch (_: Exception) {
            importResult = null
            result.error("PICKER_UNAVAILABLE", "No file picker is available", null)
        }
    }

    /**
     * Pools containing a post: Danbooru is searched by post ID, e621/e926 look
     * up the pool IDs the post already lists. Other boards report none.
     */
    private fun pools(call: MethodCall, result: MethodChannel.Result) {
        val board = call.argument<String>("board")
        val postId = call.argument<String>("postId")?.toLongOrNull()
        val ids = (call.argument<List<Any?>>("ids") ?: emptyList()).mapNotNull { it?.toString()?.toLongOrNull() }.take(20)
        val url = when (board) {
            "danbooru" -> postId?.let {
                HttpUrl.Builder().scheme("https").host(HOSTS.getValue("danbooru")).addPathSegment("pools.json")
                    .addQueryParameter("search[post_ids_include_all]", it.toString())
                    .addQueryParameter("limit", "20").build()
            }
            "e621", "e926" -> ids.takeIf { it.isNotEmpty() }?.let {
                HttpUrl.Builder().scheme("https").host(HOSTS.getValue(board)).addPathSegment("pools.json")
                    .addQueryParameter("search[id]", it.joinToString(",")).build()
            }
            else -> null
        }
        if (url == null) { result.success(emptyList<Map<String, Any?>>()); return }
        background(result) {
            client.newCall(Request.Builder().url(url).header("User-Agent", USER_AGENT).build()).execute().use { response ->
                if (!response.isSuccessful) throw IOException("HTTP failure")
                parsePools(response.body?.string() ?: "[]")
            }
        }
    }

    /** Replaces the launcher icon's shortcuts (favorites and saved searches). */
    private fun setShortcuts(call: MethodCall, result: MethodChannel.Result) {
        val manager = getSystemService(ShortcutManager::class.java)
        if (manager == null) { result.success(null); return }
        val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
        val shortcuts = items.take(manager.maxShortcutCountPerActivity).mapNotNull { item ->
            val id = (item["id"] as? String)?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val label = (item["label"] as? String)?.trim()?.take(40)?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val kind = item["kind"] as? String ?: return@mapNotNull null
            val intent = Intent(Intent.ACTION_VIEW).setClass(this, MainActivity::class.java)
                .putExtra(SHORTCUT_KIND, kind)
            (item["board"] as? String)?.let { intent.putExtra(SHORTCUT_BOARD, it) }
            (item["tags"] as? String)?.let { intent.putExtra(SHORTCUT_TAGS, it) }
            ShortcutInfo.Builder(this, id).setShortLabel(label).setLongLabel(label)
                .setIcon(Icon.createWithResource(this, R.drawable.app_icon))
                .setIntent(intent).build()
        }
        try {
            manager.dynamicShortcuts = shortcuts
        } catch (_: Exception) {
            // Rate limited or refused by the launcher; the next change retries.
        }
        result.success(null)
    }

    private fun validFileName(name: String?): Boolean =
        !name.isNullOrEmpty() && name.length <= 180 && !name.contains('/') && !name.contains('\\') &&
            !name.startsWith(".") && name.none { it.code < 32 }

    private fun autocomplete(call: MethodCall, result: MethodChannel.Result) {
        val board = call.argument<String>("board")
        if (board !in HOSTS) { result.error("INVALID_BOARD", "Unsupported imageboard", null); return }
        val query = call.argument<String>("query") ?: ""
        val limit = (call.argument<Number>("limit") ?: 10).toInt().coerceIn(1, 100)
        val key = call.argument<String>("apiKey")
        val user = call.argument<String>("userId")
        if (board in setOf("rule34", "gelbooru") && (key.isNullOrBlank() || user.isNullOrBlank())) {
            result.error("AUTH_REQUIRED", "A user ID and API key are required", null); return
        }
        if (board in setOf("konachan", "yandere")) { result.success(emptyList<Map<String, Any?>>()); return }
        // Sankaku sends its optional session's access token as apiKey.
        sankakuFamily(board)?.let { api -> background(result) { api.autocomplete(query, limit, key) }; return }
        boardClients[board]?.let { api -> background(result) { api.value.autocomplete(query, limit) }; return }
        if (board == "nozomi") { background(result) { nozomi.autocomplete(query, limit) }; return }
        background(result) {
            val api = when (board) {
                "rule34" -> ImageBoards.createRule34(key!!, user!!, client)
                "gelbooru" -> ImageBoards.createGelbooru(key!!, user!!, client)
                "e621" -> boards.E621
                "e926" -> boards.E926
                "danbooru" -> boards.DANBOORU
                "safebooru" -> boards.SAFEBOORU
                else -> boards.SAFEBOORU
            }
            try {
                api.autocomplete<IAutoComplete>(query, limit).blocking().mapNotNull { suggestion ->
                    val nameGetters = if (board == "rule34") {
                        arrayOf("getValue", "getTagName", "getName", "getLabel")
                    } else {
                        arrayOf("getTagName", "getName", "getValue", "getLabel")
                    }
                    val name = value(suggestion, *nameGetters)?.toString()?.trim()
                    if (name.isNullOrEmpty()) return@mapNotNull null
                    mapOf(
                        "name" to name,
                        "category" to autocompleteCategory(board!!, suggestion),
                        "postCount" to (value(suggestion, "getPostCount") as? Number)?.toInt()
                    )
                }
            } catch (_: IllegalArgumentException) { emptyList<Map<String, Any?>>() }
        }
    }

    private fun autocompleteCategory(board: String, suggestion: Any): String {
        if (board == "safebooru") return "general"
        val raw = value(suggestion, "getCategory", "getType")
        val number = (raw as? Number)?.toInt() ?: raw?.toString()?.trim()?.toIntOrNull()
        return if (number != null) {
            when (board) {
                "e621", "e926" -> when (number) { 0 -> "general"; 1 -> "artist"; 3 -> "copyright"; 4 -> "character"; 5 -> "species"; 7 -> "meta"; 8 -> "lore"; else -> "unknown" }
                // Keep Danbooru's numeric ids local to Danbooru. Gelbooru
                // autocomplete normally supplies a semantic category string,
                // while Rule34 supplies a provider-owned type string; numeric
                // values from either provider remain unknown rather than being
                // guessed with another board's taxonomy.
                "danbooru" -> when (number) { 0 -> "general"; 1 -> "artist"; 3 -> "copyright"; 4 -> "character"; 5 -> "meta"; else -> "unknown" }
                else -> "unknown"
            }
        } else when (raw?.toString()?.trim()?.lowercase()) {
            "general", "artist", "copyright", "character", "species", "meta", "lore" -> raw.toString().trim().lowercase()
            else -> "unknown"
        }
    }

    private fun background(
        result: MethodChannel.Result,
        pool: java.util.concurrent.Executor = executor,
        feed: FeedTask? = null,
        operation: () -> Any?
    ) {
        if (closing) { result.error("CANCELLED", "Activity closed", null); return }
        pending.add(result)
        pool.execute {
            // A feed superseded before it started was already answered.
            if (feed?.cancelled == true) return@execute
            currentFeed.set(feed)
            try {
                val value = operation()
                runOnUiThread { if (pending.remove(result)) result.success(value) }
            } catch (error: Exception) {
                val code = when (error) {
                    is SecurityException -> "DIRECTORY_ACCESS"
                    is IllegalArgumentException -> "INVALID_REQUEST"
                    is SankakuAuthException -> if (error.expired) "AUTH_EXPIRED" else "AUTH_REJECTED"
                    is SankakuTagLimitException -> "TAG_LIMIT"
                    is UpdateRejectedException -> error.code
                    is DownloadPausedException -> "PAUSED"
                    else -> if (rateLimit(error) != null) "RATE_LIMITED" else "REQUEST_FAILED"
                }
                // Only the provider's numeric tag limit or retry delay is passed on as details.
                val details = (error as? SankakuTagLimitException)?.limit?.let { mapOf("limit" to it) }
                    ?: (error as? DownloadPausedException)?.let { mapOf("uri" to it.uri) }
                    ?: rateLimit(error)?.retryAfterSeconds?.let { mapOf("retryAfter" to it) }
                // Never expose exception messages: upstream errors may contain authenticated URLs or tokens.
                runOnUiThread { if (pending.remove(result)) result.error(code, "Request failed. Check the connection, credentials, or folder access.", details) }
            } catch (_: LinkageError) {
                runOnUiThread { if (pending.remove(result)) result.error("COMPATIBILITY", "The API library is not compatible with this Android runtime.", null) }
            } finally {
                currentFeed.remove()
            }
        }
    }

    /**
     * Cancels the previous feed fetch and answers it with `CANCELLED` (Dart
     * already ignores it), then makes [result] the current feed fetch.
     * `id:` lookups and credential checks never send `feed`, so they run on.
     */
    private fun startFeed(result: MethodChannel.Result): FeedTask {
        feedTask?.let { old ->
            old.cancel()
            if (pending.remove(old.result)) old.result.error("CANCELLED", "Superseded by a newer feed request", null)
        }
        return FeedTask(result).also { feedTask = it }
    }

    /** Records a feed task's current call so [FeedTask.cancel] can stop it. */
    private fun trackFeedCall(chain: Interceptor.Chain): Response {
        currentFeed.get()?.let { task ->
            task.call = chain.call()
            // Paired with cancel(): one side always sees the other's write.
            if (task.cancelled) throw IOException("Cancelled")
        }
        return chain.proceed(chain.request())
    }

    /** The client for a board served by Sankaku's API, or null for other boards. */
    private fun sankakuFamily(board: String?): SankakuApi? = when (board) {
        "sankaku" -> sankaku
        "idolcomplex" -> idolComplex
        else -> null
    }

    private fun cancelled(): Boolean =
        closing || Thread.currentThread().isInterrupted || currentFeed.get()?.cancelled == true

    /** Sankaku-only password sign-in; returns the session map from [sankakuSession]. */
    private fun signIn(call: MethodCall, result: MethodChannel.Result) {
        if (call.argument<String>("board") != "sankaku") { result.error("INVALID_BOARD", "Sign-in is not supported for this imageboard", null); return }
        val login = call.argument<String>("login")?.trim()
        val password = call.argument<String>("password")
        if (login.isNullOrEmpty() || password.isNullOrEmpty()) {
            result.error("INVALID_REQUEST", "A username and password are required", null); return
        }
        background(result) { sankaku.signIn(login, password) }
    }

    private fun refreshSignIn(call: MethodCall, result: MethodChannel.Result) {
        if (call.argument<String>("board") != "sankaku") { result.error("INVALID_BOARD", "Sign-in is not supported for this imageboard", null); return }
        val refreshToken = call.argument<String>("refreshToken")
        if (refreshToken.isNullOrBlank()) { result.error("AUTH_REJECTED", "Sign in again", null); return }
        background(result) { sankaku.refreshSignIn(refreshToken, call.argument<String>("userId") ?: "") }
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
        val feed = if (call.argument<Boolean>("feed") == true) startFeed(result) else null
        // Boards with their own HTTP clients (ExtraBoards.kt, MoreBoards.kt).
        boardClients[board]?.let { api ->
            background(result, feed = feed) { api.value.fetch(tags, page, limit, random, seed) { cancelled() } }
            return
        }
        if (board == "nozomi") {
            background(result, feed = feed) {
                nozomi.fetch(tags, page, limit, random, seed, makeCursorKey("nozomi", tags, limit, random, if (random) seed else 0)) { cancelled() }
            }
            return
        }
        val sankakuApi = sankakuFamily(board)
        if (sankakuApi != null) {
            background(result, feed = feed) {
                // Sankaku pages by keyset token and orders discovery with
                // order:random, so it bypasses the windowed library path.
                // Only random feeds key their token chain by seed: callers
                // that omit it get a fresh seed per call.
                sankakuApi.fetch(
                    tags, page, limit, random, makeCursorKey(board!!, tags, limit, random, if (random) seed else 0),
                    avifPreviews = Build.VERSION.SDK_INT >= 31,
                    accessToken = key,
                ) { cancelled() }
            }
            return
        }
        background(result, feed = feed) {
            val api = when (board) {
                "rule34" -> ImageBoards.createRule34(key!!, user!!, client)
                "gelbooru" -> ImageBoards.createGelbooru(key!!, user!!, client)
                "e621" -> boards.E621
                "e926" -> boards.E926
                // Keep konachan.com as the full-content primary. Its direct
                // custom board avoids any provider-specific default changes.
                "konachan" -> konachanCom
                "yandere" -> boards.YANDERE
                "danbooru" -> boards.DANBOORU
                else -> boards.SAFEBOORU
            }
            val window = if (random) discoveryWindows.getOrPut(seed) { Random(seed).nextInt(21) } else 0
            val cursorKey = makeCursorKey(board!!, tags, limit, random, seed)
            if (page == 0) providerCursors.remove(cursorKey)
            var images = if (board == "konachan") {
                fetchKonachanWindow(tags, page, limit, window, cursorKey)
            } else {
                fetchWindow(api, board, tags, page, limit, window, cursorKey)
            }
            if (random && page == 0 && images.isEmpty() && window > 0) {
                discoveryWindows[seed] = 0
                providerCursors.remove(cursorKey)
                images = fetchWindow(api, board, tags, page, limit, 0, cursorKey)
            }
            if (discoveryWindows.size > 128) discoveryWindows.keys.filter { it != seed }.take(64).forEach { discoveryWindows.remove(it) }
            if (providerCursors.size > 256) providerCursors.keys.take(128).forEach { providerCursors.remove(it) }
            if (cancelled()) throw IOException("Cancelled")
            val ordered = if (random) images.shuffled(Random(seed xor page)) else images
            enrichProviderTags(board, ordered, key, user)
            ordered.map { mapImage(it, board, key, user) }
        }
    }

    /**
     * Gelbooru's tag API accepts a space-separated `names` list and returns
     * [{"name":"...", "type":0}]. Keep this deliberately bounded: post
     * fetching must remain useful when the metadata service is unavailable.
     */
    private fun enrichProviderTags(
        board: String,
        images: List<BoardImage>,
        apiKey: String?,
        userId: String?
    ) {
        if (board != "gelbooru" || apiKey.isNullOrBlank() || userId.isNullOrBlank()) return
        val missing = LinkedHashSet<String>()
        images.flatMap { it.getTags() ?: emptyList() }.forEach { tag ->
            val name = tag.trim()
            if (name.isNotEmpty() && tagCategory(board, name) == null) missing.add(name)
        }
        if (missing.isEmpty()) return
        for (batch in missing.chunked(TAG_LOOKUP_BATCH_SIZE).take(TAG_LOOKUP_MAX_BATCHES)) {
            try {
                val url = okhttp3.HttpUrl.Builder()
                    .scheme("https").host("gelbooru.com").addPathSegments("index.php")
                    .addQueryParameter("page", "dapi").addQueryParameter("s", "tag")
                    .addQueryParameter("q", "index").addQueryParameter("json", "1")
                    .addQueryParameter("names", batch.joinToString(" "))
                    .addQueryParameter("api_key", apiKey).addQueryParameter("user_id", userId)
                    .build()
                gelbooruTagClient.newCall(Request.Builder().url(url).header("User-Agent", USER_AGENT).build())
                    .execute().use { response ->
                        if (!response.isSuccessful) return
                        val body = response.body?.string() ?: return
                        val records = parseGelbooruTagRecords(body)
                        val found = HashSet<String>()
                        for (index in 0 until records.length()) {
                            val record = records.optJSONObject(index) ?: continue
                            val name = record.optString("name").trim()
                            if (name.isEmpty()) continue
                            putTagCategory(board, name, gelbooruTagCategory(record.opt("type")))
                            found.add(name)
                        }
                        // Negative caching prevents repeated lookups for tags
                        // omitted by the provider response.
                        batch.filterNot { found.contains(it) }.forEach { putTagCategory(board, it, "unknown") }
                    }
            } catch (_: Exception) {
                // Metadata is optional; post results must not fail because of it.
                break
            }
        }
    }

    private fun tagCategory(board: String, tag: String): String? = synchronized(gelbooruTagCacheLock) {
        gelbooruTagCache["$board\u0000$tag"]
    }

    private fun putTagCategory(board: String, tag: String, category: String) = synchronized(gelbooruTagCacheLock) {
        gelbooruTagCache["$board\u0000$tag"] = category
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
            if (cancelled()) throw IOException("Cancelled")
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

    private fun fetchKonachanWindow(
        tags: List<String>,
        page: Int,
        limit: Int,
        window: Int,
        cursorKey: String,
    ): List<BoardImage> {
        val safeFallback = konachanFallbackAllowed(tags)
        try {
            val primary = fetchWindow(konachanCom, "konachan", tags, page, limit, window, cursorKey)
            if (primary.isNotEmpty() || !safeFallback) return primary
        } catch (error: RuntimeException) {
            if (!safeFallback) throw error
        }

        // konachan.net is safe-mode only: never send an explicit query there.
        // Reset a partially advanced cursor so the fallback keeps page offsets
        // and provider-page semantics independent of the failed .com request.
        providerCursors.remove(cursorKey)
        return fetchWindow(konachanNet, "konachan", tags, page, limit, window, cursorKey)
    }

    private fun konachanFallbackAllowed(tags: List<String>): Boolean =
        tags.none { tag ->
            when (tag.trim().lowercase()) {
                // konachan.net is the safe-mode mirror. Do not use it for a
                // query that explicitly asks for questionable or explicit
                // posts, otherwise a successful fallback would look like a
                // complete result set while silently omitting those ratings.
                "questionable", "rating:q", "rating:questionable",
                "rating:se", "rating:sensitive",
                "explicit", "rating:e", "rating:explicit" -> true
                else -> false
            }
        }

    private fun mapImage(image: BoardImage, board: String, apiKey: String?, userId: String?): Map<String, Any?> {
        val original = authorizeMediaUrl(normalizeUrl(playableUrl(image, board), board), board, apiKey, userId)
        val preview = authorizeMediaUrl(
            normalizeUrl(value(image, "getParsedPreviewFileUrl", "getPreview_url", "getPreviewUrl")?.toString(), board),
            board, apiKey, userId
        )
        val rawTags = image.getTags() ?: emptyList<String>()
        val details = tagDetails(image, board, rawTags)
        return mapOf(
            "id" to (value(image, "getId")?.toString() ?: "0"),
            "url" to original, "previewUrl" to preview,
            "tags" to rawTags,
            "tagDetails" to details,
            "postUrl" to postUrl(board, value(image, "getId")?.toString()),
            "rating" to (image.getRating()?.toString() ?: "Unknown"),
            "uploader" to (value(image, "getUploader_name", "getOwner", "getAuthor", "getUploader_id")?.toString() ?: ""),
            "source" to sourceValue(image), "width" to image.getWidth(), "height" to image.getHeight(),
            "score" to image.getScore(), "description" to (value(image, "getDescription")?.toString() ?: ""),
            "videoVariants" to videoVariants(image, board, original),
            "md5" to (value(image, "getMd5")?.toString()?.trim()?.lowercase()?.takeIf { MD5_HASH.matches(it) } ?: ""),
            "parentId" to (value(image, "getParent_id") as? Number)?.toLong()?.takeIf { it > 0 }?.toString(),
            "hasChildren" to (image.hasChildren() || value(image, "getHas_active_children") == true),
            "sampleUrl" to sampleUrl(image, board, original, preview, apiKey, userId),
            "pools" to ((value(image, "getPools") as? List<*>)?.mapNotNull { (it as? Number)?.toLong()?.toString() } ?: emptyList<String>()),
        )
    }

    /** A resized rendition for the viewer's data saver; empty when there is none. */
    private fun sampleUrl(image: BoardImage, board: String, original: String, preview: String, apiKey: String?, userId: String?): String {
        val raw = if (board == "danbooru") value(image, "getParsedLargeFileUrl") else value(image, "getSample_url")
        val url = authorizeMediaUrl(normalizeUrl(raw?.toString(), board), board, apiKey, userId)
        return if (url == original || url == preview) "" else url
    }

    /**
     * Danbooru ugoira originals are ZIP frame archives. Their large sample is
     * a WebM rendition that the video player can stream directly.
     */
    private fun playableUrl(image: BoardImage, board: String): String? {
        val url = image.getURL()
        if (board != "danbooru" || value(image, "getFile_ext")?.toString()?.lowercase() != "zip") return url
        val sample = value(image, "getParsedLargeFileUrl")?.toString() ?: return url
        return if (sample.substringBefore('?').lowercase().let { it.endsWith(".webm") || it.endsWith(".mp4") }) sample else url
    }

    private fun videoVariants(image: BoardImage, board: String, original: String): List<Map<String, Any?>> {
        if (board != "e621" && board != "e926") return emptyList()
        val alternates = (value(image, "getSample") as? Map<*, *>)?.get("alternates") as? Map<*, *> ?: return emptyList()
        return parseVideoAlternates(alternates).mapNotNull { variant ->
            val url = normalizeUrl(variant.url, board)
            if (url.isEmpty() || url == original) null
            else mapOf(
                "label" to variant.label, "url" to url, "width" to variant.width,
                "height" to variant.height, "quality" to variant.quality
            )
        }.distinctBy { it["url"] }
    }

    private fun tagDetails(image: BoardImage, board: String, rawTags: List<String>): List<Map<String, String>> {
        val result = LinkedHashMap<String, String>()
        fun add(values: Any?, category: String) {
            (values as? List<*>)?.forEach { tag ->
                val name = tag?.toString()?.trim() ?: ""
                if (name.isNotEmpty()) result.putIfAbsent(name, category)
            }
        }
        if (board == "e621" || board == "e926") {
            val groups = value(image, "getAllTags")
            add(value(groups ?: image, "getGeneral"), "general")
            add(value(groups ?: image, "getArtist"), "artist")
            add(value(groups ?: image, "getCopyright"), "copyright")
            add(value(groups ?: image, "getCharacter"), "character")
            add(value(groups ?: image, "getSpecies"), "species")
            add(value(groups ?: image, "getMeta"), "meta")
            add(value(groups ?: image, "getLore"), "lore")
            add(rawTags, "general")
        } else if (board == "danbooru") {
            add(value(image, "getTag_string_general")?.toString()?.split(Regex("\\s+")), "general")
            add(value(image, "getTag_string_artist")?.toString()?.split(Regex("\\s+")), "artist")
            add(value(image, "getTag_string_character")?.toString()?.split(Regex("\\s+")), "character")
            add(value(image, "getTag_string_copyright")?.toString()?.split(Regex("\\s+")), "copyright")
            add(value(image, "getTag_string_meta")?.toString()?.split(Regex("\\s+")), "meta")
            add(rawTags, "general")
        } else if (board == "gelbooru") {
            rawTags.forEach { tag ->
                val name = tag.trim()
                if (name.isNotEmpty()) {
                    val category = tagCategory(board, name)
                    if (category != null && category != "unknown") result[name] = category
                }
            }
            add(rawTags, "general")
        } else add(rawTags, "general")
        return result.map { mapOf("name" to it.key, "category" to it.value) }
    }

    private fun postUrl(board: String, id: String?): String? {
        val numericId = id?.toLongOrNull() ?: return null
        val host = HOSTS[board] ?: return null
        return when (board) {
            "danbooru", "e621", "e926" -> "https://$host/posts/$numericId"
            "konachan", "yandere" -> "https://$host/post/show/$numericId"
            else -> "https://$host/index.php?page=post&s=view&id=$numericId"
        }
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

    private fun fetchMedia(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("url")
        val parsed = value?.toHttpUrlOrNull()
        if (sankakuFamily(call.argument<String>("board")) != null && parsed != null &&
            parsed.scheme == "https" && isSankakuMediaHost(parsed.host)) {
            background(result, mediaExecutor) {
                decodableMedia(readMedia(value, ::isSankakuMediaHost, null))
            }
            return
        }
        // Nozomi media answers 404 without its site as the Referer.
        if (call.argument<String>("board") == "nozomi" && parsed != null &&
            parsed.scheme == "https" && NozomiApi.isMediaHost(parsed.host)) {
            background(result, mediaExecutor) { readMedia(value, NozomiApi::isMediaHost, NozomiApi.REFERER) }
            return
        }
        // Realbooru media is fetched with the site as Referer, as other clients send it.
        if (call.argument<String>("board") == "realbooru" && parsed != null &&
            parsed.scheme == "https" && RealbooruApi.isMediaHost(parsed.host)) {
            background(result, mediaExecutor) { readMedia(value, RealbooruApi::isMediaHost, RealbooruApi.REFERER) }
            return
        }
        if (parsed == null || !isGelbooruHost(parsed.host) || parsed.scheme != "https" ||
            parsed.queryParameter("api_key").isNullOrBlank() || parsed.queryParameter("user_id").isNullOrBlank()) {
            result.error("INVALID_URL", "Unsupported media URL", null)
            return
        }
        background(result, mediaExecutor) { readMedia(value, ::isGelbooruHost, GELBOORU_REFERER) }
    }

    /**
     * Flutter decodes formats Skia lacks, such as AVIF, through Android's
     * ImageDecoder while blocking its UI thread until the whole image is
     * decoded, so a grid of AVIF previews froze the app as they arrived.
     * They are decoded here on a media thread instead and returned as WebP,
     * which Flutter decodes off the UI thread. Other formats pass unchanged.
     */
    private fun decodableMedia(bytes: ByteArray): ByteArray {
        if (!isAvif(bytes)) return bytes
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) throw IOException("Unsupported image format")
        val source = ImageDecoder.createSource(ByteBuffer.wrap(bytes))
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > MAX_DECODED_SIDE) {
                val scale = MAX_DECODED_SIDE.toDouble() / longest
                decoder.setTargetSize(
                    maxOf(1, (info.size.width * scale).toInt()),
                    maxOf(1, (info.size.height * scale).toInt())
                )
            }
        }
        try {
            val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Bitmap.CompressFormat.WEBP_LOSSY
            } else {
                @Suppress("DEPRECATION") Bitmap.CompressFormat.WEBP
            }
            val output = ByteArrayOutputStream(maxOf(bytes.size, 65536))
            if (!bitmap.compress(format, DECODED_QUALITY, output)) throw IOException("Encoding failed")
            return output.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun readMedia(value: String, allowedHost: (String) -> Boolean, referer: String?): ByteArray {
        var current = value.toHttpUrlOrNull() ?: throw IllegalArgumentException("Invalid URL")
        repeat(MAX_MEDIA_REDIRECTS + 1) {
            if (current.scheme != "https" || !allowedHost(current.host) ||
                current.username.isNotEmpty() || current.password.isNotEmpty()) {
                throw IOException("Invalid media redirect")
            }
            val request = okhttp3.Request.Builder().url(current)
                .apply { if (referer != null) header("Referer", referer) }
                .header("User-Agent", USER_AGENT).build()
            mediaClient.newCall(request).execute().use { response ->
                if (response.isRedirect) {
                    val location = response.header("Location") ?: throw IOException("Invalid redirect")
                    val next = current.resolve(location) ?: throw IOException("Invalid redirect")
                    if (next.scheme != "https" || !allowedHost(next.host) ||
                        next.username.isNotEmpty() || next.password.isNotEmpty()) {
                        throw IOException("Invalid media redirect")
                    }
                    current = next
                } else {
                    if (!response.isSuccessful) throw IOException("HTTP failure")
                    val body = response.body ?: throw IOException("Empty response")
                    if (body.contentLength() > MAX_MEDIA_BYTES) throw IOException("Response too large")
                    val output = ByteArrayOutputStream(minOf(MAX_MEDIA_BYTES.toInt(), 65536))
                    body.byteStream().use { input ->
                        val buffer = ByteArray(65536)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > MAX_MEDIA_BYTES) throw IOException("Response too large")
                            output.write(buffer, 0, count)
                        }
                    }
                    return output.toByteArray()
                }
            }
        }
        throw IOException("Too many redirects")
    }

    private fun sourceValue(image: BoardImage): String {
        val source = value(image, "getSource")?.toString()
        if (!source.isNullOrBlank()) return source
        return (value(image, "getSources") as? List<*>)?.filterIsInstance<String>()?.joinToString("\n") ?: ""
    }

    private fun value(target: Any, vararg names: String): Any? {
        for (name in names) {
            try {
                val method = try { target.javaClass.getMethod(name) } catch (_: NoSuchMethodException) {
                    target.javaClass.getDeclaredMethod(name)
                }
                method.isAccessible = true
                val found = method.invoke(target)
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
        when (requestCode) {
            CONFIRM_CREDENTIAL -> { finishAuth(resultCode == Activity.RESULT_OK); return }
            EXPORT -> { finishExport(resultCode, data?.data); return }
            IMPORT -> { finishImport(resultCode, data?.data); return }
        }
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

    private fun finishExport(resultCode: Int, uri: Uri?) {
        val result = exportResult ?: return
        val content = exportContent
        exportResult = null
        exportContent = null
        if (resultCode != Activity.RESULT_OK || uri == null || content == null) { result.success(false); return }
        background(result, mediaExecutor) {
            (contentResolver.openOutputStream(uri, "wt") ?: throw IOException("Cannot open file")).use {
                it.write(content.toByteArray(Charsets.UTF_8))
            }
            true
        }
    }

    private fun finishImport(resultCode: Int, uri: Uri?) {
        val result = importResult ?: return
        importResult = null
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        background(result, mediaExecutor) {
            (contentResolver.openInputStream(uri) ?: throw IOException("Cannot open file")).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(65536)
                var total = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_IMPORT_BYTES) throw IllegalArgumentException("File too large")
                    output.write(buffer, 0, count)
                }
                output.toString(Charsets.UTF_8.name())
            }
        }
    }

    /**
     * Saves the media at `url` as `name` in `directory` (or Download/BooruPlus).
     * With `resume`, the partial file a paused download left (see
     * [DownloadPausedException]) is continued with a range request when the
     * host allows it, and rewritten from the start otherwise.
     */
    private fun download(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val name = call.argument<String>("name")?.trim()
        val directory = call.argument<String>("directory")
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS download URLs are allowed", null); return }
        if (name.isNullOrEmpty() || name.length > 180 || name.contains('/') || name.contains('\\') || name.any { it.code < 32 }) {
            result.error("INVALID_NAME", "Invalid download name", null); return
        }
        if (Build.VERSION.SDK_INT < 29 && directory == null) { result.error("DIRECTORY_REQUIRED", "Choose a download folder in Settings", null); return }
        val resume = call.argument<String>("resume")?.let(Uri::parse)?.takeIf { ownsPartial(it, directory) }
        // The size the partial file's download reported; a range is only
        // appended when the host reports the same size again.
        val resumeTotal = call.argument<Number>("resumeTotal")?.toLong()?.takeIf { it > 0 }
        // Dart passes an id when it wants progress reports or may pause this download.
        val progressId = call.argument<Number>("id")?.toLong()
        progressId?.let(activeDownloads::add)
        background(result, downloadExecutor) {
            var uri: Uri? = null
            fun pauseRequested() = progressId != null && pausedDownloads.remove(progressId)
            try {
                if (pauseRequested()) throw DownloadPausedException()
                val existing = resume?.let(::partialSize)
                // Open the network first; an HTTP failure must not leave a target stream open.
                val ranged = if (existing != null && existing > 0 && resumeTotal != null && existing < resumeTotal) {
                    openRange(url!!, existing, resumeTotal)
                } else null
                val connection = ranged ?: openSecureConnection(url!!)
                val offset = if (ranged != null) existing!! else 0L
                val length = if (ranged != null) contentRangeTotal(ranged) else connection.contentLengthLong.takeIf { it > 0 }
                downloadStream(connection).use { input ->
                    if (length != null && length > MAX_DOWNLOAD_BYTES) throw DownloadRefusedException("Download too large")
                    uri = if (existing != null) resume else createTarget(name, directory)
                    if (progressId != null) reportTarget(progressId, uri!!)
                    // "wa" appends to the partial file; "wt" rewrites one the host would not continue.
                    val mode = when { ranged != null -> "wa"; existing != null -> "wt"; else -> "w" }
                    (contentResolver.openOutputStream(uri!!, mode) ?: throw IOException("Cannot open target")).use { output ->
                        val buffer = ByteArray(65536)
                        // A host that keeps sending can neither fill the
                        // storage nor hold a download thread for good.
                        val deadline = System.nanoTime() + TRANSFER_DEADLINE_NANOS
                        var received = offset
                        var reported = -1L
                        while (true) {
                            // Closing the app keeps the partial file too, so Dart can resume it later.
                            if (pauseRequested() || closing || Thread.currentThread().isInterrupted) throw DownloadPausedException()
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            if (received > MAX_DOWNLOAD_BYTES) throw DownloadRefusedException("Download too large")
                            if (System.nanoTime() > deadline) throw IOException("Download timed out")
                            output.write(buffer, 0, count)
                            // At most one report per percent (or per 512 KB when the size is unknown).
                            val step = if (length != null) received * 100 / length else received / (512L * 1024L)
                            if (progressId != null && step != reported) {
                                reported = step
                                reportProgress(progressId, received, length)
                            }
                        }
                    }
                }
                if (directory == null && Build.VERSION.SDK_INT >= 29) {
                    contentResolver.update(uri!!, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                }
                uri.toString()
            } catch (_: DownloadPausedException) {
                throw DownloadPausedException(uri?.toString() ?: resume?.toString())
            } catch (error: Exception) {
                // A dropped connection or timeout keeps the partial file, which
                // Dart's retry continues (or discards when the download is
                // removed); a refused or unwritable download deletes it.
                if (error !is IOException || error is DownloadRefusedException) uri?.let { deleteTarget(it, directory) }
                throw error
            } finally {
                progressId?.let {
                    activeDownloads.remove(it)
                    pausedDownloads.remove(it)
                }
            }
        }
    }

    /**
     * The rest of `url` from byte [offset], or null when the host answers
     * with anything other than exactly that range of a [total]-byte file.
     */
    private fun openRange(url: String, offset: Long, total: Long): HttpURLConnection? {
        val connection = try {
            openSecureConnection(url) { it.setRequestProperty("Range", "bytes=$offset-") }
        } catch (_: IOException) { return null }
        val start = connection.getHeaderField("Content-Range")?.removePrefix("bytes ")?.substringBefore('-')?.trim()?.toLongOrNull()
        // A different size means a different file: start over rather than append.
        if (connection.responseCode == 206 && start == offset && contentRangeTotal(connection) == total) return connection
        connection.disconnect()
        return null
    }

    private fun contentRangeTotal(connection: HttpURLConnection): Long? =
        connection.getHeaderField("Content-Range")?.substringAfterLast('/')?.trim()?.toLongOrNull()?.takeIf { it > 0 }

    /** The size of a partial download, or null when it is gone. */
    private fun partialSize(uri: Uri): Long? = try {
        contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize.takeIf { size -> size >= 0 } }
    } catch (_: Exception) { null }

    /**
     * Whether [uri] can be a file this app's downloads wrote: a MediaStore
     * download without a folder, or a document inside the chosen folder.
     */
    private fun ownsPartial(uri: Uri, directory: String?): Boolean = try {
        when {
            uri.scheme != "content" -> false
            directory == null -> uri.authority == MediaStore.AUTHORITY
            else -> {
                val tree = Uri.parse(directory)
                uri.authority == tree.authority && DocumentsContract.isTreeUri(uri) &&
                    DocumentsContract.getTreeDocumentId(uri) == DocumentsContract.getTreeDocumentId(tree)
            }
        }
    } catch (_: Exception) { false }

    private fun deleteTarget(uri: Uri, directory: String?) {
        try {
            if (directory != null) DocumentsContract.deleteDocument(contentResolver, uri) else contentResolver.delete(uri, null, null)
        } catch (_: Exception) { }
    }

    /** Deletes the partial file of a paused download that was removed. */
    private fun discardDownload(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val directory = call.argument<String>("directory")
        if (uri == null || !ownsPartial(uri, directory)) { result.success(false); return }
        background(result, downloadExecutor) { deleteTarget(uri, directory); true }
    }

    /** Where a download is being written, sent once before its first bytes. */
    private fun reportTarget(id: Long, uri: Uri) {
        runOnUiThread {
            if (!closing) downloadChannel?.invokeMethod("target", mapOf("id" to id, "uri" to uri.toString()))
        }
    }

    /**
     * Keeps downloads running while the app is in the background with a
     * foreground service and its notification; see [DownloadKeepAliveService].
     */
    private fun setDownloadsActive(call: MethodCall, result: MethodChannel.Result) {
        if (call.argument<Boolean>("active") == true) {
            askForNotifications()
            DownloadKeepAliveService.update(
                this,
                call.argument<String>("text") ?: "",
                call.argument<Number>("percent")?.toInt() ?: -1,
            )
        } else {
            DownloadKeepAliveService.stop(this)
        }
        result.success(null)
    }

    /** Asks once (Android 13+) to show the download notification. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val preferences = getSharedPreferences(NATIVE_PREFERENCES, MODE_PRIVATE)
        if (preferences.getBoolean(NOTIFICATIONS_ASKED, false)) return
        preferences.edit().putBoolean(NOTIFICATIONS_ASKED, true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS)
    }

    private fun reportProgress(id: Long, received: Long, total: Long?) {
        runOnUiThread {
            if (!closing) downloadChannel?.invokeMethod("progress", mapOf("id" to id, "received" to received, "total" to total))
        }
    }

    /** The size in bytes of the media at `url`, or null when the host does not say. */
    private fun mediaSize(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (!secureHttps(url)) { result.error("INVALID_URL", "Only HTTPS media URLs are allowed", null); return }
        background(result, mediaExecutor) {
            val head = try { openSecureConnection(url!!, "HEAD") } catch (_: IOException) { null }
            val headLength = head?.let { try { it.contentLengthLong } finally { it.disconnect() } }
            if (headLength != null && headLength > 0) return@background headLength
            // Some hosts refuse HEAD or omit the length; ask for one byte and read the total.
            val probe = try { openSecureConnection(url!!) { it.setRequestProperty("Range", "bytes=0-0") } } catch (_: IOException) { return@background null }
            try {
                if (probe.responseCode == 206) {
                    probe.getHeaderField("Content-Range")?.substringAfterLast('/')?.trim()?.toLongOrNull()?.takeIf { it > 0 }
                } else {
                    probe.contentLengthLong.takeIf { it > 0 }
                }
            } finally { probe.disconnect() }
        }
    }

    /**
     * Downloads the release APK at `url` (GitHub only, redirects included)
     * into the share cache, checks that it is a newer build of this app signed
     * with the same key, and opens the package installer with it. Reports
     * progress like [download] when given an `id`.
     */
    private fun installUpdate(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val host = try { URI(url ?: "").host } catch (_: Exception) { null }
        if (!secureHttps(url) || host == null || !isUpdateHost(host)) {
            result.error("INVALID_URL", "Updates come from GitHub releases only", null); return
        }
        val progressId = call.argument<Number>("id")?.toLong()
        background(result, mediaExecutor) {
            // Its own folder: no share or other update can replace the file
            // between the checks below and the installer reading it.
            val file = newSharedFile(UPDATE_FILE)
            try {
                val connection = openSecureConnection(url!!, allowHost = { isUpdateHost(it) })
                val length = connection.contentLengthLong.takeIf { it > 0 }
                downloadStream(connection).use { input ->
                    if (length != null && length > MAX_UPDATE_BYTES) throw IOException("Update too large")
                    file.outputStream().use { output ->
                        val buffer = ByteArray(65536)
                        var received = 0L
                        var reported = -1L
                        while (true) {
                            if (closing || Thread.currentThread().isInterrupted) throw IOException("Cancelled")
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            if (received > MAX_UPDATE_BYTES) throw IOException("Update too large")
                            output.write(buffer, 0, count)
                            val step = if (length != null) received * 100 / length else received / (512L * 1024L)
                            if (progressId != null && step != reported) {
                                reported = step
                                reportProgress(progressId, received, length)
                            }
                        }
                    }
                }
                checkUpdate(file)
            } catch (error: Exception) {
                file.parentFile?.deleteRecursively()
                throw error
            }
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(SharedMediaProvider.uriFor(this, file), APK_MIME_TYPE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            val opened = FutureTask { try { startActivity(intent); true } catch (_: Exception) { false } }
            runOnUiThread(opened)
            if (!opened.get()) {
                file.parentFile?.deleteRecursively()
                throw UpdateRejectedException("UPDATE_INVALID", "No package installer")
            }
            null
        }
    }

    /** Rejects an APK that is not a newer build of this app signed with the same key. */
    private fun checkUpdate(file: File) {
        @Suppress("DEPRECATION")
        val archive = packageManager.getPackageArchiveInfo(file.path, signerFlags())
            ?: throw UpdateRejectedException("UPDATE_INVALID", "Not an app package")
        val installed = installedPackage()
        if (archive.packageName != packageName) throw UpdateRejectedException("UPDATE_INVALID", "A different app")
        if (versionCode(archive) <= versionCode(installed)) {
            throw UpdateRejectedException("UPDATE_NOT_NEWER", "Not newer than the installed build")
        }
        // Some archives report no signers; the installer still compares keys then.
        val incoming = signers(archive)
        val current = signers(installed)
        if (incoming.isNotEmpty() && current.isNotEmpty() && incoming.none(current::contains)) {
            throw UpdateRejectedException("UPDATE_SIGNATURE", "Signed with a different key")
        }
    }

    @Suppress("DEPRECATION")
    private fun installedPackage(): PackageInfo = packageManager.getPackageInfo(packageName, signerFlags())

    @Suppress("DEPRECATION")
    private fun signerFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    /** Signing certificates, including earlier ones the current key was rotated from. */
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
        } else {
            info.signatures
        }
        return signatures.orEmpty().map { it.toCharsString() }.toSet()
    }

    private fun openSecureDownload(value: String): InputStream = downloadStream(openSecureConnection(value))

    private fun downloadStream(connection: HttpURLConnection): InputStream = try {
        object : FilterInputStream(connection.inputStream) {
            override fun close() { try { super.close() } finally { connection.disconnect() } }
        }
    } catch (error: Exception) { connection.disconnect(); throw error }

    /**
     * Follows up to six HTTPS-only redirects, each to a public host
     * ([isPublicHost]) that [allowHost] accepts; returns a connected 2xx
     * response.
     */
    private fun openSecureConnection(
        value: String,
        method: String = "GET",
        allowHost: (String) -> Boolean = { true },
        configure: (HttpURLConnection) -> Unit = {},
    ): HttpURLConnection {
        var current = URI(value)
        repeat(6) {
            if (!secureHttps(current.toString())) throw IOException("Insecure URL")
            if (!allowHost(current.host) || !isPublicHost(current.host)) throw IOException("Unexpected host")
            val connection = current.toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.requestMethod = method
                connection.connectTimeout = 15000
                connection.readTimeout = 30000
                connection.setRequestProperty("User-Agent", USER_AGENT)
                if (isGelbooruHost(current.host)) connection.setRequestProperty("Referer", GELBOORU_REFERER)
                if (NozomiApi.isMediaHost(current.host)) connection.setRequestProperty("Referer", NozomiApi.REFERER)
                if (RealbooruApi.isMediaHost(current.host)) connection.setRequestProperty("Referer", RealbooruApi.REFERER)
                configure(connection)
                val code = connection.responseCode
                if (code in 300..399) {
                    val location = connection.getHeaderField("Location") ?: throw IOException("Invalid redirect")
                    connection.disconnect()
                    current = current.resolve(location)
                } else {
                    if (code !in 200..299) throw IOException("HTTP failure")
                    return connection
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

    private fun mimeType(name: String) = mediaMimeType(name)

    private fun secureHttps(value: String?): Boolean = try {
        val uri = URI(value ?: "")
        uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null
    } catch (_: Exception) { false }

    override fun onDestroy() {
        closing = true
        directoryResult?.success(null)
        directoryResult = null
        exportResult?.success(false)
        exportResult = null
        exportContent = null
        importResult?.success(null)
        importResult = null
        authResult?.success(false)
        authResult = null
        pending.toList().forEach { if (pending.remove(it)) it.error("CANCELLED", "Activity closed", null) }
        client.dispatcher.cancelAll()
        if (nozomiClient.isInitialized()) nozomi.close()
        if (hybooruClient.isInitialized()) hybooruClient.value.close()
        executor.shutdownNow()
        mediaExecutor.shutdownNow()
        downloadExecutor.shutdownNow()
        // Dart's queue goes with the activity; interrupted downloads keep
        // their partial files and resume when the app opens again.
        DownloadKeepAliveService.stop(this)
        super.onDestroy()
    }

    companion object {
        private const val PICKER = 4101
        private const val EXPORT = 4102
        private const val IMPORT = 4103
        private const val CONFIRM_CREDENTIAL = 4104
        private const val NOTIFICATIONS = 4105
        private const val NATIVE_PREFERENCES = "booruplus.native"
        private const val NOTIFICATIONS_ASKED = "notificationsAsked"
        internal const val SHORTCUT_KIND = "com.booruplus.app.SHORTCUT_KIND"
        private const val SHORTCUT_BOARD = "com.booruplus.app.SHORTCUT_BOARD"
        private const val SHORTCUT_TAGS = "com.booruplus.app.SHORTCUT_TAGS"
        internal const val LINK_TEXT = "com.booruplus.app.LINK_TEXT"
        // A link or a short shared message; longer text is cut here.
        internal const val MAX_LINK_TEXT = 2048
        private const val MAX_SHARE_BYTES = 200L * 1024L * 1024L
        // Provider API responses (JSON/XML) are far smaller; media is apart.
        private const val MAX_RESPONSE_BYTES = 16L * 1024L * 1024L
        private const val MAX_DOWNLOAD_BYTES = 2L * 1024L * 1024L * 1024L
        // A whole download or share, however steadily the host sends.
        private const val TRANSFER_DEADLINE_NANOS = 60L * 60L * 1_000_000_000L
        private const val FRAME_TIMEOUT_SECONDS = 60L
        private const val MAX_IMPORT_BYTES = 20L * 1024L * 1024L
        private const val SHARE_CACHE_MILLIS = 60L * 60L * 1000L
        private const val MAX_WINDOW_REQUESTS = 32
        private const val MAX_MEDIA_REDIRECTS = 5
        private const val MAX_MEDIA_BYTES = 50L * 1024L * 1024L
        // Matches the viewer's decode bound; Sankaku previews are 600px.
        private const val MAX_DECODED_SIDE = 4096
        private const val DECODED_QUALITY = 90
        private const val TAG_LOOKUP_BATCH_SIZE = 40
        private const val TAG_LOOKUP_MAX_BATCHES = 4
        private const val TAG_LOOKUP_TIMEOUT_SECONDS = 8L
        private const val TAG_CACHE_LIMIT = 512
        private const val USER_AGENT = "BooruPlus/1.0 Android (imageboard browser)"
        private const val GELBOORU_REFERER = "https://gelbooru.com/"
        // A downloaded update, served to the package installer by SharedMediaProvider.
        private const val UPDATE_FILE = "booruplus-update.apk"
        private const val MAX_UPDATE_BYTES = 300L * 1024L * 1024L
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        // GitHub release downloads redirect to its asset storage.
        private fun isUpdateHost(host: String): Boolean = host == "github.com" || host.endsWith(".githubusercontent.com")
        private val HOSTS = mapOf("rule34" to "rule34.xxx", "e621" to "e621.net", "konachan" to "konachan.com", "yandere" to "yande.re", "danbooru" to "danbooru.donmai.us", "safebooru" to "safebooru.org", "gelbooru" to "gelbooru.com", "e926" to "e926.net", "sankaku" to SankakuApi.SITE_HOST, "idolcomplex" to SankakuApi.IDOL_SITE_HOST, "tbib" to Gelbooru02Api.TBIB_HOST, "aibooru" to AiBooruApi.HOST, "nozomi" to NozomiApi.SITE_HOST, "sakugabooru" to SakugabooruApi.HOST, "xbooru" to Gelbooru02Api.XBOORU_HOST, "mspabooru" to Gelbooru02Api.MSPABOORU_HOST, "eshuushuu" to EShuushuuApi.HOST, "mikubooru" to HybooruApi.HOST, "nanbooru" to ShimmieApi.HOST, "realbooru" to RealbooruApi.HOST, "derpibooru" to DerpibooruApi.HOST)
        private fun isGelbooruHost(host: String): Boolean = host == "gelbooru.com" || host.endsWith(".gelbooru.com")
    }
}

internal fun mediaMimeType(name: String) = when (name.substringAfterLast('.', "").lowercase()) {
    "jpg", "jpeg" -> "image/jpeg"
    "png" -> "image/png"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "avif" -> "image/avif"
    "mp4" -> "video/mp4"
    "webm" -> "video/webm"
    "apk" -> "application/vnd.android.package-archive"
    else -> "application/octet-stream"
}

/**
 * Whether [host] names only public internet addresses. Downloads, shares,
 * and size checks follow URLs from provider posts and restored backups, so
 * they never reach this device, its local network, or other private ranges.
 */
internal fun isPublicHost(host: String?): Boolean {
    val name = host?.removePrefix("[")?.removeSuffix("]")?.trimEnd('.')?.lowercase()
    if (name.isNullOrEmpty() || name == "localhost" || name.endsWith(".localhost")) return false
    val addresses = try { InetAddress.getAllByName(name) } catch (_: Exception) { return false }
    return addresses.isNotEmpty() && addresses.all(::isPublicAddress)
}

private fun isPublicAddress(address: InetAddress): Boolean {
    if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
        address.isSiteLocalAddress || address.isMulticastAddress) return false
    val bytes = address.address
    if (address is Inet6Address) {
        // An IPv4 address carried in IPv6 (::a.b.c.d) is judged as IPv4.
        if (bytes.take(12).all { it == 0.toByte() }) {
            return isPublicAddress(InetAddress.getByAddress(bytes.copyOfRange(12, 16)))
        }
        // Unique local addresses, fc00::/7.
        return (bytes[0].toInt() and 0xfe) != 0xfc
    }
    val first = bytes[0].toInt() and 0xff
    val second = bytes[1].toInt() and 0xff
    return when {
        first == 0 -> false
        first == 100 && second in 64..127 -> false // Carrier-grade NAT
        first == 192 && second == 0 && bytes[2].toInt() == 0 -> false
        first == 198 && second in 18..19 -> false
        first >= 240 -> false
        else -> true
    }
}

/**
 * A download stopped by Dart's pause (or the app closing). Its partial file
 * at [uri] is kept and sent to Dart as the `PAUSED` error's details.
 */
internal class DownloadPausedException(val uri: String? = null) : IOException("Paused")

/** A download that must not be kept or retried as it is, such as one too large. */
internal class DownloadRefusedException(message: String) : IOException(message)

/** A downloaded update that must not be installed; [code] is sent to Dart. */
internal class UpdateRejectedException(val code: String, message: String) : IOException(message)

/** Danbooru/e621 pool records as `{id, name, postCount}`; names use spaces. */
internal fun parsePools(body: String): List<Map<String, Any?>> {
    val records = JSONArray(body.trim().ifEmpty { "[]" })
    val pools = ArrayList<Map<String, Any?>>()
    for (index in 0 until records.length()) {
        val record = records.optJSONObject(index) ?: continue
        val id = record.optLong("id")
        if (id <= 0) continue
        pools.add(
            mapOf(
                "id" to id.toString(),
                "name" to record.optString("name").replace('_', ' ').trim().ifEmpty { "Pool $id" },
                "postCount" to record.optInt("post_count"),
            )
        )
    }
    return pools
}

internal fun parseGelbooruTagRecords(body: String): JSONArray {
    val payload = body.trim()
    if (payload.startsWith("[")) return JSONArray(payload)
    val envelope = JSONObject(payload)
    val tags = envelope.opt("tag")
    if (tags is JSONArray) return tags
    if (tags is JSONObject) return JSONArray().apply { put(tags) }
    return JSONArray()
}

/** [quality] is the resolution tier (e.g. 720 for "720p"), not the height. */
internal data class VideoAlternate(val label: String, val url: String, val width: Int, val height: Int, val quality: Int)

/**
 * Reads e621 `sample.alternates`. Current responses group entries with a
 * single `url` under "original", "variants" (same-size MP4) and "samples"
 * ("480p", "720p"); older ones mapped "480p"/"original" directly to
 * `{type, width, height, urls: [webm, mp4]}`. Both shapes are accepted and MP4
 * is preferred for device decoder support. e621 names tiers by the short side
 * (a portrait "720p" sample can be 810x1440), so quality uses the tier from the
 * key, or the short side when the key has none. Results are best first.
 */
internal fun parseVideoAlternates(alternates: Map<*, *>): List<VideoAlternate> {
    val found = ArrayList<VideoAlternate>()
    val tier = Regex("(\\d+)p")
    fun visit(key: String, node: Any?, depth: Int) {
        val entry = node as? Map<*, *> ?: return
        val type = entry["type"] as? String
        if (type != null && type != "video") return
        val urls = (entry["urls"] as? List<*>)?.filterIsInstance<String>()?.filter { it.isNotBlank() } ?: emptyList()
        val url = (entry["url"] as? String)?.takeIf { it.isNotBlank() }
            ?: urls.firstOrNull { it.substringBefore('?').endsWith(".mp4", ignoreCase = true) }
            ?: urls.firstOrNull()
        if (url != null) {
            val height = (entry["height"] as? Number)?.toInt() ?: 0
            val width = (entry["width"] as? Number)?.toInt() ?: 0
            val named = tier.matchEntire(key)?.groupValues?.get(1)?.toIntOrNull()
            val quality = named ?: if (width > 0 && height > 0) minOf(width, height) else height
            if (quality <= 0) return
            val label = if (named != null) key else {
                val extension = url.substringBefore('?').substringAfterLast('.', "").uppercase()
                if (extension.isEmpty()) "${quality}p" else "${quality}p $extension"
            }
            found.add(VideoAlternate(label, url, width, height, quality))
            return
        }
        if (depth < 2) entry.forEach { (child, value) -> if (child is String && child != "has") visit(child, value, depth + 1) }
    }
    alternates.forEach { (key, value) -> if (key is String && key != "has") visit(key, value, 0) }
    return found
        .sortedWith(compareByDescending<VideoAlternate> { it.quality }.thenBy { if (it.url.substringBefore('?').endsWith(".mp4", true)) 0 else 1 })
        .distinctBy { it.url }
}

internal fun gelbooruTagCategory(raw: Any?): String {
    val type = when (raw) {
        is Number -> raw.toInt()
        else -> raw?.toString()?.trim()?.toIntOrNull()
    }
    // Gelbooru tag types are provider-local: 0 general, 1 artist,
    // 2 invalid/unused, 3 copyright, 4 character, 5 meta.
    return when (type) {
        0 -> "general"
        1 -> "artist"
        3 -> "copyright"
        4 -> "character"
        5 -> "meta"
        else -> "unknown"
    }
}
