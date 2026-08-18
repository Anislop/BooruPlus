import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/models.dart';
import 'site_catalog.dart';

// Default palette sampled from the supplied BooruPlus app icon. Per-site
// accents and dark surfaces live in site_catalog.dart.
const accent = Color(0xFFF20B3D);
const _darkCanvas = Color(0xFF2A2227);
const _darkPanel = Color(0xFF352A30);
const _amoledPanel = Color(0xFF141114);
const _lightCanvas = Color(0xFFF6F2F4);

ThemeChoice _palette = ThemeChoice.standard;

/// The active palette.
ThemeChoice get palette => _palette;

/// Whether the white palette is active, so text and icons are dark.
bool get lightPalette => _palette == ThemeChoice.white;

/// Switches the palette read by [canvas], [panel], [appBarSurface], [ink],
/// and [tagTone]. Widgets read it directly, so the caller rebuilds the whole
/// tree.
void setPalette(ThemeChoice choice) => _palette = choice;

double _surfaceOpacity = .8;
double _panelOpacity = .8;
double _detailsOpacity = .8;
double _surfaceBlur = 16;

/// Opacity (0-1) of the drawer's frosted website list, from
/// [AppSettings.surfaceOpacity]; the default for a [FrostedSurface].
double get surfaceOpacity => _surfaceOpacity;

/// Opacity (0-1) of the one-handed panel, from [AppSettings.panelOpacity].
double get panelSurfaceOpacity => _panelOpacity;

/// Opacity (0-1) of the viewer's details, from
/// [AppSettings.detailsOpacity].
double get detailsSurfaceOpacity => _detailsOpacity;

/// Blur radius behind the frosted surfaces; 0 turns blurring off.
double get surfaceBlur => _surfaceBlur;

/// Applies the frosted-surface opacities and [blur] to every
/// [FrostedSurface]. Like [setPalette], widgets read them directly.
void setSurfaceGlass({
  required int opacity,
  required int panelOpacity,
  required int detailsOpacity,
  required int blur,
}) {
  _surfaceOpacity = opacity.clamp(20, 100) / 100;
  _panelOpacity = panelOpacity.clamp(20, 100) / 100;
  _detailsOpacity = detailsOpacity.clamp(20, 100) / 100;
  _surfaceBlur = blur.clamp(0, 30).toDouble();
}

/// Page background: the BooruPlus dark tone, near-white, or black for AMOLED
/// screens.
Color get canvas => switch (_palette) {
  ThemeChoice.standard => _darkCanvas,
  ThemeChoice.white => _lightCanvas,
  ThemeChoice.amoled => Colors.black,
};

/// Raised surfaces such as cards, sheets, and the viewer's details panel.
Color get panel => switch (_palette) {
  ThemeChoice.standard => _darkPanel,
  ThemeChoice.white => Colors.white,
  ThemeChoice.amoled => _amoledPanel,
};

/// The app bar color for [board]: its site tone, a pale tint of its accent
/// in the white theme, or black for AMOLED.
Color appBarSurface(Board board) => switch (_palette) {
  ThemeChoice.standard => appearanceFor(board).surface,
  ThemeChoice.white => Color.lerp(
    appearanceFor(board).accent,
    Colors.white,
    .8,
  )!,
  ThemeChoice.amoled => Colors.black,
};

/// Secondary text and icons over [canvas] or [panel] at [opacity]: white
/// on the dark palettes, black on the white one.
Color ink(double opacity) =>
    (lightPalette ? Colors.black : Colors.white).withValues(alpha: opacity);

/// [color] (a pastel tag-category color) darkened enough to read on the
/// white palette.
Color tagTone(Color color) =>
    lightPalette ? Color.lerp(color, Colors.black, .45)! : color;

/// The full BooruPlus logo for the current palette.
String get logoAsset =>
    lightPalette ? 'assets/LogoFullColor.png' : 'assets/LogoFullColorWhite.png';

ThemeData buildAppTheme({Board? board}) {
  // Site colors belong to the app bar. Keep the rest of the application on
  // the BooruPlus palette so switching boards does not recolor every tab.
  const primary = accent;
  final background = canvas;
  final appBarColor = board == null ? canvas : appBarSurface(board);
  final brightness = lightPalette ? Brightness.light : Brightness.dark;
  final surface = Color.lerp(
    background,
    lightPalette ? Colors.black : Colors.white,
    lightPalette ? .045 : .055,
  )!;
  final scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
    surface: background,
    primary: primary,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: background,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(
      backgroundColor: appBarColor,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
    ),
    drawerTheme: DrawerThemeData(backgroundColor: canvas),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: panel),
    dialogTheme: DialogThemeData(backgroundColor: panel),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(color: primary.withValues(alpha: .2)),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: primary.withValues(alpha: .22),
      side: BorderSide(color: primary.withValues(alpha: .18)),
      labelStyle: TextStyle(color: scheme.onSurface),
    ),
  );
}

final appTheme = buildAppTheme();

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 42});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: canvas,
      borderRadius: BorderRadius.circular(size * .29),
      border: Border.all(color: accent.withValues(alpha: .24)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Image.asset('assets/AppIcon.png', fit: BoxFit.cover),
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
      ),
    ),
  );
}

/// [color] at the user's surface opacity (or [opacity], 0-1, when given)
/// over a blur of whatever lies behind, so the feed or the image shows
/// through. Fully opaque surfaces
/// skip the blur, which would be invisible and still cost a pass. While
/// [active] is false the surface is transparent and blurs nothing; the
/// widget tree stays the same so toggling keeps the child's state.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    super.key,
    required this.color,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.active = true,
    this.opacity,
  });
  final Color color;
  final Widget child;
  final BorderRadius borderRadius;
  final bool active;
  final double? opacity;

  @override
  Widget build(BuildContext context) {
    final opacity = this.opacity ?? surfaceOpacity;
    final blur = surfaceBlur;
    final frosted = active && opacity < 1 && blur > 0;
    final rounded = borderRadius != BorderRadius.zero;
    return ClipRRect(
      borderRadius: borderRadius,
      clipBehavior: frosted || rounded ? Clip.antiAlias : Clip.none,
      child: BackdropFilter(
        enabled: frosted,
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Material(
          color: active
              ? color.withValues(alpha: color.a * opacity)
              : Colors.transparent,
          borderRadius: borderRadius,
          child: child,
        ),
      ),
    );
  }
}

/// Reports its child's height after layout whenever it changes.
class SizeReporter extends SingleChildRenderObjectWidget {
  const SizeReporter({super.key, required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderSizeReporter).onHeight = onHeight;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onHeight);
  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Layout cannot rebuild widgets; report once this frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
