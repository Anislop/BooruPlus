import 'package:flutter/foundation.dart';

/// Premium, the Play edition's one-time purchase. It removes ads and
/// unlocks the features below; the Full edition has everything unlocked
/// ([UnlockedPremium]).
enum PremiumFeature {
  noAds,
  websites,
  reorderWebsites,
  noShare,
  downloads,
  classicDrawer,
  videoQuality,
  amoled;

  String get title => switch (this) {
    noAds => 'No ads',
    websites => 'More websites',
    reorderWebsites => 'Reorganize websites',
    noShare => 'No share',
    downloads => 'Faster downloads',
    classicDrawer => 'Classic side menu',
    videoQuality => '1080p and original video',
    amoled => 'AMOLED theme',
  };

  String get description => switch (this) {
    noAds => 'No ads in the feed or in booruShorts.',
    websites => 'Yande.re, Gelbooru, MSPABooru, E-Shuushuu, and Derpibooru.',
    reorderWebsites => 'Put the websites you use most at the top of the menu.',
    noShare => 'Hide every share button and action for privacy.',
    downloads => 'Run up to four downloads at once instead of one.',
    classicDrawer => 'The original side menu: a long list above the websites.',
    videoQuality => 'Stream videos in 1080p or at their original quality.',
    amoled => 'Pure black for OLED screens.',
  };
}

/// Limits that apply without Premium.
abstract final class FreeLimits {
  /// Downloads running at once.
  static const downloadConcurrency = 1;

  /// The highest video tier streamed (720p); 1080p and originals need
  /// Premium.
  static const videoQuality = 720;
}

/// Whether Premium is owned, and the purchase flow.
abstract class PremiumService extends ChangeNotifier {
  /// Whether Premium is owned (always true in the Full edition).
  bool get active;

  /// Whether the store answered and the product can be bought.
  bool get available => false;

  /// The localized price, once the store reports it.
  String? get price => null;

  /// A purchase or restore is in progress.
  bool get busy => false;

  /// The last purchase problem, for the Premium page.
  String? get error => null;

  /// Reads what the user owns as last known, completing once it is;
  /// connects to the store, whose answer arrives later through listeners.
  Future<void> start() async {}

  /// Starts the purchase. The result arrives through [active].
  Future<void> buy() async {}

  /// Looks up purchases made earlier on this account.
  Future<void> restore() async {}
}

/// The Full edition: nothing is locked and there is nothing to buy.
class UnlockedPremium extends PremiumService {
  @override
  bool get active => true;
}

/// A Premium state set by hand, for tests and previews.
class ManualPremium extends PremiumService {
  ManualPremium({bool active = false}) {
    _active = active;
  }
  bool _active = false;
  int purchases = 0;

  @override
  bool get active => _active;
  set active(bool value) {
    if (value == _active) return;
    _active = value;
    notifyListeners();
  }

  @override
  bool get available => true;

  @override
  String? get price => r'$2.99';

  @override
  Future<void> buy() async {
    purchases++;
    active = true;
  }
}
