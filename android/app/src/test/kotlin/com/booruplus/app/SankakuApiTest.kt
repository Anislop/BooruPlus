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
}
