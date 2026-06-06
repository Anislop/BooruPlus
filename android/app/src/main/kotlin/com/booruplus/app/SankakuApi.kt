package com.booruplus.app

import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/**
 * Anonymous client for the Sankaku Complex API at sankakuapi.com (the
 * capi-v2.sankakucomplex.com host used by older wrappers now refuses requests).
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
        cancelled: () -> Boolean,
    ): List<Map<String, Any?>> {
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
                .addQueryParameter("tags", query).build())
            val array = batch as? JSONArray ?: (batch as JSONObject).optJSONArray("data") ?: JSONArray()
            return posts(array, avifPreviews, limit)
        }

        val result = ArrayList<Map<String, Any?>>()
        var token = stored
        var requests = 0
        while (result.size < limit && requests++ < MAX_REQUESTS) {
            if (cancelled()) throw IOException("Cancelled")
            // Request exactly what is still needed: a keyset token skips past
            // every returned row, so surplus rows could not be served later.
            val size = minOf(limit - result.size, PAGE_SIZE)
            val url = endpoint("posts/keyset").addQueryParameter("limit", size.toString())
                .addQueryParameter("tags", query)
            if (!token.isNullOrEmpty()) url.addQueryParameter("next", token)
            val body = request(url.build()) as? JSONObject ?: throw IOException("Unexpected response")
            result.addAll(posts(body.optJSONArray("data") ?: JSONArray(), avifPreviews, limit - result.size))
            token = jsonString(body.optJSONObject("meta"), "next") ?: ""
            if (token.isEmpty()) break
        }
        cursors["$cursorKey\u0003${page + 1}"] = token ?: ""
        return result
    }

    fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val value = query.trim().trimStart('-', '~').trim()
        if (value.isEmpty()) return emptyList()
        val body = request(endpoint("tags/autosuggestCreating").addQueryParameter("tag", value).build())
        return parseSankakuSuggestions(body as? JSONArray ?: JSONArray(), limit)
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

    private fun request(url: HttpUrl): Any {
        val request = Request.Builder().url(url)
            .header("User-Agent", userAgent)
            .header("Accept", "application/json")
            .build()
        client.newCall(request).execute().use { response ->
            // Error bodies carry codes such as anonymous tag limits; the caller
            // reports a generic message and never the request URL.
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            val text = response.body?.string()?.trim() ?: throw IOException("Empty response")
            val parsed = if (text.startsWith("[")) JSONArray(text) else JSONObject(text)
            if (parsed is JSONObject && parsed.has("success") && !parsed.optBoolean("success", true)) {
                throw IOException("Request rejected")
            }
            return parsed
        }
    }

    companion object {
        const val API_HOST = "sankakuapi.com"
        const val SITE_HOST = "www.sankakucomplex.com"
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
    // AVIF decoding is available to Flutter through Android's ImageDecoder
    // from API 31. Older devices get the WebP/JPEG sample instead.
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

private fun extension(url: String): String =
    url.substringBefore('?').substringBefore('#').substringAfterLast('/').substringAfterLast('.', "").lowercase()

/** org.json on Android turns JSON null into the string "null"; treat it as absent. */
private fun jsonString(target: JSONObject?, key: String): String? {
    val value = target?.opt(key) ?: return null
    if (value == JSONObject.NULL) return null
    return value.toString().trim().takeIf { it.isNotEmpty() }
}
