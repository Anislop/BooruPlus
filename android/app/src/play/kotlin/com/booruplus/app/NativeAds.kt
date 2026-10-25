package com.booruplus.app

import android.content.Context
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.google.android.gms.ads.nativead.MediaView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.NativeAdFactory

/**
 * Native ad layouts for the Play edition, built in code so they match the
 * app: [TileFactory] fills one feed grid tile (media, headline, an "Ad"
 * badge, rounded like a post tile), and [PageFactory] fills a booruShorts
 * page (media, then icon, headline, body, and the call to action). The ad
 * SDK draws its AdChoices mark in a corner of each.
 */
internal object NativeAds {
    const val TILE = "booruplusTile"
    const val PAGE = "booruplusPage"

    private const val ACCENT = 0xFFF20B3D.toInt()
    private const val TILE_SURFACE = 0xFF1A1A1F.toInt()

    private fun Context.dp(value: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics).toInt()

    private fun Context.badge(text: String): TextView = TextView(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
        typeface = Typeface.DEFAULT_BOLD
        setPadding(dp(6f), dp(2f), dp(6f), dp(2f))
        background = GradientDrawable().apply {
            setColor(ACCENT)
            cornerRadius = dp(5f).toFloat()
        }
    }

    private fun rounded(view: View, radius: Float) {
        view.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, radius)
            }
        }
        view.clipToOutline = true
    }

    /** One grid tile, the size of the post tiles around it. */
    class TileFactory(private val context: Context) : NativeAdFactory {
        override fun createNativeAd(nativeAd: NativeAd, customOptions: MutableMap<String, Any>?): NativeAdView =
            with(context) {
                val view = NativeAdView(this)
                val frame = FrameLayout(this).apply { setBackgroundColor(TILE_SURFACE) }
                val media = MediaView(this).apply { setImageScaleType(ImageView.ScaleType.CENTER_CROP) }
                frame.addView(media, FrameLayout.LayoutParams(MATCH, MATCH))
                val headline = TextView(this).apply {
                    text = nativeAd.headline
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                    typeface = Typeface.DEFAULT_BOLD
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                    setPadding(dp(8f), dp(14f), dp(8f), dp(7f))
                    background = GradientDrawable(
                        GradientDrawable.Orientation.BOTTOM_TOP,
                        intArrayOf(0xCC000000.toInt(), 0x00000000),
                    )
                }
                frame.addView(headline, FrameLayout.LayoutParams(MATCH, WRAP, Gravity.BOTTOM))
                frame.addView(
                    badge("Ad"),
                    FrameLayout.LayoutParams(WRAP, WRAP, Gravity.TOP or Gravity.START).apply {
                        setMargins(dp(6f), dp(6f), 0, 0)
                    },
                )
                view.addView(frame, FrameLayout.LayoutParams(MATCH, MATCH))
                view.mediaView = media
                view.headlineView = headline
                rounded(view, dp(12f).toFloat())
                view.setNativeAd(nativeAd)
                view
            }
    }

    /** A full booruShorts page. */
    class PageFactory(private val context: Context) : NativeAdFactory {
        override fun createNativeAd(nativeAd: NativeAd, customOptions: MutableMap<String, Any>?): NativeAdView =
            with(context) {
                val view = NativeAdView(this).apply { setBackgroundColor(Color.BLACK) }
                val column = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    // Clear of the Shorts top bar and the gesture area.
                    setPadding(dp(16f), dp(72f), dp(16f), dp(40f))
                }
                column.addView(
                    badge("Sponsored"),
                    LinearLayout.LayoutParams(WRAP, WRAP).apply { bottomMargin = dp(12f) },
                )
                val media = MediaView(this).apply { setImageScaleType(ImageView.ScaleType.FIT_CENTER) }
                column.addView(media, LinearLayout.LayoutParams(MATCH, 0, 1f))
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }
                val icon = ImageView(this).apply {
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    nativeAd.icon?.drawable?.let(::setImageDrawable) ?: run { visibility = View.GONE }
                }
                rounded(icon, dp(10f).toFloat())
                row.addView(icon, LinearLayout.LayoutParams(dp(44f), dp(44f)).apply { marginEnd = dp(12f) })
                val texts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
                val headline = TextView(this).apply {
                    text = nativeAd.headline
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                    typeface = Typeface.DEFAULT_BOLD
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                }
                texts.addView(headline)
                val advertiser = TextView(this).apply {
                    text = nativeAd.advertiser
                    setTextColor(0x8AFFFFFF.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    maxLines = 1
                    if (nativeAd.advertiser.isNullOrBlank()) visibility = View.GONE
                }
                texts.addView(advertiser)
                row.addView(texts, LinearLayout.LayoutParams(0, WRAP, 1f))
                column.addView(row, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(16f) })
                val body = TextView(this).apply {
                    text = nativeAd.body
                    setTextColor(0xDEFFFFFF.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    maxLines = 3
                    ellipsize = TextUtils.TruncateAt.END
                    if (nativeAd.body.isNullOrBlank()) visibility = View.GONE
                }
                column.addView(body, LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(8f) })
                val action = Button(this).apply {
                    text = nativeAd.callToAction ?: "Learn more"
                    isAllCaps = false
                    setTextColor(Color.WHITE)
                    typeface = Typeface.DEFAULT_BOLD
                    background = GradientDrawable().apply {
                        setColor(ACCENT)
                        cornerRadius = dp(16f).toFloat()
                    }
                }
                column.addView(action, LinearLayout.LayoutParams(MATCH, dp(48f)).apply { topMargin = dp(16f) })
                view.addView(column, FrameLayout.LayoutParams(MATCH, MATCH))
                view.mediaView = media
                view.headlineView = headline
                view.iconView = icon
                view.advertiserView = advertiser
                view.bodyView = body
                view.callToActionView = action
                view.setNativeAd(nativeAd)
                view
            }
    }

    private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
}
