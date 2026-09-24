# booruShorts

A full-screen, vertically swiped video feed across every usable website, in
the style of Instagram Reels and YouTube Shorts. Opened from the navigation
drawer (compact shortcut row and classic drawer list).

## Decisions

| Topic | Decision |
| --- | --- |
| Entry point | Navigation drawer item. |
| Multiple Shorts tags | Any tag (OR): each tag is its own stream per website, and streams are interleaved. This keeps every request within the website's tag budget. |
| Order | Random, with one seed per Shorts session (the same `random`/`randomSeed` fetch the discovery feed uses). |
| Websites | Every usable website by default (visible, and signed in where required) that hosts video; individual websites can be switched off in Settings. |

## Feed source

Each website gets its own video query, combined with at most one Shorts tag.
Checked live on 2026-10-18:

| Website | Video query | Notes |
| --- | --- | --- |
| Danbooru, AIBooru | `filetype:mp4,webm` | A metatag, so it does not count toward the anonymous two-tag limit (`filetype:mp4,webm 1girl -solo` is accepted). |
| e621, e926 | `~type:webm ~type:mp4` | e621 OR syntax. |
| Gelbooru, Rule34, Sankaku, Idol Complex, Nozomi | `video` | Sankaku returned only `video/*` files; Nozomi serves `nozomi/video.nozomi`. Gelbooru/Rule34 need credentials and were not probed. |
| Safebooru, TBIB | (excluded) | `video` and `webm` return only GIFs. |
| Konachan, Yande.re | (excluded) | Image-only websites. |

The video query goes through `AppState._queryTagsFor`, so rating syntax and
blocked-tag exclusions are added within each website's budget. The local
checks still run on every result: `MediaPost.isVideo`, the blacklist, no-AI,
ratings, hidden posts, and hidden uploaders.

`ShortsFeed` (in `app_state.dart`) is modeled on `MultiSiteSearch`: its own
generation, per-stream pages, end-of-results and errors, and it never sends
`feed: true`, so it cannot cancel the main feed. The same file found on two
websites (same MD5) appears once. Sankaku-family media URLs expire after
about an hour; Shorts passes posts through `AppState.displayReady` before
playing them.

## Player

- A vertical `PageView`, one video playing at a time, looping by default
  (or moving on when it ends with *Auto-advance*).
- Portrait videos fill the screen; landscape videos are letterboxed over a
  blurred copy of the preview.
- At most three controllers exist: the previous, the current, and the next
  (initialized and paused). Others are disposed. Each controller is checked
  against the page it was created for, so fast swiping cannot leave a stale
  video playing.
- Gelbooru and Nozomi need their Referer header; `videoHeaders` in
  `media_viewer.dart` is shared by the viewer and Shorts.
- Quality: the viewer's video quality setting, capped at 720p (and at 480p
  while the data saver applies), so the feed loads quickly. The original is
  used when a website offers no renditions.
- Shorts uses its own controls instead of Chewie. The app pauses Shorts when
  it goes to the background and keeps the screen awake while Shorts is open.
- Blurred ratings follow the blur settings: a blurred video shows its
  preview and a *Reveal* button.

## Gestures and controls

- Tap: pause or play, with a brief icon in the center.
- Double-tap: skip ahead 5 seconds (clamped to the end), with a `+5s` badge
  where the finger landed. Favorite from the rail.
- Long-press: 2x speed while held.
- Bottom scrub bar: a thin full-width progress bar whose played and buffered
  parts fill from the left edge. Touching it
  thickens it and shows `0:12 / 0:30`; dragging pauses and seeks, releasing
  resumes.
- Mute toggle in the top bar; the choice is remembered (`shortsMuted`).
- Gear button in the top bar: a sheet showing the tags Shorts searches
  (`shortsTags`), where tags can be added (with autocomplete) or removed
  without opening Settings. Changes are saved at once and restart the feed.
- Bottom-left: the website, artist tags, and up to three character or
  copyright tags. Tapping a tag filters Shorts to that tag (shown as a chip
  that clears the filter).

## Right rail (top to bottom)

1. Favorite: filled when saved; uses the existing favorites.
2. Details: a bottom sheet with rating, score, size, uploader, source,
   grouped tags (tap to filter Shorts), and *Open full details*, which opens
   the regular viewer on the post with its details panel open.
3. Website badge: the website's logo. Opens a sheet with *Open on website*,
   *Only this website* (this session), and *Hide this website from Shorts*.
4. Share, Download, and More (hide post, hide uploader).

## Settings: booruShorts

- Tags (chips with autocomplete). Without tags Shorts shows all videos.
- Websites: switches for the websites that host video.
- Start muted.
- Auto-advance at the end of a video (otherwise loop).

New `AppSettings` fields: `shortsTags`, `shortsOff`, `shortsMuted`,
`shortsAutoAdvance`. All have defaults and load from older settings.

## Later

Picture-in-picture, auto-scroll mode, watch history.
