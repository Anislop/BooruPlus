import 'package:flutter/material.dart';

import '../core/models.dart';

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
  });

  final String name;
  final IconData icon;
  final Color accent;
  final Color surface;
}

const boardAppearances = <Board, BoardAppearance>{
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
};

BoardAppearance appearanceFor(Board board) => boardAppearances[board]!;

class BoardIcon extends StatelessWidget {
  const BoardIcon(this.board, {super.key, this.size = 42});

  final Board board;
  final double size;

  @override
  Widget build(BuildContext context) {
    final appearance = appearanceFor(board);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: appearance.surface,
        borderRadius: BorderRadius.circular(size * .28),
        border: Border.all(color: appearance.accent.withValues(alpha: .28)),
      ),
      child: Icon(appearance.icon, size: size * .52, color: appearance.accent),
    );
  }
}
