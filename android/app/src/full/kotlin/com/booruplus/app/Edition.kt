package com.booruplus.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

/**
 * The Full edition: every website, the GitHub updater, no ads. The Play
 * flavor has its own `Edition` (src/play) with the same members.
 */
internal object Edition {
    const val PLAY = false

    /** Boards native code serves; null serves every board. */
    val boards: Set<String>? = null

    fun attach(context: Context, engine: FlutterEngine) {}

    fun detach(engine: FlutterEngine) {}
}
