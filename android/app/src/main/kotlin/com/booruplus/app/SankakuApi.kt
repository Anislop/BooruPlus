package com.booruplus.app

import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InterruptedIOException
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Sankaku refused a password or refresh token, or a bearer token expired. */
internal class SankakuAuthException(val expired: Boolean) : IOException("Sankaku sign-in rejected")

/** The search used more counted tags than the account allows; [limit] is Sankaku's reported maximum. */
internal class SankakuTagLimitException(val limit: Int?) : IOException("Sankaku tag limit")

/**
 * Client for the Sankaku Complex API at sankakuapi.com (the
 * capi-v2.sankakucomplex.com host used by older wrappers now refuses requests).
 * Requests are anonymous unless Dart passes an access token.
 *
 * Provider behavior this relies on:
 * - `/posts/keyset` returns `{meta: {next}, data: [...]}` with full typed tags.
 *   Offset paging (`/posts?page=`) is refused for anonymous users beyond page
 *   50, so keyset tokens are tracked per Flutter page instead.
 * - Post IDs are opaque alphanumeric strings (older responses used numbers).
 * - Media URLs are signed and expire after roughly an hour; Dart refreshes
 *   saved posts by looking them up again with an `id:` search.
 * - Pages can be shorter than requested because the server filters posts; a
 *   null `next` token is the only end marker.
 * - `POST /auth/token` with `{login, password}` returns `access_token`,
 *   `refresh_token`, and their lifetimes in `access_token_ttl` /
 *   `refresh_token_ttl` seconds (the access token is also a JWT with `exp`).
 *   Posting `{refresh_token}` to the same endpoint renews the session. A bad
 *   password is HTTP 403; a bad or expired bearer token is HTTP 401.
 * - Tag-limit refusals are HTTP 429 with a code ending in `tags-limit` and the
 *   allowed count in `param`.
 */
internal class SankakuApi(private val client: OkHttpClient, private val userAgent: String) {
    // "$cursorKey\u0003$page" -> keyset token for that Flutter page. An empty
    // token marks an exhausted search.
    private val cursors = ConcurrentHashMap<String, String>()

    fun fetch(
        tags: List<String>,
        page: Int,
        limit: Int,
        random: Boolean,
        cursorKey: String,
        avifPreviews: Boolean,
        accessToken: String?,
        cancelled: () -> Boolean,
    ): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        // The timeout covers this entire page search, not each successive
        // keyset request. Unavailable media must not multiply a 45s timeout
        // by MAX_REQUESTS while the UI waits for its first usable posts.
        val timeoutMillis = client.callTimeoutMillis.takeIf { it > 0 }?.toLong() ?: 45_000L
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        if (page == 0) cursors.keys.filter { it.startsWith("$cursorKey\u0003") }.forEach { cursors.remove(it) }
        if (cursors.size > MAX_CURSORS) cursors.keys.take(MAX_CURSORS / 2).forEach { cursors.remove(it) }
        val query = sankakuQuery(tags, random)
        val stored = cursors["$cursorKey\u0003$page"]
        if (stored != null && stored.isEmpty()) return emptyList()
        if (page > 0 && stored == null) {
            // The keyset chain was lost (for example after cursor pruning).
            // Offset paging still serves the first 50 pages anonymously.
            val batch = request(endpoint("posts").addQueryParameter("page", (page + 1).toString())
                .addQueryParameter("limit", minOf(limit, PAGE_SIZE).toString())
                .addQueryParameter("tags", query).build(), accessToken, deadline)
            val array = batch as? JSONArray ?: (batch as JSONObject).optJSONArray("data") ?: JSONArray()
            return posts(array, avifPreviews, limit)
        }

        val result = ArrayList<Map<String, Any?>>()
        var token = stored
        var requests = 0
        val visited = HashSet<String>()
        if (!token.isNullOrEmpty()) visited.add(token)
        while (result.isEmpty() && requests++ < MAX_REQUESTS) {
            if (cancelled()) throw IOException("Cancelled")
            // Return the first usable batch, even if filtering made it short.
            // Filling it with more HTTP requests delays already usable posts
            // and loses them altogether if a later request fails.
            val size = minOf(limit, PAGE_SIZE)
            val url = endpoint("posts/keyset").addQueryParameter("limit", size.toString())
                .addQueryParameter("tags", query)
            if (!token.isNullOrEmpty()) url.addQueryParameter("next", token)
            val body = request(url.build(), accessToken, deadline) as? JSONObject ?: throw IOException("Unexpected response")
            result.addAll(posts(body.optJSONArray("data") ?: JSONArray(), avifPreviews, limit - result.size))
            token = jsonString(body.optJSONObject("meta"), "next") ?: ""
            if (token.isEmpty()) break
            if (!visited.add(token)) throw IOException("Repeated pagination token")
        }
        if (cancelled()) throw IOException("Cancelled")
        // Empty means exhausted to Dart. Hitting a search bound with a live
        // cursor is a retryable failure, not the end of the provider's feed.
        if (result.isEmpty() && !token.isNullOrEmpty()) throw IOException("No accessible posts in page window")
        cursors["$cursorKey\u0003${page + 1}"] = token ?: ""
        return result
    }

    fun autocomplete(query: String, limit: Int, accessToken: String?): List<Map<String, Any?>> {
        val value = query.trim().trimStart('-', '~').trim()
        if (value.isEmpty()) return emptyList()
        val body = request(endpoint("tags/autosuggestCreating").addQueryParameter("tag", value).build(), accessToken)
        return parseSankakuSuggestions(body as? JSONArray ?: JSONArray(), limit)
    }

    /** Exchanges a password for a session map; the password is not kept. */
    fun signIn(login: String, password: String): Map<String, Any?> {
        val body = JSONObject().put("login", login).put("password", password)
        return sankakuSession(authenticate(body), fallbackUser = login, fallbackRefresh = null)
    }

    /** Renews a session. Keeps [refreshToken] if the response does not rotate it. */
    fun refreshSignIn(refreshToken: String, userId: String): Map<String, Any?> {
        val body = JSONObject().put("refresh_token", refreshToken)
        return sankakuSession(authenticate(body), fallbackUser = userId, fallbackRefresh = refreshToken)
    }

    private fun authenticate(body: JSONObject): JSONObject {
        val request = Request.Builder().url(endpoint("auth/token").build())
            .header("User-Agent", userAgent)
            .header("Accept", "application/json")
            .post(body.toString().toRequestBody(JSON))
            .build()
        client.newCall(request).execute().use { response ->
            // A bad password is 403 and a bad refresh token 401. Any other
            // client error is also a refusal, so a changed endpoint signs out
            // instead of failing every request; server and network failures
            // stay generic and keep the session.
            if (response.code in 400..499 && response.code != 429) throw SankakuAuthException(expired = false)
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            val parsed = JSONObject(response.body?.string()?.trim() ?: throw IOException("Empty response"))
            if (!parsed.optBoolean("success", true)) throw SankakuAuthException(expired = false)
            return parsed
        }
    }

    private fun posts(array: JSONArray, avifPreviews: Boolean, limit: Int): List<Map<String, Any?>> {
        val result = ArrayList<Map<String, Any?>>()
        for (index in 0 until array.length()) {
            if (result.size >= limit) break
            val post = array.optJSONObject(index) ?: continue
            parseSankakuPost(post, avifPreviews)?.let(result::add)
        }
        return result
    }

    private fun endpoint(path: String): HttpUrl.Builder = HttpUrl.Builder()
        .scheme("https").host(API_HOST).addPathSegments(path)
        .addQueryParameter("lang", "en")

    private fun request(url: HttpUrl, accessToken: String?, deadline: Long? = null): Any {
        val builder = Request.Builder().url(url)
            .header("User-Agent", userAgent)
            .header("Accept", "application/json")
        if (!accessToken.isNullOrBlank()) builder.header("Authorization", "Bearer $accessToken")
        val call = client.newCall(builder.build())
        if (deadline != null) {
            if (System.nanoTime() >= deadline) throw InterruptedIOException("Page timed out")
            call.timeout().deadlineNanoTime(deadline)
        }
        call.execute().use { response ->
            // Error bodies carry codes such as tag limits; the caller reports
            // a generic message and never the request URL or token.
            if (!response.isSuccessful) throw requestError(response, !accessToken.isNullOrBlank())
            val text = response.body?.string()?.trim() ?: throw IOException("Empty response")
            val parsed = if (text.startsWith("[")) JSONArray(text) else JSONObject(text)
            if (parsed is JSONObject && parsed.has("success") && !parsed.optBoolean("success", true)) {
                throw IOException("Request rejected")
            }
            return parsed
        }
    }

    private fun requestError(response: Response, authenticated: Boolean): IOException {
        if (response.code == 401 && authenticated) return SankakuAuthException(expired = true)
        if (response.code == 429) {
            val error = try {
                JSONObject(response.peekBody(MAX_ERROR_BYTES).string())
            } catch (_: Exception) { null }
            if (jsonString(error, "code")?.endsWith("tags-limit") == true) {
                return SankakuTagLimitException(jsonString(error, "param")?.toIntOrNull())
            }
        }
        return IOException("HTTP ${response.code}")
    }

    companion object {
        const val API_HOST = "sankakuapi.com"
        const val SITE_HOST = "www.sankakucomplex.com"
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private const val MAX_ERROR_BYTES = 16L * 1024
        private const val PAGE_SIZE = 100
        private const val MAX_REQUESTS = 8
        private const val MAX_CURSORS = 256
    }
}

/** Adds `order:random` for discovery unless the user chose an order. */
internal fun sankakuQuery(tags: List<String>, random: Boolean): String {
    val clean = tags.map { it.trim() }.filter { it.isNotEmpty() }
    val ordered = clean.any { it.lowercase().startsWith("order:") }
    return (if (random && !ordered) clean + "order:random" else clean).joinToString(" ")
}

/**
 * The session map returned to Dart: `userId` (display name), `accessToken`,
 * `refreshToken`, and `expiresAt` (epoch milliseconds, or null if unknown).
 */
internal fun sankakuSession(body: JSONObject, fallbackUser: String, fallbackRefresh: String?): Map<String, Any?> {
    val access = jsonString(body, "access_token") ?: throw IOException("Missing access token")
    val user = body.optJSONObject("current_user")
    val ttl = body.optLong("access_token_ttl", 0L)
    val expiresAt = if (ttl > 0) System.currentTimeMillis() + ttl * 1000 else jwtExpiry(access)
    return mapOf(
        "userId" to (jsonString(user, "name") ?: fallbackUser),
        "accessToken" to access,
        "refreshToken" to (jsonString(body, "refresh_token") ?: fallbackRefresh ?: ""),
        "expiresAt" to expiresAt,
    )
}

/** Reads the `exp` claim (seconds) of a JWT without verifying it. */
internal fun jwtExpiry(token: String): Long? = try {
    val payload = token.split('.').getOrNull(1) ?: throw IllegalArgumentException()
    val json = JSONObject(String(java.util.Base64.getUrlDecoder().decode(payload.trimEnd('='))))
    json.optLong("exp", 0L).takeIf { it > 0 }?.times(1000)
} catch (_: Exception) { null }

/**
 * Sankaku tag types are provider-local: 0 general, 1 artist, 2 studio,
 * 3 copyright, 4 character, 5 genre, 8 medium, 9 meta. Studios are grouped
 * with copyrights, genres with general tags, and media with meta tags.
 */
internal fun sankakuTagCategory(raw: Any?): String {
    val type = when (raw) {
        is Number -> raw.toInt()
        else -> raw?.toString()?.trim()?.toIntOrNull()
    }
    return when (type) {
        0, 5 -> "general"
        1 -> "artist"
        2, 3 -> "copyright"
        4 -> "character"
        8, 9 -> "meta"
        else -> "unknown"
    }
}

private val SANKAKU_ID = Regex("[A-Za-z0-9]{1,32}")
private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "gif", "webp")

/**
 * Converts a Sankaku post to the channel's post map, or null when the post has
 * no file this client may load (anonymous users receive no URL for some
 * content). Signed media URLs are passed through byte-for-byte: re-encoding
 * their query would invalidate the signature.
 */
internal fun parseSankakuPost(post: JSONObject, avifPreviews: Boolean): Map<String, Any?>? {
    val id = jsonString(post, "id") ?: return null
    if (!SANKAKU_ID.matches(id)) return null
    val url = sankakuMediaUrl(jsonString(post, "file_url")) ?: return null
    val preview = sankakuMediaUrl(jsonString(post, "preview_url"))
    // The 600px AVIF preview is a fraction of the 2200-3000px sample's size,
    // and Android's ImageDecoder reads AVIF from API 31. Flutter must not
    // decode it itself (see MediaImage); fetchMedia converts it natively.
    // Older devices get the WebP/JPEG sample instead.
    val sample = sankakuMediaUrl(jsonString(post, "sample_url"))
        ?.takeIf { extension(it) in IMAGE_EXTENSIONS }
    val previewUrl = if (avifPreviews) preview ?: sample else sample ?: preview

    val details = LinkedHashMap<String, String>()
    val typed = post.optJSONArray("tags") ?: JSONArray()
    for (index in 0 until typed.length()) {
        val tag = typed.optJSONObject(index) ?: continue
        val name = (jsonString(tag, "tagName") ?: jsonString(tag, "name"))?.trim().orEmpty()
        if (name.isEmpty()) continue
        val category = sankakuTagCategory(tag.opt("type"))
        details.putIfAbsent(name, if (category == "unknown") "general" else category)
    }
    // Some response versions truncate `tags` but keep every name here.
    val names = post.optJSONArray("tag_names")
    val rawTags = ArrayList<String>()
    if (names != null) {
        for (index in 0 until names.length()) {
            val name = names.optString(index).trim()
            if (name.isNotEmpty() && name != "null") rawTags.add(name)
        }
    }
    if (rawTags.isEmpty()) rawTags.addAll(details.keys)
    rawTags.forEach { details.putIfAbsent(it, "general") }

    val author = post.optJSONObject("author")
    val source = jsonString(post, "source")?.takeUnless { it == "removed" } ?: ""
    return mapOf(
        "id" to id,
        "url" to url,
        "previewUrl" to (previewUrl ?: ""),
        "tags" to rawTags,
        "tagDetails" to details.map { mapOf("name" to it.key, "category" to it.value) },
        "postUrl" to "https://${SankakuApi.SITE_HOST}/posts/$id",
        "rating" to when (jsonString(post, "rating")?.lowercase()) {
            "s" -> "safe"
            "q" -> "questionable"
            "e" -> "explicit"
            else -> "Unknown"
        },
        "uploader" to (jsonString(author, "display_name") ?: jsonString(author, "name") ?: ""),
        "source" to source,
        "width" to post.optInt("width"),
        "height" to post.optInt("height"),
        "score" to post.optInt("total_score"),
        "description" to "",
        "videoVariants" to emptyList<Map<String, Any?>>(),
    )
}

internal fun parseSankakuSuggestions(array: JSONArray, limit: Int): List<Map<String, Any?>> {
    val result = ArrayList<Map<String, Any?>>()
    val seen = HashSet<String>()
    for (index in 0 until array.length()) {
        if (result.size >= limit) break
        val tag = array.optJSONObject(index) ?: continue
        val name = (jsonString(tag, "tagName") ?: jsonString(tag, "name"))?.trim().orEmpty()
        val count = tag.optInt("post_count", tag.optInt("count"))
        // The endpoint echoes the typed text as a zero-count "tag".
        if (name.isEmpty() || count <= 0 || !seen.add(name.lowercase())) continue
        result.add(mapOf("name" to name, "category" to sankakuTagCategory(tag.opt("type")), "postCount" to count))
    }
    return result
}

/** Accepts HTTPS (or protocol-relative/HTTP, upgraded) URLs without user info. */
internal fun sankakuMediaUrl(value: String?): String? {
    val raw = value?.trim().orEmpty()
    if (raw.isEmpty()) return null
    val url = when {
        raw.startsWith("//") -> "https:$raw"
        raw.startsWith("http://", ignoreCase = true) -> "https://" + raw.substring(7)
        else -> raw
    }
    return try {
        val uri = URI(url)
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) null else url
    } catch (_: Exception) { null }
}

/** Hosts that serve Sankaku's signed media (`v.`, `s.` and similar). */
internal fun isSankakuMediaHost(host: String): Boolean =
    host == "sankakucomplex.com" || host.endsWith(".sankakucomplex.com")

/** True for an ISO-BMFF file whose `ftyp` brand is AVIF (still or sequence). */
internal fun isAvif(bytes: ByteArray): Boolean {
    if (bytes.size < 12) return false
    if (String(bytes, 4, 4, Charsets.US_ASCII) != "ftyp") return false
    val brand = String(bytes, 8, 4, Charsets.US_ASCII)
    return brand == "avif" || brand == "avis"
}

private fun extension(url: String): String =
    url.substringBefore('?').substringBefore('#').substringAfterLast('/').substringAfterLast('.', "").lowercase()

/** org.json on Android turns JSON null into the string "null"; treat it as absent. */
private fun jsonString(target: JSONObject?, key: String): String? {
    val value = target?.opt(key) ?: return null
    if (value == JSONObject.NULL) return null
    return value.toString().trim().takeIf { it.isNotEmpty() }
}
