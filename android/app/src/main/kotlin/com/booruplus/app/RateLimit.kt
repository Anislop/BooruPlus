package com.booruplus.app

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException

/**
 * A provider kept answering HTTP 429/503 after [RateLimitInterceptor]'s
 * bounded backoff. [retryAfterSeconds] is the provider's last Retry-After
 * value, when it sent one in seconds.
 */
internal class RateLimitedException(val retryAfterSeconds: Int?) : IOException("Rate limited")

/** The [RateLimitedException] behind [error], including library wrappers. */
internal fun rateLimit(error: Throwable): RateLimitedException? =
    generateSequence(error) { it.cause }.take(8).filterIsInstance<RateLimitedException>().firstOrNull()

/**
 * Retries GET requests refused with 429 (or a busy 503) after a short wait,
 * honoring Retry-After up to [MAX_WAIT_SECONDS], then reports a typed
 * [RateLimitedException] instead of a generic HTTP failure. Immediate
 * re-requests only extend a provider's throttle window, so the user's retry
 * would keep failing. Sankaku's tag-limit refusal also uses 429; it passes
 * through untouched so its typed error still reaches Dart.
 */
internal class RateLimitInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        var response = chain.proceed(request)
        if (request.method != "GET") return response
        var attempt = 0
        while (limited(response)) {
            val wait = retryAfter(response)
            response.close()
            if (attempt >= MAX_RETRIES || (wait != null && wait > MAX_WAIT_SECONDS)) {
                throw RateLimitedException(wait)
            }
            try {
                Thread.sleep((wait ?: (1 shl attempt)).coerceAtLeast(1) * 1000L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                throw InterruptedIOException("Cancelled")
            }
            if (chain.call().isCanceled()) throw IOException("Cancelled")
            attempt++
            response = chain.proceed(request)
        }
        return response
    }

    private fun limited(response: Response): Boolean = when (response.code) {
        429 -> !response.peekBody(MAX_PEEK_BYTES).string().contains("tags-limit")
        503 -> true
        else -> false
    }

    private fun retryAfter(response: Response): Int? =
        response.header("Retry-After")?.trim()?.toIntOrNull()?.coerceAtLeast(0)

    private companion object {
        const val MAX_RETRIES = 2
        const val MAX_WAIT_SECONDS = 5
        const val MAX_PEEK_BYTES = 16L * 1024
    }
}
