import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/edition.dart';
import 'theme.dart';

/// Opens the Premium page (the Play edition's one-time purchase).
Future<void> openPremium(BuildContext context, AppState state) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => PremiumScreen(state: state)));

/// Shows what Premium unlocks when [state] lacks it; returns whether
/// [feature] can be used. For locked controls: `if (!await requirePremium(…))
/// return;`.
Future<bool> requirePremium(
  BuildContext context,
  AppState state,
  PremiumFeature feature,
) async {
  if (state.unlocked(feature)) return true;
  await openPremium(context, state);
  return state.unlocked(feature);
}

/// A small lock shown beside a Premium control.
class PremiumLock extends StatelessWidget {
  const PremiumLock({super.key, this.size = 18});
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Premium',
    child: Icon(Icons.lock_rounded, size: size, color: accent),
  );
}

/// What Premium includes, its price, and the purchase and restore buttons.
/// After the purchase it shows that Premium is active.
class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key, required this.state});
  final AppState state;

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  PremiumService get _premium => widget.state.premium;

  static IconData _icon(PremiumFeature feature) => switch (feature) {
    PremiumFeature.noAds => Icons.block_rounded,
    PremiumFeature.websites => Icons.public_rounded,
    PremiumFeature.reorderWebsites => Icons.reorder_rounded,
    PremiumFeature.noShare => Icons.share_rounded,
    PremiumFeature.downloads => Icons.download_rounded,
    PremiumFeature.classicDrawer => Icons.menu_rounded,
    PremiumFeature.videoQuality => Icons.high_quality_rounded,
    PremiumFeature.amoled => Icons.dark_mode_rounded,
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _premium,
    builder: (context, _) {
      final owned = _premium.active;
      final price = _premium.price;
      return Scaffold(
        appBar: AppBar(title: const Text('BooruPlus Premium')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    color: accent,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                owned ? 'Premium is active' : 'Get more from BooruPlus',
                key: const ValueKey('premium_title'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: ink(.87),
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                owned
                    ? 'Thanks for supporting BooruPlus. Everything below is unlocked.'
                    : 'One purchase, yours to keep. No subscription.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ink(.54), fontSize: 14),
              ),
              const SizedBox(height: 24),
              const SectionLabel('Included'),
              const SizedBox(height: 8),
              for (final feature in PremiumFeature.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: panel,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(_icon(feature), color: accent, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              feature.title,
                              style: TextStyle(
                                color: ink(.87),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              feature.description,
                              style: TextStyle(color: ink(.54), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      if (owned)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.check_circle_rounded,
                            color: accent,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Without Premium: ads in the feed and booruShorts, one download at a time, and videos up to 720p.',
                style: TextStyle(color: ink(.38), fontSize: 12),
              ),
              const SizedBox(height: 24),
              if (!owned) ...[
                FilledButton(
                  key: const ValueKey('premium_buy'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _premium.busy || !_premium.available
                      ? null
                      : _premium.buy,
                  child: _premium.busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(
                          price == null
                              ? (_premium.available
                                    ? 'Get Premium'
                                    : 'Google Play is not available')
                              : 'Get Premium · $price',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _premium.busy ? null : _premium.restore,
                  child: const Text('Restore purchase'),
                ),
              ],
              if (_premium.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: accent, fontSize: 13),
                  ),
                ),
              if (kPlayEdition && !owned)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Paid once through Google Play. Restores on any device signed in to the same Google account.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink(.38), fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
