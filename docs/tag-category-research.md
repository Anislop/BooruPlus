# Tag-category capability probe

**Probe date:** 2026-09-14  
**Scope:** BooruPlus source plus current provider documentation/source  
**Status:** Research and planning only; no application implementation was performed.

## Executive answer

Yes. A tag can be differentiated by category when the selected booru exposes tag metadata. Typical categories are `general`, `artist`, `copyright`, and `character`; e621/e926 add categories such as `species`, `meta`, and `lore`.

The category is provider-owned metadata. It should not be guessed from the tag's spelling. For example, a creator name is only an `artist` tag if that board has classified it as one. The same text can be `general` on one board and `artist` on another, and a tag can be ambiguous.

There is also an important distinction between an artist tag and the uploader/owner field on a post:

- An `artist` tag identifies the credited creator according to the board's tagging system.
- `uploader`, `owner`, or similar post metadata identifies the account that uploaded the post.
- Those values can be different and should remain separate in the app model.

The practical recommendation is to add a provider-aware typed-tag layer with an `unknown` fallback. Category support is strong for e621/e926 and Danbooru, and achievable for the remaining boards through tag metadata lookups. A universal, offline classification of every flattened tag is not reliable.

## What the current app does

The current data path loses category information at the native-to-Flutter boundary:

1. The shared Java `BoardImage` interface exposes only `getTags()`, which returns a flattened `List<String>`.
2. `MainActivity.mapImage()` sends only the flattened `tags` list in the `fetch` result.
3. `MediaPost` stores only `final List<String> tags` and accepts either a list or a whitespace-delimited string.
4. The Flutter repository has a `fetch` method but no autocomplete or tag-metadata method.

Relevant source anchors:

- [`MainActivity.mapImage`](../android/app/src/main/kotlin/com/booruplus/app/MainActivity.kt#L185-L198)
- [`MediaPost`](../lib/core/models.dart#L53-L109)
- [`PlatformBoardRepository.fetch`](../lib/core/services.dart#L31-L55)
- [`BoardImage`](../android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/entities/BoardImage.java)

The vendored library does contain more information than the common interface suggests:

- Its `ImageBoard.autocomplete()` API already exists, but it is not connected to Flutter.
- Danbooru, e621/e926, and Gelbooru autocomplete POJOs contain category/type fields.
- e621/e926 post models contain separate tag arrays internally.
- The Danbooru model currently retains artist and character strings, but not every categorized tag string.

Relevant library anchors:

- [`ImageBoard.autocomplete`](../android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/ImageBoard.java#L381-L427)
- [`FurryImage.Tags`](../android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/entities/impl/FurryImage.java#L48-L145)
- [`SafeFurryImage.Tags`](../android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/entities/impl/SafeFurryImage.java#L29-L143)
- [`DanbooruImage`](../android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/entities/impl/DanbooruImage.java#L42-L162)
- [`DefaultBoards`](../android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/boards/DefaultBoards.java#L35-L69)

## Provider-by-provider findings

| Provider | Category data available? | What the current integration preserves | Planning consequence |
| --- | --- | --- | --- |
| **Danbooru** | Yes. The tag API returns a numeric category: `0` general, `1` artist, `3` copyright, `4` character, `5` meta. Autocomplete also returns a category. | The autocomplete POJO has `category`; the post model retains only some category-specific fields and `getTags()` still flattens them. | Add complete categorized post mapping or use the tag API for enrichment. Keep Danbooru's numeric mapping local to Danbooru. |
| **e621 / e926** | Yes. Post responses group tags into arrays such as `general`, `artist`, `copyright`, `character`, `species`, `meta`, and `lore`. Tag and autocomplete records also carry category IDs. | The `FurryImage` and `SafeFurryImage` models already deserialize the grouped arrays, but `getTags()` collapses them. | This is the easiest first implementation: map the existing grouped arrays before flattening. e621 category IDs differ from Danbooru's and must not share a numeric table. |
| **Gelbooru** | Yes, primarily `artist`, `character`, and `copyright`; untyped tags are generally treated as general. The autocomplete DTO has a category string. The tag API also supports tag records. | Post tags are a single raw string; autocomplete is not exposed to Flutter. | Use autocomplete/tag metadata when available, normalize string or numeric type values, and fall back to `unknown` if the endpoint omits data. |
| **Rule34** | Yes. The site documents the same three explicit types (`artist`, `character`, `copyright`) and its tag API/autocomplete exposes type information. | Post tags are a single raw string; the autocomplete DTO has `type` but is not wired into the app. | Use the authenticated tag endpoint or autocomplete adapter. Do not assume every raw post tag can be classified without a lookup. |
| **Safebooru** | Yes. The site has typed tags and its tag list displays `general`, `artist`, `character`, and `copyright`. | The post model is raw-string-only. The current Safebooru autocomplete DTO has no category/type field. | Add a tag-record lookup or extend the provider DTO. Category is available from the site, but not from the current autocomplete object. |
| **Konachan** | Yes. Its Moebooru-compatible tag API documents `general: 0`, `artist: 1`, `copyright: 3`, and `character: 4`. | The post model is raw-string-only and the vendored board configuration has no autocomplete endpoint. | Add a provider-specific tag lookup. Treat the tag API as authoritative instead of inferring from names or tag colors. |
| **Yande.re** | Likely yes through the same Moebooru tag API family; its API v2 is also documented by third-party API references as able to include tag types. | The post model is raw-string-only and the current board configuration has no autocomplete endpoint. | Verify the live response shape during implementation and keep an `unknown` fallback because the site/API has historically changed availability. |

### Why numeric categories cannot be shared blindly

Danbooru uses `5` for `meta`. Current e621 source uses a different extended mapping in which `5` is `species`, `7` is `meta`, and `8` is `lore` (with `contributor` and `invalid` also represented). The normalized app model should use semantic names, not provider numeric IDs.

## What can be supported at each layer

### Post details

There are two cases:

1. **Structured post response:** e621/e926 already provide category arrays, and Danbooru's API exposes category-specific tag fields. The native bridge can map these directly without additional requests.
2. **Flattened post response:** Gelbooru, Rule34, Safebooru, Konachan, and the current Yande.re model provide a space-delimited tag string to this library. The app must resolve those names against the board's tag endpoint, preferably in a batch and with caching.

The second case means the UI may need to show the raw tags immediately and enrich them asynchronously. Offline, rate-limited, deleted, or ambiguous tags should remain `unknown`, not be force-classified.

### Search/autocomplete

Category-aware autocomplete is also possible, but the current app has no channel for it. The vendored library's generic `IAutoComplete` interface exposes only `getTagName()`, even when a concrete DTO contains `category` or `type`. A future bridge should return a normalized suggestion record such as:

```text
name, category, postCount, ambiguous, provider
```

The search bar should use the category only as display/filter metadata. The submitted search token should remain the provider's actual tag name and query syntax.

### Category prefixes are not a substitute for metadata

Queries such as `artist:some_name` or `character:some_name` are useful provider search syntax, but they do not prove that a bare returned tag belongs to that category. Prefixes should be treated as query operators; category fields from tag records remain the source of truth.

## Recommended future model

Preserve the existing flattened `tags` field for compatibility, and add typed information alongside it rather than replacing it immediately.

Suggested semantic categories:

```text
general
artist
copyright
character
species
meta
lore
contributor
invalid
unknown
```

Suggested record shape:

```text
TagInfo {
  name: String
  category: TagCategory
  postCount: optional integer
  ambiguous: optional boolean
  provider: Board
}
```

`MediaPost` can then expose either `typedTags: List<TagInfo>` or grouped lists derived from that list. A list of records is preferable as the canonical form because it preserves provider metadata and permits future fields such as aliases, deprecation, or wiki availability.

## Recommended implementation sequence

### Phase 0: response fixtures and compatibility checks

- Capture representative JSON/XML for all eight boards, including one post with artist/character/copyright/general tags where possible.
- Capture autocomplete/tag-record responses for each board.
- Include authenticated fixtures for Rule34 and Gelbooru because the app already requires credentials for them.
- Confirm Yande.re's currently reachable tag and API-v2 response shape at implementation time.

### Phase 1: preserve category data in the native bridge

- Map e621/e926 grouped arrays directly from the existing model objects.
- Extend the Danbooru model mapping to include all categorized tag fields that the live API returns.
- Add a native normalized representation, for example `tagDetails` or `tagGroups`, while continuing to return `tags`.
- Keep uploader/owner/source metadata separate from tag categories.

### Phase 2: provider adapters for flattened posts

- Implement per-board category mappings and endpoint builders.
- Batch tag lookups where the provider permits it; avoid one network request per visible tag.
- Cache by `board + normalizedTag`, with a bounded size and a reasonable expiration time.
- Add negative caching for missing tags and preserve `unknown` for incomplete responses.

### Phase 3: category-aware autocomplete

- Add a debounced Flutter repository method and a native method-channel operation.
- Prefer the provider's autocomplete response when it includes type/category.
- Fall back to tag metadata lookup only when necessary.
- Respect provider rate limits, authentication, and failures without breaking ordinary text entry.

### Phase 4: UI presentation

- Group post tags into sections such as Artists, Characters, Copyrights, and General.
- Use a neutral style for `unknown` and provider-specific categories that do not map cleanly.
- Preserve the current tap-to-search behavior.
- Consider category badges in autocomplete and an optional category filter, but do not make category display required for search.

### Phase 5: tests and regression coverage

- Use stored provider fixtures; do not make widget tests depend on live booru availability.
- Test each provider's numeric/string mapping independently.
- Test null, missing, malformed, ambiguous, and duplicate tag records.
- Test that an artist tag is not confused with the uploader.
- Test offline/lookup-failure behavior and ensure raw tags still display.

## Risks and decisions to keep explicit

- **Provider drift:** endpoints and response shapes can change, especially for older Moebooru/Gelbooru-compatible sites.
- **Different taxonomies:** category IDs are provider-specific; only normalized semantic names should cross the Flutter boundary.
- **Ambiguity:** ambiguous is a separate property, not a category.
- **Staleness:** tag categories and counts can change; cache metadata must not be treated as permanent truth.
- **Latency:** enriching flattened post tags adds requests unless batched/cached.
- **Privacy/security:** authenticated tag requests must follow the existing credential-handling rules and never expose API keys in logs.
- **Offline support:** category data may be unavailable even when the post itself was already fetched; `unknown` is an expected state.

## Bottom line

The feature is feasible and worth planning. The cleanest initial slice is e621/e926 because the current native models already contain grouped tag arrays. Danbooru is next, with a small native model/mapping expansion. The other boards can be supported through provider-specific tag metadata lookups, but they need caching, rate-limit handling, and an explicit `unknown` state.

No Luna subagent was needed for this bounded probe. No application code or tests were edited; this note is the only new artifact.

## Sources

Provider documentation and source reviewed:

- [Danbooru tag API reference](https://danbooru.donmai.us/wiki_pages/api:tags)
- [Danbooru API help](https://danbooru.donmai.us/wiki_pages/help:api)
- [Danbooru tag model](https://github.com/danbooru/danbooru/blob/master/app/models/tag.rb)
- [e621 tag category source](https://github.com/e621ng/e621ng/blob/master/app/logical/tag_category.rb)
- [e621 tag model](https://github.com/e621ng/e621ng/blob/master/app/models/tag.rb)
- [e621 API reference](https://e621.net/help/api)
- [Gelbooru API basics](https://gelbooru.com/index.php?id=18780&page=wiki&s=view)
- [Gelbooru tag types](https://gelbooru.com/index.php?page=help&topic=post)
- [Rule34 API basics](https://rule34.xxx/?page=help&topic=dapi)
- [Rule34 tag types](https://rule34.xxx/index.php?page=help&topic=post)
- [Safebooru tag types](https://safebooru.org/index.php?page=help&topic=post)
- [Safebooru tag list](https://safebooru.org/index.php?page=tags&s=list)
- [Konachan tag help](https://konachan.com/help/tags)
- [Konachan/Moebooru API reference](https://konachan.com/help/api)

