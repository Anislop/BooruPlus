package com.booruplus.app

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/*
 * Small JSON clients for boards the vendored library does not model:
 * Gelbooru 0.2 DAPI boards (TBIB, XBooru, MSPABooru), AIBooru (a Danbooru
 * fork whose absolute CDN URLs the library's Danbooru entity rewrites onto
 * danbooru.donmai.us), and Nozomi (binary post-ID indexes plus one JSON file
 * per post). Each returns the same post maps as MainActivity.mapImage.
 * MoreBoards.kt holds the clients for boards on other engines.
 */

internal fun OkHttpClient.getBody(url: HttpUrl, userAgent: String, headers: Map<String, String> = emptyMap()): String? {
    val builder = Request.Builder().url(url).header("User-Agent", userAgent)
    headers.forEach { (name, value) -> builder.header(name, value) }
    newCall(builder.build()).execute().use { response ->
        if (response.code == 404) return null
        if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
        return response.body?.string()
    }
}

/** Splits a space-separated tag string, dropping blanks. */
internal fun splitTags(value: String?): List<String> =
    value?.trim()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() } ?: emptyList()

/** A page offset for unfiltered discovery, so each random session starts somewhere new. */
internal fun discoveryOffset(random: Boolean, tags: List<String>, seed: Int): Int =
    if (random && tags.isEmpty()) Random(seed).nextInt(21) else 0

/** [value] resolved against `https://<host>/`, or null unless it is a plain HTTPS URL. */
internal fun httpsUrl(host: String, value: String?): String? {
    if (value.isNullOrBlank() || value == "null") return null
    return try {
        val url = java.net.URI("https://$host/").resolve(value.trim())
        url.takeIf { it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null }?.toString()
    } catch (_: Exception) { null }
}

internal val MD5_PATTERN = Regex("^[0-9a-f]{32}$")

/** A board client with its own HTTP requests; MainActivity dispatches to it by board ID. */
internal interface BoardClient {
    fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>>
    fun autocomplete(query: String, limit: Int): List<Map<String, Any?>>
}

/**
 * Gelbooru 0.2 DAPI JSON boards: TBIB (tbib.org), XBooru (xbooru.com), and
 * MSPABooru (mspabooru.com). XBooru sends file URLs; TBIB and MSPABooru send
 * only `directory` and `image`, and their thumbnails end in `.jpg` (TBIB) or
 * keep the image's extension (MSPABooru, [keepsThumbnailExtension]). An empty
 * search answers with an empty body. Ratings mix the old (`safe`) and new
 * (`general`) names, so Dart filters ratings locally instead of sending
 * `rating:`.
 */
internal class Gelbooru02Api(
    private val client: OkHttpClient,
    private val userAgent: String,
    private val host: String,
    private val keepsThumbnailExtension: Boolean = false,
) : BoardClient {
    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        val pid = page + discoveryOffset(random, tags, seed)
        val posts = request(tags, pid, limit)
        val result = if (posts.isEmpty() && pid != page) request(tags, page, limit) else posts
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun request(tags: List<String>, pid: Int, limit: Int): List<Map<String, Any?>> {
        val url = HttpUrl.Builder().scheme("https").host(host).addPathSegment("index.php")
            .addQueryParameter("page", "dapi").addQueryParameter("s", "post")
            .addQueryParameter("q", "index").addQueryParameter("json", "1")
            .addQueryParameter("limit", limit.coerceIn(1, 200).toString())
            .addQueryParameter("pid", pid.toString())
            .apply { if (tags.isNotEmpty()) addQueryParameter("tags", tags.joinToString(" ")) }
            .build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (body.isEmpty() || !body.startsWith("[")) return emptyList()
        val array = JSONArray(body)
        return (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(::mapPost) }
    }

    private fun mapPost(post: JSONObject): Map<String, Any?>? {
        val id = post.optLong("id").takeIf { it > 0 } ?: return null
        val directory = post.optString("directory").takeIf { it.isNotBlank() }
        val image = post.optString("image").takeIf { it.isNotBlank() && !it.contains('/') }
        val base = image?.substringBeforeLast('.')
        val thumbnailExtension = if (keepsThumbnailExtension) image?.substringAfterLast('.', "jpg") else "jpg"
        val original = httpsUrl(host, post.optString("file_url"))
            ?: if (directory != null && image != null) "https://$host/images/$directory/$image" else return null
        val preview = httpsUrl(host, post.optString("preview_url"))
            ?: if (directory != null && base != null) "https://$host/thumbnails/$directory/thumbnail_$base.$thumbnailExtension" else original
        val sample = if (post.optBoolean("sample")) {
            httpsUrl(host, post.optString("sample_url"))
                ?: if (directory != null && base != null) "https://$host/samples/$directory/sample_$base.$thumbnailExtension" else null
        } else null
        val tags = splitTags(post.optString("tags"))
        return mapOf(
            "id" to id.toString(),
            "url" to original,
            "previewUrl" to preview,
            "tags" to tags,
            "tagDetails" to tags.map { mapOf("name" to it, "category" to "general") },
            "postUrl" to "https://$host/index.php?page=post&s=view&id=$id",
            "rating" to post.optString("rating", "Unknown"),
            "uploader" to post.optString("owner"),
            "source" to post.optString("source"),
            "width" to post.optInt("width"), "height" to post.optInt("height"),
            "score" to post.optInt("score"), "description" to "",
            "videoVariants" to emptyList<Map<String, Any?>>(),
            "md5" to post.optString("hash").lowercase().takeIf { MD5_PATTERN.matches(it) }.orEmpty(),
            "parentId" to post.optLong("parent_id").takeIf { it > 0 }?.toString(),
            "hasChildren" to false,
            "sampleUrl" to (sample?.takeIf { it != original && it != preview } ?: ""),
            "pools" to emptyList<String>(),
        )
    }

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim()
        if (term.isEmpty()) return emptyList()
        val url = HttpUrl.Builder().scheme("https").host(host).addPathSegment("autocomplete.php")
            .addQueryParameter("q", term).build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("[")) return emptyList()
        val array = JSONArray(body)
        return (0 until minOf(array.length(), limit)).mapNotNull { index ->
            // TBIB and XBooru send {label: "name (count)", value}; MSPABooru sends bare names.
            val item = array.optJSONObject(index)
            val name = (item?.optString("value") ?: array.optString(index)).trim().takeIf { it.isNotEmpty() }
                ?: return@mapNotNull null
            val count = item?.let { Regex("\\((\\d+)\\)\\s*$").find(it.optString("label"))?.groupValues?.get(1)?.toIntOrNull() }
            mapOf("name" to name, "category" to "unknown", "postCount" to count)
        }
    }

    companion object {
        const val TBIB_HOST = "tbib.org"
        const val XBOORU_HOST = "xbooru.com"
        const val MSPABOORU_HOST = "mspabooru.com"
    }
}

/**
 * AIBooru (aibooru.online; aibooru.org is a parked domain): Danbooru's API
 * with absolute CDN URLs on cdn.aibooru.download. Anonymous searches allow
 * four tags. Its extra `model` tag category is shown as meta.
 */
internal class AiBooruApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        val offset = discoveryOffset(random, tags, seed)
        val posts = request(tags, page + offset, limit)
        val result = if (posts.isEmpty() && offset > 0) request(tags, page, limit) else posts
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun request(tags: List<String>, page: Int, limit: Int): List<Map<String, Any?>> {
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("posts.json")
            .addQueryParameter("limit", limit.coerceIn(1, 200).toString())
            .addQueryParameter("page", (page + 1).toString())
            .apply { if (tags.isNotEmpty()) addQueryParameter("tags", tags.joinToString(" ")) }
            .build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("[")) {
            if (body.contains("TagLimitError")) throw IllegalArgumentException("Too many tags")
            return emptyList()
        }
        val array = JSONArray(body)
        return (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(::mapPost) }
    }

    private fun mapPost(post: JSONObject): Map<String, Any?>? {
        val id = post.optLong("id").takeIf { it > 0 } ?: return null
        // Banned or restricted posts omit their file URLs.
        val original = mediaUrl(post.optString("file_url")) ?: return null
        val preview = mediaUrl(post.optString("preview_file_url")) ?: original
        val sample = mediaUrl(post.optString("large_file_url"))
        val tags = splitTags(post.optString("tag_string"))
        val details = LinkedHashMap<String, String>()
        listOf(
            "tag_string_artist" to "artist", "tag_string_character" to "character",
            "tag_string_copyright" to "copyright", "tag_string_meta" to "meta",
            "tag_string_model" to "meta", "tag_string_general" to "general",
        ).forEach { (field, category) -> splitTags(post.optString(field)).forEach { details.putIfAbsent(it, category) } }
        tags.forEach { details.putIfAbsent(it, "general") }
        return mapOf(
            "id" to id.toString(),
            "url" to original, "previewUrl" to preview,
            "tags" to tags,
            "tagDetails" to details.map { mapOf("name" to it.key, "category" to it.value) },
            "postUrl" to "https://$HOST/posts/$id",
            "rating" to post.optString("rating", "Unknown"),
            "uploader" to "",
            "source" to post.optString("source"),
            "width" to post.optInt("image_width"), "height" to post.optInt("image_height"),
            "score" to post.optInt("score"), "description" to "",
            "videoVariants" to emptyList<Map<String, Any?>>(),
            "md5" to post.optString("md5").lowercase().takeIf { MD5.matches(it) }.orEmpty(),
            "parentId" to post.optLong("parent_id").takeIf { it > 0 }?.toString(),
            "hasChildren" to (post.optBoolean("has_children") || post.optBoolean("has_active_children")),
            "sampleUrl" to (sample?.takeIf { it != original && it != preview } ?: ""),
            "pools" to emptyList<String>(),
        )
    }

    private fun mediaUrl(value: String?): String? = httpsUrl(HOST, value)

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim()
        if (term.isEmpty()) return emptyList()
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("autocomplete.json")
            .addQueryParameter("search[query]", term).addQueryParameter("search[type]", "tag_query")
            .addQueryParameter("limit", limit.toString()).build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("[")) return emptyList()
        val array = JSONArray(body)
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val name = item.optString("value").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val category = when (item.optInt("category", -1)) {
                0 -> "general"; 1 -> "artist"; 3 -> "copyright"; 4 -> "character"; 5 -> "meta"; else -> "unknown"
            }
            mapOf("name" to name, "category" to category, "postCount" to item.optInt("post_count").takeIf { it > 0 })
        }
    }

    companion object {
        const val HOST = "aibooru.online"
        private val MD5 = Regex("^[0-9a-f]{32}$")
    }
}

/**
 * Nozomi (nozomi.la). Data lives on j.gold-usergeneratedcontent.net:
 * - `index.nozomi`, `nozomi/<tag>.nozomi`, and their `-Popular` variants are
 *   big-endian 32-bit post IDs, newest (or most popular) first, served with
 *   byte ranges (`Content-Range` gives the total).
 * - `post/<c>/<ba>/<id>.json` holds a post's typed tags and media `dataid`.
 * - Media sits on w. (WebP), g. (GIF), v. (video), and qtn. (thumbnails)
 *   under `<c>/<ba>/<hash>`, and answers 404 without a nozomi.la Referer.
 * Tag files can hold millions of IDs, so a search reads the smallest
 * positive tag's index in ranges and checks the other tags against each
 * post's JSON, within a bounded number of candidates per call.
 */
internal class NozomiApi(private val client: OkHttpClient, private val userAgent: String) {
    private val positions = ConcurrentHashMap<String, Long>()
    // Where a page's empty, unfinished scan stopped and when, so a retry
    // soon after continues there (page 0 included, whose cursors a new
    // search clears).
    private val retryFrom = ConcurrentHashMap<String, Pair<Long, Long>>()
    private val totals = ConcurrentHashMap<String, Long>()
    private val suggestions = object : LinkedHashMap<String, List<Pair<String, Int>>>(4, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<Pair<String, Int>>>?) = size > 3
    }
    private val posts: ExecutorService = Executors.newFixedThreadPool(6)

    fun fetch(
        tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int,
        cursorKey: String, cancelled: () -> Boolean,
    ): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        val popular = tags.any { it.equals("order:popular", ignoreCase = true) }
        val terms = tags.filterNot { it.contains(':') }.map { it.lowercase() }
        val excluded = terms.filter { it.startsWith("-") }.map { it.substring(1) }.filter { it.isNotEmpty() }.toSet()
        // `~a ~b`: a post needs at least one of them. A lone `~a` is required.
        val either = terms.filter { it.startsWith("~") }.map { it.substring(1) }.filter { it.isNotEmpty() }.toSet()
        val anyOf = if (either.size > 1) either else emptySet()
        val required = (terms.filterNot { it.startsWith("-") || it.startsWith("~") } + either.filter { anyOf.isEmpty() }).distinct()
        // Read the smallest required tag's index; check the rest per post.
        val source = required.map { indexPath(it, popular) }
            .minByOrNull { total(it) } ?: indexPath(null, popular)
        val total = total(source)
        if (total <= 0) return emptyList()
        val others = required.filter { indexPath(it, popular) != source }.toSet()
        val filtering = others.isNotEmpty() || excluded.isNotEmpty() || anyOf.isNotEmpty()
        if (page == 0) positions.keys.filter { it.startsWith(cursorKey) }.forEach { positions.remove(it) }
        if (positions.size > 256) positions.keys.take(128).forEach { positions.remove(it) }
        val key = "$cursorKey\u0003$page"
        val retry = retryFrom.remove(key)?.takeIf { System.nanoTime() - it.second < RETRY_WINDOW_NANOS }?.first
        if (retryFrom.size > 64) retryFrom.clear()
        val start = retry ?: positions[key] ?: run {
            val first = if (random && total > limit * 4L) Random(seed).nextLong(total - limit * 4L) else 0L
            first + page.toLong() * limit
        }
        var position = start
        val result = ArrayList<Map<String, Any?>>()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(40)
        var scanned = 0
        while (result.size < limit && position < total && scanned < MAX_CANDIDATES && System.nanoTime() < deadline) {
            if (cancelled()) throw IOException("Cancelled")
            val count = minOf(if (filtering) CHUNK else (limit - result.size).toLong(), total - position).toInt()
            val ids = readIds(source, position, count)
            if (ids.isEmpty()) { position = total; break }
            val loaded = posts.invokeAll(ids.map { id -> Callable { runCatching { post(id) }.getOrNull() } })
                .map { it.get() }
            for (post in loaded) {
                position++
                scanned++
                if (post == null) continue
                @Suppress("UNCHECKED_CAST")
                val postTags = (post["tags"] as List<String>).map { it.lowercase() }.toSet()
                if (!postTags.containsAll(others) || excluded.any { it in postTags }) continue
                if (anyOf.isNotEmpty() && anyOf.none { it in postTags }) continue
                result.add(post)
                // The next page resumes right after this post and reads the
                // rest of the chunk again.
                if (result.size >= limit) break
            }
        }
        // Nothing found in a bounded scan of a long index is not its end:
        // fail so Dart keeps the page retryable, and let the retry continue
        // where this scan stopped rather than ending the feed.
        if (result.isEmpty() && position < total) {
            retryFrom[key] = position to System.nanoTime()
            throw IOException("No matching posts in this range")
        }
        positions["$cursorKey\u0003${page + 1}"] = position
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun indexPath(tag: String?, popular: Boolean): String = when {
        tag == null -> if (popular) "index-Popular.nozomi" else "index.nozomi"
        popular -> "nozomi/popular/${encode(tag)}-Popular.nozomi"
        else -> "nozomi/${encode(tag)}.nozomi"
    }

    // Matches the site's urlencode(remove_slashes(tag)).
    private fun encode(tag: String): String =
        java.net.URLEncoder.encode(tag.replace("/", ""), "UTF-8").replace("+", "%20")

    private fun url(path: String): HttpUrl = "https://$DATA_HOST/$path".toHttpUrl()

    /** The number of IDs in [path]'s index; 0 when the tag does not exist. */
    private fun total(path: String): Long = totals[path] ?: run {
        val request = Request.Builder().url(url(path)).header("User-Agent", userAgent)
            .header("Range", "bytes=0-3").build()
        val value = client.newCall(request).execute().use { response ->
            when {
                response.code == 404 -> 0L
                !response.isSuccessful -> throw IOException("HTTP ${response.code}")
                else -> response.header("Content-Range")?.substringAfterLast('/')?.toLongOrNull()?.div(4)
                    ?: ((response.body?.contentLength() ?: 0L) / 4)
            }
        }
        if (totals.size > 512) totals.clear()
        totals[path] = value
        value
    }

    private fun readIds(path: String, position: Long, count: Int): List<Long> {
        if (count <= 0) return emptyList()
        val request = Request.Builder().url(url(path)).header("User-Agent", userAgent)
            .header("Range", "bytes=${position * 4}-${(position + count) * 4 - 1}").build()
        val bytes = client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            response.body?.bytes() ?: ByteArray(0)
        }
        // A server ignoring the range sends the whole file from the start.
        val offset = if (bytes.size > count * 4 && position > 0) (position * 4).toInt() else 0
        val available = ((bytes.size - offset) / 4).coerceAtMost(count)
        return (0 until available).map { index ->
            val at = offset + index * 4
            ((bytes[at].toLong() and 0xff) shl 24) or ((bytes[at + 1].toLong() and 0xff) shl 16) or
                ((bytes[at + 2].toLong() and 0xff) shl 8) or (bytes[at + 3].toLong() and 0xff)
        }
    }

    private fun post(id: Long): Map<String, Any?>? {
        val body = client.getBody(url("post/${hashPath(id.toString())}.json"), userAgent) ?: return null
        return mapPost(JSONObject(body))
    }

    private fun mapPost(post: JSONObject): Map<String, Any?>? {
        val id = post.optLong("postid").takeIf { it > 0 } ?: return null
        val media = post.optJSONArray("imageurls")?.optJSONObject(0) ?: return null
        val hash = media.optString("dataid").takeIf { HASH.matches(it) } ?: return null
        val type = media.optString("type").lowercase().takeIf { TYPE.matches(it) } ?: return null
        val video = media.optString("is_video").let { it.isNotEmpty() && it != "false" && it != "0" }
        val path = hashPath(hash)
        val original = when {
            video -> "https://v.$MEDIA_DOMAIN/$path.$type"
            type == "gif" -> "https://g.$MEDIA_DOMAIN/$path.gif"
            else -> "https://w.$MEDIA_DOMAIN/$path.webp"
        }
        val details = LinkedHashMap<String, String>()
        for ((field, category) in listOf("artist" to "artist", "character" to "character", "copyright" to "copyright", "general" to "general")) {
            val list = post.optJSONArray(field) ?: continue
            for (index in 0 until list.length()) {
                val name = list.optJSONObject(index)?.optString("tag")?.trim().orEmpty()
                if (name.isNotEmpty()) details.putIfAbsent(name, category)
            }
        }
        return mapOf(
            "id" to id.toString(),
            "url" to original,
            "previewUrl" to "https://qtn.$MEDIA_DOMAIN/$path.$type.webp",
            "tags" to details.keys.toList(),
            "tagDetails" to details.map { mapOf("name" to it.key, "category" to it.value) },
            "postUrl" to "https://$SITE_HOST/post/$id.html",
            // Nozomi does not rate posts.
            "rating" to "Unknown",
            "uploader" to "", "source" to "",
            "width" to media.optInt("width", post.optInt("width")),
            "height" to media.optInt("height", post.optInt("height")),
            "score" to 0, "description" to "",
            "videoVariants" to emptyList<Map<String, Any?>>(),
            "md5" to "", "parentId" to null, "hasChildren" to false,
            "sampleUrl" to "", "pools" to emptyList<String>(),
        )
    }

    /** Suggestions from the site's per-letter tag lists, most-used first. */
    fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim().lowercase().removePrefix("-").replace(' ', '_')
        if (term.isEmpty()) return emptyList()
        val letter = term.first().takeIf { it in 'a'..'z' }?.toString() ?: "0"
        val list = synchronized(suggestions) { suggestions[letter] } ?: run {
            val body = client.getBody(url("search-$letter.json"), userAgent) ?: return emptyList()
            val json = JSONObject(body)
            val entries = ArrayList<Pair<String, Int>>(json.length())
            json.keys().forEach { key -> entries.add(key to json.optInt(key)) }
            entries.sortByDescending { it.second }
            synchronized(suggestions) { suggestions[letter] = entries }
            entries
        }
        return list.asSequence().filter { it.first.startsWith(term) }.take(limit)
            .map { mapOf("name" to it.first, "category" to "unknown", "postCount" to it.second) }.toList()
    }

    fun close() = posts.shutdownNow()

    companion object {
        const val SITE_HOST = "nozomi.la"
        const val DATA_HOST = "j.gold-usergeneratedcontent.net"
        const val MEDIA_DOMAIN = "gold-usergeneratedcontent.net"
        const val REFERER = "https://nozomi.la/"
        private const val CHUNK = 48L
        private const val MAX_CANDIDATES = 960
        private val RETRY_WINDOW_NANOS = TimeUnit.MINUTES.toNanos(2)
        private val HASH = Regex("^[0-9a-f]{3,128}$")
        private val TYPE = Regex("^[a-z0-9]{2,5}$")

        /** Whether [host] serves Nozomi media that needs [REFERER]. */
        fun isMediaHost(host: String): Boolean = host.endsWith(".$MEDIA_DOMAIN")

        /** `<c>/<ba>/<value>` from a post ID or media hash, as the site builds paths. */
        fun hashPath(value: String): String =
            if (value.length < 3) value else "${value.last()}/${value.substring(value.length - 3, value.length - 1)}/$value"
    }
}
