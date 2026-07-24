# Android native API

The Android implementation exposes a Flutter method channel named `booruplus/platform`.

The bridge uses the exact Apache-2.0 licensed upstream `imageboard-api` 3.0.0 source, vendored as the local Gradle module `android/imageboard-api`. The upstream tag is `3.0.0` at commit `3ec69ae`; the published README advertises `io.github.kodehawa:imageboard-api:3.0.0`, but that coordinate is not present in Maven Central. The vendored module preserves the upstream `LICENSE` file and uses the upstream package names and implementation.

The vendored model classes include a small project patch, documented in their source comments, to expose provider fields omitted by the upstream common interface: Rule34 id, preview URL, source, and owner; e621/e926 id, uploader id, sources, preview URL, and the raw `sample` object (for video alternates). This keeps the upstream implementation intact while making the Flutter map metadata complete.

A later patch (each change commented `BooruPlus patch`) adds the fields behind parent/child links, pools, md5 lookups, and the data saver's sample images:

- `DanbooruImage`: `id` (Danbooru posts previously had no ID in the map), `md5`, `parent_id`.
- `GelbooruImage`: `md5` (falling back to `hash`), `parent_id`, `sample_url`.
- `Rule34Image`: `hash` (as `getMd5`), `parent_id`, `sample_url`.
- `SafebooruImage`: `hash`, `parent_id`, and `sample`; `getSample_url` builds the `samples/{dir}/sample_{name}.jpg` URL when the post has one.
- `KonachanImage`: `md5`, `parent_id`. `YandereImage`: getters for its existing `md5` and `parent_id`.
- `FurryImage`/`SafeFurryImage` (e621/e926): `file.md5`, `relationships.parent_id`/`has_active_children`, `pools`, and the sample URL (`SafeFurryImage` gained the `sample` map).

Jackson only binds private fields that have a getter or `@JsonProperty`, and unknown properties are ignored, so posts from older responses still parse. `MainActivity.mapImage` reads the new getters reflectively and omits a sample equal to the original or the preview.

## `fetch`

Arguments are `board`, `tags` (`List<String>`), `limit`, `page`, `random`, and optional `apiKey` and `userId`. `page` is zero based. Limits up to 200 are supported; the bridge fetches successive provider pages in batches of at most 100 and combines them before applying random ordering. Supported board ids are `rule34`, `e621`, `konachan`, `yandere`, `danbooru`, `safebooru`, `gelbooru`, and `e926`.

The result is a list of maps with `id`, `url`, `previewUrl`, `tags`, `rating`, `uploader`, `source`, `width`, `height`, `score`, `description`, and `videoVariants`. Rule34 and Gelbooru credentials are supplied only to the library call and are never logged.

`videoVariants` lists alternate video streams as maps with `label`, `url`, `width`, `height`, and `quality`. `quality` is the resolution tier, such as 720 for "720p". e621 names tiers by the short side, so a portrait 720p sample can be 1440 pixels tall. Only e621/e926 supply alternates. They are read from `sample.alternates` in either the current `{original, variants, samples}` layout or the legacy `{"480p": {urls: [...]}}` layout, with MP4 preferred and the original file excluded. Other boards return an empty list. Danbooru ugoira posts, whose originals are ZIP frame archives, report their WebM sample as `url` so they play as video.

## `pickDownloadDirectory`

Launches Android's Storage Access Framework and returns a persisted tree URI string, or `null` when cancelled. Pass that URI back as `directory` to `download`.

## `download`

Arguments are `url`, `name`, and nullable `directory`. Only HTTPS URLs without embedded user information are accepted, including every HTTPS redirect hop. Downloads are streamed on a native executor. A selected tree uses SAF; the tree URI is converted to its document URI before creation. When no directory is selected, Android 10 and newer use the public Downloads MediaStore collection under `Download/BooruPlus`; Android 9 and older require a selected directory. Partial MediaStore entries and files are deleted if streaming fails. The result is the saved URI string.

The Android application id and namespace are `com.booruplus.app`. The minimum SDK is 26 because Jackson 3.1.3, required by the exact upstream 3.0.0 implementation, contains `MethodHandle.invoke*` instructions that Android D8 cannot lower below API 26. Android backup is disabled because credentials are handled by the Flutter secure-storage layer.
