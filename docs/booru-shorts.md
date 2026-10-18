# booruShorts

A full-screen, vertically swiped video feed across every usable website, in
the style of Instagram Reels and YouTube Shorts. Opened from the navigation
drawer (compact shortcut row and classic drawer list).

## Decisions

| Topic | Decision |
| --- | --- |
| Entry point | Navigation drawer item. |
| Multiple Shorts tags | Any tag (OR): each tag is its own stream per website, and streams are interleaved. This keeps every request within the website's tag budget. |
| Order | Random, with one seed per Shorts session (the same `random`/`randomSeed` fetch the discovery feed uses). Once the viewer has interests, For you reorders the fetched videos by them (see *For you: recommendations*). |
| Tabs | For you (random or personalized) and Following (newest videos with followed tags). |
| Like vs favorite | A separate Like and *Not for me* on the rail; Favorite keeps its meaning and counts as a stronger like. |
| Websites | Every usable website by default (visible, and signed in where required) that hosts video; individual websites can be switched off in Settings. |

## Feed source

Each website gets its own video query, combined with at most one Shorts tag.
Checked live on 2026-10-18:

| Website | Video query | Notes |
| --- | --- | --- |
| Danbooru, AIBooru | `filetype:mp4,webm` | A metatag, so it does not count toward the anonymous two-tag limit (`filetype:mp4,webm 1girl -solo` is accepted). |
| e621, e926 | `~type:webm ~type:mp4` | e621 OR syntax. |
| Gelbooru, Rule34, Sankaku, Idol Complex, Nozomi, XBooru, Nanbooru | `video` | Sankaku returned only `video/*` files; Nozomi serves `nozomi/video.nozomi`. Gelbooru/Rule34 need credentials and were not probed. |
| Sakugabooru | `animated` | Its clips are MP4/WebM tagged `animated`. |
| Safebooru, TBIB | (excluded) | `video` and `webm` return only GIFs. |
| Konachan, Yande.re, MSPABooru, E-Shuushuu, Mikubooru | (excluded) | Image-only websites. |
| AIBooru | (excluded) | Retired: no longer offered anywhere in the app. |

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

## For you: recommendations

The websites cannot recommend anything, so all of it happens on the device
(`lib/core/shorts_profile.dart`). Nothing is sent anywhere.

**Signals.** Explicit: Like +1.0, Favorite +1.5, Download +1.0, Share +0.5,
opening details +0.2, *Not for me* -1.5, hiding the post -2.0, and tapping a
tag +0.5 on that tag alone. Implicit, from watch time: finishing (90%) +0.3,
each replay +0.2 (at most three), and a quick skip (under two seconds and a
quarter of the video) -0.3. Watching part of a video says nothing. Undo and
un-liking take a signal back.

**Watch time** is media time actually played: forward position changes while
playing, ignoring jumps over 2.5 seconds (the scrub bar, the +5s
double-tap). Paused, backgrounded, and blurred-and-unrevealed time is not
counted. It is reported when the video is left, before the previous video is
seeked back to the start.

**Profile.** One weight per tag (shared across websites), website, and
uploader, each within ±3. A signal is spread over the post's tags, weighted
by category (artist 1.5, character 1.3, copyright 1.2, species 1.0, general
0.6, meta 0) and divided by √(tag count). Tags nearly every video has
(`video`, `animated`, `sound`, `highres`, …), metatags, and the website's
video query are skipped. Weights halve every 14 days without use. At most
2000 tags are kept, by strength.

**Score.** Σ category weight × rarity × tag weight / √(tag count), plus half
the website weight and 0.3 × the uploader weight. Rarity is
`log(1 + watched / (1 + videos with the tag))`, so common tags count less.

**Order.** Fetched videos wait in a pool. Five at a time move to the feed:
the best scores, plus random noise, and a share picked at random (Discovery:
Less 10%, Normal 25%, More 45%), without a third video in a row by the same
artist or a fourth from the same website. Videos already seen come last.
The pool is refilled when fewer than 20 unseen videos wait. Feedback
reorders what is still in the pool, so it shows within a few videos.

**Fetching.** With no Shorts tags and no filter, up to three liked tags
(weight 0.6 or more) get streams of their own on every website, in the same
rotation as the rest. With Shorts tags, recommendations only reorder.

**Exactly as before** when the profile is empty, *Personalize For you* is
off, or in the Following tab: videos appear in arrival order and no liked-tag
streams are asked for.

**Muted tags** ("Not interested", by holding a tag) never show in either tab.
Clearly disliked tags (weight -2 or lower) are dropped from For you.

**Why this video.** The details sheet names the liked tags behind the pick,
or says it was picked to explore.

**Privacy.** Learning stops in incognito and with personalization off;
incognito also stops the watch history. Backups carry interests and muted
tags, not the history. *Your interests* lists what was learned, each tag
removable, with a full reset.

## Following

Tags followed by holding a tag (or in the gear sheet / Settings) fill the
Following tab with the newest videos (`random: false`), each tag its own
stream per website like Shorts tags. Without followed tags the tab explains
how to follow and asks for nothing.

## Watch history

The last 100 videos watched for two seconds or more (sanitized posts), newest
first, from the ⋮ menu or Settings. The last 2000 videos shown (by MD5 when
known) count as seen. Clearing the history forgets both.

## Auto-scroll

A session toggle in the ⋮ menu (shown as a chip that turns it off). Videos
stop looping and move on when they end, or after the *Auto-scroll length*
(10, 15, 30, or 60 seconds of playing; Whole by default). Pausing stops it.

## Picture-in-picture

From the ⋮ menu, or automatically when leaving the app while a video plays
(*Picture-in-picture* in Settings, on by default). The window is shaped like
the video and shows it alone; playback continues while the app is inactive
in picture-in-picture. Never offered while the app lock or *Hide in recent
apps* is on, and not entered when the share sheet or a browser opens.
Android 12+ enters through `setAutoEnterEnabled`; older versions from
`onUserLeaveHint`.

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
  (`shortsTags`, or `shortsFollowing` in the Following tab), where tags can
  be added (with autocomplete) or removed without opening Settings. Changes
  are saved at once and restart the feed.
- ⋮ menu: Auto-scroll, Picture-in-picture, Watch history, Your interests.
- Bottom-left: the website, artist tags, and up to three character or
  copyright tags. Tapping a tag filters Shorts to that tag (shown as a chip
  that clears the filter); holding it offers the filter, Follow, and Not
  interested.

## Right rail (top to bottom)

1. Favorite: filled when saved; uses the existing favorites.
2. Like: a signal only (session state on the button).
3. Not for me: learns a dislike and moves on, with Undo.
4. Details: a bottom sheet with rating, score, size, uploader, source,
   grouped tags (tap to filter Shorts), and *Open full details*, which opens
   the regular viewer on the post with its details panel open.
5. Website badge: the website's logo. Opens a sheet with *Open on website*,
   *Only this website* (this session), and *Hide this website from Shorts*.
6. Share, Download, and More (hide post, hide uploader).

The rail scales down to fit short screens and large text.

## Settings: booruShorts

- Tags (chips with autocomplete). Without tags Shorts shows all videos.
- Websites: switches for the websites that host video.
- Start muted.
- Auto-advance at the end of a video (otherwise loop).
- Following (tags).
- Personalize For you, and Discovery (Less, Normal, More).
- Auto-scroll length.
- Picture-in-picture.
- Your interests and Watch history.

New `AppSettings` fields: `shortsTags`, `shortsOff`, `shortsMuted`,
`shortsAutoAdvance`, `shortsPersonalized` (true), `shortsExploration`
(normal), `shortsFollowing`, `shortsAutoScrollSeconds` (0, 10, 15, 30, 60),
`shortsPictureInPicture` (true). All have defaults and load from older
settings. The interest profile and history are stored separately
(`ShortsProfileStore`, key `shortsProfile.v1`).

## Later

Mapping tag aliases across websites (e621 and Danbooru name some tags
differently), weighting streams by website interest, and a badge for new
videos in Following. Picture-in-picture has not been checked on a device yet.
