import 'package:flutter/material.dart';

const accent = Color(0xFFB8F3D3);
const canvas = Color(0xFF101413);
const panel = Color(0xFF1B211F);

final appTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: canvas,
  colorScheme: ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    surface: canvas,
    primary: accent,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: canvas,
    surfaceTintColor: Colors.transparent,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: panel,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
  ),
  snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  dividerTheme: const DividerThemeData(color: Color(0xFF303A35)),
);

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 42});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: accent,
      borderRadius: BorderRadius.circular(size * .29),
    ),
    child: Icon(Icons.grid_view_rounded, size: size * .6, color: canvas),
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
      style: const TextStyle(
        color: accent,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
      ),
    ),
  );
}
