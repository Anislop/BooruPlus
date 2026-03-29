import 'package:flutter/material.dart';

import '../core/models.dart';
import 'site_catalog.dart';

// Default palette sampled from the supplied BooruPlus app icon. Per-site
// accents and dark surfaces live in site_catalog.dart.
const accent = Color(0xFFF20B3D);
const canvas = Color(0xFF2A2227);
const panel = Color(0xFF352A30);

ThemeData buildAppTheme({Board? board}) {
  final appearance = board == null ? null : appearanceFor(board);
  final primary = appearance?.accent ?? accent;
  final background = appearance?.surface ?? canvas;
  final surface = Color.lerp(background, Colors.white, .055)!;
  final scheme = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: Brightness.dark,
    surface: background,
    primary: primary,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
    ),
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
