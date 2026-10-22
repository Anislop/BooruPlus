package com.booruplus.app

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.asResponseBody
import okio.Buffer
import okio.ForwardingSource
import okio.buffer
import org.json.JSONArray
import org.json.JSONObject
import java.io.EOFException
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
 * danbooru.donmai.us), Nozomi (binary post-ID indexes plus one JSON file
 * per post), Derpibooru (Philomena's JSON API), and Realbooru (HTML pages;
 * its API is switched off). Each returns the same post maps as
 * MainActivity.mapImage. MoreBoards.kt holds the clients for boards on
 * other engines.
 */

/**
 * Fails a response once its body passes [limit] bytes (after decompression),
 * so a provider cannot exhaust memory with an enormous or endless answer
 * before it is parsed. Media bytes have their own bound and skip this.
 */
internal class ResponseLimitInterceptor(private val limit: Long) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val response = chain.proceed(chain.request())
        val body = response.body
        if (body.contentLength() > limit) {
            response.close()
            throw IOException("Response too large")
        }
        val source = object : ForwardingSource(body.source()) {
            private var total = 0L
            override fun read(sink: Buffer, byteCount: Long): Long {
                val count = super.read(sink, byteCount)
                if (count > 0) {
                    total += count
                    if (total > limit) throw IOException("Response too large")
                }
                return count
            }
        }
        return response.newBuilder()
            .body(source.buffer().asResponseBody(body.contentType(), body.contentLength()))
            .build()
    }
}

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
        // `id:<n>` (a post link opened in the app) reads that one post; Dart
        // applies the other tags locally.
        tags.firstNotNullOfOrNull { ID_LOOKUP.matchEntire(it.trim())?.groupValues?.get(1)?.toLongOrNull() }?.let { id ->
            return if (page > 0) emptyList() else listOfNotNull(post(id))
        }
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
        val first = position * 4
        val wanted = count * 4L
        val request = Request.Builder().url(url(path)).header("User-Agent", userAgent)
            .header("Range", "bytes=$first-${first + wanted - 1}").build()
        val bytes = client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            val source = response.body.source()
            if (response.code == 206) {
                // A partial answer must start where this read asked.
                val start = response.header("Content-Range")?.substringAfter("bytes ", "")
                    ?.substringBefore('-')?.trim()?.toLongOrNull()
                if (start != first) throw IOException("Unexpected range")
            } else {
                // A server ignoring the range sends the whole file from the
                // start: skip to the position instead of holding the file.
                try { source.skip(first) } catch (_: EOFException) { return@use ByteArray(0) }
            }
            val buffer = Buffer()
            while (buffer.size < wanted && source.read(buffer, wanted - buffer.size) != -1L) Unit
            buffer.readByteArray()
        }
        val available = bytes.size / 4
        return (0 until available).map { index ->
            val at = index * 4
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
        private val ID_LOOKUP = Regex("^id:(\\d{1,12})$", RegexOption.IGNORE_CASE)

        /** Whether [host] serves Nozomi media that needs [REFERER]. */
        fun isMediaHost(host: String): Boolean = host.endsWith(".$MEDIA_DOMAIN")

        /** `<c>/<ba>/<value>` from a post ID or media hash, as the site builds paths. */
        fun hashPath(value: String): String =
            if (value.length < 3) value else "${value.last()}/${value.substring(value.length - 3, value.length - 1)}/$value"
    }
}

/** [value] as an absolute HTTPS URL against [base]; protocol-relative and plain HTTP links are upgraded. */
private fun upgradedHttpsUrl(base: String, value: String?): String? {
    val text = value?.trim()?.takeIf { it.isNotEmpty() && it != "null" } ?: return null
    val upgraded = if (text.startsWith("http://", ignoreCase = true)) "https://" + text.substring(7) else text
    val url = try { java.net.URI(base).resolve(upgraded.replace(" ", "%20")) } catch (_: IllegalArgumentException) { return null }
    return url.takeIf { it.scheme == "https" && !it.host.isNullOrBlank() && it.userInfo == null }?.toString()
}

/** A JSON string field, or "" when it is missing or null (optString returns "null" for JSON null). */
private fun JSONObject.text(name: String): String = if (isNull(name)) "" else optString(name).trim()

/**
 * Derpibooru (derpibooru.org): Philomena's JSON API. Tag names hold spaces,
 * so the app's underscored tags are turned back into names and joined with
 * commas; field searches (`score.gte:100`, `created_at:>=2024-01-01`) keep
 * their underscores. Searches use the Everything filter so the app's own
 * rating and blocked-tag filters apply instead of the site's default
 * filter. Ratings are tags (`safe`, `suggestive`, `questionable`,
 * `explicit`); `rating:` tags from the app are rewritten to them. Ordering
 * is the `sf`/`sd` parameters, mapped from `order:` tags; discovery uses a
 * seeded `random:` order so its pages stay consistent. At most 50 posts
 * per page. Hashes are SHA-512, so `md5:` lookups find nothing.
 */
internal class DerpibooruApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        if (tags.any { it.startsWith("md5:", ignoreCase = true) }) return emptyList()
        val (field, direction) = sort(tags, random, seed)
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegments("api/v1/json/search/images")
            .addQueryParameter("q", query(tags).ifEmpty { "*" })
            .addQueryParameter("filter_id", EVERYTHING_FILTER)
            .addQueryParameter("per_page", limit.coerceIn(1, MAX_PER_PAGE).toString())
            .addQueryParameter("page", (page + 1).toString())
            .addQueryParameter("sf", field).addQueryParameter("sd", direction)
            .build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return emptyList()
        val images = JSONObject(body).optJSONArray("images") ?: return emptyList()
        return (0 until images.length()).mapNotNull { images.optJSONObject(it)?.let(::mapPost) }
    }

    internal fun mapPost(image: JSONObject): Map<String, Any?>? {
        val id = image.optLong("id").takeIf { it > 0 } ?: return null
        // Removed and merged images keep only their IDs.
        if (image.optBoolean("hidden_from_users")) return null
        val urls = image.optJSONObject("representations") ?: return null
        val full = upgradedHttpsUrl(SITE, urls.text("full")) ?: return null
        val mime = image.text("mime_type").lowercase()
        val video = mime.startsWith("video/")
        val thumb = upgradedHttpsUrl(SITE, urls.text("thumb"))
        val large = upgradedHttpsUrl(SITE, urls.text("large"))
        // Video thumbnails are short WebM clips; Philomena renders a GIF of
        // each beside them. A video too small for thumbnails has none.
        val preview = when {
            !video -> thumb ?: full
            thumb != null && thumb.substringAfterLast('/').startsWith("thumb.") -> thumb.substringBeforeLast('/') + "/thumb.gif"
            else -> ""
        }
        val url = when {
            // WebM uploads have an H.264 copy, which more devices decode in hardware.
            video && full.endsWith(".webm") -> full.removeSuffix(".webm") + ".mp4"
            // Flutter cannot draw SVG; the large rendition is a PNG.
            mime == "image/svg+xml" -> large ?: full
            else -> full
        }
        val tags = image.optJSONArray("tags")?.let { array ->
            (0 until array.length()).map { array.optString(it).trim().replace(' ', '_') }.filter { it.isNotEmpty() }
        } ?: emptyList()
        return mapOf(
            "id" to id.toString(),
            "url" to url, "previewUrl" to preview,
            "tags" to tags,
            "tagDetails" to tags.map { mapOf("name" to it, "category" to category(it)) },
            "postUrl" to "https://$HOST/images/$id",
            "rating" to rating(tags),
            "uploader" to image.text("uploader"),
            "source" to image.text("source_url"),
            "width" to image.optInt("width"), "height" to image.optInt("height"),
            "score" to image.optInt("score"), "description" to image.text("description"),
            "videoVariants" to emptyList<Map<String, Any?>>(),
            "md5" to "",
            "parentId" to null,
            "hasChildren" to false,
            "sampleUrl" to (large?.takeIf { !video && it != url && it != preview } ?: ""),
            "pools" to emptyList<String>(),
        )
    }

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim().removePrefix("-").replace('_', ' ')
        if (term.isEmpty() || term.contains(',')) return emptyList()
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegments("api/v1/json/search/tags")
            .addQueryParameter("q", term.replace(SPECIAL, "\\\\$1") + "*")
            .addQueryParameter("per_page", MAX_PER_PAGE.toString())
            .build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return emptyList()
        val tags = JSONObject(body).optJSONArray("tags") ?: return emptyList()
        return (0 until tags.length()).mapNotNull { tags.optJSONObject(it) }
            // Aliases redirect to another tag, which is listed on its own.
            .filter { it.text("aliased_tag").isEmpty() && it.text("name").isNotEmpty() }
            .sortedByDescending { it.optInt("images") }
            .take(limit)
            .map { tag ->
                val name = tag.text("name").replace(' ', '_')
                val category = when (tag.text("category")) {
                    "origin" -> "artist"
                    "character", "oc" -> "character"
                    "species" -> "species"
                    "content-official", "content-fanmade" -> "copyright"
                    "rating", "spoiler", "error" -> "meta"
                    else -> "general"
                }
                mapOf("name" to name, "category" to category, "postCount" to tag.optInt("images").takeIf { it > 0 })
            }
    }

    companion object {
        const val HOST = "derpibooru.org"
        private const val SITE = "https://$HOST/"
        // Derpibooru's system "Everything" filter (the site's default hides explicit images).
        private const val EVERYTHING_FILTER = "56027"
        private const val MAX_PER_PAGE = 50
        private val SPECIAL = Regex("""([\\*?"()])""")
        private val ORDER = Regex("^(order|sort):.+", RegexOption.IGNORE_CASE)
        private val FIELD = Regex("""^([a-z_]+)(\.(?:gte|gt|lte|lt))?:(.*)$""", RegexOption.IGNORE_CASE)
        // Philomena's image search fields (Images.Query); other `name:` tokens are namespaced tags.
        private val FIELDS = setOf(
            "id", "width", "height", "score", "upvotes", "downvotes", "hides", "faves", "pixels", "size",
            "orig_size", "comment_count", "source_count", "tag_count", "body_type_tag_count",
            "error_tag_count", "character_tag_count", "content_fanmade_tag_count",
            "content_official_tag_count", "oc_tag_count", "origin_tag_count", "rating_tag_count",
            "species_tag_count", "spoiler_tag_count", "uploader_id", "faved_by_id", "duplicate_id",
            "aspect_ratio", "wilson_score", "duration", "created_at", "updated_at", "first_seen_at",
            "faved_by", "orig_sha512_hash", "sha512_hash", "uploader", "source_url", "original_format",
            "mime_type", "file_name", "animated", "processed", "thumbnails_generated", "description",
            "gallery_id", "my",
        )
        private val SORT_FIELDS = setOf(
            "id", "updated_at", "first_seen_at", "aspect_ratio", "faves", "downvotes", "upvotes", "width",
            "height", "score", "comment_count", "tag_count", "wilson_score", "pixels", "size", "duration", "hides",
        )
        private val RATING_TERMS = mapOf(
            "safe" to "safe", "s" to "safe", "general" to "safe", "g" to "safe",
            "questionable" to "(suggestive || questionable)", "q" to "(suggestive || questionable)",
            "explicit" to "explicit", "e" to "explicit",
        )
        private val ARTIST_NAMESPACES = setOf("artist", "editor", "colorist", "photographer", "prompter")
        private val COPYRIGHT_NAMESPACES = setOf("comic", "series", "art_pack", "fanfic")
        private val CONTENT_RATINGS = setOf("safe", "suggestive", "questionable", "explicit", "semi-grimdark", "grimdark", "grotesque")

        /** The Philomena search for the app's [tags], without ordering tags. */
        internal fun query(tags: List<String>): String =
            tags.filterNot { ORDER.matches(it) }.mapNotNull(::term).joinToString(",")

        private fun term(tag: String): String? {
            val negated = tag.startsWith("-")
            val body = tag.removePrefix("-").trim().ifEmpty { return null }
            val value = if (body.startsWith("rating:", ignoreCase = true)) {
                RATING_TERMS[body.substringAfter(':').lowercase()] ?: return null
            } else {
                field(body) ?: body.replace('_', ' ')
            }
            return if (negated) "-$value" else value
        }

        /** A field search with Danbooru-style comparisons (`:>=`) as Philomena's (`.gte:`); null for a tag. */
        private fun field(body: String): String? {
            val match = FIELD.matchEntire(body) ?: return null
            val name = match.groupValues[1].lowercase()
            if (name !in FIELDS) return null
            if (match.groupValues[2].isNotEmpty()) return "$name${match.groupValues[2].lowercase()}:${match.groupValues[3]}"
            val value = match.groupValues[3]
            return when {
                value.startsWith(">=") -> "$name.gte:${value.substring(2)}"
                value.startsWith("<=") -> "$name.lte:${value.substring(2)}"
                value.startsWith(">") -> "$name.gt:${value.substring(1)}"
                value.startsWith("<") -> "$name.lt:${value.substring(1)}"
                else -> "$name:$value"
            }
        }

        /** The `sf`/`sd` pair for the last `order:` tag; newest first by default. */
        internal fun sort(tags: List<String>, random: Boolean, seed: Int): Pair<String, String> {
            val seeded = "random:${seed.toLong() and 0xffffffffL}"
            val order = tags.lastOrNull { ORDER.matches(it) }?.substringAfter(':')?.lowercase()
                ?: return (if (random) seeded else "id") to "desc"
            val direction = if (order.endsWith("_asc") || order.endsWith(":asc")) "asc" else "desc"
            val field = order.removeSuffix("_asc").removeSuffix("_desc").removeSuffix(":asc").removeSuffix(":desc")
            return when (field) {
                "random" -> seeded
                "favcount", "favorites", "fav" -> "faves"
                "mpixels", "quality" -> "pixels"
                "popular", "popularity" -> "wilson_score"
                // Upload dates sort as first_seen_at (created_at is not a sort field).
                "created_at", "date" -> "first_seen_at"
                in SORT_FIELDS -> field
                else -> "id"
            } to direction
        }

        private fun rating(tags: List<String>): String = when {
            "explicit" in tags -> "explicit"
            "questionable" in tags || "suggestive" in tags -> "questionable"
            "safe" in tags -> "safe"
            else -> "Unknown"
        }

        /** A tag's kind from its namespace; image results do not include tag categories. */
        private fun category(tag: String): String {
            if (tag in CONTENT_RATINGS) return "meta"
            val namespace = tag.substringBefore(':', "")
            return when {
                namespace in ARTIST_NAMESPACES -> "artist"
                namespace == "oc" -> "character"
                namespace in COPYRIGHT_NAMESPACES -> "copyright"
                namespace == "spoiler" || namespace == "generator" -> "meta"
                else -> "general"
            }
        }
    }
}

/**
 * Realbooru (realbooru.com): a Gelbooru 0.2 site whose API is switched off
 * (its DAPI answers `success="false"`), so posts are read from its HTML
 * pages, as LoliSnatcher and Boorusama do. List pages hold 42 thumbnails
 * with their tags (and sometimes `score:`/`rating:`) in the image title.
 * A post's file URL, size, and typed tags appear only on its own page, which
 * `id:` lookups read; Dart asks for that when the viewer opens a post, so
 * listed posts carry their thumbnail as `url` until then. Media hosts are
 * sent the site as Referer.
 */
internal class RealbooruApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    // List pages hold a fixed PAGE_SIZE posts; [limit] does not apply.
    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        val ids = tags.firstNotNullOfOrNull { ID_LOOKUP.matchEntire(it.trim()) }?.groupValues?.get(1)
        if (ids != null) {
            return ids.split(',').mapNotNull { it.toLongOrNull()?.takeIf { id -> id > 0 } }.distinct().take(MAX_LOOKUPS).mapNotNull { id ->
                if (cancelled()) throw IOException("Cancelled")
                client.getBody(postUrl(id).toHttpUrl(), userAgent)?.let { parsePost(id, it) }
            }
        }
        val offset = discoveryOffset(random, tags, seed)
        val posts = list(tags, page + offset)
        val result = if (posts.isEmpty() && offset > 0) list(tags, page) else posts
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun list(tags: List<String>, page: Int): List<Map<String, Any?>> {
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("index.php")
            .addQueryParameter("page", "post").addQueryParameter("s", "list")
            .addQueryParameter("tags", tags.joinToString(" ").ifBlank { "all" })
            .addQueryParameter("pid", (page * PAGE_SIZE).toString())
            .build()
        return parseList(client.getBody(url, userAgent).orEmpty())
    }

    // Its pages offer no tag lookup to read without the API.
    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> = emptyList()

    companion object {
        const val HOST = "realbooru.com"
        const val REFERER = "https://realbooru.com/"
        const val PAGE_SIZE = 42
        private const val MAX_LOOKUPS = 40
        private val ID_LOOKUP = Regex("""^id:(\d{1,12}(?:,\d{1,12})*)$""", RegexOption.IGNORE_CASE)
        private val THUMB = Regex("""<a\b[^>]*\bid\s*=\s*["']p(\d{1,12})["'][^>]*>(?:(?!</a>)[\s\S]){0,600}?(<img\b[^>]*>)""", RegexOption.IGNORE_CASE)
        private val HASH = Regex("""([0-9a-f]{32})\.[a-z0-9]{2,5}(?:\?.*)?$""", RegexOption.IGNORE_CASE)
        private val IMAGE_PATH = Regex("""/images/([0-9a-f]{2})/([0-9a-f]{2})/([0-9a-f]{32})\.""", RegexOption.IGNORE_CASE)
        private val VIDEO_PLAYER = Regex("""<video\b[^>]*\bid\s*=\s*["']gelcomVideoPlayer["'][^>]*>[\s\S]*?</video>""", RegexOption.IGNORE_CASE)
        private val VIDEO = Regex("""<video\b[^>]*>[\s\S]*?</video>""", RegexOption.IGNORE_CASE)
        private val VIDEO_TAG = Regex("""<video\b[^>]*>""", RegexOption.IGNORE_CASE)
        private val SOURCE = Regex("""<source\b[^>]*>""", RegexOption.IGNORE_CASE)
        private val MAIN_IMAGE = Regex("""<img\b[^>]*\bid\s*=\s*["']image["'][^>]*>""", RegexOption.IGNORE_CASE)
        private val IMAGE = Regex("""<img\b[^>]*>""", RegexOption.IGNORE_CASE)
        private val CONTAINER = Regex("""class\s*=\s*["'][^"']*\bimageContainer\b""", RegexOption.IGNORE_CASE)
        private val TAG_LIST = Regex("""\bid\s*=\s*["']tagLink["']""", RegexOption.IGNORE_CASE)
        private val TAG_ELEMENT = Regex("""<(li|a)\b([^>]*)>""", RegexOption.IGNORE_CASE)
        private val LINK_TEXT = Regex("""<a\b[^>]*>([\s\S]*?)</a>""", RegexOption.IGNORE_CASE)
        private val TAGS_FIELD = Regex("""<textarea\b[^>]*\bname\s*=\s*["']tags["'][^>]*>([\s\S]*?)</textarea>""", RegexOption.IGNORE_CASE)
        private val SOURCE_FIELD = Regex("""<input\b[^>]*\bname\s*=\s*["']source["'][^>]*>""", RegexOption.IGNORE_CASE)
        private val UPLOADER = Regex("""<a\b[^>]*href\s*=\s*["'][^"']*page=account&(?:amp;)?s=profile&(?:amp;)?id=\d+[^"']*["'][^>]*>([^<]+)</a>""", RegexOption.IGNORE_CASE)
        private val RATING = Regex("""Rating:\s*(?:<[^>]*>\s*)*(safe|general|sensitive|questionable|explicit)""", RegexOption.IGNORE_CASE)
        private val MARKUP = Regex("<[^>]*>")
        private val ENTITY = Regex("""&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);""", RegexOption.IGNORE_CASE)
        // Element classes on the post page's tag list, by app tag category.
        private val TAG_CLASSES = listOf(
            setOf("tag-type-artist", "model") to "artist",
            setOf("tag-type-copyright", "copyright") to "copyright",
            setOf("tag-type-character", "character") to "character",
            setOf("tag-type-metadata", "tag-type-meta", "metadata") to "meta",
            setOf("tag-type-general", "general") to "general",
        )

        fun isMediaHost(host: String): Boolean = host == HOST || host.endsWith(".$HOST")

        fun postUrl(id: Long) = "https://$HOST/index.php?page=post&s=view&id=$id"

        private val ATTRIBUTES = ConcurrentHashMap<String, Regex>()

        private fun attr(element: String, name: String): String? =
            ATTRIBUTES.getOrPut(name) {
                Regex("""(?<![\w-])$name\s*=\s*(["'])(.*?)\1""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
            }.find(element)?.groupValues?.get(2)?.let(::decode)?.trim()?.takeIf { it.isNotEmpty() }

        private fun decode(value: String): String = ENTITY.replace(value) { match ->
            val entity = match.groupValues[1].lowercase()
            when {
                entity.startsWith("#x") -> entity.substring(2).toIntOrNull(16)?.let { String(Character.toChars(it)) }
                entity.startsWith("#") -> entity.substring(1).toIntOrNull()?.let { String(Character.toChars(it)) }
                else -> mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ")[entity]
            } ?: match.value
        }

        private fun text(html: String): String = decode(MARKUP.replace(html, " ")).replace(Regex("\\s+"), " ").trim()

        /** Thumbnails from a list page, in page order. */
        internal fun parseList(html: String): List<Map<String, Any?>> {
            val seen = HashSet<Long>()
            return THUMB.findAll(html).mapNotNull { match ->
                val id = match.groupValues[1].toLongOrNull()?.takeIf { it > 0 && seen.add(it) } ?: return@mapNotNull null
                val image = match.groupValues[2]
                // Lazily loaded thumbnails keep the real address in data-src.
                val thumb = upgradedHttpsUrl(REFERER, attr(image, "data-src") ?: attr(image, "src")) ?: return@mapNotNull null
                var rating: String? = null
                var score = 0
                val title = attr(image, "title") ?: attr(image, "alt") ?: ""
                // Titles are either space-separated tags or comma-separated names with spaces.
                val words = if (title.contains(", ")) title.split(", ").map { it.trim().replace(' ', '_') } else title.split(Regex("\\s+"))
                val tags = words.filter { word ->
                    when {
                        word.startsWith("rating:", ignoreCase = true) -> { rating = word.substringAfter(':'); false }
                        word.startsWith("score:", ignoreCase = true) -> { score = word.substringAfter(':').toIntOrNull() ?: 0; false }
                        else -> word.isNotBlank()
                    }
                }.distinct()
                mapOf(
                    "id" to id.toString(),
                    // The file is only named on the post's page; see the class comment.
                    "url" to thumb, "previewUrl" to thumb,
                    "tags" to tags,
                    "tagDetails" to tags.map { mapOf("name" to it, "category" to "general") },
                    "postUrl" to postUrl(id),
                    // Realbooru is an adult site; untitled ratings count as explicit for filtering.
                    "rating" to (rating ?: "explicit"),
                    "uploader" to "", "source" to "",
                    "width" to 0, "height" to 0,
                    "score" to score, "description" to "",
                    "videoVariants" to emptyList<Map<String, Any?>>(),
                    "md5" to (HASH.find(thumb)?.groupValues?.get(1)?.lowercase() ?: ""),
                    "parentId" to null,
                    "hasChildren" to false,
                    "sampleUrl" to "",
                    "pools" to emptyList<String>(),
                )
            }.toList()
        }

        /** A post from its page, or null when the page names no media. */
        internal fun parsePost(id: Long, html: String): Map<String, Any?>? {
            val container = CONTAINER.find(html)?.range?.first
            val region = if (container != null) html.substring(container, minOf(html.length, container + 6000)) else html
            val video = VIDEO_PLAYER.find(html)?.value ?: VIDEO.find(region)?.value
            val element: String
            val file: String?
            if (video != null) {
                element = VIDEO_TAG.find(video)?.value ?: ""
                file = attr(element, "src") ?: SOURCE.find(video)?.value?.let { attr(it, "src") }
            } else {
                element = MAIN_IMAGE.find(html)?.value ?: IMAGE.find(region)?.value?.takeIf { container != null } ?: ""
                file = attr(element, "src")
            }
            val url = upgradedHttpsUrl(REFERER, file) ?: return null
            val path = IMAGE_PATH.find(url)?.groupValues
            val preview = path?.let { "https://$HOST/thumbnails/${it[1]}/${it[2]}/thumbnail_${it[3]}.jpg" }
                ?: upgradedHttpsUrl(REFERER, attr(element, "poster")) ?: ""
            val details = LinkedHashMap<String, String>()
            TAG_LIST.find(html)?.range?.first?.let { start ->
                val list = html.substring(start, minOf(html.length, start + 60000))
                TAG_ELEMENT.findAll(list).forEach { match ->
                    val classes = attr(match.value, "class")?.split(Regex("\\s+"))?.toSet() ?: return@forEach
                    val category = TAG_CLASSES.firstOrNull { (names, _) -> classes.any(names::contains) }?.second ?: return@forEach
                    val rest = list.substring(match.range.last + 1)
                    val name = if (match.groupValues[1].equals("a", ignoreCase = true)) {
                        text(rest.substringBefore("</a>"))
                    } else {
                        // Gelbooru lists "? tag count": the "?" link opens the wiki.
                        LINK_TEXT.findAll(rest.substringBefore("</li>")).map { text(it.groupValues[1]) }
                            .firstOrNull { it.isNotEmpty() && it != "?" && it != "+" && it != "-" }.orEmpty()
                    }.replace(' ', '_')
                    if (name.isNotEmpty() && name != "?") details.putIfAbsent(name, category)
                }
            }
            TAGS_FIELD.find(html)?.groupValues?.get(1)?.let(::decode)?.split(Regex("\\s+"))
                ?.filter { it.isNotBlank() }?.forEach { details.putIfAbsent(it, "general") }
            val score = Regex("""\bid\s*=\s*["']psc$id["'][^>]*>\s*(-?\d+)""").find(html)?.groupValues?.get(1)?.toIntOrNull() ?: 0
            return mapOf(
                "id" to id.toString(),
                "url" to url, "previewUrl" to preview,
                "tags" to details.keys.toList(),
                "tagDetails" to details.map { mapOf("name" to it.key, "category" to it.value) },
                "postUrl" to postUrl(id),
                "rating" to (RATING.find(html)?.groupValues?.get(1)?.lowercase() ?: "explicit"),
                "uploader" to (UPLOADER.find(html)?.groupValues?.get(1)?.let(::text) ?: ""),
                "source" to (SOURCE_FIELD.find(html)?.value?.let { attr(it, "value") } ?: ""),
                "width" to (attr(element, "width")?.toIntOrNull() ?: 0),
                "height" to (attr(element, "height")?.toIntOrNull() ?: 0),
                "score" to score, "description" to "",
                "isVideo" to (video != null),
                "videoVariants" to emptyList<Map<String, Any?>>(),
                "md5" to (HASH.find(url)?.groupValues?.get(1)?.lowercase() ?: ""),
                "parentId" to null,
                "hasChildren" to false,
                "sampleUrl" to "",
                "pools" to emptyList<String>(),
            )
        }
    }
}
