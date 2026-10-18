package com.booruplus.app

import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MoreBoardsTest {
    private fun respond(chain: Interceptor.Chain, body: String, code: Int = 200): Response =
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
            .code(code).message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()

    private fun client(handler: (Interceptor.Chain) -> Response) =
        OkHttpClient.Builder().addInterceptor(handler).build()

    @Test fun pagedWindowSlicesProviderPagesAcrossFlutterPages() {
        val source = (0 until 500).toList()
        val requested = mutableListOf<Pair<Int, Int>>()
        fun window(page: Int, limit: Int, max: Int) = pagedWindow(page, limit, max, { false }) { index, size ->
            requested += index to size
            source.drop(index * size).take(size)
        }
        // 200 posts from pages of at most 72: three pages of 67.
        assertEquals((200 until 400).toList(), window(1, 200, 72))
        assertTrue(requested.all { it.second == 67 })
        requested.clear()
        // A limit within the provider's maximum maps one to one.
        assertEquals((50 until 100).toList(), window(1, 50, 100))
        assertEquals(listOf(1 to 50), requested)
        // A short provider page ends the window.
        assertEquals((400 until 500).toList(), window(2, 200, 100))
        assertTrue(window(3, 200, 100).isEmpty())
    }

    @Test fun eShuushuuSearchesByTagIdFollowingAliases() {
        val imageQueries = mutableListOf<okhttp3.HttpUrl>()
        val api = EShuushuuApi(client { chain ->
            val url = chain.request().url
            when (url.encodedPath) {
                "/api/v1/tags" -> {
                    val tags = when (url.queryParameter("search")) {
                        "hatsune miku" -> JSONArray().put(JSONObject().put("title", "Hatsune Mikuo").put("tag_id", 9))
                            .put(JSONObject().put("title", "Hatsune Miku").put("tag_id", 7).put("is_alias", true).put("alias_of", 74925))
                        "glasses" -> JSONArray().put(JSONObject().put("title", "glasses").put("tag_id", 11))
                        else -> JSONArray()
                    }
                    respond(chain, JSONObject().put("tags", tags).toString())
                }
                "/api/v1/images" -> {
                    imageQueries += url
                    val image = JSONObject().put("image_id", 5).put("url", "https://cdn.e-shuushuu.net/fullsize/a.jpg")
                        .put("thumbnail_url", "https://cdn.e-shuushuu.net/thumbs/a.webp")
                        .put("tags", JSONArray().put(JSONObject().put("title", "Hatsune Miku").put("type", 4)))
                    respond(chain, JSONObject().put("images", JSONArray().put(image)).toString())
                }
                else -> throw AssertionError("Unexpected ${url.encodedPath}")
            }
        }, "test")

        val posts = api.fetch(listOf("hatsune_miku", "-glasses", "-not_a_tag", "order:score", "rating:safe"), 0, 50, false, 0) { false }
        val query = imageQueries.single()
        assertEquals("74925", query.queryParameter("tags"))
        assertEquals("all", query.queryParameter("tags_mode"))
        assertEquals("11", query.queryParameter("exclude_tags"))
        assertEquals("bayesian_rating", query.queryParameter("sort_by"))
        assertEquals("hatsune_miku", (posts.single()["tags"] as List<*>).single())

        // An unknown tag matches nothing and asks for no images.
        assertTrue(api.fetch(listOf("not_a_tag"), 0, 50, false, 0) { false }.isEmpty())
        assertEquals(1, imageQueries.size)
    }

    @Test fun gelbooru02BuildsMediaUrlsWhenThePostOmitsThem() {
        val body = JSONArray().put(
            JSONObject().put("id", 3).put("directory", "15").put("image", "abc.png")
                .put("hash", "0123456789abcdef0123456789abcdef").put("sample", true).put("tags", "a b")
        ).toString()
        val mspa = Gelbooru02Api(client { respond(it, body) }, "test", Gelbooru02Api.MSPABOORU_HOST, keepsThumbnailExtension = true)
        val post = mspa.fetch(emptyList(), 0, 50, false, 0) { false }.single()
        assertEquals("https://mspabooru.com/images/15/abc.png", post["url"])
        assertEquals("https://mspabooru.com/thumbnails/15/thumbnail_abc.png", post["previewUrl"])
        assertEquals("https://mspabooru.com/samples/15/sample_abc.png", post["sampleUrl"])

        val tbib = Gelbooru02Api(client { respond(it, body) }, "test", Gelbooru02Api.TBIB_HOST)
        assertEquals("https://tbib.org/thumbnails/15/thumbnail_abc.jpg", tbib.fetch(emptyList(), 0, 50, false, 0) { false }.single()["previewUrl"])
    }

    @Test fun hybooruTagsComeFromEachPostAndFailuresLeaveItUntagged() {
        val sha = "a".repeat(64)
        val api = HybooruApi(client { chain ->
            val path = chain.request().url.encodedPath
            when (path) {
                "/api/post" -> respond(chain, JSONObject().put("posts", JSONArray()
                    .put(JSONObject().put("id", 1).put("sha256", sha).put("extension", ".png").put("width", 10).put("height", 20))
                    .put(JSONObject().put("id", 2).put("sha256", sha).put("extension", ".mp4"))).toString())
                "/api/post/1" -> respond(chain, JSONObject().put("id", 1)
                    .put("tags", JSONObject().put("character:hatsune_miku", 5).put("smile", 3)).toString())
                else -> respond(chain, "", 500)
            }
        }, "test")
        try {
            val posts = api.fetch(listOf("order:mpixels"), 0, 50, false, 0) { false }
            assertEquals(listOf("1", "2"), posts.map { it["id"] })
            assertEquals("https://booru.funmaker.moe/files/f$sha.png", posts[0]["url"])
            assertEquals("https://booru.funmaker.moe/files/t$sha.thumbnail", posts[0]["previewUrl"])
            assertEquals(listOf("character:hatsune_miku", "smile"), (posts[0]["tags"] as List<*>).map { it.toString() }.sorted())
            assertTrue((posts[1]["tags"] as List<*>).isEmpty())
            assertEquals(10, posts[0]["width"])
        } finally {
            api.close()
        }
    }
}
