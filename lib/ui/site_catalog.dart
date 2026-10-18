import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'theme.dart';

/// Presentation settings for each supported imageboard.
///
/// Keep this map data-only so changing a site's accent or dark surface does
/// not require touching the browsing UI. These are intentionally darkened
/// values so white text remains readable in the app chrome.
class BoardAppearance {
  const BoardAppearance({
    required this.name,
    required this.icon,
    required this.accent,
    required this.surface,
    this.logoUrl,
    this.logoAsset,
  });

  final String name;
  final IconData icon;
  final Color accent;
  final Color surface;
  final String? logoUrl;
  final String? logoAsset;
}

const _defaults = <Board, BoardAppearance>{
  Board.safebooru: BoardAppearance(
    name: 'Safebooru',
    icon: Icons.shield_outlined,
    accent: Color(0xFF63B5E8),
    surface: Color(0xFF172A35),
  ),
  Board.danbooru: BoardAppearance(
    name: 'Danbooru',
    icon: Icons.palette_outlined,
    accent: Color(0xFFE8A16B),
    surface: Color(0xFF35251D),
  ),
  Board.konachan: BoardAppearance(
    name: 'Konachan',
    icon: Icons.cloud_outlined,
    accent: Color(0xFF75C1E5),
    surface: Color(0xFF182C35),
  ),
  Board.yandere: BoardAppearance(
    name: 'Yande.re',
    icon: Icons.favorite_border,
    accent: Color(0xFFE27B9B),
    surface: Color(0xFF351F29),
  ),
  Board.e926: BoardAppearance(
    name: 'e926',
    icon: Icons.pets_outlined,
    accent: Color(0xFF8DB9DE),
    surface: Color(0xFF1E2B38),
  ),
  Board.e621: BoardAppearance(
    name: 'e621',
    icon: Icons.pets,
    accent: Color(0xFFE49A62),
    surface: Color(0xFF38271E),
  ),
  Board.gelbooru: BoardAppearance(
    name: 'Gelbooru',
    icon: Icons.bubble_chart_outlined,
    accent: Color(0xFFB59AE5),
    surface: Color(0xFF2B223A),
  ),
  Board.rule34: BoardAppearance(
    name: 'Rule34',
    icon: Icons.public,
    accent: Color(0xFF9EAEE3),
    surface: Color(0xFF22283B),
  ),
  Board.sankaku: BoardAppearance(
    name: 'Sankaku Complex',
    icon: Icons.local_fire_department_outlined,
    accent: Color(0xFFF2A25C),
    surface: Color(0xFF3A2616),
  ),
  Board.idolcomplex: BoardAppearance(
    name: 'Idol Complex',
    icon: Icons.photo_camera_outlined,
    accent: Color(0xFFE88BB5),
    surface: Color(0xFF3A1A2A),
  ),
  Board.tbib: BoardAppearance(
    name: 'TBIB',
    icon: Icons.collections_outlined,
    accent: Color(0xFF7CC48A),
    surface: Color(0xFF1B2E22),
  ),
  Board.aibooru: BoardAppearance(
    name: 'AIBooru',
    icon: Icons.auto_awesome_outlined,
    accent: Color(0xFF5FD3C6),
    surface: Color(0xFF163330),
  ),
  Board.nozomi: BoardAppearance(
    name: 'Nozomi',
    icon: Icons.wb_sunny_outlined,
    accent: Color(0xFFE6C65C),
    surface: Color(0xFF352E16),
  ),
  Board.sakugabooru: BoardAppearance(
    name: 'Sakugabooru',
    icon: Icons.movie_filter_outlined,
    accent: Color(0xFFE88A6E),
    surface: Color(0xFF38211A),
  ),
  Board.xbooru: BoardAppearance(
    name: 'XBooru',
    icon: Icons.grid_view_outlined,
    accent: Color(0xFFD98AA8),
    surface: Color(0xFF361E28),
  ),
  Board.mspabooru: BoardAppearance(
    name: 'MSPABooru',
    icon: Icons.menu_book_outlined,
    accent: Color(0xFF7DD36F),
    surface: Color(0xFF1C3119),
  ),
  Board.eshuushuu: BoardAppearance(
    name: 'E-Shuushuu',
    icon: Icons.brush_outlined,
    accent: Color(0xFF8FB4E6),
    surface: Color(0xFF1D2838),
  ),
  Board.mikubooru: BoardAppearance(
    name: 'Mikubooru',
    icon: Icons.music_note_outlined,
    accent: Color(0xFF5CCFD0),
    surface: Color(0xFF163233),
  ),
  Board.nanbooru: BoardAppearance(
    name: 'Nanbooru',
    icon: Icons.smart_toy_outlined,
    accent: Color(0xFFB79CE8),
    surface: Color(0xFF2A2238),
  ),
};

final boardAppearances = <Board, BoardAppearance>{..._defaults};

Future<void> loadSiteCatalog() async {
  try {
    final decoded = jsonDecode(
      await rootBundle.loadString('assets/site_config.json'),
    );
    if (decoded is! Map || decoded['sites'] is! Map) return;
    final sites = decoded['sites'] as Map;
    for (final board in Board.values) {
      final raw = sites[board.name];
      if (raw is! Map) continue;
      final fallback = _defaults[board]!;
      boardAppearances[board] = BoardAppearance(
        name: _string(raw['name'], fallback.name),
        icon: fallback.icon,
        accent: _color(raw['accent'], fallback.accent),
        surface: _color(raw['surface'], fallback.surface),
        logoUrl: _optionalString(raw['logoUrl']),
        logoAsset: _optionalString(raw['logoAsset']),
      );
    }
  } catch (_) {}
}

BoardAppearance appearanceFor(Board board) => boardAppearances[board]!;

class BoardIcon extends StatelessWidget {
  const BoardIcon(this.board, {super.key, this.size = 42});

  final Board board;
  final double size;

  @override
  Widget build(BuildContext context) => SiteLogo(board, size: size);
}

class SiteLogo extends StatelessWidget {
  const SiteLogo(
    this.board, {
    super.key,
    this.size = 30,
    this.colored = false,
    this.showBorder = false,
  });
  final Board board;
  final double size;
  final bool colored;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final appearance = appearanceFor(board);
    final fallback = Icon(
      appearance.icon,
      size: showBorder ? size * .55 : size * .75,
      color: colored ? appearance.accent : ink(.70),
    );
    final image = appearance.logoAsset?.isNotEmpty == true
        ? Image.asset(
            appearance.logoAsset!,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => fallback,
          )
        : appearance.logoUrl?.isNotEmpty == true
        ? Image.network(
            appearance.logoUrl!,
            width: size,
            height: size,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : fallback,
            errorBuilder: (_, _, _) => fallback,
          )
        : fallback;

    if (showBorder) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colored ? appearance.surface : ink(.04),
          borderRadius: BorderRadius.circular(size * .24),
          border: Border.all(
            color: colored
                ? appearance.accent.withValues(alpha: .32)
                : ink(.12),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: EdgeInsets.all(size * .14), child: image),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: Center(child: image),
    );
  }
}

String _string(dynamic value, String fallback) =>
    value is String && value.trim().isNotEmpty ? value.trim() : fallback;
String? _optionalString(dynamic value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
Color _color(dynamic value, Color fallback) {
  if (value is! String) return fallback;
  final hex = value.replaceFirst('#', '');
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null || (hex.length != 6 && hex.length != 8)) return fallback;
  return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
}
