import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'site_catalog.dart';
import 'tag_input.dart';
import 'theme.dart';

/// Searches several websites at once and shows one merged feed.
class MultiSearchScreen extends StatefulWidget {
  const MultiSearchScreen({
    super.key,
    required this.state,
    this.initialTags = const [],
  });
  final AppState state;
  final List<String> initialTags;

  @override
  State<MultiSearchScreen> createState() => _MultiSearchScreenState();
}

/// A search to return to with back, like the feed's search history.
class _HistoryEntry {
  _HistoryEntry(this.tags, {this.search, this.offset = 0, this.viewer});
  final List<String> tags;

  /// The loaded results, so back restores them instead of searching again.
  /// Only the newest entries keep one.
  MultiSiteSearchSnapshot? search;
  final double offset;

  /// The viewer a tag was chosen in, reopened at that post on back.
  final ({List<SavedPost> posts, int index})? viewer;
}

class _MultiSearchScreenState extends State<MultiSearchScreen> {
  static const _restorableEntries = 5;
  late final MultiSiteSearch _search = widget.state.multiSiteSearch();
  final _scroll = ScrollController();
  final _history = <_HistoryEntry>[];
  late List<String> _tags = List.of(widget.initialTags);
  // Websites that can search now, and those chosen for this search.
  List<Board> _available = const [];
  Set<Board> _chosen = {};
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 700) _search.loadMore();
    });
    final visible = widget.state.settings.visibleBoards;
    widget.state.searchableBoards(among: visible).then((boards) {
      if (!mounted) return;
      // Starts with the websites switched off last time still off.
      final off = widget.state.settings.multiSearchOff;
      setState(() {
        _available = boards;
        _chosen = boards.where((board) => !off.contains(board)).toSet();
        _ready = true;
      });
      if (_tags.isNotEmpty) _run();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Searches [_tags]. The search shown before it is kept, so back
  /// returns to it; [viewer] is the viewer a tag was chosen in.
  void _run({({List<SavedPost> posts, int index})? viewer}) {
    if (_tags.isEmpty || _chosen.isEmpty) return;
    final current = _search.tags;
    if (current.isNotEmpty && !_sameQuery(current, _tags)) {
      setState(() {
        _history.add(
          _HistoryEntry(
            current,
            search: _search.snapshot(),
            offset: _scroll.hasClients ? _scroll.offset : 0,
            viewer: viewer,
          ),
        );
        // Older entries search again rather than holding their results.
        final stale = _history.length - _restorableEntries;
        for (var i = 0; i < stale; i++) {
          _history[i].search = null;
        }
      });
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.state.recordMultiSearch(_tags);
    _search.search(_tags, _available.where(_chosen.contains));
  }

  bool _sameQuery(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Returns to the previous search, at the scroll position it was left,
  /// and reopens the viewer it was left from.
  void _back() {
    if (_history.isEmpty) return;
    final previous = _history.removeLast();
    setState(() => _tags = List.of(previous.tags));
    final boards = _available.where(_chosen.contains);
    final snapshot = previous.search;
    if (snapshot != null) {
      _search.restore(snapshot, boards);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(
          previous.offset.clamp(0.0, _scroll.position.maxScrollExtent),
        );
      });
    } else {
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _search.search(previous.tags, boards);
    }
    final viewer = previous.viewer;
    if (viewer != null) _openViewer(viewer.posts, viewer.index);
  }

  /// Recent searches on all sites; one can be searched again or swiped
  /// away.
  Future<void> _showHistory() async {
    final state = widget.state;
    final query = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final history = state.multiSearchHistory;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .75,
              ),
              child: history.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        state.settings.incognito
                            ? 'Incognito is on, so searches are not recorded.'
                            : 'No recent searches yet. Searches on all sites appear here.',
                      ),
                    )
                  : ListView(
                      key: const ValueKey('multi_search_history'),
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          title: const Text('Recent searches'),
                          subtitle: const Text(
                            'Swipe a search away to delete it',
                          ),
                          leading: const Icon(Icons.history_rounded),
                          trailing: TextButton(
                            key: const ValueKey('multi_search_history_clear'),
                            onPressed: state.clearMultiSearchHistory,
                            child: const Text('Clear'),
                          ),
                        ),
                        for (final query in history)
                          Dismissible(
                            key: ValueKey('multi_history:${query.join(' ')}'),
                            background: _dismissBackground(
                              AlignmentDirectional.centerStart,
                            ),
                            secondaryBackground: _dismissBackground(
                              AlignmentDirectional.centerEnd,
                            ),
                            onDismissed: (_) => state.removeMultiSearch(query),
                            child: ListTile(
                              leading: const Icon(Icons.history_rounded),
                              title: Text(query.join(' ')),
                              onTap: () => Navigator.pop(context, query),
                            ),
                          ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
    if (query == null || !mounted) return;
    setState(() => _tags = List.of(query));
    _run();
  }

  Widget _dismissBackground(AlignmentGeometry alignment) => Container(
    color: accent.withValues(alpha: .18),
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Icon(Icons.delete_outline, color: ink(.70)),
  );

  /// Switching a website applies to the current results at once: its
  /// posts are hidden or shown, and loading more asks only the websites
  /// switched on. The choice is saved for the next search.
  void _toggle(Board board, bool selected) {
    setState(() {
      if (selected) {
        _chosen.add(board);
      } else {
        _chosen.remove(board);
      }
    });
    // Websites not offered now (signed out, hidden) keep their saved state.
    final off = {
      ...widget.state.settings.multiSearchOff.where(
        (other) => !_available.contains(other),
      ),
      ..._available.where((other) => !_chosen.contains(other)),
    };
    widget.state.setMultiSearchOff(off);
    if (_search.tags.isNotEmpty) {
      _search.setEnabled(_available.where(_chosen.contains));
    }
  }

  /// The website that suggests tags while typing: the current one when it
  /// is switched on, otherwise the first switched-on one with suggestions.
  Board? get _suggestingBoard {
    final chosen = _available.where(_chosen.contains).toList();
    final current = widget.state.board;
    if (current != null && current.suggestsTags && chosen.contains(current)) {
      return current;
    }
    return chosen.where((board) => board.suggestsTags).firstOrNull;
  }

  Future<List<TagSuggestion>> _autocomplete(String query) async {
    final board = _suggestingBoard;
    if (board == null) return const [];
    return widget.state.autocomplete(query, from: board);
  }

  /// Opens the viewer; a tag chosen there is searched here.
  Future<void> _open(List<SavedPost> results, int index) => _openViewer([
    for (final saved in results) widget.state.displayReady(saved),
  ], index);

  Future<void> _openViewer(List<SavedPost> displayed, int index) async {
    final result = await Navigator.push<ViewerTagBrowse>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewer(
          post: displayed[index].post,
          board: displayed[index].board,
          state: widget.state,
          savedPosts: displayed,
          initialIndex: index,
          allSites: true,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _tags = [result.tag]);
    _run(viewer: (posts: displayed, index: result.index));
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    // Back returns to the previous search first, like the feed.
    canPop: _history.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: _scaffold(context),
  );

  Widget _scaffold(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Search all sites'),
      actions: [
        IconButton(
          key: const ValueKey('multi_search_history_button'),
          tooltip: 'Recent searches',
          icon: const Icon(Icons.history_rounded),
          onPressed: _showHistory,
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: TagInput(
                  tags: _tags,
                  onChanged: (tags) => setState(() => _tags = tags),
                  onSubmit: _run,
                  autocomplete: _autocomplete,
                  postCount: (tag) => switch (_suggestingBoard) {
                    final board? => widget.state.postCountFor(
                      tag,
                      board: board,
                    ),
                    null => null,
                  },
                  hint: 'Tags to search on every website',
                ),
              ),
            ),
          ),
          if (!_ready)
            const LinearProgressIndicator(minHeight: 2)
          else if (_available.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No website can search right now. Sign in to one in Settings.',
                style: TextStyle(color: ink(.54)),
              ),
            )
          else
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final board in _available)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        avatar: SiteLogo(board, size: 18),
                        label: Text(board.label),
                        selected: _chosen.contains(board),
                        onSelected: (value) => _toggle(board, value),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: _search,
              builder: (context, _) => _results(context),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _results(BuildContext context) {
    final state = widget.state;
    final results = _search.results;
    final errors = _search.errors;
    if (_search.tags.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Enter tags, then search. Some websites have their own tag systems, so results may vary.',
            textAlign: TextAlign.center,
            style: TextStyle(color: ink(.54)),
          ),
        ),
      );
    }
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (errors.isNotEmpty)
          SliverToBoxAdapter(
            child: ExpansionTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: Text(
                '${errors.length} website${errors.length == 1 ? '' : 's'} stopped',
              ),
              children: [
                for (final MapEntry(key: board, value: message)
                    in errors.entries)
                  ListTile(
                    dense: true,
                    leading: SiteLogo(board, size: 22),
                    title: Text(board.label),
                    subtitle: Text(message),
                  ),
              ],
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: state.settings.columns,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final saved = state.displayReady(results[index]);
              return Stack(
                fit: StackFit.expand,
                children: [
                  MediaTile(
                    key: ValueKey(saved.identity),
                    post: saved.post,
                    board: saved.board,
                    hidePostTags: true,
                    isFavorite: state.isFavorite(
                      saved.post,
                      board: saved.board,
                    ),
                    isDownloaded: state.isDownloaded(
                      saved.post,
                      board: saved.board,
                    ),
                    blur: shouldBlurPost(state, saved.post),
                    onTap: () => _open(results, index),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: IgnorePointer(
                      child: SiteLogo(saved.board, size: 20, showBorder: true),
                    ),
                  ),
                ],
              );
            }, childCount: results.length),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: _search.loading
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : results.isEmpty && !_search.hasMore
                  ? Text(
                      'No matching media on these websites.',
                      style: TextStyle(color: ink(.54)),
                    )
                  : _search.hasMore
                  ? TextButton.icon(
                      onPressed: _search.loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Load more'),
                    )
                  : Text(
                      'You’re all caught up',
                      style: TextStyle(color: ink(.38)),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
