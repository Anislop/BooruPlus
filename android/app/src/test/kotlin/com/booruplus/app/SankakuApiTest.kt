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
import java.io.IOException
import java.util.concurrent.TimeUnit

class SankakuApiTest {
    private fun post(id: String, accessible: Boolean = true): JSONObject = JSONObject()
        .put("id", id)
        .put("file_url", if (accessible) "https://media.example/$id.jpg" else JSONObject.NULL)

    private fun response(chain: Interceptor.Chain, rows: List<JSONObject>, next: String?): Response =
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
            .code(200).message("OK")
            .body(JSONObject().put("data", JSONArray(rows))
                .put("meta", JSONObject().put("next", next ?: JSONObject.NULL))
                .toString().toResponseBody("application/json".toMediaType()))
            .build()

    private fun fetch(api: SankakuApi, page: Int = 0, limit: Int = 50, cancelled: () -> Boolean = { false }) =
        api.fetch(emptyList(), page, limit, false, "search", true, null, cancelled)

    @Test fun shortBatchReturnsBeforeRequestingAnotherPage() {
        val requested = mutableListOf<String?>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            requested.add(chain.request().url.queryParameter("next"))
            when (requested.size) {
                1 -> response(chain, listOf(post("first"), post("locked", false)), "second-page")
                2 -> response(chain, listOf(post("second")), null)
                else -> throw AssertionError("Fetched beyond the end")
            }
        }.build()
        val api = SankakuApi(client, "test")
        assertEquals(listOf("first"), fetch(api).map { it["id"] })
        assertEquals(listOf<String?>(null), requested)
        assertEquals(listOf("second"), fetch(api, page = 1).map { it["id"] })
        assertTrue(fetch(api, page = 2).isEmpty())
        assertEquals(listOf(null, "second-page"), requested)
    }

    @Test fun largeBatchLeavesTheNextKeysetForLoadMore() {
        var calls = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            assertEquals("100", chain.request().url.queryParameter("limit"))
            if (calls == 1) {
                response(chain, (1..100).map { post("p$it") }, "after100")
            } else {
                assertEquals("after100", chain.request().url.queryParameter("next"))
                response(chain, listOf(post("p101")), null)
            }
        }.build()
        val api = SankakuApi(client, "test")
        assertEquals(100, fetch(api, limit = 200).size)
        assertEquals(1, calls)
        assertEquals("p101", fetch(api, page = 1, limit = 200).single()["id"])
    }

    @Test fun inaccessibleRowsDoNotEndTheKeysetSearch() {
        var calls = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            if (calls == 1) response(chain, listOf(post("locked", false)), "accessible-page")
            else {
                assertEquals("accessible-page", chain.request().url.queryParameter("next"))
                response(chain, listOf(post("visible")), null)
            }
        }.build()
        assertEquals("visible", fetch(SankakuApi(client, "test")).single()["id"])
        assertEquals(2, calls)
    }

    @Test fun failedPageRetriesTheSameCursorWithoutLosingEarlierPosts() {
        val requested = mutableListOf<String?>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            requested.add(chain.request().url.queryParameter("next"))
            when (requested.size) {
                1 -> response(chain, listOf(post("first")), "retry-here")
                2 -> throw IOException("offline")
                else -> response(chain, listOf(post("second")), null)
            }
        }.build()
        val api = SankakuApi(client, "test")
        assertEquals("first", fetch(api).single()["id"])
        assertThrows(IOException::class.java) { fetch(api, page = 1) }
        assertEquals("second", fetch(api, page = 1).single()["id"])
        assertEquals(listOf(null, "retry-here", "retry-here"), requested)
    }

    @Test(timeout = 5000) fun keysetRequestsShareOneDeadlineAndCancelWhenItExpires() {
        val deadlines = mutableListOf<Long>()
        val client = OkHttpClient.Builder().callTimeout(400, TimeUnit.MILLISECONDS)
            .addInterceptor { chain ->
                assertTrue(chain.call().timeout().hasDeadline())
                deadlines.add(chain.call().timeout().deadlineNanoTime())
                if (deadlines.size == 1) {
                    Thread.sleep(100)
                    response(chain, listOf(post("locked", false)), "next")
                } else {
                    // Simulate a stalled request. OkHttp must cancel the call
                    // at the original page deadline, not start a fresh budget.
                    val safety = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                    while (!chain.call().isCanceled() && System.nanoTime() < safety) Thread.sleep(5)
                    assertTrue("The stalled call was not cancelled", chain.call().isCanceled())
                    throw IOException("Cancelled")
                }
            }.build()
        assertThrows(IOException::class.java) { fetch(SankakuApi(client, "test")) }
        assertEquals(2, deadlines.size)
        assertEquals(deadlines[0], deadlines[1])
    }

    @Test fun repeatedEmptyCursorFailsInsteadOfRepeatedlyFetchingIt() {
        var calls = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            response(chain, emptyList(), "same-token")
        }.build()
        assertThrows(IOException::class.java) { fetch(SankakuApi(client, "test")) }
        assertEquals(2, calls)
    }

    @Test fun requestBoundWithMorePagesIsNotReportedAsExhaustion() {
        var calls = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            calls++
            response(chain, listOf(post("locked$calls", false)), "next$calls")
        }.build()
        val api = SankakuApi(client, "test")
        assertThrows(IOException::class.java) { fetch(api) }
        assertEquals(8, calls)
    }

    @Test fun cancelledFetchDoesNotStartARequest() {
        val client = OkHttpClient.Builder().addInterceptor { _ ->
            throw AssertionError("Cancelled fetch issued HTTP request")
        }.build()
        assertThrows(IOException::class.java) { fetch(SankakuApi(client, "test"), cancelled = { true }) }
    }

    @Test
    fun recognizesAvifPreviewsAndMediaHosts() {
        fun header(brand: String) = byteArrayOf(0, 0, 0, 32) + "ftyp$brand".toByteArray() + ByteArray(8)
        assertTrue(isAvif(header("avif")))
        assertTrue(isAvif(header("avis")))
        assertFalse(isAvif(header("heic")))
        assertFalse(isAvif(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())))
        assertFalse(isAvif("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ".toByteArray()))

        assertTrue(isSankakuMediaHost("v.sankakucomplex.com"))
        assertTrue(isSankakuMediaHost("s.sankakucomplex.com"))
        assertFalse(isSankakuMediaHost("sankakucomplex.com.evil.example"))
        assertFalse(isSankakuMediaHost("evilsankakucomplex.com"))
    }

    private fun json(chain: Interceptor.Chain, code: Int, body: String): Response =
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
            .code(code).message("HTTP $code")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()

    private fun tagAndWiki(name: String, wiki: String?, aliasOf: String? = null): String = JSONObject()
        .put("wiki", wiki?.let {
            JSONObject().put("title", name).put("body", it)
                .put("updated_at", JSONObject().put("json_class", "Time").put("s", 1623894540).put("n", 0))
        } ?: JSONObject.NULL)
        .put("tag", JSONObject().put("tagName", name).put("name_en", "Display $name").put("name_ja", JSONObject.NULL)
            .put("type", 4).put("post_count", 12).put("pool_count", 3)
            .put("alias_of", aliasOf?.let { JSONObject().put("tagName", it) } ?: JSONObject()))
        .toString()

    @Test fun tagWikiParsesTheArticleAndTag() {
        val wiki = parseSankakuTagWiki(JSONObject(tagAndWiki("hatsune_miku", "A [[Vocaloid]].")))!!
        assertEquals("hatsune_miku", wiki["name"])
        assertEquals("Display hatsune_miku", wiki["displayName"])
        assertEquals("", wiki["japaneseName"])
        assertEquals("character", wiki["category"])
        assertEquals(12, wiki["postCount"])
        assertEquals(3, wiki["poolCount"])
        assertEquals("A [[Vocaloid]].", wiki["body"])
        assertEquals(1623894540000L, wiki["updatedAt"])
        assertNull(wiki["aliasOf"])
        val bare = parseSankakuTagWiki(JSONObject(tagAndWiki("outfit", null)))!!
        assertEquals("", bare["body"])
        assertNull(bare["updatedAt"])
        assertNull(parseSankakuTagWiki(JSONObject().put("wiki", JSONObject.NULL)))
    }

    @Test fun tagWikiFollowsAnAliasAndReportsUnknownTags() {
        val paths = mutableListOf<String>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val path = chain.request().url.encodedPath
            paths.add(path)
            assertNull(chain.request().header("Authorization"))
            when (path) {
                "/tag-and-wiki/name/miku_hatsune" -> json(chain, 200, tagAndWiki("miku_hatsune", null, aliasOf = "hatsune_miku"))
                "/tag-and-wiki/name/hatsune_miku" -> json(chain, 200, tagAndWiki("hatsune_miku", "Article"))
                "/tag-and-wiki/name/1%2F6_(vocaloid)" -> json(chain, 200, tagAndWiki("1/6_(vocaloid)", "Song"))
                "/tag-and-wiki/name/%252E%252E" -> json(chain, 200, tagAndWiki("..", null))
                else -> json(chain, 404, """{"success":false,"code":"snackbar__server-error_not-found"}""")
            }
        }.build()
        val api = SankakuApi(client, "test")
        val alias = api.tagWiki("miku_hatsune")!!
        assertEquals("hatsune_miku", alias["name"])
        assertEquals("miku_hatsune", alias["alias"])
        assertEquals("Article", alias["body"])
        assertNull(alias["aliasOf"])
        assertEquals("Song", api.tagWiki("1/6_(vocaloid)")!!["body"])
        assertEquals("..", api.tagWiki("..")!!["name"])
        assertNull(api.tagWiki("no_such_tag"))
        assertNull(api.tagWiki("  "))
        assertEquals(5, paths.size)
    }

    @Test fun tagWikiKeepsAnAliasWhoseTargetIsMissing() {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().url.encodedPath.endsWith("/old_name")) {
                json(chain, 200, tagAndWiki("old_name", null, aliasOf = "gone"))
            } else json(chain, 404, "{}")
        }.build()
        val wiki = SankakuApi(client, "test").tagWiki("old_name")!!
        assertEquals("old_name", wiki["name"])
        assertEquals("gone", wiki["aliasOf"])
    }

    @Test(expected = IOException::class) fun tagWikiServerFailuresStayErrors() {
        val client = OkHttpClient.Builder().addInterceptor { chain -> json(chain, 500, "{}") }.build()
        SankakuApi(client, "test").tagWiki("long_hair")
    }
}
