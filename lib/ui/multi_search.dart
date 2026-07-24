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

class _MultiSearchScreenState extends State<MultiSearchScreen> {
  late final MultiSiteSearch _search = widget.state.multiSiteSearch();
  final _scroll = ScrollController();
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
      setState(() {
        _available = boards;
        _chosen = boards.toSet();
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

  void _run() {
    if (_tags.isEmpty || _chosen.isEmpty) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _search.search(_tags, _available.where(_chosen.contains));
  }

  void _toggle(Board board, bool selected) {
    setState(() {
      if (selected) {
        _chosen.add(board);
      } else {
        _chosen.remove(board);
      }
    });
  }

  void _open(List<SavedPost> results, int index) {
    final displayed = [
      for (final saved in results) widget.state.displayReady(saved),
    ];
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MediaViewer(
          post: displayed[index].post,
          board: displayed[index].board,
          state: widget.state,
          savedPosts: displayed,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Search all sites')),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: TagInput(
                  tags: _tags,
                  onChanged: (tags) => setState(() => _tags = tags),
                  onSubmit: _run,
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
            'Enter tags, then search. Each website uses its own tag names, so results vary.',
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
                  : results.isEmpty
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
