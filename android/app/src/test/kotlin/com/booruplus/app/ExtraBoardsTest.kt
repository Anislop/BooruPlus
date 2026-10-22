package com.booruplus.app

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ExtraBoardsTest {
    private fun client(body: (okhttp3.Request) -> String, requested: MutableList<okhttp3.HttpUrl>) =
        OkHttpClient.Builder().addInterceptor { chain ->
            requested.add(chain.request().url)
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK")
                .body(body(chain.request()).toResponseBody("text/html".toMediaType()))
                .build()
        }.build()

    @Test fun danbooruRatingLettersAreItsScaleNotMoebooru() {
        assertEquals("general", danbooruRating("g"))
        assertEquals("sensitive", danbooruRating("s"))
        assertEquals("sensitive", danbooruRating("Sensitive"))
        assertEquals("questionable", danbooruRating("q"))
        assertEquals("explicit", danbooruRating("e"))
        assertEquals("Unknown", danbooruRating(null))
        assertEquals("Unknown", danbooruRating("safe"))
    }

    @Test fun danbooruSensitiveSurvivesTheLibraryRating() {
        // RatingDeserializer looks letters up by short name first, reading
        // Danbooru's `s` as SAFE; the short name keeps the letter.
        fun rated(letter: String) =
            net.kodehawa.lib.imageboards.entities.Rating.lookupFromStringShort(letter)?.getShortName()
        assertEquals("sensitive", danbooruRating(rated("s")))
        assertEquals("general", danbooruRating(rated("g")))
        assertEquals("explicit", danbooruRating(rated("e")))
    }

    @Test fun derpibooruQueriesUseTagNamesAndPhilomenaFields() {
        assertEquals(
            "twilight sparkle,-ai generated,artist:some artist,score.gte:100,created_at.gte:2024-01-01," +
                "mime_type:video/*,(suggestive || questionable),faves.lt:5",
            DerpibooruApi.query(listOf(
                "twilight_sparkle", "-ai_generated", "artist:some_artist", "score:>=100",
                "created_at:>=2024-01-01", "mime_type:video/*", "rating:questionable", "order:score", "faves.lt:5",
            )),
        )
        assertEquals("" , DerpibooruApi.query(listOf("order:random")))
    }

    @Test fun derpibooruOrderTagsBecomeSortParameters() {
        assertEquals("id" to "desc", DerpibooruApi.sort(listOf("pony"), false, 1))
        assertEquals("random:4294967295" to "desc", DerpibooruApi.sort(emptyList(), true, -1))
        assertEquals("id" to "asc", DerpibooruApi.sort(listOf("order:id_asc"), false, 1))
        assertEquals("faves" to "desc", DerpibooruApi.sort(listOf("order:favcount"), false, 1))
        assertEquals("pixels" to "desc", DerpibooruApi.sort(listOf("order:mpixels"), false, 1))
        assertEquals("score" to "asc", DerpibooruApi.sort(listOf("order:score_asc"), false, 1))
        assertEquals("id" to "desc", DerpibooruApi.sort(listOf("order:unknown"), false, 1))
    }

    @Test fun derpibooruSearchesTheEverythingFilterAndMapsImages() {
        val requested = mutableListOf<okhttp3.HttpUrl>()
        val image = JSONObject()
            .put("id", 42).put("mime_type", "video/webm").put("width", 640).put("height", 360)
            .put("score", 12).put("uploader", JSONObject.NULL).put("source_url", "https://example.com/a")
            .put("description", "").put("tags", JSONArray(listOf("safe", "artist:a b", "oc:pony", "solo")))
            .put("representations", JSONObject()
                .put("full", "https://derpicdn.net/img/view/2024/1/2/42.webm")
                .put("thumb", "https://derpicdn.net/img/2024/1/2/42/thumb.webm")
                .put("large", "https://derpicdn.net/img/2024/1/2/42/large.webm"))
        val hidden = JSONObject().put("id", 43).put("hidden_from_users", true)
        val api = DerpibooruApi(client({ JSONObject().put("images", JSONArray(listOf(image, hidden))).toString() }, requested), "test")
        val posts = api.fetch(listOf("solo", "order:score"), 1, 120, false, 0) { false }
        val url = requested.single()
        assertEquals("solo", url.queryParameter("q"))
        assertEquals("56027", url.queryParameter("filter_id"))
        assertEquals("50", url.queryParameter("per_page"))
        assertEquals("2", url.queryParameter("page"))
        assertEquals("score", url.queryParameter("sf"))
        val post = posts.single()
        assertEquals("42", post["id"])
        assertEquals("https://derpicdn.net/img/view/2024/1/2/42.mp4", post["url"])
        assertEquals("https://derpicdn.net/img/2024/1/2/42/thumb.gif", post["previewUrl"])
        assertEquals("", post["sampleUrl"])
        assertEquals("", post["uploader"])
        assertEquals("safe", post["rating"])
        assertEquals(listOf("safe", "artist:a_b", "oc:pony", "solo"), post["tags"])
        assertEquals(
            listOf("meta", "artist", "character", "general"),
            (post["tagDetails"] as List<*>).map { (it as Map<*, *>)["category"] },
        )
        assertTrue(api.fetch(listOf("md5:0123"), 0, 10, false, 0) { false }.isEmpty())
        assertEquals(1, requested.size)
    }

    private val listPage = """
        <div class="items">
          <div class="col thumb"><a id="p101" href="index.php?page=post&amp;s=view&amp;id=101">
            <img src="//realbooru.com/thumbnails/ab/cd/thumbnail_0123456789abcdef0123456789abcdef.jpg"
                 title="blonde outdoors score:5 rating:explicit" alt="" /></a></div>
          <div class="col thumb"><a id="p102" href="index.php?page=post&amp;s=view&amp;id=102">
            <img data-src="https://realbooru.com/thumbnails/ef/01/thumbnail_fedcba9876543210fedcba9876543210.jpg"
                 src="data:image/gif;base64,R0lGOD" title="long hair, tom &amp; jerry, video" /></a></div>
          <a id="p101" href="#"><img src="https://realbooru.com/x.jpg" /></a>
        </div>
    """.trimIndent()

    @Test fun realbooruListPagesGiveThumbnailsAndTags() {
        val posts = RealbooruApi.parseList(listPage)
        assertEquals(listOf("101", "102"), posts.map { it["id"] })
        val first = posts[0]
        val thumb = "https://realbooru.com/thumbnails/ab/cd/thumbnail_0123456789abcdef0123456789abcdef.jpg"
        assertEquals(thumb, first["url"])
        assertEquals(thumb, first["previewUrl"])
        assertEquals(listOf("blonde", "outdoors"), first["tags"])
        assertEquals("explicit", first["rating"])
        assertEquals(5, first["score"])
        assertEquals("0123456789abcdef0123456789abcdef", first["md5"])
        val second = posts[1]
        assertEquals("https://realbooru.com/thumbnails/ef/01/thumbnail_fedcba9876543210fedcba9876543210.jpg", second["previewUrl"])
        assertEquals(listOf("long_hair", "tom_&_jerry", "video"), second["tags"])
    }

    @Test fun realbooruPostPagesGiveTheFileAndTypedTags() {
        val page = """
            <div id="tagLink"><ul>
              <li class="tag-type-copyright"><a href="wiki">?</a> <a href="index.php?page=post&amp;s=list&amp;tags=studio">studio</a> 12</li>
              <li class="tag-type-general"><a href="wiki">?</a> <a href="list">long hair</a> 300</li>
              <li><a class="model" href="list">jane doe</a></li>
              <li><a class="metadata" href="list">video</a></li>
            </ul>Rating: Explicit Posted by <a href="index.php?page=account&amp;s=profile&amp;id=9">uploader1</a></div>
            <span id="psc5">17</span>
            <input type="text" name="source" value="https://example.com/src" />
            <div class="imageContainer">
              <video id="gelcomVideoPlayer" width="1280" height="720" poster="//realbooru.com/thumbnails/12/34/thumbnail_00112233445566778899aabbccddeeff.jpg">
                <source src="https://video-cdn.realbooru.com/images/12/34/00112233445566778899aabbccddeeff.mp4" type="video/mp4">
              </video>
            </div>
        """.trimIndent()
        val post = RealbooruApi.parsePost(5, page)!!
        assertEquals("https://video-cdn.realbooru.com/images/12/34/00112233445566778899aabbccddeeff.mp4", post["url"])
        assertEquals("https://realbooru.com/thumbnails/12/34/thumbnail_00112233445566778899aabbccddeeff.jpg", post["previewUrl"])
        assertEquals(true, post["isVideo"])
        assertEquals(1280, post["width"])
        assertEquals(720, post["height"])
        assertEquals(17, post["score"])
        assertEquals("uploader1", post["uploader"])
        assertEquals("https://example.com/src", post["source"])
        assertEquals("explicit", post["rating"])
        assertEquals("00112233445566778899aabbccddeeff", post["md5"])
        assertEquals(
            listOf("studio" to "copyright", "long_hair" to "general", "jane_doe" to "artist", "video" to "meta"),
            (post["tagDetails"] as List<*>).map { (it as Map<*, *>).let { tag -> tag["name"] to tag["category"] } },
        )

        val image = RealbooruApi.parsePost(6, """<img alt="x" id="image" src="https://realbooru.com/images/aa/bb/aabbccddeeff00112233445566778899.jpeg" width="800" height="600">""")!!
        assertEquals("https://realbooru.com/images/aa/bb/aabbccddeeff00112233445566778899.jpeg", image["url"])
        assertEquals("https://realbooru.com/thumbnails/aa/bb/thumbnail_aabbccddeeff00112233445566778899.jpg", image["previewUrl"])
        assertEquals(false, image["isVideo"])
        assertNull(RealbooruApi.parsePost(7, "<html><body>Not found</body></html>"))
    }

    @Test fun realbooruIdLookupsReadPostPagesAndListsPageByFortyTwo() {
        val requested = mutableListOf<okhttp3.HttpUrl>()
        val api = RealbooruApi(client({ request ->
            if (request.url.queryParameter("s") == "view") {
                """<img id="image" src="https://realbooru.com/images/aa/bb/aabbccddeeff00112233445566778899.jpg">"""
            } else listPage
        }, requested), "test")
        val found = api.fetch(listOf("id:5,6", "-blocked"), 0, RealbooruApi.PAGE_SIZE, false, 0) { false }
        assertEquals(listOf("5", "6"), found.map { it["id"] })
        assertEquals(listOf("5", "6"), requested.map { it.queryParameter("id") })
        requested.clear()
        assertEquals(2, api.fetch(listOf("blonde", "-solo"), 2, RealbooruApi.PAGE_SIZE, false, 0) { false }.size)
        assertEquals("blonde -solo", requested.single().queryParameter("tags"))
        assertEquals("84", requested.single().queryParameter("pid"))
        requested.clear()
        api.fetch(emptyList(), 0, RealbooruApi.PAGE_SIZE, false, 0) { false }
        assertEquals("all", requested.single().queryParameter("tags"))
    }
}
