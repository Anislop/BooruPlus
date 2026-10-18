package com.booruplus.app

import android.util.Xml
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.io.IOException
import java.io.StringReader
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.random.Random

/*
 * Clients for boards on engines other than Gelbooru/Danbooru: Sakugabooru
 * (Moebooru), e-shuushuu (its own REST API), Mikubooru (Hybooru), and
 * Nanbooru (Shimmie's Danbooru-compatible XML API). Dart sends them the
 * usual `order:`, `id:`, `md5:`, and `created_at:>=` tags; each client
 * translates what its engine supports and drops the rest. All return the
 * same post maps as MainActivity.mapImage.
 */

/**
 * Reads the zero-based Flutter [page] of [limit] posts from a provider whose
 * pages hold at most [maxPageSize] posts. The provider page size splits
 * [limit] as evenly as it can, and the provider pages covering the window
 * are read in turn and sliced; a short provider page ends the window.
 */
internal fun <T> pagedWindow(
    page: Int, limit: Int, maxPageSize: Int, cancelled: () -> Boolean,
    read: (providerPage: Int, pageSize: Int) -> List<T>,
): List<T> {
    val chunks = (limit + maxPageSize - 1) / maxPageSize
    val size = (limit + chunks - 1) / chunks
    val offset = page.toLong() * limit
    val first = (offset / size).toInt()
    val last = ((offset + limit - 1) / size).toInt()
    val items = ArrayList<T>()
    for (index in first..last) {
        if (cancelled()) throw IOException("Cancelled")
        val batch = read(index, size)
        items += batch
        if (batch.size < size) break
    }
    return items.drop((offset - first.toLong() * size).toInt()).take(limit)
}

/** A namespaced tag's category (`artist:name`), or [fallback] without a known namespace. */
private fun namespaceCategory(tag: String, fallback: String = "general"): String =
    when (tag.substringBefore(':', "").lowercase()) {
        "artist", "creator" -> "artist"
        "character" -> "character"
        "copyright", "series" -> "copyright"
        "species" -> "species"
        "meta", "medium" -> "meta"
        else -> fallback
    }

private fun postMap(
    id: Long, url: String, preview: String, tags: List<String>, details: List<Pair<String, String>>,
    postUrl: String, rating: String = "Unknown", uploader: String = "", source: String = "",
    width: Int = 0, height: Int = 0, score: Int = 0, md5: String = "", parentId: Long = 0,
    hasChildren: Boolean = false, sample: String? = null,
): Map<String, Any?> = mapOf(
    "id" to id.toString(),
    "url" to url, "previewUrl" to preview,
    "tags" to tags,
    "tagDetails" to details.map { mapOf("name" to it.first, "category" to it.second) },
    "postUrl" to postUrl,
    "rating" to rating, "uploader" to uploader, "source" to source,
    "width" to width, "height" to height, "score" to score, "description" to "",
    "videoVariants" to emptyList<Map<String, Any?>>(),
    "md5" to md5.lowercase().takeIf { MD5_PATTERN.matches(it) }.orEmpty(),
    "parentId" to parentId.takeIf { it > 0 }?.toString(),
    "hasChildren" to hasChildren,
    "sampleUrl" to (sample?.takeIf { it != url && it != preview } ?: ""),
    "pools" to emptyList<String>(),
)

/** The string at [name], or "" when it is missing or JSON null (optString gives "null"). */
private fun JSONObject.text(name: String): String = if (isNull(name)) "" else optString(name)

/** A `created_at:>=` or `date:>=` day from Dart's date filter, if [tag] is one. */
private fun dateFrom(tag: String): String? =
    Regex("^(?:created_at|date):>=?(\\d{4}-\\d{2}-\\d{2})").find(tag.lowercase())?.groupValues?.get(1)

/**
 * Sakugabooru (www.sakugabooru.com): Moebooru's `post.json`, asked with
 * `api_version=2&include_tags=1` so each page names its tags' types. Most
 * posts are MP4/WebM clips with JPEG previews; for videos the sample and
 * JPEG URLs repeat the original, so no sample is sent.
 */
internal class SakugabooruApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        val offset = discoveryOffset(random, tags, seed)
        val posts = request(tags, page + offset, limit)
        val result = if (posts.isEmpty() && offset > 0) request(tags, page, limit) else posts
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun request(tags: List<String>, page: Int, limit: Int): List<Map<String, Any?>> {
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("post.json")
            .addQueryParameter("api_version", "2").addQueryParameter("include_tags", "1")
            .addQueryParameter("limit", limit.coerceIn(1, 200).toString())
            .addQueryParameter("page", (page + 1).toString())
            .apply { if (tags.isNotEmpty()) addQueryParameter("tags", tags.joinToString(" ")) }
            .build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return emptyList()
        val json = JSONObject(body)
        val types = json.optJSONObject("tags")
        val posts = json.optJSONArray("posts") ?: return emptyList()
        return (0 until posts.length()).mapNotNull { posts.optJSONObject(it)?.let { post -> mapPost(post, types) } }
    }

    private fun mapPost(post: JSONObject, types: JSONObject?): Map<String, Any?>? {
        val id = post.optLong("id").takeIf { it > 0 } ?: return null
        val original = httpsUrl(HOST, post.optString("file_url")) ?: return null
        val preview = httpsUrl(HOST, post.optString("preview_url")) ?: original
        val tags = splitTags(post.optString("tags"))
        return postMap(
            id, original, preview, tags,
            tags.map { it to category(types?.optString(it)) },
            postUrl = "https://$HOST/post/show/$id",
            rating = post.optString("rating", "Unknown"),
            uploader = post.text("author"), source = post.text("source"),
            width = post.optInt("width"), height = post.optInt("height"), score = post.optInt("score"),
            md5 = post.optString("md5"), parentId = post.optLong("parent_id"),
            hasChildren = post.optBoolean("has_children"),
            sample = httpsUrl(HOST, post.optString("sample_url")),
        )
    }

    private fun category(type: String?): String = when (type?.lowercase()) {
        "artist" -> "artist"
        "copyright" -> "copyright"
        "character" -> "character"
        "meta" -> "meta"
        else -> "general"
    }

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim().trimEnd('*')
        if (term.isEmpty()) return emptyList()
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("tag.json")
            .addQueryParameter("name", "$term*").addQueryParameter("order", "count")
            .addQueryParameter("limit", limit.toString()).build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("[")) return emptyList()
        val array = JSONArray(body)
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val name = item.optString("name").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val category = when (item.optInt("type", -1)) {
                0 -> "general"; 1 -> "artist"; 3 -> "copyright"; 4 -> "character"; 5 -> "meta"; else -> "unknown"
            }
            mapOf("name" to name, "category" to category, "postCount" to item.optInt("count").takeIf { it > 0 })
        }
    }

    companion object {
        const val HOST = "www.sakugabooru.com"
    }
}

/**
 * e-shuushuu (e-shuushuu.net): a REST API whose searches take tag IDs, so
 * tag names are looked up first (cached, aliases followed). Tags are titles
 * with spaces and capitals ("Hatsune Miku"); posts show them lowercased with
 * underscores, which this client turns back into titles. An unknown tag
 * matches nothing; unknown exclusions are skipped and left to Dart's local
 * filter. The board is all-ages and has no content ratings.
 */
internal class EShuushuuApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    private val tagIds = object : LinkedHashMap<String, Long>(64, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?) = size > 512
    }

    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        tags.firstNotNullOfOrNull { Regex("^id:(\\d+)$").find(it.lowercase())?.groupValues?.get(1)?.toLongOrNull() }?.let { id ->
            if (page > 0) return emptyList()
            val body = client.getBody(apiUrl("images", id.toString()).build(), userAgent)?.trim().orEmpty()
            return if (body.startsWith("{")) listOfNotNull(mapPost(JSONObject(body))) else emptyList()
        }
        tags.firstNotNullOfOrNull { Regex("^md5:([0-9a-f]{32})$").find(it.lowercase())?.groupValues?.get(1) }?.let { md5 ->
            if (page > 0) return emptyList()
            return images(client.getBody(apiUrl("images", "search", "by-hash", md5).build(), userAgent))
        }
        val included = ArrayList<Long>()
        val excluded = ArrayList<Long>()
        var sort = "image_id" to "DESC"
        var from: String? = null
        var exclusionLookups = 0
        for (raw in tags) {
            val tag = raw.trim().lowercase()
            val day = dateFrom(tag)
            if (day != null) { from = day; continue }
            when (tag) {
                "order:score" -> { sort = "bayesian_rating" to "DESC"; continue }
                "order:favcount" -> { sort = "favorites" to "DESC"; continue }
                "order:mpixels" -> { sort = "total_pixels" to "DESC"; continue }
                "order:id_desc" -> { sort = "image_id" to "DESC"; continue }
                "order:id_asc", "order:id" -> { sort = "image_id" to "ASC"; continue }
            }
            // Other metatags have no equivalent; titles may hold colons ("re:zero").
            if (tag.removePrefix("-").substringBefore(':', "") in METATAGS) continue
            if (tag.startsWith("-")) {
                // Bounded: a long blocklist would otherwise cost one lookup per tag.
                if (tag.length < 2 || exclusionLookups++ >= MAX_EXCLUSION_LOOKUPS) continue
                tagId(tag.substring(1), cancelled)?.let(excluded::add)
            } else {
                included += tagId(tag, cancelled) ?: return emptyList()
            }
        }
        val since = from
        val start = page + discoveryOffset(random, tags, seed)
        fun read(first: Int): List<Map<String, Any?>> = pagedWindow(first, limit, MAX_PAGE_SIZE, cancelled) { index, size ->
            val url = apiUrl("images")
                .addQueryParameter("page", (index + 1).toString())
                .addQueryParameter("per_page", size.toString())
                .addQueryParameter("sort_by", sort.first).addQueryParameter("sort_order", sort.second)
                .apply {
                    if (included.isNotEmpty()) {
                        addQueryParameter("tags", included.joinToString(","))
                        addQueryParameter("tags_mode", "all")
                    }
                    if (excluded.isNotEmpty()) addQueryParameter("exclude_tags", excluded.joinToString(","))
                    since?.let { addQueryParameter("date_from", it) }
                }
                .build()
            images(client.getBody(url, userAgent))
        }
        val posts = read(start)
        val result = if (posts.isEmpty() && start != page) read(page) else posts
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun apiUrl(vararg segments: String): HttpUrl.Builder =
        HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("api").addPathSegment("v1")
            .apply { segments.forEach { addPathSegment(it) } }

    private fun images(body: String?): List<Map<String, Any?>> {
        val text = body?.trim().orEmpty()
        if (!text.startsWith("{")) return emptyList()
        val images = JSONObject(text).optJSONArray("images") ?: return emptyList()
        return (0 until images.length()).mapNotNull { images.optJSONObject(it)?.let(::mapPost) }
    }

    private fun mapPost(post: JSONObject): Map<String, Any?>? {
        val id = post.optLong("image_id").takeIf { it > 0 } ?: return null
        val original = httpsUrl(HOST, post.optString("url")) ?: return null
        val preview = httpsUrl(HOST, post.optString("thumbnail_url")) ?: original
        val sample = httpsUrl(HOST, post.optString("large_url")).takeIf { post.optInt("large") == 1 }
            ?: httpsUrl(HOST, post.optString("medium_url")).takeIf { post.optInt("medium") == 1 }
        val details = ArrayList<Pair<String, String>>()
        post.optJSONArray("tags")?.let { array ->
            for (index in 0 until array.length()) {
                val tag = array.optJSONObject(index) ?: continue
                val name = tagName(tag.optString("title")).takeIf { it.isNotEmpty() } ?: continue
                val category = when (tag.optInt("type")) { 2 -> "copyright"; 3 -> "artist"; 4 -> "character"; else -> "general" }
                details += name to category
            }
        }
        return postMap(
            id, original, preview, details.map { it.first }, details,
            postUrl = "https://$HOST/image/$id",
            uploader = post.optJSONObject("user")?.text("username").orEmpty(),
            source = post.text("source_url"),
            width = post.optInt("width"), height = post.optInt("height"),
            score = post.optInt("favorites"), md5 = post.optString("md5_hash"),
            sample = sample,
        )
    }

    /**
     * The ID of the tag shown as [name], following aliases; null when there
     * is none. Only found tags are cached, so a tag created later, or one
     * missing from this search's first page, is looked up again.
     */
    private fun tagId(name: String, cancelled: () -> Boolean): Long? {
        synchronized(tagIds) { tagIds[name] }?.let { return it }
        if (cancelled()) throw IOException("Cancelled")
        val url = apiUrl("tags").addQueryParameter("search", name.replace('_', ' '))
            .addQueryParameter("per_page", MAX_PAGE_SIZE.toString()).addQueryParameter("sort_by", "usage_count").build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return null
        val found = JSONObject(body).optJSONArray("tags")
        var id = 0L
        if (found != null) {
            for (index in 0 until found.length()) {
                val tag = found.optJSONObject(index) ?: continue
                if (tagName(tag.optString("title")) != name) continue
                id = tag.optLong("alias_of").takeIf { tag.optBoolean("is_alias") && it > 0 } ?: tag.optLong("tag_id")
                break
            }
        }
        if (id <= 0) return null
        synchronized(tagIds) { tagIds[name] = id }
        return id
    }

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim().replace('_', ' ')
        if (term.isEmpty()) return emptyList()
        val url = apiUrl("tags").addQueryParameter("search", term)
            .addQueryParameter("per_page", limit.coerceIn(1, MAX_PAGE_SIZE).toString())
            .addQueryParameter("sort_by", "usage_count").build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return emptyList()
        val tags = JSONObject(body).optJSONArray("tags") ?: return emptyList()
        return (0 until tags.length()).mapNotNull { index ->
            val tag = tags.optJSONObject(index) ?: return@mapNotNull null
            val name = tagName(tag.optString("title")).takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val category = when (tag.optInt("type")) { 1 -> "general"; 2 -> "copyright"; 3 -> "artist"; 4 -> "character"; else -> "unknown" }
            mapOf("name" to name, "category" to category, "postCount" to tag.optInt("usage_count").takeIf { it > 0 })
        }
    }

    private fun tagName(title: String): String = title.trim().lowercase().replace(Regex("\\s+"), "_")

    companion object {
        const val HOST = "e-shuushuu.net"
        private const val MAX_PAGE_SIZE = 100
        private const val MAX_EXCLUSION_LOOKUPS = 20
        private val METATAGS = setOf(
            "order", "sort", "rating", "id", "md5", "date", "created_at", "score", "user",
            "parent", "width", "height", "filetype", "type", "pool", "fav",
        )
    }
}

/**
 * Mikubooru (booru.funmaker.moe), a Hybooru instance. `/api/post` pages hold
 * at most 72 posts and carry no tags, so each post's tags come from
 * `/api/post/<id>` (fetched a few at a time and cached; a failed lookup
 * leaves the post untagged). Media is `/files/f<sha256><ext>` with JPEG
 * thumbnails at `/files/t<sha256>.thumbnail`. Its `rating` is a score, not a
 * content rating, and it has no MD5 search.
 */
internal class HybooruApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    private val details = object : LinkedHashMap<Long, JSONObject>(64, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, JSONObject>?) = size > 600
    }
    private val lookups: ExecutorService = Executors.newFixedThreadPool(4)

    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        tags.firstNotNullOfOrNull { Regex("^id:(\\d+)$").find(it.lowercase())?.groupValues?.get(1)?.toLongOrNull() }?.let { id ->
            if (page > 0) return emptyList()
            return listOfNotNull(detail(id)?.let { mapPost(it, it) })
        }
        if (tags.any { it.lowercase().startsWith("md5:") }) return emptyList()
        val query = tags.mapNotNull { raw ->
            val tag = raw.trim().lowercase()
            when {
                tag == "order:favcount" -> "order:score"
                tag == "order:mpixels" -> "order:size"
                tag.startsWith("rating:") || dateFrom(tag) != null -> null
                else -> tag.takeIf { it.isNotEmpty() }
            }
        }
        val start = page + discoveryOffset(random, tags, seed)
        fun read(from: Int): List<JSONObject> = pagedWindow(from, limit, MAX_PAGE_SIZE, cancelled) { index, size ->
            val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("api").addPathSegment("post")
                .addQueryParameter("query", query.joinToString(" "))
                .addQueryParameter("page", index.toString()).addQueryParameter("pageSize", size.toString())
                .addQueryParameter("hashes", "true").addQueryParameter("blurhash", "true")
                .build()
            val body = client.getBody(url, userAgent)?.trim().orEmpty()
            if (!body.startsWith("{")) return@pagedWindow emptyList()
            val posts = JSONObject(body).optJSONArray("posts") ?: return@pagedWindow emptyList()
            (0 until posts.length()).mapNotNull { posts.optJSONObject(it) }
        }
        val summaries = read(start).ifEmpty { if (start != page) read(page) else emptyList() }
        val full = details(summaries.map { it.optLong("id") }, cancelled)
        val result = summaries.mapIndexedNotNull { index, summary -> mapPost(summary, full[index]) }
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    /**
     * Each post's details, looked up a few at a time; null where a lookup
     * failed or ran past the deadline. The lookups run on [lookups], where
     * the feed's cancellation is not visible, so this thread polls
     * [cancelled] and stops them all when the feed is superseded.
     */
    private fun details(ids: List<Long>, cancelled: () -> Boolean): List<JSONObject?> {
        if (cancelled()) throw IOException("Cancelled")
        val futures = ids.map { id -> lookups.submit(Callable { runCatching { detail(id) }.getOrNull() }) }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(DETAIL_TIMEOUT_SECONDS)
        try {
            return futures.map { future ->
                var value: JSONObject? = null
                while (true) {
                    if (cancelled()) throw IOException("Cancelled")
                    val left = deadline - System.nanoTime()
                    if (left <= 0) break
                    try {
                        value = future.get(minOf(left, POLL_NANOS), TimeUnit.NANOSECONDS)
                        break
                    } catch (_: TimeoutException) {
                    } catch (_: ExecutionException) {
                        break
                    }
                }
                value
            }
        } finally {
            futures.forEach { it.cancel(true) }
        }
    }

    private fun detail(id: Long): JSONObject? {
        if (id <= 0) return null
        synchronized(details) { details[id] }?.let { return it }
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("api").addPathSegment("post")
            .addPathSegment(id.toString()).build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return null
        val post = JSONObject(body)
        synchronized(details) { details[id] = post }
        return post
    }

    private fun mapPost(summary: JSONObject, detail: JSONObject?): Map<String, Any?>? {
        val id = summary.optLong("id").takeIf { it > 0 } ?: return null
        val sha = summary.optString("sha256").lowercase().takeIf { SHA256.matches(it) } ?: return null
        val extension = summary.optString("extension").takeIf { EXTENSION.matches(it) } ?: return null
        val tags = detail?.optJSONObject("tags")?.keys()?.asSequence()?.toList().orEmpty()
        val source = detail?.optJSONArray("sources")?.optString(0).orEmpty()
        return postMap(
            id, "https://$HOST/files/f$sha$extension", "https://$HOST/files/t$sha.thumbnail",
            tags, tags.map { it to namespaceCategory(it) },
            postUrl = "https://$HOST/posts/$id",
            source = source,
            width = detail?.optInt("width")?.takeIf { it > 0 } ?: summary.optInt("width"),
            height = detail?.optInt("height")?.takeIf { it > 0 } ?: summary.optInt("height"),
            md5 = detail?.optString("md5")?.takeIf { it.isNotEmpty() } ?: summary.optString("md5"),
        )
    }

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim().lowercase().trimEnd('*')
        if (term.isEmpty()) return emptyList()
        val url = HttpUrl.Builder().scheme("https").host(HOST).addPathSegment("api").addPathSegment("tags")
            .addQueryParameter("query", "$term*").addQueryParameter("pageSize", limit.toString()).build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return emptyList()
        val tags = JSONObject(body).optJSONObject("tags") ?: return emptyList()
        return tags.keys().asSequence().take(limit).map { name ->
            mapOf("name" to name, "category" to namespaceCategory(name, "unknown"), "postCount" to tags.optInt(name).takeIf { it > 0 })
        }.toList()
    }

    fun close() = lookups.shutdownNow()

    companion object {
        const val HOST = "booru.funmaker.moe"
        private const val MAX_PAGE_SIZE = 72
        private const val DETAIL_TIMEOUT_SECONDS = 20L
        private val POLL_NANOS = TimeUnit.MILLISECONDS.toNanos(200)
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val EXTENSION = Regex("^\\.[A-Za-z0-9]{1,5}$")
    }
}

/**
 * Nanbooru (emmytherobot.art), a Shimmie board with the Danbooru-compatible
 * XML API: `/api/danbooru/find_posts` takes `tags`, `limit` (at most 100),
 * and a one-based `page`; media URLs are site-relative. Tags carry their
 * category as a namespace (`artist:name`). Shimmie orders with
 * `order:<column>_<dir>` and filters dates with `posted>=`. The board is
 * safe-for-work and leaves posts unrated.
 */
internal class ShimmieApi(private val client: OkHttpClient, private val userAgent: String) : BoardClient {
    override fun fetch(tags: List<String>, page: Int, limit: Int, random: Boolean, seed: Int, cancelled: () -> Boolean): List<Map<String, Any?>> {
        if (cancelled()) throw IOException("Cancelled")
        val query = tags.mapNotNull { raw ->
            val tag = raw.trim().lowercase()
            dateFrom(tag)?.let { return@mapNotNull "posted>=$it" }
            when {
                tag == "order:score" -> "order:score_desc"
                tag == "order:favcount" -> "order:favorites_desc"
                tag == "order:mpixels" -> "order:width_desc"
                tag.startsWith("id:") -> "id=${tag.substring(3)}"
                tag.startsWith("rating:") -> null
                else -> tag.takeIf { it.isNotEmpty() }
            }
        }
        val start = page + discoveryOffset(random, tags, seed)
        fun read(from: Int) = pagedWindow(from, limit, MAX_PAGE_SIZE, cancelled) { index, size ->
            val url = HttpUrl.Builder().scheme("https").host(HOST)
                .addPathSegment("api").addPathSegment("danbooru").addPathSegment("find_posts")
                .addQueryParameter("limit", size.toString()).addQueryParameter("page", (index + 1).toString())
                .apply { if (query.isNotEmpty()) addQueryParameter("tags", query.joinToString(" ")) }
                .build()
            parse(client.getBody(url, userAgent))
        }
        val posts = read(start)
        val result = if (posts.isEmpty() && start != page) read(page) else posts
        return if (random) result.shuffled(Random(seed xor page)) else result
    }

    private fun parse(body: String?): List<Map<String, Any?>> {
        val text = body?.trim().orEmpty()
        if (!text.startsWith("<")) return emptyList()
        val parser = Xml.newPullParser()
        parser.setInput(StringReader(text))
        val posts = ArrayList<Map<String, Any?>>()
        while (parser.next() != XmlPullParser.END_DOCUMENT) {
            if (parser.eventType != XmlPullParser.START_TAG || parser.name != "tag") continue
            fun attribute(name: String): String = parser.getAttributeValue(null, name).orEmpty()
            val id = attribute("id").toLongOrNull()?.takeIf { it > 0 } ?: continue
            val original = httpsUrl(HOST, attribute("file_url")) ?: continue
            val tags = splitTags(attribute("tags"))
            posts += postMap(
                id, original, httpsUrl(HOST, attribute("preview_url")) ?: original,
                tags, tags.map { it to namespaceCategory(it) },
                postUrl = "https://$HOST/post/view/$id",
                uploader = attribute("author"), source = attribute("source"),
                width = attribute("width").toIntOrNull() ?: 0, height = attribute("height").toIntOrNull() ?: 0,
                score = attribute("score").toIntOrNull() ?: 0, md5 = attribute("md5"),
            )
        }
        return posts
    }

    override fun autocomplete(query: String, limit: Int): List<Map<String, Any?>> {
        val term = query.trim().lowercase()
        if (term.isEmpty()) return emptyList()
        val url = HttpUrl.Builder().scheme("https").host(HOST)
            .addPathSegment("api").addPathSegment("internal").addPathSegment("autocomplete")
            .addQueryParameter("s", term).build()
        val body = client.getBody(url, userAgent)?.trim().orEmpty()
        if (!body.startsWith("{")) return emptyList()
        val json = JSONObject(body)
        // Aliases point at their tag (`newtag`); show the tag once.
        val seen = LinkedHashMap<String, Int?>()
        json.keys().forEach { key ->
            val entry = json.optJSONObject(key) ?: return@forEach
            val name = entry.optString("newtag").takeIf { it.isNotBlank() && it != "null" } ?: key
            if (name !in seen) seen[name] = entry.optInt("count").takeIf { it > 0 }
        }
        return seen.entries.take(limit).map { (name, count) ->
            mapOf("name" to name, "category" to namespaceCategory(name, "unknown"), "postCount" to count)
        }
    }

    companion object {
        const val HOST = "emmytherobot.art"
        private const val MAX_PAGE_SIZE = 100
    }
}
