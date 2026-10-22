import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'downloads.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'theme.dart';

enum _SavedSort { newest, oldest, score }

extension on _SavedSort {
  String get label => switch (this) {
    _SavedSort.newest => 'Recently saved',
    _SavedSort.oldest => 'Oldest saved',
    _SavedSort.score => 'Highest score',
  };
}

class SavedPostsScreen extends StatefulWidget {
  const SavedPostsScreen({super.key, required this.state, this.hidden = false});

  final AppState state;
  final bool hidden;

  @override
  State<SavedPostsScreen> createState() => _SavedPostsScreenState();
}

class _SavedPostsScreenState extends State<SavedPostsScreen> {
  final _search = TextEditingController();
  Board? _board;
  _SavedSort _sort = _SavedSort.newest;
  bool _selecting = false;
  // Identities, so a selection survives rebuilds and refreshed media URLs.
  final Set<String> _selected = {};

  AppState get _state => widget.state;
  bool get _hidden => widget.hidden;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Posts matching the website filter and the search, in the chosen order.
  /// Search terms match within tags; a leading `-` excludes, and `#123`
  /// finds a post ID.
  List<SavedPost> _visible(List<SavedPost> all) {
    final terms = _search.text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty && term != '-')
        .toList();
    bool matches(SavedPost saved) {
      if (_board != null && saved.board != _board) return false;
      final tags = saved.post.tags.map((tag) => tag.toLowerCase()).toList();
      for (final term in terms) {
        if (term.startsWith('#')) {
          if (saved.post.displayId.toLowerCase() != term.substring(1)) {
            return false;
          }
          continue;
        }
        final excluded = term.startsWith('-');
        final value = excluded ? term.substring(1) : term;
        final found = tags.any((tag) => tag.contains(value));
        if (found == excluded) return false;
      }
      return true;
    }

    final result = all.where(matches).toList();
    switch (_sort) {
      case _SavedSort.newest:
        return result.reversed.toList();
      case _SavedSort.oldest:
        return result;
      case _SavedSort.score:
        // A stable sort keeps the saved order among equal scores.
        final indexed = result.indexed.toList()
          ..sort((a, b) {
            final byScore = b.$2.post.score.compareTo(a.$2.post.score);
            return byScore == 0 ? a.$1.compareTo(b.$1) : byScore;
          });
        return [for (final entry in indexed) entry.$2];
    }
  }

  void _toggle(SavedPost saved) => setState(() {
    if (!_selected.remove(saved.identity)) _selected.add(saved.identity);
    _selecting = true;
  });

  void _endSelection() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  List<SavedPost> _selectedPosts(List<SavedPost> visible) =>
      visible.where((saved) => _selected.contains(saved.identity)).toList();

  void _notify(String message, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: duration ?? const Duration(seconds: 4),
        ),
      );
  }

  Future<void> _removeSelected(List<SavedPost> posts) async {
    if (posts.isEmpty) return;
    if (_hidden) {
      await _state.unhidePosts(posts);
    } else {
      await _state.unfavoritePosts(posts);
    }
    if (!mounted) return;
    _endSelection();
    _notify(
      _hidden
          ? 'Unhid ${_count(posts.length)}.'
          : 'Removed ${_count(posts.length)} from favorites.',
    );
  }

  Future<void> _unhideAll(List<SavedPost> all) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unhide all posts?'),
        content: Text('${_count(all.length)} will show in feeds again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unhide all'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _state.unhidePosts(all);
    _notify('Unhid ${_count(all.length)}.');
  }

  /// Queues the selected favorites in the Download Manager.
  Future<void> _downloadSelected(List<SavedPost> posts) async {
    if (posts.isEmpty) return;
    final queued = await queueDownloads(context, _state, posts);
    if (queued != null && mounted) _endSelection();
  }

  static String _count(int count) => '$count post${count == 1 ? '' : 's'}';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _state,
    builder: (context, _) {
      final all = _hidden ? _state.hiddenPosts : _state.favoritePosts;
      final present = {for (final saved in all) saved.identity};
      _selected.removeWhere((identity) => !present.contains(identity));
      final boards = listedBoards
          .where((board) => all.any((saved) => saved.board == board))
          .toList();
      if (_board != null && !boards.contains(_board)) _board = null;
      final visible = _visible(all);
      final selected = _selectedPosts(visible);
      return PopScope<void>(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _endSelection();
        },
        child: Scaffold(
          appBar: _selecting
              ? _selectionBar(visible, selected)
              : AppBar(
                  title: Text(_hidden ? 'Hidden posts' : 'Favorites'),
                  actions: [
                    if (visible.isNotEmpty)
                      IconButton(
                        tooltip: 'Select posts',
                        icon: const Icon(Icons.checklist_rounded),
                        onPressed: () => setState(() => _selecting = true),
                      ),
                    if (_hidden && all.isNotEmpty)
                      IconButton(
                        tooltip: 'Unhide all',
                        icon: const Icon(Icons.visibility_rounded),
                        onPressed: () => _unhideAll(all),
                      ),
                    const SizedBox(width: 4),
                  ],
                ),
          body: all.isEmpty
              ? Center(
                  child: Text(
                    _hidden ? 'No hidden posts.' : 'No favorites yet.',
                  ),
                )
              : Column(
                  children: [
                    _filters(boards, visible.length, all.length),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(
                                  'No saved posts match these filters.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: ink(.54)),
                                ),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 300,
                                    mainAxisExtent: 354,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              itemCount: visible.length,
                              itemBuilder: (context, index) {
                                final saved = visible[index];
                                return _SavedPostCard(
                                  state: _state,
                                  saved: saved,
                                  display: _state.displayReady(saved),
                                  hidden: _hidden,
                                  allPosts: visible,
                                  index: index,
                                  selecting: _selecting,
                                  selected: _selected.contains(saved.identity),
                                  onToggle: () => _toggle(saved),
                                );
                              },
                            ),
                    ),
                  ],
                ),
        ),
      );
    },
  );

  PreferredSizeWidget _selectionBar(
    List<SavedPost> visible,
    List<SavedPost> selected,
  ) {
    final allSelected = selected.length == visible.length;
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel selection',
        icon: const Icon(Icons.close_rounded),
        onPressed: _endSelection,
      ),
      title: Text('${selected.length} selected'),
      actions: [
        IconButton(
          tooltip: allSelected ? 'Clear selection' : 'Select all',
          icon: Icon(
            allSelected ? Icons.deselect_rounded : Icons.select_all_rounded,
          ),
          onPressed: () => setState(() {
            if (allSelected) {
              _selected.clear();
            } else {
              _selected.addAll(visible.map((saved) => saved.identity));
            }
          }),
        ),
        if (!_hidden)
          IconButton(
            tooltip: 'Download selected',
            icon: const Icon(Icons.download_outlined),
            onPressed: selected.isEmpty
                ? null
                : () => _downloadSelected(selected),
          ),
        IconButton(
          tooltip: _hidden ? 'Unhide selected' : 'Remove from favorites',
          icon: Icon(
            _hidden ? Icons.visibility_rounded : Icons.heart_broken_outlined,
          ),
          onPressed: selected.isEmpty ? null : () => _removeSelected(selected),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _filters(List<Board> boards, int shown, int total) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Filter by tag, -tag, or #id',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear filter',
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () => setState(_search.clear),
                  ),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              PopupMenuButton<_SavedSort>(
                tooltip: 'Sort saved posts',
                initialValue: _sort,
                onSelected: (sort) => setState(() => _sort = sort),
                itemBuilder: (_) => [
                  for (final sort in _SavedSort.values)
                    PopupMenuItem(value: sort, child: Text(sort.label)),
                ],
                child: Chip(
                  avatar: const Icon(Icons.sort_rounded, size: 17),
                  label: Text(_sort.label),
                ),
              ),
              if (boards.length > 1) ...[
                const SizedBox(width: 6),
                ChoiceChip(
                  label: const Text('All websites'),
                  selected: _board == null,
                  onSelected: (_) => setState(() => _board = null),
                ),
                for (final board in boards) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: Text(board.label),
                    selected: _board == board,
                    onSelected: (selected) =>
                        setState(() => _board = selected ? board : null),
                  ),
                ],
              ],
              const SizedBox(width: 10),
              Text(
                shown == total ? '$total' : '$shown of $total',
                style: TextStyle(color: ink(.38), fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SavedPostCard extends StatelessWidget {
  const _SavedPostCard({
    required this.state,
    required this.saved,
    required this.display,
    required this.hidden,
    required this.allPosts,
    required this.index,
    required this.selecting,
    required this.selected,
    required this.onToggle,
  });

  final AppState state;
  final SavedPost saved;
  final SavedPost display;
  final bool hidden;
  final List<SavedPost> allPosts;
  final int index;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final post = display.post;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              MediaTile(
                key: ValueKey(saved.identity),
                post: post,
                board: saved.board,
                isFavorite: !hidden,
                isDownloaded: state.isDownloaded(post, board: saved.board),
                blur: _shouldBlur(post),
                onTap: () {
                  if (selecting) {
                    onToggle();
                    return;
                  }
                  if (hidden) {
                    state.unhidePost(post, board: saved.board);
                    return;
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => MediaViewer(
                        post: post,
                        board: saved.board,
                        state: state,
                        savedPosts: allPosts,
                        initialIndex: index,
                      ),
                    ),
                  );
                },
                // Holding a favorite opens its preview; holding a hidden
                // post (which has no preview) starts a selection.
                onLongPress: hidden && !selecting ? onToggle : null,
                onLongPressOrigin: hidden || selecting
                    ? null
                    : (origin, controller) => showQuickPostActions(
                        context,
                        post: post,
                        board: saved.board,
                        state: state,
                        isFavorite: state.isFavorite(post, board: saved.board),
                        controller: controller,
                        origin: origin,
                      ),
              ),
              if (selecting)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: .22)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: selected
                          ? Border.all(color: accent, width: 3)
                          : null,
                    ),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: selected ? accent : Colors.white70,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text(
          post.description.isEmpty ? 'No description' : post.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: ink(.70)),
        ),
        const SizedBox(height: 3),
        Text(
          'Website: ${saved.board.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            color: accent,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (post.source.trim().isNotEmpty)
          Text(
            'Source: ${post.source}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: ink(.54)),
          ),
        if (hidden && !selecting)
          TextButton.icon(
            onPressed: () => state.unhidePost(post, board: saved.board),
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.visibility, size: 16),
            label: const Text('Unhide'),
          ),
      ],
    );
  }

  bool _shouldBlur(MediaPost post) {
    final rating = post.rating.trim().toLowerCase();
    if (rating.contains('explicit') || rating == 'e') {
      return state.settings.blurExplicit;
    }
    return (rating.contains('questionable') || rating == 'q') &&
        state.settings.blurQuestionable;
  }
}
