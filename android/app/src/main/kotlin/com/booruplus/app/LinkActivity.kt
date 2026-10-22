package com.booruplus.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Receives website links opened with BooruPlus (`VIEW`) and text shared to
 * it (`SEND`), and hands the text to [MainActivity] in the app's own task,
 * so a share never starts a second copy of the app inside the sharing app's
 * task. It shows nothing and finishes at once. Dart reads the website and
 * post from the text and trusts nothing else about it.
 */
class LinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = runCatching {
            when (intent?.action) {
                Intent.ACTION_VIEW -> intent.dataString
                Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
                else -> null
            }
        }.getOrNull()?.trim()?.take(MainActivity.MAX_LINK_TEXT)
        if (!text.isNullOrEmpty()) {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
                    .putExtra(MainActivity.LINK_TEXT, text)
            )
        }
        finish()
    }
}
