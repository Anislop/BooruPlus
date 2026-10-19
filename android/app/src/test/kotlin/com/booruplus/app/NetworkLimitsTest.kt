package com.booruplus.app

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.asResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class NetworkLimitsTest {
    private fun read(body: ResponseBody): String = OkHttpClient.Builder()
        .addInterceptor(ResponseLimitInterceptor(16))
        .addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK").body(body).build()
        }
        .build()
        .newCall(Request.Builder().url("https://example.com/").build())
        .execute().use { it.body.string() }

    private val json = "application/json".toMediaType()

    @Test fun responsesWithinTheLimitPassUnchanged() {
        assertEquals("[1,2,3]", read("[1,2,3]".toResponseBody(json)))
    }

    @Test fun oversizedResponsesFailWithOrWithoutALength() {
        assertThrows(IOException::class.java) { read("x".repeat(17).toResponseBody(json)) }
        // A chunked or compressed body announces no length; reading stops at the limit.
        val unsized = Buffer().writeUtf8("x".repeat(17)).asResponseBody(json, -1)
        assertThrows(IOException::class.java) { read(unsized) }
    }

    @Test fun onlyPublicHostsAreDownloadDestinations() {
        listOf(
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254",
            "100.64.0.1", "0.0.0.0", "240.0.0.1", "[::1]", "[fd00::1]", "[fe80::1]",
            "[::ffff:10.0.0.1]", "localhost", "media.localhost", "", null,
        ).forEach { assertFalse("$it", isPublicHost(it)) }
        listOf("93.184.216.34", "[2606:4700::1111]").forEach { assertTrue(it, isPublicHost(it)) }
    }
}
