import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'premium.dart';

/// Premium through Google Play Billing (`in_app_purchase`): one
/// non-consumable product, acknowledged on arrival so Play does not refund
/// it, and looked up again at every start so a refund takes Premium away.
///
/// Ownership is cached on the device (outside settings and backups) so
/// Premium applies at once on launch, before the store answers. There is
/// no server-side receipt check: nothing about the user leaves the device.
class PlayPremiumService extends PremiumService {
  /// The Play Console product ID of the one-time purchase.
  static const productId = String.fromEnvironment(
    'PREMIUM_PRODUCT_ID',
    defaultValue: 'booruplus_premium',
  );
  static const _cacheKey = 'premium.owned.v1';

  final InAppPurchase _store = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchases;
  ProductDetails? _product;
  bool _active = false, _busy = false, _started = false;
  String? _error;

  @override
  bool get active => _active;
  @override
  bool get available => _product != null;
  @override
  String? get price => _product?.price;
  @override
  bool get busy => _busy;
  @override
  String? get error => _error;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _active = prefs.getBool(_cacheKey) ?? false;
      notifyListeners();
    } catch (_) {
      // Without the cache Premium waits for the store's answer.
    }
    unawaited(_connect());
  }

  /// Listens for purchases and asks the store what the account owns.
  Future<void> _connect() async {
    _purchases = _store.purchaseStream.listen(
      _onPurchases,
      onError: (Object _) => _fail('The purchase could not be completed.'),
    );
    try {
      if (!await _store.isAvailable()) return;
      final response = await _store.queryProductDetails({productId});
      _product = response.productDetails
          .where((product) => product.id == productId)
          .firstOrNull;
      notifyListeners();
      await _refreshOwned();
    } catch (_) {
      // The store is unreachable; the cached state stays until next start.
    }
  }

  /// Reads what the account owns now: a refunded or revoked purchase turns
  /// Premium off, and purchases still waiting are acknowledged.
  Future<void> _refreshOwned() async {
    final response = await _store
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>()
        .queryPastPurchases();
    if (response.error != null) return;
    var owned = false;
    for (final purchase in response.pastPurchases) {
      if (purchase.productID != productId) continue;
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        owned = true;
      }
      if (purchase.pendingCompletePurchase) {
        await _store.completePurchase(purchase);
      }
    }
    await _setActive(owned);
  }

  @override
  Future<void> buy() async {
    final product = _product;
    if (product == null || _busy) {
      if (product == null) _fail('Google Play is not available right now.');
      return;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final started = await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      if (!started) _fail('The purchase could not be started.');
    } catch (_) {
      _fail('The purchase could not be started.');
    }
  }

  @override
  Future<void> restore() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await _refreshOwned();
      if (!_active) _error = 'No earlier Premium purchase was found.';
    } catch (_) {
      _error = 'Google Play is not available right now.';
    }
    _busy = false;
    notifyListeners();
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != productId) continue;
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _busy = true;
          notifyListeners();
        case PurchaseStatus.purchased || PurchaseStatus.restored:
          _busy = false;
          await _setActive(true);
        case PurchaseStatus.error:
          _fail('The purchase could not be completed.');
        case PurchaseStatus.canceled:
          _busy = false;
          notifyListeners();
      }
      if (purchase.pendingCompletePurchase) {
        await _store.completePurchase(purchase);
      }
    }
  }

  Future<void> _setActive(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_cacheKey, value);
    } catch (_) {
      // The store is asked again on the next start.
    }
    if (_active == value) return;
    _active = value;
    _error = null;
    notifyListeners();
  }

  void _fail(String message) {
    _busy = false;
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _purchases?.cancel();
    super.dispose();
  }
}
