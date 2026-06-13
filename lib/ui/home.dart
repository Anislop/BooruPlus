import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'media_viewer.dart';
import 'media_image.dart';
import 'search_guide.dart';
import 'settings.dart';
import 'saved_posts.dart';
import 'site_catalog.dart';
import 'tag_input.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});
  final AppState state;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scroll = ScrollController();
  final _searchHistory = <List<String>>[];
  bool _drawerOpen = false;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 700 && widget.state.error == null) {
        widget.state.loadMore();
      }
    });
    widget.state.addListener(_showNotice);
  }

  @override
  void dispose() {
    widget.state.removeListener(_showNotice);
    _scroll.dispose();
    super.dispose();
  }

  void _showNotice() {
    if (!mounted) return;
    final notice = widget.state.takeNotice();
    if (notice == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }

  void _search(List<String> tags) {
    final next = List<String>.unmodifiable(tags);
    if (!_sameQuery(widget.state.tags, next) &&
        (_searchHistory.isEmpty ||
            !_sameQuery(_searchHistory.last, widget.state.tags))) {
      _searchHistory.add(List<String>.unmodifiable(widget.state.tags));
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.state.search(next);
  }

  bool _sameQuery(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _handleBack() {
    if (_searchHistory.isEmpty) return;
    final previous = _searchHistory.removeLast();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.state.search(previous);
  }

  Future<void> _saveAndShowQueries() async {
    if (widget.state.tags.isNotEmpty) {
      await widget.state.addSavedQuery(widget.state.tags);
    }
    if (mounted) await _showSavedQueries();
  }

  Future<void> _showSavedQueries() async {
    await _showQueryPopup(
      title: 'Saved searches',
      headerIcon: Icons.bookmarks_outlined,
      queries: widget.state.savedQueries,
      emptyMessage: 'No saved searches yet. Search tags, then tap the bookmark to save them.',
      deleteTooltip: 'Delete saved search',
      onDelete: widget.state.removeSavedQuery,
    );
  }

  Future<void> _showRecentSearches() async {
    await _showQueryPopup(
      title: 'Recent searches',
      headerIcon: Icons.history_rounded,
      queries: widget.state.recentSearches,
      emptyMessage:
          'No recent searches yet. Search tags to build your history.',
      deleteTooltip: 'Delete recent search',
      onDelete: widget.state.removeRecentSearch,
    );
  }

  Future<void> _showQueryPopup({
    required String title,
    required IconData headerIcon,
    required List<List<String>> queries,
    required String emptyMessage,
    required String deleteTooltip,
    required Future<void> Function(List<String>) onDelete,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: queries.isEmpty
            ? Padding(padding: EdgeInsets.all(28), child: Text(emptyMessage))
            : ListView(
                shrinkWrap: true,
                children: [
                  ListTile(title: Text(title), leading: Icon(headerIcon)),
                  for (final query in queries)
                    ListTile(
                      title: Text(query.join(' ')),
                      leading: const Icon(Icons.search_rounded),
                      onTap: () {
                        Navigator.pop(context);
                        _search(query);
                      },
                      trailing: IconButton(
                        tooltip: deleteTooltip,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await onDelete(query);
                          if (context.mounted) Navigator.pop(context);
                        },
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final board = widget.state.board;
    if (board == null) return;
    if (board == Board.gelbooru || board == Board.rule34) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This website does not expose date searches; use newest/oldest sorting instead.',
          ),
        ),
      );
      return;
    }
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    String day(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final value = day(date);
    final dateTag = switch (board) {
      Board.danbooru => 'date:>=$value',
      // Sankaku rejects open-ended dates; close the range after today.
      Board.sankaku =>
        'date:${value}T00:00..${day(DateTime.now().add(const Duration(days: 1)))}T00:00',
      _ => 'created_at:>=$value',
    };
    _search([
      ...widget.state.tags.where(
        (tag) => !tag.startsWith('created_at:') && !tag.startsWith('date:'),
      ),
      dateTag,
    ]);
  }

  void _chooseFilter(String filter) {
    final board = widget.state.board;
    if (board == null) return;
    final tags = widget.state.tags
        .where((tag) => !tag.startsWith('order:') && !tag.startsWith('sort:'))
        .toList();
    final sort = _sortTag(board, filter);
    _search(sort == null ? tags : [...tags, sort]);
  }

  Future<void> _chooseRatings() async {
    var selected = widget.state.selectedRatings.toSet();
    final result = await showModalBottomSheet<Set<Rating>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                leading: Icon(Icons.filter_alt_outlined),
                title: Text('Ratings'),
                subtitle: Text('Choose which ratings appear in the feed'),
              ),
              for (final rating in Rating.values)
                CheckboxListTile(
                  title: Text(rating.label),
                  value: selected.contains(rating),
                  onChanged: (value) => setSheetState(() {
                    if (value == true) {
                      selected.add(rating);
                    } else {
                      selected.remove(rating);
                    }
                  }),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, selected),
                    child: const Text('Apply'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (result != null && mounted) await widget.state.setRatingFilters(result);
  }

  String? _sortTag(Board board, String filter) {
    if (filter == 'none') return null;
    final gelbooruSyntax = board == Board.gelbooru || board == Board.rule34;
    if (gelbooruSyntax) {
      return switch (filter) {
        'score' => 'sort:score',
        'quality' => 'sort:width:desc',
        'newest' => 'sort:id:desc',
        'oldest' => 'sort:id:asc',
        // Gelbooru does not expose a favorites ordering in its search syntax.
        'favorites' => 'sort:score',
        _ => null,
      };
    }
    if (board == Board.sankaku) {
      return switch (filter) {
        'score' => 'order:popularity',
        'quality' => 'order:quality',
        'newest' => 'order:id_desc',
        'oldest' => 'order:id_asc',
        // Sankaku times out on favorite-count ordering.
        'favorites' => 'order:popularity',
        _ => null,
      };
    }
    return switch (filter) {
      'score' => 'order:score',
      'favorites' => 'order:favcount',
      'quality' => 'order:mpixels',
      'newest' => 'order:id_desc',
      'oldest' => 'order:id_asc',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => _build(context),
  );

  Widget _tile(
    BuildContext context,
    AppState state,
    List<MediaPost> posts,
    Board board,
    int index,
    bool hidePostTags,
  ) {
    final post = state.displayPost(posts[index], board: board);
    return MediaTile(
      key: ValueKey('${board.name}:${post.displayId}:${post.url}'),
      post: post,
      board: board,
      hidePostTags: hidePostTags,
      onTap: () async {
        final tag = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => MediaViewer(
              post: post,
              board: board,
              posts: posts,
              initialIndex: index,
              state: state,
            ),
          ),
        );
        if (tag != null && mounted) _search([tag]);
      },
      isFavorite: state.isFavorite(post, board: board),
      blur: _shouldBlur(state, post),
      onLongPress: null,
      onLongPressOrigin: (origin, controller) => showQuickPostActions(
        context,
        post: post,
        board: board,
        state: state,
        isFavorite: state.isFavorite(post, board: board),
        controller: controller,
        origin: origin,
      ),
    );
  }

  Widget _gallery(
    BuildContext context,
    AppState state,
    List<MediaPost> posts,
    Board board,
    double tileHeight,
    bool hierarchical,
    bool hidePostTags,
  ) {
    if (!hierarchical) {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: state.settings.columns,
          mainAxisExtent: tileHeight,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) =>
              _tile(context, state, posts, board, index, hidePostTags),
          childCount: posts.length,
        ),
      );
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, rowIndex) {
        final start = rowIndex * state.settings.columns;
        final end = (start + state.settings.columns)
            .clamp(0, posts.length)
            .toInt();
        final row = posts.sublist(start, end);
        final aspects = row.map((post) {
          final width = post.width > 0 ? post.width : 1;
          final height = post.height > 0 ? post.height : 1;
          return (width / height).clamp(.5, 3.0).toDouble();
        }).toList();
        final total = aspects.fold<double>(0, (sum, value) => sum + value);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            height: tileHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < row.length; i++)
                  Expanded(
                    flex: (aspects[i] / total * 1000)
                        .round()
                        .clamp(1, 1000)
                        .toInt(),
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: i + 1 == row.length ? 0 : 8,
                      ),
                      child: _tile(
                        context,
                        state,
                        posts,
                        board,
                        start + i,
                        hidePostTags,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      }, childCount: (posts.length / state.settings.columns).ceil()),
    );
  }

  Widget _build(BuildContext context) {
    final state = widget.state;
    final board = state.board;
    if (board == null) return const SizedBox.shrink();
    final site = appearanceFor(board);
    final hierarchicalGrid = state.settings.hierarchicalGrid;
    final hidePostTags = state.settings.hidePostTags;
    final posts = state.posts;
    return PopScope<void>(
      canPop: _searchHistory.isEmpty || _drawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_drawerOpen) _handleBack();
      },
      child: Scaffold(
        onDrawerChanged: (open) {
          if (_drawerOpen != open && mounted) {
            setState(() => _drawerOpen = open);
          }
        },
        drawerEnableOpenDragGesture: state.settings.gesturesEnabled,
        drawerEdgeDragWidth: state.settings.gesturesEnabled
            ? MediaQuery.sizeOf(context).width
            : null,
        appBar: AppBar(
          backgroundColor: site.surface,
          title: Row(
            children: [
              SiteLogo(board, size: 28, colored: true),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  site.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: state.tags.isEmpty
                  ? 'Saved searches'
                  : 'Save and open saved searches',
              onPressed: _saveAndShowQueries,
              icon: Icon(
                state.tags.isEmpty
                    ? Icons.bookmarks_outlined
                    : Icons.bookmark_add_outlined,
              ),
            ),
            if (state.recentSearches.isNotEmpty)
              IconButton(
                tooltip: 'Open recent searches',
                onPressed: _showRecentSearches,
                icon: const Icon(Icons.history_rounded),
              ),
            IconButton(
              tooltip: 'Refresh feed',
              onPressed: state.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.all(24),
                  child: Row(
                    children: [
                      Image(
                        image: AssetImage('assets/LogoFullColorWhite.png'),
                        height: 38,
                        fit: BoxFit.contain,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Text(
                    'Browsing ${board.label}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('Settings'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(state: state),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.favorite_rounded),
                  title: const Text('Favorites'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SavedPostsScreen(state: state),
                      ),
                    );
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 16, 24, 4),
                  child: Text(
                    'Websites',
                    style: TextStyle(
                      color: Colors.white54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final option in Board.values)
                        ListTile(
                          dense: true,
                          selected: option == board,
                          leading: SiteLogo(option, size: 32),
                          title: Text(appearanceFor(option).name),
                          onTap: option == board
                              ? null
                              : () async {
                                  Navigator.pop(context);
                                  _searchHistory.clear();
                                  await state.chooseBoard(option);
                                },
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => SearchGuideScreen(board: board),
                            ),
                          );
                        },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Learn to search',
                            style: TextStyle(
                              color: Colors.white70,
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'BooruPlus · Android',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: TagInput(
                      tags: state.tags,
                      onChanged: _search,
                      autocomplete: state.autocomplete,
                    ),
                  ),
                ),
              ),
              FilterBar(
                board: board,
                tags: state.tags,
                selectedRatings: state.selectedRatings,
                onFilter: _chooseFilter,
                onDate: _pickDate,
                onRatings: _chooseRatings,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                child: Row(
                  children: [
                    Icon(
                      state.tags.isEmpty
                          ? Icons.shuffle_rounded
                          : Icons.tag_rounded,
                      size: 16,
                      color: accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.tags.isEmpty ? 'DISCOVER' : 'SEARCH RESULTS',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.8,
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${posts.length} posts',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final tileHeight =
                        ((bounds.maxHeight - 8 * (state.settings.rows - 1)) /
                                state.settings.rows)
                            .clamp(88.0, 600.0);
                    return RefreshIndicator(
                      onRefresh: state.refresh,
                      child: CustomScrollView(
                        controller: _scroll,
                        clipBehavior: Clip.hardEdge,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            sliver: _gallery(
                              context,
                              state,
                              posts,
                              board,
                              tileHeight,
                              hierarchicalGrid,
                              hidePostTags,
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 32,
                                horizontal: 24,
                              ),
                              child: Center(
                                child: state.loading
                                    ? const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      )
                                    : state.error != null
                                    ? Column(
                                        children: [
                                          const Icon(
                                            Icons.cloud_off_outlined,
                                            size: 32,
                                            color: Colors.white54,
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            state.error!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.white60,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          OutlinedButton(
                                            onPressed: state.loadMore,
                                            child: const Text('Try again'),
                                          ),
                                        ],
                                      )
                                    : posts.isEmpty
                                    ? Column(
                                        children: [
                                          const Icon(
                                            Icons.image_search_rounded,
                                            size: 42,
                                            color: Colors.white38,
                                          ),
                                          const SizedBox(height: 16),
                                          const Text(
                                            'No matching media',
                                            style: TextStyle(
                                              fontSize: 20,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          const Text(
                                            'Try different tags or review your blacklist.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.white54,
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: state.refresh,
                                            child: const Text('Refresh'),
                                          ),
                                        ],
                                      )
                                    : state.hasMore
                                    ? TextButton.icon(
                                        onPressed: state.loadMore,
                                        icon: const Icon(Icons.expand_more),
                                        label: const Text('Load more'),
                                      )
                                    : const Text(
                                        'You’re all caught up',
                                        style: TextStyle(color: Colors.white38),
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MediaTile extends StatefulWidget {
  const MediaTile({
    super.key,
    required this.post,
    required this.board,
    required this.onTap,
    this.hidePostTags = false,
    this.isFavorite = false,
    this.blur = false,
    this.onLongPress,
    this.onLongPressOrigin,
    this.onLongPressMove,
    this.onLongPressEnd,
    this.onLongPressCancel,
  });
  final MediaPost post;
  final Board board;
  final VoidCallback onTap;
  final bool hidePostTags;
  final bool isFavorite;
  final bool blur;
  final VoidCallback? onLongPress;
  final void Function(Rect, QuickActionOverlayController)? onLongPressOrigin;
  final ValueChanged<Offset>? onLongPressMove;
  final ValueChanged<Offset>? onLongPressEnd;
  final VoidCallback? onLongPressCancel;
  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  final _quickActions = QuickActionOverlayController();
  bool _pressed = false;

  @override
  void dispose() {
    _quickActions.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final board = widget.board;
    final url = post.previewUrl.isNotEmpty
        ? post.previewUrl
        : _displayUrl(post);
    final media = url.isEmpty
        ? const Center(
            child: Icon(
              Icons.image_not_supported_outlined,
              color: Colors.white24,
            ),
          )
        : board == Board.gelbooru
        ? MediaImage(
            url: url,
            board: board,
            fit: BoxFit.cover,
            cacheWidth: 480,
            errorWidget: const Center(
              child: Icon(Icons.broken_image_outlined, color: Colors.white24),
            ),
          )
        : Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: 480,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Center(
                    child: Icon(Icons.image_outlined, color: Colors.white12),
                  ),
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_outlined, color: Colors.white24),
            ),
          );
    final ratingColor = _ratingColor(post.rating);
    final displayedMedia = widget.blur
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: media,
          )
        : media;
    return Semantics(
      label:
          '${post.isVideo ? 'Video' : 'Image'} ${post.displayId}, rating ${post.rating}',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) {
          _quickActions.beginGesture();
          setState(() => _pressed = true);
          final render = context.findRenderObject();
          if (render is RenderBox && render.hasSize) {
            widget.onLongPressOrigin?.call(
              render.localToGlobal(Offset.zero) & render.size,
              _quickActions,
            );
          }
          widget.onLongPress?.call();
        },
        onLongPressMoveUpdate: (details) {
          _quickActions.update(details.globalPosition);
          widget.onLongPressMove?.call(details.globalPosition);
        },
        onLongPressEnd: (details) {
          setState(() => _pressed = false);
          _quickActions.releaseAt(details.globalPosition);
          widget.onLongPressEnd?.call(details.globalPosition);
        },
        onLongPressCancel: () {
          setState(() => _pressed = false);
          _quickActions.cancel();
          widget.onLongPressCancel?.call();
        },
        child: AnimatedScale(
          scale: _pressed ? 1.08 : 1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: Material(
            color: panel,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: ratingColor, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  displayedMedia,
                  if (post.isVideo)
                    const Center(
                      child: CircleAvatar(
                        backgroundColor: Colors.black54,
                        radius: 20,
                        child: Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (!widget.hidePostTags && post.tagDetails.isNotEmpty)
                    Positioned(
                      top: 6,
                      left: 6,
                      right: 6,
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 3,
                        children: [
                          for (final tag in post.tagDetails.take(3))
                            _tagBadge(tag),
                        ],
                      ),
                    ),
                  if (widget.isFavorite)
                    const Positioned(
                      right: 7,
                      bottom: 7,
                      child: Icon(
                        Icons.favorite,
                        color: Color(0xFFFF77A8),
                        size: 20,
                      ),
                    ),
                  if (widget.blur)
                    const Center(
                      child: Icon(
                        Icons.visibility_off_outlined,
                        color: Colors.white70,
                        size: 25,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tagBadge(TagInfo tag) {
    final color = _tagColor(tag.category);
    return Container(
      constraints: const BoxConstraints(maxWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: .7)),
      ),
      child: Text(
        tag.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 9),
      ),
    );
  }
}

Color _tagColor(TagCategory category) => switch (category) {
  TagCategory.artist => const Color(0xFFE8A0FF),
  TagCategory.character => const Color(0xFF8BC8FF),
  TagCategory.copyright => const Color(0xFFFFA56B),
  TagCategory.species => const Color(0xFF91D99B),
  TagCategory.meta => const Color(0xFFFFD166),
  TagCategory.lore => const Color(0xFFC1A7FF),
  _ => Colors.white70,
};

String _displayUrl(MediaPost post) {
  final dynamic value = post;
  try {
    final authenticated = value.authenticatedUrl;
    if (authenticated is String && authenticated.isNotEmpty) {
      return authenticated;
    }
  } catch (_) {}
  try {
    final urls = value.urlMap;
    if (urls is Map) {
      for (final key in const ['preview', 'thumbnail', 'original', 'url']) {
        final candidate = urls[key];
        if (candidate is String && candidate.isNotEmpty) return candidate;
      }
    }
  } catch (_) {}
  return post.url;
}

String _originalUrl(MediaPost post) {
  final dynamic value = post;
  try {
    final authenticated = value.authenticatedUrl;
    if (authenticated is String && authenticated.isNotEmpty) {
      return authenticated;
    }
  } catch (_) {}
  try {
    final urls = value.urlMap;
    if (urls is Map) {
      for (final key in const ['original', 'file', 'url']) {
        final candidate = urls[key];
        if (candidate is String && candidate.isNotEmpty) return candidate;
      }
    }
  } catch (_) {}
  return post.url;
}

String _quickActionUrl(MediaPost post) {
  if (post.isVideo) {
    return post.previewUrl.isNotEmpty ? post.previewUrl : _displayUrl(post);
  }
  return _originalUrl(post);
}

/// The hold preview is small, so a provider rendition of at most 720p (or
/// the user's lower preference) starts sooner than the original file.
String _peekVideoUrl(MediaPost post, int preferredHeight) {
  final limit = preferredHeight > 0 && preferredHeight < 720
      ? preferredHeight
      : 720;
  return post.videoVariantFor(limit)?.url ?? _originalUrl(post);
}

bool _shouldBlur(AppState state, MediaPost post) {
  final rating = post.rating.trim().toLowerCase();
  if (rating.contains('explicit') || rating == 'e') {
    return state.settings.blurExplicit;
  }
  return (rating.contains('questionable') || rating == 'q') &&
      state.settings.blurQuestionable;
}

Color _ratingColor(String rating) {
  final normalized = rating.toLowerCase();
  if (normalized.contains('explicit') || normalized == 'e') {
    return Colors.redAccent;
  }
  if (normalized.contains('questionable') || normalized == 'q') {
    return Colors.orangeAccent;
  }
  return Colors.grey;
}

class QuickActionOverlayController {
  void Function(Offset)? _onMove;
  VoidCallback? _onRelease;
  VoidCallback? _onCancel;
  bool _pendingRelease = false;
  bool _pendingCancel = false;
  Offset? _pendingReleasePosition;

  void update(Offset position) => _onMove?.call(position);
  void beginGesture() {
    _pendingRelease = false;
    _pendingCancel = false;
    _pendingReleasePosition = null;
  }

  void release() {
    final callback = _onRelease;
    if (callback == null) {
      _pendingRelease = true;
      return;
    }
    callback();
  }

  void releaseAt(Offset position) {
    final move = _onMove;
    final release = _onRelease;
    if (move == null || release == null) {
      _pendingReleasePosition = position;
      _pendingRelease = true;
      return;
    }
    move(position);
    release();
  }

  void cancel() {
    final callback = _onCancel;
    if (callback == null) {
      _pendingCancel = true;
      return;
    }
    callback();
  }

  void _attach({
    required void Function(Offset) onMove,
    required VoidCallback onRelease,
    required VoidCallback onCancel,
  }) {
    _onMove = onMove;
    _onRelease = onRelease;
    _onCancel = onCancel;
    final pendingCancel = _pendingCancel;
    final pendingRelease = _pendingRelease;
    final pendingPosition = _pendingReleasePosition;
    _pendingCancel = false;
    _pendingRelease = false;
    _pendingReleasePosition = null;
    if (pendingCancel) {
      scheduleMicrotask(onCancel);
    } else if (pendingRelease) {
      scheduleMicrotask(() {
        if (pendingPosition != null) onMove(pendingPosition);
        onRelease();
      });
    }
  }

  void _detach() {
    _onMove = null;
    _onRelease = null;
    _onCancel = null;
    _pendingRelease = false;
    _pendingCancel = false;
    _pendingReleasePosition = null;
  }
}

Future<void> showQuickPostActions(
  BuildContext context, {
  required MediaPost post,
  required Board board,
  required AppState state,
  bool? isFavorite,
  QuickActionOverlayController? controller,
  Rect? origin,
}) async {
  final result = Completer<String?>();
  late final OverlayEntry entry;
  final dialogKey = GlobalKey<_QuickActionDialogState>();
  final blur = _shouldBlur(state, post);
  void complete(String? action) {
    if (!result.isCompleted) result.complete(action);
  }

  entry = OverlayEntry(
    builder: (_) => Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: const SizedBox.expand(),
          ),
        ),
        ModalBarrier(
          color: Colors.black.withValues(alpha: .48),
          dismissible: true,
          semanticsLabel: 'Post actions',
          onDismiss: () {
            final dialog = dialogKey.currentState;
            if (dialog == null) {
              complete(null);
            } else {
              dialog.dismiss();
            }
          },
        ),
        _QuickActionDialog(
          key: dialogKey,
          post: post,
          board: board,
          isFavorite: isFavorite ?? state.isFavorite(post, board: board),
          blur: blur,
          videoUrl: post.isVideo && !blur
              ? _peekVideoUrl(post, state.settings.videoQuality)
              : null,
          controller: controller,
          origin: origin,
          onResult: complete,
        ),
      ],
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  final action = await result.future;
  if (entry.mounted) entry.remove();
  // Actions only touch app state, so they still apply if the tile that
  // opened the preview was rebuilt or scrolled away meanwhile.
  if (action == 'favorite') {
    await state.toggleFavorite(post, board: board);
  } else if (action == 'hide') {
    await state.hidePost(post, board: board);
  }
}

class _QuickActionDialog extends StatefulWidget {
  const _QuickActionDialog({
    super.key,
    required this.post,
    required this.board,
    required this.isFavorite,
    required this.onResult,
    required this.blur,
    this.videoUrl,
    this.controller,
    this.origin,
  });
  final MediaPost post;
  final Board board;
  final bool isFavorite;
  final ValueChanged<String?> onResult;
  final bool blur;

  /// Stream to autoplay (muted, looping) for video posts; null shows only
  /// the poster.
  final String? videoUrl;
  final QuickActionOverlayController? controller;
  final Rect? origin;

  @override
  State<_QuickActionDialog> createState() => _QuickActionDialogState();
}

class _QuickActionDialogState extends State<_QuickActionDialog>
    with SingleTickerProviderStateMixin {
  static const _inset = 12.0;
  static const _gap = 10.0;
  final _favoriteKey = GlobalKey();
  final _hideKey = GlobalKey();
  late final AnimationController _animationController;
  late final CurvedAnimation _positionAnimation;
  VideoPlayerController? _video;
  bool _videoReady = false;
  String? _armed;
  bool _revealed = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 180),
    )..forward();
    _positionAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    widget.controller?._attach(
      onMove: _updateArmed,
      onRelease: _releaseArmed,
      onCancel: _cancel,
    );
    final videoUrl = widget.videoUrl;
    if (videoUrl != null && videoUrl.isNotEmpty) _startVideo(videoUrl);
  }

  @override
  void dispose() {
    widget.controller?._detach();
    // dispose() never completes for a player whose creation failed.
    _video?.dispose().ignore();
    _video = null;
    _positionAnimation.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _startVideo(String url) async {
    final video = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: widget.board == Board.gelbooru
          ? const {
              'Referer': 'https://gelbooru.com/',
              'User-Agent': 'BooruPlus/1.0',
            }
          : const {},
    );
    _video = video;
    bool stale() => !mounted || _closing || !identical(_video, video);
    try {
      await video.initialize();
      if (stale()) return;
      await video.setLooping(true);
      // A hold is a quick peek; stay silent until the post is opened.
      await video.setVolume(0);
      if (stale()) return;
      await video.play();
      if (!stale()) setState(() => _videoReady = true);
    } catch (_) {
      // The poster remains when the stream cannot start.
    }
  }

  void _updateArmed(Offset position) {
    final next = _contains(_favoriteKey, position)
        ? 'favorite'
        : _contains(_hideKey, position)
        ? 'hide'
        : null;
    if (next != _armed && mounted) setState(() => _armed = next);
  }

  bool _contains(GlobalKey key, Offset position) {
    final render = key.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return false;
    final local = render.globalToLocal(position);
    return (Offset.zero & render.size).contains(local);
  }

  void _releaseArmed() {
    _finish(_armed);
  }

  void _cancel() => dismiss();

  void _commit(String action) => _finish(action);

  void dismiss() => _finish(null);

  Future<void> _finish(String? action) async {
    if (_closing) return;
    _closing = true;
    widget.controller?._detach();
    try {
      await _animationController.reverse().orCancel;
    } on TickerCanceled {
      // Disposal can cancel the ticker; still resolve the dismissal once.
    }
    widget.onResult(action);
  }

  Widget _media(double width) {
    final post = widget.post;
    final mediaUrl = _quickActionUrl(post);
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context)).round();
    const broken = Center(child: Icon(Icons.broken_image_outlined));
    // The grid already decoded the thumbnail at this size, so it shows
    // instantly while the original image loads above it.
    final placeholder =
        !post.isVideo &&
            widget.board != Board.gelbooru &&
            post.previewUrl.isNotEmpty &&
            post.previewUrl != mediaUrl
        ? Image.network(
            post.previewUrl,
            fit: BoxFit.contain,
            cacheWidth: 480,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          )
        : null;
    final Widget media = mediaUrl.isEmpty
        ? const Center(child: Icon(Icons.image_not_supported_outlined))
        : widget.board == Board.gelbooru
        ? MediaImage(
            url: mediaUrl,
            board: widget.board,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
          )
        : Image.network(
            mediaUrl,
            fit: BoxFit.contain,
            cacheWidth: post.isVideo ? 480 : cacheWidth,
            errorBuilder: (_, _, _) =>
                placeholder == null ? broken : const SizedBox.shrink(),
          );
    final video = _video;
    return Stack(
      fit: StackFit.expand,
      children: [
        ?placeholder,
        media,
        if (_videoReady && video != null)
          Center(
            child: AspectRatio(
              aspectRatio: video.value.aspectRatio,
              child: VideoPlayer(video),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final captionStyle =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          color: Colors.white70,
        );
    final caption = post.description.isEmpty
        ? 'Post #${post.displayId}'
        : post.description;

    // Size the card from the post's own aspect ratio so the preview hugs
    // the media instead of letterboxing it inside a fixed box.
    final maxCardWidth = (size.width - 32).clamp(240.0, 520.0).toDouble();
    final maxCardHeight = ((size.height - safe.vertical) * .82)
        .clamp(320.0, 760.0)
        .toDouble();
    final maxContentWidth = maxCardWidth - _inset * 2;
    final minContentWidth = maxContentWidth < 236 ? maxContentWidth : 236.0;
    // Measured at the narrowest width so the estimate never falls short.
    final captionPainter = TextPainter(
      text: TextSpan(text: caption, style: captionStyle),
      maxLines: 2,
      ellipsis: '…',
      textDirection: Directionality.of(context),
      textScaler: textScaler,
    )..layout(maxWidth: minContentWidth);
    final captionHeight = captionPainter.height;
    captionPainter.dispose();
    final buttonHeight = 30 + textScaler.scale(20);
    final chrome = _inset * 2 + _gap * 2 + captionHeight + buttonHeight;
    final aspect = post.width > 0 && post.height > 0
        ? (post.width / post.height).clamp(1 / 3, 3.0).toDouble()
        : 1.0;
    final maxMediaHeight = (maxCardHeight - chrome) < 120
        ? 120.0
        : maxCardHeight - chrome;
    var mediaWidth = maxContentWidth;
    var mediaHeight = mediaWidth / aspect;
    if (mediaHeight > maxMediaHeight) {
      mediaHeight = maxMediaHeight;
      mediaWidth = mediaHeight * aspect;
    }
    final contentWidth = mediaWidth < minContentWidth
        ? minContentWidth
        : mediaWidth;
    final target = Rect.fromCenter(
      center: Offset(
        size.width / 2,
        safe.top + (size.height - safe.vertical) / 2,
      ),
      width: contentWidth + _inset * 2,
      height: mediaHeight + chrome,
    );

    final media = _media(mediaWidth);
    final displayedMedia = widget.blur && !_revealed
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: media,
          )
        : media;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (event) => _updateArmed(event.position),
      onPointerUp: (event) {
        _updateArmed(event.position);
        _releaseArmed();
      },
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                final rect = RectTween(
                  begin: widget.origin ?? target,
                  end: target,
                ).evaluate(_positionAnimation)!;
                return Positioned.fromRect(
                  rect: rect,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: target.width,
                      height: target.height,
                      child: child,
                    ),
                  ),
                );
              },
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.all(_inset),
                  child: Center(
                    // Absorbs any shortfall in the height estimate (e.g.
                    // unusual fonts) by scaling instead of overflowing.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: contentWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: mediaWidth,
                              height: mediaHeight,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: ColoredBox(
                                  color: Colors.black45,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Positioned.fill(child: displayedMedia),
                                      if (_videoReady)
                                        const Positioned(
                                          right: 8,
                                          bottom: 8,
                                          child: Icon(
                                            Icons.volume_off_rounded,
                                            size: 18,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      if (widget.blur && !_revealed)
                                        FilledButton.icon(
                                          onPressed: () =>
                                              setState(() => _revealed = true),
                                          icon: const Icon(Icons.visibility),
                                          label: const Text('Reveal media'),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: _gap),
                            Text(
                              caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: captionStyle,
                            ),
                            const SizedBox(height: _gap),
                            Row(
                              children: [
                                Expanded(
                                  child: _actionButton(
                                    key: _favoriteKey,
                                    action: 'favorite',
                                    icon: Icons.favorite_rounded,
                                    label: widget.isFavorite
                                        ? 'Unfavorite'
                                        : 'Favorite',
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _actionButton(
                                    key: _hideKey,
                                    action: 'hide',
                                    icon: Icons.visibility_off_rounded,
                                    label: 'Hide',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required Key key,
    required String action,
    required IconData icon,
    required String label,
  }) => FilledButton.icon(
    key: key,
    onPressed: () => _commit(action),
    style: FilledButton.styleFrom(
      backgroundColor: _armed == action ? accent : Colors.black54,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 13),
    ),
    icon: Icon(icon),
    label: Text(label),
  );
}

class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.board,
    required this.tags,
    required this.selectedRatings,
    required this.onFilter,
    required this.onDate,
    required this.onRatings,
  });
  final Board board;
  final List<String> tags;
  final List<Rating> selectedRatings;
  final ValueChanged<String> onFilter;
  final VoidCallback onDate;
  final VoidCallback onRatings;

  @override
  Widget build(BuildContext context) {
    final order = tags
        .where((tag) => tag.startsWith('order:') || tag.startsWith('sort:'))
        .firstOrNull;
    final date = tags
        .where(
          (tag) => tag.startsWith('created_at:') || tag.startsWith('date:'),
        )
        .firstOrNull;
    final noFavoriteOrder =
        board == Board.gelbooru ||
        board == Board.rule34 ||
        board == Board.sankaku;
    final sortItems = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'none', child: Text('Relevance / default')),
      const PopupMenuItem(value: 'score', child: Text('Popularity / score')),
      if (!noFavoriteOrder)
        const PopupMenuItem(value: 'favorites', child: Text('Favorites')),
      const PopupMenuItem(value: 'quality', child: Text('Quality')),
      const PopupMenuItem(value: 'newest', child: Text('Newest')),
      const PopupMenuItem(value: 'oldest', child: Text('Oldest')),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            PopupMenuButton<String>(
              tooltip: 'Sort results',
              onSelected: onFilter,
              itemBuilder: (_) => sortItems,
              child: Chip(
                avatar: const Icon(Icons.sort_rounded, size: 17),
                label: Text(order == null ? 'Sort' : order.split(':').last),
              ),
            ),
            const SizedBox(width: 6),
            ActionChip(
              avatar: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(
                date == null
                    ? 'Date'
                    : RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(date)?[0] ??
                          date.split('>=').last,
              ),
              onPressed: onDate,
            ),
            const SizedBox(width: 6),
            ActionChip(
              avatar: const Icon(Icons.shield_outlined, size: 16),
              label: Text(
                selectedRatings.length == Rating.values.length
                    ? 'Ratings'
                    : selectedRatings.isEmpty
                    ? 'No ratings'
                    : selectedRatings.map((rating) => rating.label).join(', '),
              ),
              onPressed: onRatings,
            ),
          ],
        ),
      ),
    );
  }
}
