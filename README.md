<div align="center">

<img src="assets/AppIcon.png" alt="BooruPlus app icon" width="112">

<br><br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/LogoFullColorWhite.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/LogoFullColor.png">
  <img src="assets/LogoFullColorWhite.png" alt="booruPLUS+" width="460">
</picture>

### booru client for all things imageboard.

Browse, search, save, and swipe through imageboards from a single, fast, ad-free Android app.

<br>

![Android](https://img.shields.io/badge/Android-8.0%2B-3DDC84?style=for-the-badge&logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-Dart%203.13-02569B?style=for-the-badge&logo=flutter&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-bridge-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)
![Websites](https://img.shields.io/badge/websites-18-F20B3D?style=for-the-badge)

[Highlights](#-highlights) · [All features](#-all-features) · [Websites](#-supported-websites) · [Install](#-install) · [Build](#-build-from-source) · [Privacy](#-privacy)

</div>

---

## Highlights

<table>
<tr>
<td width="50%" align="center">
<img src="docs/media/booru-shorts.gif" alt="booruShorts walkthrough" width="300">
</td>
<td width="50%">

### booruShorts

A full-screen vertical video feed built from every website that hosts video, doom scroll and swipe through media from different imageboards!

- **Like**, **Favorite**, or **Not for me** from the side rail
- **For you** learns which tags you enjoy from likes, favorites, and watch time
- **Following** shows the newest videos from tags you follow
- Auto-scroll, picture-in-picture, watch history, and a **Your interests** page you can reset

> Algorithm and Recommendation feed is computed on the application, nothing is sent on the websites!

</td>
</tr>
<tr>
<td width="50%">

### Hold to preview

Hold any post to see it large without leaving the grid, then slide onto an action and let go.

- **Favorite** saves it to your collection
- **Hide** removes it from every feed
- **Uploader** hides everything from that uploader
- Let go anywhere else to close the preview

</td>
<td width="50%" align="center">
<img src="docs/media/post-hold.gif" alt="Hold a post to preview, favorite, or hide it" width="300">
</td>
</tr>
<tr>
<td width="50%" align="center">
<img src="docs/media/post-details.gif" alt="Post details and the tag menu" width="300">
</td>
<td width="50%">

### Post Details

Swipe up in the viewer for everything about a post.

- Rating, size, file type, and tag count
- Uploader, original source, and **Open in browser**
- **Find on other sites** looks up the same file elsewhere
- Tap a tag to search it. **Hold** a tag to search it on all sites, add it to or exclude it from your search, block it, or copy it

</td>
</tr>
<tr>
<td width="50%">

### Search all sites

One search across every website you use, in one merged grid.

- Tag suggestions with post counts as you type
- Switch individual websites off for the search
- Every result is marked with its website's logo
- Also available by holding a tag in any post

</td>
<td width="50%" align="center">
<img src="docs/media/search-all-sites.gif" alt="Search on all sites" width="300">
</td>
</tr>
<tr>
<td width="50%" align="center">
<img src="docs/media/websites.gif" alt="Switching and reordering websites" width="300">
</td>
<td width="50%">

### Reorganize and Hide websites

Switch websites from the side menu. Each website keeps its own feed, saved searches, and colors.

- Tap **tune** beside *Websites* to reorder them by dragging
- Switch websites off to hide them from the menu

</td>
</tr>
</table>

---

## All features

<details open>
<summary><b>Browsing and search</b></summary>

| Feature | Details |
| --- | --- |
| Discover feed | A random feed for each website, kept in the same order while you scroll. |
| Tag search | Includes autocompletion, post counts (if supported) and turn to chips when selected. |
| Typed tags | Artist, character, copyright, species, meta, and lore tags each have their own color where the website provides categories. |
| Sort | Relevance, popularity, favorites, quality, newest, or oldest, depending on what the website supports. |
| Date and Rating filters | Narrow results by upload date and by rating (general, sensitive, questionable, explicit) on websites that have ratings. |
| Saved searches | Bookmark searches per website, or share one list across every website. New-post counts show what arrived since your last visit. |
| Recent searches | Your search history, with suggestions ranked by how often you use each tag. |
| Search all sites | Search on all websites at once, you could also hide some. |
| Search guides | In-app syntax help for each website's search features. |
| Back navigation | Going back restores the previous feed exactly where you left it. |
| Rate-limit handling | Waits and retries when a website says it is busy, with a countdown when it keeps refusing. |

</details>

<details open>
<summary><b>Grid and layout</b></summary>

| Feature | Details |
| --- | --- |
| Adjustable grid | Choose columns and rows per screen. |
| Hierarchical grid | A proportional gallery layout where every post keeps its own shape. |
| Clean gallery | Hide the tags shown on grid tiles. |
| Posts per batch | Request 50 to 200 posts at a time. |
| Hold to preview | Preview a post, then slide onto Favorite, Hide, or Uploader. |
| Multi-select | Select several posts to favorite or download them together. |
| One-handed mode | Moves search, filters, and feed actions to the bottom, with a jump-to-top button on your preferred side. |
| Hide panel while scrolling | The bottom panel slides away as you scroll down and returns as you scroll up. |
| Side menu | A compact menu with shortcuts, or the classic layout with every entry listed. |

</details>

<details open>
<summary><b>Viewer</b></summary>

| Feature | Details |
| --- | --- |
| Paging and zoom | Swipe between posts and pinch to zoom. |
| Double-tap to favorite | Optional: double-tapping an image favorites it instead of zooming. |
| Volume keys | Optional: volume down and up move to the next and previous post. |
| Slideshow | Advances on a timer, or when a video ends. |
| Video | Streams video, with a lower-resolution option on e621 and e926. |
| Data saver | Shows the website's smaller sample image, with **Load original** for full size. |
| Tags & details | Rating, size, uploader, source, typed tags, and the original file size. |
| Tag menu | Hold a tag: search it, search on all sites, add or exclude it, block it on one or all websites, or copy it. |
| Related posts | Parent and child posts, pools (Danbooru, e621, e926), and related posts that share artists or characters. |
| Find on other sites | Finds the same file on other websites. |
| Download and share | Download posts locally on your device. |

</details>

<details open>
<summary><b>booruShorts</b></summary>

| Feature | Details |
| --- | --- |
| Vertical video feed | Videos from every website that hosts them, one tap from the side menu. |
| For you | Ranks videos by tags you like. Likes, favorites, downloads, shares, and watching to the end count for a video; quick skips and **Not for me** count against it. |
| Discovery | Choose how often For you mixes in videos outside your interests (less, normal, or more). |
| Following | The newest videos with the tags you follow. Hold a tag to follow or mute it. |
| Shorts tags | Limit For you to the tags you choose. |
| Controls | Scrub bar, double-tap to skip 5 seconds, hold for 2× speed, mute. |
| Auto-scroll and auto-advance | Play each video for a set time, or move on when a video ends. |
| Picture-in-picture | Keep watching in a small window after leaving the app. |
| Watch history and interests | Review what you watched and what For you learned, you may forget a tag or reset everything. Up to you. |
| Per-website control | Watch one website only for a visit, or switch a website off for booruShorts. |

</details>

<details open>
<summary><b>Collections and downloads</b></summary>

| Feature | Details |
| --- | --- |
| Favorites | One collection across every website, filterable by website and tag, with sorting, multi-select removal, and batch download. |
| Hidden posts | Everything you hid, ready to unhide one by one or all at once. |
| Hidden uploaders | Uploaders whose posts never appear, per website. |
| Downloads | Saved to `Download/BooruPlus` or a folder you choose, with a file name template. |
| Download history | Every download in one place. Removing an entry keeps the file. |
| Favorite when downloading | Optional: downloaded posts are favorited too. |
| Launcher shortcuts | Long-press the app icon to open favorites or your top saved searches. |

</details>

<details open>
<summary><b>Filters and safety</b></summary>

| Feature | Details |
| --- | --- |
| Blocked tags | Block tags on every website or on one website. They are excluded from searches and filtered again on the device. |
| No AI-generated posts | Hides posts tagged `ai_generated`, with per-website exceptions. |
| Blur | Blur explicit or questionable previews and media until revealed. |
| Ratings | Pick which ratings appear in feeds. |

</details>

<details open>
<summary><b>Appearance, privacy, and data</b></summary>

| Feature | Details |
| --- | --- |
| Themes | Default (warm dark), White, and AMOLED black. App bars take each website's color. |
| Reduce motion | Skips the opening animation and the blur behind panels for slower phones. |
| App lock | Fingerprint, face, or screen lock when opening the app or returning after 30 seconds away. |
| Hide in recent apps | Blanks the app preview in recent apps and blocks screenshots. |
| Incognito | Stops recording recent searches, tag usage, and booruShorts learning and history. |
| Backup and restore | Export settings, favorites, and hidden posts to a file and restore them later. Credentials are never included. |
| Cache | See how much space the cache uses and clear it. |
| Website connections | Add API keys or sign in where a website needs it. Credentials stay in Android's encrypted storage. |
| Updates | Checks GitHub releases at launch and offers the newest uncensored APK: **Update** installs it, **Not now** asks again next time. Turn the check off or check by hand in Settings. |

</details>

---

## Supported websites

<div align="center">

| Website | Account | booruShorts | Notes |
| --- | :---: | :---: | --- |
| Safebooru | — | — | Safe-for-work images only |
| Danbooru | — | ✅ | Typed tags, pools |
| Gelbooru | API key required | ✅ | |
| Konachan | — | — | Wallpapers; no tag suggestions |
| Yande.re | — | — | High-resolution scans; no tag suggestions |
| e926 | — | ✅ | Safe-for-work e621; pools, video quality |
| e621 | — | ✅ | Pools, video quality |
| Rule34 | API key required | ✅ | |
| Sankaku Complex | Optional sign-in | ✅ | |
| Idol Complex | — | ✅ | |
| TBIB | — | — | |
| Nozomi | — | ✅ | No ratings; sorts by newest or popular |
| Sakugabooru | — | ✅ | Animation clips, credited by animator |
| XBooru | — | ✅ | |
| MSPABooru | — | — | Homestuck and MS Paint Adventures art |
| E-Shuushuu | — | — | All-ages anime art; no ratings |
| Mikubooru | — | — | Hatsune Miku and VOCALOID art; no ratings |
| Nanbooru | — | ✅ | Emmy the Robot and Nandroid art; no ratings |
| Realbooru | — | — | Photos of real people; read from its pages, no tag suggestions |
| Derpibooru | — | ✅ | My Little Pony art |

</div>

> [!NOTE]
> BooruPlus does not host any content. Every post comes from the website it is shown with, under that website's rules. 
> Several websites carry adult content: use blocked tags, rating filters, and blur to shape what you see.

---

## 📦 Install

Download `booruplus-<version>-<build>-uncensored.apk` from [Releases](https://github.com/Anislop/BooruPlus/releases) and open it on your phone. The `nightly` prerelease is the latest build of `main`. After that, BooruPlus offers newer releases by itself.

---

## 🛠️ Build from source

**You need:** the Flutter SDK (Dart 3.13 or newer), the Android SDK, and JDK 17. The app runs on Android 8.0 (API 26) and newer. iOS is not supported.

```bash
git clone https://github.com/Anislop/BooruPlus.git
cd BooruPlus
flutter pub get
flutter run                # on a connected device or emulator
flutter build apk --release
```

**Checks**

```bash
flutter analyze
flutter test
```

Live integration tests (`integration_test/`) need a real Android device with network access.

---

## Privacy

- No accounts, analytics, or ads. The app talks only to the websites you choose, and to GitHub to look for updates (you can turn that off in Settings).
- booruShorts learns on your phone. Turn **Personalize For you** off, or use incognito, to stop it.
- API keys and sign-in sessions live in Android's encrypted storage and are never written to backups. Sankaku passwords are exchanged for a session and not stored.
- **We do not send or store anything about you to the websites and servers.** Check the source code to see.

---

## AI Disclosure

**Is this a vibe-coded project?** No, not entirely. AI was used only for commit messages, comments, integrating tests and regression tests. API creation, UI layouts were mostly handwritten code. We use only AI to guide and assist our work to make things faster.

## FAQs
- **iOS Support?**
    - No possibility. Sideloading is hard in iOS, and the full app is sure won't be accepted by Apple themselves. The project itself is written mostly in Android in mind. However, this may change in the future.
- **Play Store?**
    - Coming soon.
- **Is this all free?**
    - Yes. Will always be. You can fork it, you can do whatever you want as long as you follow our license. We will not add ads at all (it's open source anyways)

---

## 📄 License

BooruPlus is free software, released under the [GNU General Public License v3.0](LICENSE). You may use, study, share, and modify it, but any version you distribute must also be released under GPL-3.0 with its source code.

The vendored library in `android/imageboard-api/` keeps its own [Apache License 2.0](android/imageboard-api/LICENSE).

---

<div align="center">

<img src="assets/anislopFlat.png" alt="" width="128">

**Made with love by the [Anislop Department](https://x.com/Anislop_Dept).**

</div>
