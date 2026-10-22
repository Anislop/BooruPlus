package com.booruplus.app

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * The website answered that its API is switched off (as Realbooru's DAPI
 * did), rather than failing the request. Reported to Dart as `API_OFF`.
 */
internal class ApiOffException : IOException("API switched off")

/** The [ApiOffException] behind [error], including library wrappers. */
internal fun apiOff(error: Throwable): ApiOffException? =
    generateSequence(error) { it.cause }.take(8).filterIsInstance<ApiOffException>().firstOrNull()

/**
 * Recognizes API requests a website refuses because its API is off: a
 * Gelbooru-style DAPI `success="false"` (XML or JSON) whose reason says the
 * API is off, and API error pages saying so. Other refusals (sign-in, bad
 * queries, pages too deep, no reason at all) pass through untouched.
 */
internal class ApiOffInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (request.method != "GET") return response
        val url = request.url
        val dapi = url.queryParameter("page") == "dapi"
        val api = dapi || url.encodedPath.contains("/api/") || url.encodedPath.endsWith(".json")
        if (!api) return response
        if (dapi && response.isSuccessful) {
            val body = response.peekBody(MAX_PEEK_BYTES).string()
            if (!DAPI_REFUSED.containsMatchIn(body)) return response
            if (!OFF_REASON.containsMatchIn(body) || AUTH_REASON.containsMatchIn(body)) return response
            response.close()
            throw ApiOffException()
        }
        if (response.code in OFF_CODES) {
            val body = response.peekBody(MAX_PEEK_BYTES).string()
            if (API_DISABLED.containsMatchIn(body)) {
                response.close()
                throw ApiOffException()
            }
        }
        return response
    }

    internal companion object {
        const val MAX_PEEK_BYTES = 16L * 1024
        val OFF_CODES = setOf(403, 404, 410, 501)
        // <response success="false" reason="..."/> or {"success": false, ...}.
        val DAPI_REFUSED = Regex("""success["']?\s*[=:]\s*["']?false\b""", RegexOption.IGNORE_CASE)
        val OFF_REASON = Regex("""\b(disabled|shut ?(off|down)|switched off|turned off|offline|unavailable|no longer available)\b""", RegexOption.IGNORE_CASE)
        val AUTH_REASON = Regex("""auth|api[_ ]?key|user[_ ]?id|login|credential""", RegexOption.IGNORE_CASE)
        val API_DISABLED = Regex("""\bapi\b[^<]{0,60}\b(disabled|shut ?off|switched off|turned off|offline)\b""", RegexOption.IGNORE_CASE)
    }
}
