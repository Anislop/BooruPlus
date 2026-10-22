package com.booruplus.app

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class ApiStatusTest {
    private fun fetch(url: String, code: Int, body: String): String = OkHttpClient.Builder()
        .addInterceptor(ApiOffInterceptor())
        .addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(code).message("status")
                .body(body.toResponseBody("text/xml".toMediaType())).build()
        }
        .build()
        .newCall(Request.Builder().url(url).build())
        .execute().use { it.body.string() }

    private val dapi = "https://realbooru.com/index.php?page=dapi&s=post&q=index"

    @Test fun aDapiRefusalSayingTheApiIsOffIsApiOff() {
        assertThrows(ApiOffException::class.java) {
            fetch(dapi, 200, """<?xml version="1.0"?><response success="false" reason="This API has been disabled."/>""")
        }
        assertThrows(ApiOffException::class.java) {
            fetch(dapi, 200, """{"success": false, "message": "The API is temporarily unavailable"}""")
        }
    }

    @Test fun otherRefusalsAndPostsPassThrough() {
        val auth = """<response success="false" reason="Missing authentication. Go to api.example for an api_key."/>"""
        assertEquals(auth, fetch(dapi, 200, auth))
        val bare = """<response success="false"/>"""
        assertEquals(bare, fetch(dapi, 200, bare))
        val deep = """<response success="false" reason="Too deep! Pull it back some."/>"""
        assertEquals(deep, fetch(dapi, 200, deep))
        val posts = """<posts count="0" offset="0"/>"""
        assertEquals(posts, fetch(dapi, 200, posts))
    }

    @Test fun apiErrorPagesSayingTheApiIsDisabledAreApiOff() {
        assertThrows(ApiOffException::class.java) {
            fetch("https://example.org/api/v1/json/search/images", 403, "<h1>The API is disabled for now</h1>")
        }
        val forbidden = "<h1>Forbidden</h1>"
        assertEquals(forbidden, fetch("https://example.org/posts.json", 403, forbidden))
        // Pages that are not API requests are never inspected.
        val page = "the API is disabled"
        assertEquals(page, fetch("https://example.org/index.php?page=post&s=list", 403, page))
    }
}
