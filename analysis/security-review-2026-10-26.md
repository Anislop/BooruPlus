# BooruPlus security and privacy review

Reviewed 2026-10-26, as root only, against source commit `7b627cb1485dfd3279e4f5388a30f5332b9d5b9b` (version `2.3.1+1`). This is an assessment, not a security fix. No production code was changed, real credentials inspected, or live provider attacks performed.

## Scope and edition coverage

**The uncensored source was reviewed. A distinct Play Store version could not be located or verified.** The checkout has one application ID, one main manifest, no `productFlavors`, and only debug/profile manifest overlays. The release workflow names its APK `*-uncensored.apk`. Local and remote-tracking branches contain no identifiable Play Store branch. README still describes Play Store distribution as forthcoming. A request for its source/build configuration remained unanswered when this report was prepared.

| Area | Uncensored checkout | Play Store edition |
| --- | --- | --- |
| Flutter models, authentication, privacy, UI and persistence | Reviewed | Findings apply if this code is reused; separate edition unverified |
| Kotlin/Java network paths, sharing, downloads, links and updater | Reviewed | Separate native implementation/manifest unverified |
| Build/signing configuration and CI release naming | Reviewed | No Play flavor, AAB pipeline or edition boundary found |
| Installed APK/AAB, merged manifest, release logs, device behavior | Not tested | Not supplied/tested |

Relevant edition evidence: `android/app/build.gradle.kts:49-88`, `android/app/src/main/AndroidManifest.xml`, `.github/workflows/cd.yml:122-128`, `lib/core/updates.dart:67-70`.

Do not use this report as approval of a Play Store release. In particular, reusing this configuration would retain the GitHub uncensored updater, `REQUEST_INSTALL_PACKAGES`, the same package ID, and the same board catalog. A future edition needs an explicit update/content boundary and verification of its actual artifact. This is a release-design gap, not evidence that an existing Play installation has been bypassed.

## Results

No critical vulnerability, demonstrated account takeover, or GPS collection was established. There are actionable privacy disclosures and incomplete handling of untrusted media. Severity includes prerequisites; a synthetic counterexample is not proof that a provider currently supplies malicious data.

| ID | Severity | Finding | Evidence strength |
| --- | --- | --- | --- |
| S1 | Medium | Saved-search text is exposed outside the app lock through launcher shortcuts | Reproduced at the platform-channel boundary |
| S2 | Medium | Learned Shorts interests become provider queries, including during incognito | Reproduced using a recording repository |
| S3 | Medium | Backup media URLs bypass the native public-host validation when displayed | Import and routing reproduced; Android network exploitation untested |
| S4 | Low; potentially Medium for actual account secrets | Saved-URL sanitization is incomplete | Synthetic secret retention reproduced; ordinary account-token exfiltration not established |
| S5 | Low | A feed searched in incognito becomes persistent after toggling incognito off | Reproduced through the real state/persistence path |
| S6 | Medium, conditional on hostile media | Ordinary image loading lacks the native path's response-size limits | Source trace; no resource-exhaustion attack run |

### S1 — App lock does not protect saved-search labels in the launcher

**Evidence:** `lib/main.dart:134-179` calls `_updateShortcuts()` when settings load, including while locked. It publishes the first three saved searches verbatim as labels and tags. Its cache key does not include `appLock` or `secureScreen`. `MainActivity.kt:670-689` places those labels and intent extras into `ShortcutManager.dynamicShortcuts`.

**Exposure:** Someone holding an unlocked Android device can long-press the app icon and read sensitive saved searches without authenticating to BooruPlus. The launcher also receives the query data. This does not require root or permission to read app-private storage. The app's screen-security flag does not govern the launcher's UI. Opening the shortcut still waits for authentication; the finding concerns disclosure of its label, not navigation bypass.

**Reproduction:** Save a distinctive query, enable app lock and secure screen, close and reopen the app without unlocking it. Probe S1 confirms the query is sent through `setShortcuts` while the app displays its locked screen. Confirm actual launcher presentation on a device as the final integration check.

**Remediation:** Suppress sensitive search shortcuts whenever app lock/privacy settings require it; clear previously published entries when enabling protection. Include privacy settings in the shortcut cache key. Account for pinned shortcuts and platform retention as well as dynamic entries. Test both cold launch and switching protection on after shortcuts already exist.

Android documents that dynamic shortcuts expose context-sensitive app actions through launchers: [Create shortcuts](https://developer.android.com/develop/ui/compose/system/shortcuts/creating-shortcuts).

### S2 — Learned interests are transmitted as searches, even in incognito

**Evidence:** `lib/core/app_state.dart:3030-3054` enables ranking when personalization and a stored profile exist, without checking incognito. It selects up to three learned tags and creates a stream for each tag on each selected board. `_fetch` at `3285-3301` passes these tags to the provider repository. The learning/history guard at `1173-1202` prevents new recording in incognito but does not prevent use or transmission of the existing profile.

**Exposure:** A provider receives sensitive interests learned from activity elsewhere, associated with the user's network address and, where configured, their provider account. It receives selected query terms, not the entire profile or raw watch history. Ordinary searches necessarily contact providers; the additional disclosure here is automatically sending previously learned interests. README's statement at line 48 that nothing is sent to websites is contradicted by this flow. The Settings description at `lib/ui/settings.dart:1478` is also incomplete about what “on this device only” means.

**Reproduction:** Teach `audit_private_interest`, turn incognito on, and start an otherwise unfiltered Shorts feed. Probe S2 records a repository request containing that learned tag. No live account or HTTP request is involved.

**Remediation:** Keep learned-tag retrieval local, or clearly disclose and separately control personalized provider queries. Disable these streams in incognito, including streams already created when the setting changes. Preserve the existing guard against recording new history. Test that explicit user searches still work while unsolicited learned-interest queries do not.

### S3 — Imported media can cause requests to arbitrary or private hosts

**Evidence:** `AppState.importBackup` at `lib/core/app_state.dart:1377-1401` accepts favorite/hidden post maps. `MediaPost.fromMap` retains their URL strings (`lib/core/models.dart:490-580`), and `SavedPost.sanitized()` only removes two query parameters from three fields (`752-800`). `lib/ui/media_image.dart:72-91,176-183` sends ordinary images directly to `NetworkImage`. That path does not invoke `MainActivity.openSecureConnection` or `isPublicHost`. Video playback similarly constructs network controllers from post/variant URLs (`lib/ui/media_viewer.dart:465-474`).

**Exposure and prerequisites:** A user must import an attacker-provided backup and display its posts, or encounter a provider response containing an attacker-controlled media URL. Merely rendering the thumbnail can contact an arbitrary public tracking server and disclose the network address plus a unique URL identifier. Private-network URLs also reach the image transport without the application's native address checks. This is client-side request forgery, not server-side SSRF: there is no app backend. The destination still has to satisfy the transport's TLS/platform restrictions; a private HTTPS server with an untrusted certificate is not shown to succeed. HTTP behavior and local-network access restrictions vary with the Android/runtime version and were not exercised.

**Reproduction:** Probe S3 imports `https://127.0.0.1:8443/audit-preview.jpg`, verifies it survives in favorites and is assigned to the non-native image path. It deliberately performs no request to that address. A device test should use a server the tester owns and assert rejection before connecting, including redirects and video variants.

**Remediation:** Enforce one media URL policy at import/provider normalization and in every transport. Require HTTPS without user info; restrict expected CDN hosts where practical; reject private/reserved addresses at connection time and every redirect. Validate image, sample, preview and video-variant URLs consistently. Do not rely on a parser-only check while another networking stack follows redirects independently.

Flutter's API explicitly fetches the supplied URL and does not advertise an application-specific host policy: [NetworkImage](https://api.flutter.dev/flutter/painting/NetworkImage-class.html).

### S4 — “Sanitized” saved posts can retain URL secrets

**Evidence:** Both `SavedPost.sanitized()` (`lib/core/models.dart:752-800`) and `LocalPostStore._sanitizePost` (`lib/core/services.dart:310-328`) only redact exact `api_key`/`user_id` query keys on `url`, `previewUrl`, and `sampleUrl`. `MediaPost.withUrls` preserves `postUrl`, `source`, and `videoVariants` (`models.dart:638-665`). Other query tokens and URL user info are not stripped. Backups export this representation at `app_state.dart:1361-1370`. `postBrowserUrl` (`media_viewer.dart:2271-2280`) returns a provider-host `postUrl` unchanged, including its query.

**Exposure and prerequisites:** A secret already present in a secondary URL survives persistence/export; a credential-bearing provider-host post link can reach the clipboard, share sheet or browser. Signed Sankaku media URLs also retain their capability parameters in saved posts, exports and watch history, until the provider expires them. These media signatures are not established to be account access/refresh tokens.

**What was not found:** Normal Gelbooru authorization attaches the user's key to the primary/preview/sample URLs, which are redacted. Native post-page links are normally generated without account keys. Sankaku account tokens are stored separately. There is no demonstrated routine path that inserts the user's current account key into `postUrl`, `source`, or variants. The secondary-field result is a redaction gap for imported/provider-supplied data, not proof of automatic account leakage.

**Reproduction:** Probe S4 supplies only the literal `SYNTHETIC` as a key. The primary URL loses it, while secondary URLs and a signed media URL retain it; the browser-link helper returns the synthetic key unchanged.

**Remediation:** Consolidate sanitization across persisted/exported fields. Prefer canonical board/post identity for backups and re-fetch short-lived signed media when opened. Strip credential material from outward-facing post links and reject URL user info. Define provider-specific handling of signature parameters so durable storage/export is safe without breaking active playback. Test all URL fields, repeated parameters and signed URLs, not just primary Gelbooru images.

### S5 — Toggling incognito off makes the private feed eligible for resume storage

**Evidence:** `setIncognito` (`lib/core/app_state.dart:1329-1341`) only updates settings; it retains the current query and posts. `persistFeed` (`526-556`) checks the current flag, then writes the current tags and posts to `feeds.resume`. Home invokes this on backgrounding (`lib/ui/home.dart:123-132`). No per-feed marker records that the data originated during incognito.

**Exposure:** Search in incognito, turn it off from the drawer without starting a new search, then background the app. That private query and its posts can be saved and reopened on a later launch. This requires a deliberate mode change and resume enabled; persistence while incognito remains enabled is correctly blocked. It does not expose data remotely or bypass Android private storage.

**Reproduction:** Probe S5 confirms no saved feed while incognito is on, followed by the private tag appearing in stored feeds after switching it off.

**Remediation:** Mark incognito-origin feeds/snapshots as non-persistable for their lifetime, or discard/reload them when leaving incognito. Cover feed restoration and board switching as well as a direct toggle. Clarify the transition behavior in the UI.

### S6 — Ordinary image response bodies are not bounded before decoding

**Evidence:** `lib/ui/media_image.dart:176-183` uses `NetworkImage` for most boards. The reviewed installed Flutter implementation, `packages/flutter/lib/src/painting/_network_image_io.dart:110-151`, reads the response with `consolidateHttpClientResponseBytes` before decoding. There is no app-level compressed-byte limit or total transfer deadline on this route. `boundedImage` limits decoded dimensions, not downloaded body size. In contrast, `MainActivity.readMedia` bounds native media to 50 MiB (`MainActivity.kt:1282-1320,1900-1901`).

**Exposure and prerequisites:** A hostile media origin reached through S3, or a compromised/provider-controlled media response, can send a very large or continuously growing body. Several automatically loaded thumbnails amplify memory and data consumption and can terminate the app. An image decode-size limit does not prevent this preceding allocation. No huge-response experiment was run, and no native decoder exploit or code execution is claimed.

**Remediation:** Use a bounded image transport for all boards, with streamed byte accounting, cancellation, total deadlines, redirect policy and concurrency limits. Enforce limits for missing or dishonest `Content-Length`. Test modest synthetic over-limit bodies rather than deliberately exhausting a device. Verify the exact Flutter version used by the shipped artifact.

## Authentication hardening and conditional risks

These are separate from the reproduced findings because exploit prerequisites or shipping behavior remain unverified.

1. **Sankaku authentication POST redirects can retain secrets.** `MainActivity.kt:85-103` leaves ordinary redirects enabled and only disables HTTP/HTTPS scheme changes. `SankakuApi.kt:124-141` sends a password or refresh token in a replayable POST body. OkHttp 5.3.2 preserves that body for 307/308 redirects, including cross-host HTTPS redirects; stripping `Authorization` does not remove a JSON password. A redirect from the fixed authentication endpoint to another HTTPS origin could therefore forward the body. This requires an upstream redirect/misconfiguration or compromise; an ordinary media uploader cannot select the auth endpoint, and a passive network observer cannot alter TLS. No such production redirect was observed. Use a dedicated no-redirect authentication client, or explicit same-origin validation. Validate with synthetic credentials and controlled servers. Source: [OkHttp 5.3.2 redirect implementation](https://github.com/square/okhttp/blob/parent-5.3.2/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/http/RetryAndFollowUpInterceptor.kt#L270-L310).
2. **Vendored debug logging receives credential-bearing URLs.** `android/imageboard-api/src/main/java/net/kodehawa/lib/imageboards/ImageBoard.java:415,480` passes `response.request().url()` to SLF4J after authorization injection in `requests/RequestFactory.java:100-115`. This includes query keys on authenticated providers. The inspected build declares `slf4j-api` without an explicit logging backend; actual release log emission was not established. Redact/remove these calls before adding any logger and inspect packaged release logging. Do not label the present release as proven to leak keys to logcat without that check.
3. **Public-host DNS validation is separate from connection resolution.** `MainActivity.kt:1808-1809,1947-1951` checks DNS and then lets `HttpURLConnection` resolve/connect independently. This is not address pinning. DNS rebinding would additionally depend on resolver caching and a TLS-valid target. `saveFrame` also probes a URL and opens it again in `MediaMetadataRetriever` (`530-548`), whose later requests bypass that original check. Use a validated connection/address binding or bounded downloaded local media. No end-to-end bypass was demonstrated.
4. **Release signing falls back to a debug key.** `android/app/build.gradle.kts:12-16,82-85` and CD allow this when release signing is unavailable. That can publish an unusable update and, when a shared/known debug key is used, weakens signing trust. The CI runner's freshly generated debug key is not assumed to be known to an attacker. Fail release publication closed when signing credentials are absent. Signing-secret contents were not inspected.

## Location and other privacy boundaries

- **Precise device location:** No `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, background location permission, `LocationManager`, geolocation plugin, or location API use was found in the inspected source/dependency declarations. `DownloadRecord.location` means a saved file URI, not coordinates. The merged manifests and actual shipped binaries remain unverified.
- **IP-based location:** API servers, media CDNs and GitHub receive the device's public egress IP for their respective connections. They can potentially infer approximate geography. Incognito and app lock do not provide network anonymity. S3 additionally permits unexpected media origins. No exact physical address or GPS leakage was demonstrated.
- **Interests and identifiers:** Queries, autocomplete text, upstream filter exclusions, post IDs/MD5 lookups, and applicable authentication go to providers. Cross-site search and “find on other sites” deliberately contact multiple boards. The blanket README privacy claim that nothing about the user is sent/stored by websites is not supportable; this client cannot control provider logs. S2 adds unsolicited learned-interest queries.
- **Media metadata:** Share, copy-image and download stream the original bytes; no EXIF/GPS scrubber was found (`MainActivity.kt:439-462,492-501,1527-1543`). A source file's embedded metadata can be handed to recipients. This is metadata of the downloaded source, not newly measured device location; the app has no camera/upload path in scope. If privacy-safe sharing is desired, offer explicit metadata stripping.
- **Local records and exports:** Favorites, hidden posts, settings, searches, feeds, downloads and Shorts history are app-private but generally not encrypted by the app. Android storage isolation is a meaningful boundary; root/device compromise is outside the app-lock threat model. A user-exported JSON backup contains sensitive preferences and collections and may be saved through a cloud document provider. It is not encrypted. These are expected export/storage properties, not an automatic remote leak.
- **Clipboard and “No share”:** No share is a UI convenience that hides share actions; copy actions deliberately remain. Clipboard recipients, external browsers, share targets and public download folders are outside the app lock. Copying media now creates a content URI grant through the clipboard. The reviewed behavior should not be described as comprehensive data-loss prevention.

## Controls that are present

| Feature | Observed protection and limits |
| --- | --- |
| Account storage | `LocalSettingsStore` uses `FlutterSecureStorage` per board (`services.dart:437-494`). Passwords are exchanged for sessions, not saved. No credential values were inspected. |
| Auth renewal/sign-out | Session generations and serialized secure-storage access prevent a late refresh restoring a signed-out session (`app_state.dart:2036-2074`). Full race coverage was not rerun. |
| Normal Gelbooru images | Credential attachment is HTTPS/provider-host scoped in Dart; native normalization and native image redirects also constrain hosts. Normal saved primary URLs lose API keys. |
| Native errors | `MainActivity.background` returns generic messages instead of upstream exception text (`763-803`), reducing authenticated-URL disclosure in UI errors. |
| Backups | Normal account credentials and download directory are excluded; restore preserves app lock and an already enabled secure-screen flag (`app_state.dart:1361-1418`). S4 qualifies the URL sanitization guarantee. |
| Links/intents | Exported link entry points parse supported board links; pending links/shortcuts wait behind app lock. The platform method channel itself is not an exported Android IPC service. |
| Sharing | Non-exported, read-only provider; temporary URI grants; random per-share folders; path traversal checks (`SharedMediaProvider.kt:25-40`). No arbitrary private-file read was identified. |
| Downloads | HTTPS, redirect/public-address checks, size/time limits, filename checks, SAF/MediaStore access. S3 concerns other media transports; conditional DNS concerns remain above. |
| Notifications | Download notification text contains counts/progress, not tags, URLs or credentials (`download_queue.dart:440-473`). |
| Updates | GitHub host restriction, package/build checks and signer comparison before Android's installer (`MainActivity.kt:1693-1784`). Empty signer results defer to the installer; no APK-signature bypass was demonstrated. |
| App lock/PiP | Lock overlay and pending-navigation checks exist; Shorts disables PiP when app lock or secure screen is set (`shorts.dart:309-325`). OS lifecycle/snapshot behavior needs device testing. |
| Tracking/code execution | No analytics/crash-reporting SDK, location collection, custom trust-all TLS handler, or WebView/JavaScript execution path was found in the inspected app code and declared dependencies. This is not a binary/supply-chain guarantee. |

## Verification and limits

Reproducible probes are in [security_reproductions_test.dart](security_reproductions_test.dart). **They intentionally pass when the documented exposure exists.** They are audit evidence outside the ordinary `test/` suite, not tests asserting secure behavior. All network/provider/platform operations in these probes are mocked; S3 does not contact a loopback or LAN service. All credential strings are synthetic.

Executed successfully:

```sh
flutter test --no-pub analysis/security_reproductions_test.dart
# 5 probes passed: S1–S5.

flutter test --no-pub test/core_test.dart test/widget_test.dart --name \
  'saved Gelbooru URLs|session credentials round-trip|restoring a backup can turn secure screen|incognito saves no feed|launcher shortcut waits|shared link waits'
# 6 existing regressions passed.
```

Commands used `/root/flutter-sdk/bin/flutter`. The installed toolchain reports Flutter 3.47.2 / Dart 3.13.2; `pubspec.yaml` requests Dart ^3.13.3 and the workflow specifies Flutter 3.47.3. These tests ran with existing dependencies using `--no-pub`, so they do not establish a build with the repository's exact required SDK. An initial test attempt failed because a generated native-assets hook had an incompatible SDK hash. Only `.dart_tool/hooks_runner` was moved to `/tmp/booruplus-audit-hooks-20261026` and regenerated; no dependency/toolchain or production source was changed to make the probes pass.

Also performed source/path review, permission/dependency/security-sink searches and diff whitespace checks. The managed-runtime status tool and network-policy snapshot were unavailable in this environment; no credential discovery was attempted.

Not performed: full test suite, Android build, emulator/device tests, installed artifact or merged-manifest inspection, production packet capture/logcat, signed-in live provider tests, dependency CVE/database scan, malicious TLS/redirect or DNS rebinding experiments, metadata extraction from real media, or Play Store artifact verification. Absence of findings in a reviewed path does not prove absence of vulnerabilities.

## Suggested fix order

1. Close S1's launcher disclosure and decide whether learned-interest queries are compatible with the promised privacy model (S2).
2. Introduce consistent media host/address/redirect and byte-limit enforcement (S3/S6).
3. Correct persistence/export sanitization and incognito transition handling (S4/S5).
4. Harden authentication redirects and log redaction; fail release signing closed.
5. Review the actual Play source/AAB separately, then test both shipped variants on Android for network, lock, sharing, backup and update boundaries.
