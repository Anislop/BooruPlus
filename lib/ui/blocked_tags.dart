import 'package:flutter/material.dart';

import '../core/models.dart';
import 'site_catalog.dart';
import 'tag_input.dart';
import 'theme.dart';

/// Blocked tags for every website and per website, edited as a draft.
class BlockedTags {
  const BlockedTags({required this.all, required this.byBoard});
  final List<String> all;
  final Map<Board, List<String>> byBoard;
}

/// One scrolling list: tags blocked on every website first, then a section
/// per website. Leaving the screen returns the edited [BlockedTags]; the
/// settings screen saves them with its other preferences.
class BlockedTagsScreen extends StatefulWidget {
  const BlockedTagsScreen({
    super.key,
    required this.initial,
    required this.boards,
  });
  final BlockedTags initial;

  /// Websites in display order.
  final List<Board> boards;

  @override
  State<BlockedTagsScreen> createState() => _BlockedTagsScreenState();
}

class _BlockedTagsScreenState extends State<BlockedTagsScreen> {
  late List<String> _all = widget.initial.all;
  late final Map<Board, List<String>> _byBoard = {...widget.initial.byBoard};
  final _allKey = GlobalKey<TagInputState>();
  final _boardKeys = <Board, GlobalKey<TagInputState>>{};

  GlobalKey<TagInputState> _keyFor(Board board) =>
      _boardKeys.putIfAbsent(board, GlobalKey<TagInputState>.new);

  /// Commits unfinished input so a typed tag is not lost on leaving.
  BlockedTags _result() {
    _allKey.currentState?.commit();
    for (final key in _boardKeys.values) {
      key.currentState?.commit();
    }
    return BlockedTags(all: _all, byBoard: Map.unmodifiable(_byBoard));
  }

  Widget _section({
    required Widget leading,
    required String title,
    required String subtitle,
    required Widget input,
  }) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: ink(.54), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        input,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope<BlockedTags>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) Navigator.pop(context, _result());
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Blocked tags')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            // Not lazy: every section stays built, so unfinished input in
            // any of them is committed on leaving.
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Blocked tags are added to every query and filtered from returned posts. Enter a tag, then press space.',
                    style: TextStyle(
                      color: ink(.54),
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                  _section(
                    leading: const Icon(Icons.public_rounded, color: accent),
                    title: 'All websites',
                    subtitle: 'Blocked on every website.',
                    input: TagInput(
                      key: _allKey,
                      tags: _all,
                      hint: 'Block a tag everywhere',
                      searchStyle: false,
                      onChanged: (tags) => setState(() => _all = tags),
                    ),
                  ),
                  const SectionLabel('Websites'),
                  for (final board in widget.boards)
                    _section(
                      leading: SiteLogo(board, size: 28, colored: true),
                      title: appearanceFor(board).name,
                      subtitle: (_byBoard[board] ?? const []).isEmpty
                          ? 'Only the tags blocked on all websites.'
                          : 'These apply on ${board.label} only.',
                      input: TagInput(
                        key: _keyFor(board),
                        tags: _byBoard[board] ?? const [],
                        hint: 'Block a tag on ${board.label}',
                        searchStyle: false,
                        onChanged: (tags) =>
                            setState(() => _byBoard[board] = tags),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
