import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' hide AppState;

import '../core/app_state.dart';
import '../core/edition.dart';
import 'premium_page.dart';
import 'theme.dart';

/// Where ads sit among a feed's posts: one after every [every] posts, so a
/// list of `n` posts has [slots] items. [every] 0 means no ads.
class AdLayout {
  const AdLayout(this.every);
  final int every;

  static const none = AdLayout(0);

  /// Posts and ads together, for [posts] posts. An ad needs [every] posts
  /// before it and one after, so the list never ends on an ad.
  int slots(int posts) =>
      every <= 0 || posts <= 0 ? posts : posts + (posts - 1) ~/ every;

  /// Whether the item at [slot] is an ad.
  bool isAd(int slot) => every > 0 && (slot + 1) % (every + 1) == 0;

  /// Which ad (0, 1, 2…) the item at [slot] is.
  int adIndex(int slot) => slot ~/ (every + 1);

  /// The post at [slot], or for an ad, the post after it.
  int postIndex(int slot) => every <= 0 ? slot : slot - slot ~/ (every + 1);

  /// The item showing post [index].
  int slotOf(int index) => every <= 0 ? index : index + index ~/ every;
}

/// The Play edition's ads: AdMob native ads drawn by the native layouts in
/// `NativeAds.kt`, shown only without Premium. Nothing here runs in the
/// Full edition. The SDK starts after the consent form (UMP) where the law
/// needs one, with ad content rated Teen at most. Each ad widget loads and
/// disposes its own ad, so an ad is never shown twice or released while
/// shown; one scrolled away and back loads a new ad.
class Ads extends ChangeNotifier {
  Ads._();
  static final instance = Ads._();

  /// Google's sample native ad units unless the build passes real ones.
  static const _tileUnit = String.fromEnvironment(
    'ADMOB_FEED_UNIT',
    defaultValue: 'ca-app-pub-3940256099942544/2247696110',
  );
  static const _pageUnit = String.fromEnvironment(
    'ADMOB_SHORTS_UNIT',
    defaultValue: 'ca-app-pub-3940256099942544/1044960115',
  );

  /// One ad after this many posts in the feed grid, and in booruShorts.
  static const feedEvery = 24;
  static const shortsEvery = 7;

  bool _starting = false, _ready = false, _privacyOptions = false;

  /// Whether ads may be requested (SDK started, consent settled).
  bool get ready => _ready;

  /// Whether Settings must offer the ad privacy choices.
  bool get privacyOptionsRequired => _privacyOptions;

  /// Asks for consent where required, then starts the ads SDK. Safe to
  /// call more than once.
  Future<void> start() async {
    if (!kPlayEdition || _starting) return;
    _starting = true;
    final settled = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => ConsentForm.loadAndShowConsentFormIfRequired(
        (_) => settled.isCompleted ? null : settled.complete(),
      ),
      (_) => settled.isCompleted ? null : settled.complete(),
    );
    await settled.future;
    try {
      _privacyOptions =
          await ConsentInformation.instance
              .getPrivacyOptionsRequirementStatus() ==
          PrivacyOptionsRequirementStatus.required;
      if (!await ConsentInformation.instance.canRequestAds()) {
        notifyListeners();
        return;
      }
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(maxAdContentRating: MaxAdContentRating.t),
      );
      await MobileAds.instance.initialize();
      _ready = true;
    } catch (_) {
      // No ads this session.
    }
    notifyListeners();
  }

  /// Opens the consent choices again (Settings › Privacy).
  Future<void> showPrivacyOptions() async {
    final done = Completer<void>();
    await ConsentForm.showPrivacyOptionsForm((_) => done.complete());
    await done.future;
    _ready = await ConsentInformation.instance.canRequestAds();
    notifyListeners();
  }

  /// A native ad for a feed tile, or a booruShorts [page], loading. The
  /// caller owns it and disposes it.
  NativeAd load({
    required bool page,
    required void Function(NativeAd ad) onLoaded,
    required VoidCallback onFailed,
  }) {
    final ad = NativeAd(
      adUnitId: page ? _pageUnit : _tileUnit,
      factoryId: page ? 'booruplusPage' : 'booruplusTile',
      request: const AdRequest(nonPersonalizedAds: true),
      nativeAdOptions: NativeAdOptions(
        mediaAspectRatio: page
            ? MediaAspectRatio.portrait
            : MediaAspectRatio.square,
        videoOptions: VideoOptions(startMuted: true),
      ),
      listener: NativeAdListener(
        onAdLoaded: (ad) => onLoaded(ad as NativeAd),
        onAdFailedToLoad: (_, _) => onFailed(),
      ),
    );
    unawaited(ad.load());
    return ad;
  }
}

/// Loads one ad for its widget once ads are ready, and disposes it with
/// the widget. [loaded] is the ad once it can be shown.
mixin _OwnAd<T extends StatefulWidget> on State<T> {
  bool get page;
  NativeAd? _ad;
  bool _loaded = false;

  NativeAd? get loaded => _loaded ? _ad : null;

  @override
  void initState() {
    super.initState();
    Ads.instance.addListener(_request);
    _request();
  }

  void _request() {
    if (!mounted || _ad != null || !Ads.instance.ready) return;
    _ad = Ads.instance.load(
      page: page,
      onLoaded: (_) {
        if (mounted) setState(() => _loaded = true);
      },
      // Stays on the Premium promotion; the next widget for this slot
      // tries again.
      onFailed: () {},
    );
  }

  @override
  void dispose() {
    Ads.instance.removeListener(_request);
    _ad?.dispose();
    super.dispose();
  }
}

/// Whether [state] shows ads now: the Play edition without Premium.
bool showsAds(AppState state) => kPlayEdition && !state.premiumActive;

/// An ad in the feed grid, the size of a post tile. While the ad loads, or
/// when none is available, the tile offers Premium instead, so the grid
/// stays even.
class FeedAdTile extends StatefulWidget {
  const FeedAdTile({super.key, required this.state});
  final AppState state;

  @override
  State<FeedAdTile> createState() => _FeedAdTileState();
}

class _FeedAdTileState extends State<FeedAdTile> with _OwnAd {
  @override
  bool get page => false;

  @override
  Widget build(BuildContext context) {
    final ad = loaded;
    if (ad != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AdWidget(ad: ad),
      );
    }
    return _PremiumTile(state: widget.state);
  }
}

class _PremiumTile extends StatelessWidget {
  const _PremiumTile({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Material(
    color: panel,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => openPremium(context, state),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.workspace_premium_rounded,
              color: accent,
              size: 28,
            ),
            const SizedBox(height: 6),
            Text(
              'No ads with Premium',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink(.87),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// An ad page in booruShorts, between videos.
class ShortsAdPage extends StatefulWidget {
  const ShortsAdPage({
    super.key,
    required this.state,
    this.active = false,
    this.onSkip,
  });
  final AppState state;

  /// The page is showing; with auto-scroll, [onSkip] moves on after a few
  /// seconds.
  final bool active;
  final VoidCallback? onSkip;

  @override
  State<ShortsAdPage> createState() => _ShortsAdPageState();
}

class _ShortsAdPageState extends State<ShortsAdPage> with _OwnAd {
  Timer? _skip;

  @override
  bool get page => true;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ShortsAdPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.onSkip != widget.onSkip) {
      _schedule();
    }
  }

  void _schedule() {
    _skip?.cancel();
    final skip = widget.onSkip;
    if (widget.active && skip != null) {
      _skip = Timer(const Duration(seconds: 6), skip);
    }
  }

  @override
  void dispose() {
    _skip?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = loaded;
    if (ad != null) {
      return ColoredBox(
        color: Colors.black,
        child: AdWidget(ad: ad),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.workspace_premium_rounded,
                color: accent,
                size: 48,
              ),
              const SizedBox(height: 12),
              const Text(
                'Enjoy booruShorts without ads',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => openPremium(context, widget.state),
                child: const Text('See Premium'),
              ),
              const SizedBox(height: 8),
              const Text(
                'Swipe up to keep watching',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
