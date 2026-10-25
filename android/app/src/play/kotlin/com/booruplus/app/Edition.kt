package com.booruplus.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

/**
 * The Google Play edition. Native code serves only these boards (Dart's
 * `ContentPolicy.play` lists the same ones, free and Premium), Konachan
 * only through konachan.net, no optional sign-in, and no updater. Also
 * registers the native ad layouts Dart's ads ask for by factory ID.
 */
internal object Edition {
    const val PLAY = true

    val boards: Set<String>? = setOf(
        "safebooru", "danbooru", "konachan", "e926", "sankaku", "idolcomplex",
        "sakugabooru", "yandere", "gelbooru", "mspabooru", "eshuushuu", "derpibooru",
    )

    fun attach(context: Context, engine: FlutterEngine) {
        GoogleMobileAdsPlugin.registerNativeAdFactory(engine, NativeAds.TILE, NativeAds.TileFactory(context))
        GoogleMobileAdsPlugin.registerNativeAdFactory(engine, NativeAds.PAGE, NativeAds.PageFactory(context))
    }

    fun detach(engine: FlutterEngine) {
        GoogleMobileAdsPlugin.unregisterNativeAdFactory(engine, NativeAds.TILE)
        GoogleMobileAdsPlugin.unregisterNativeAdFactory(engine, NativeAds.PAGE)
    }
}
