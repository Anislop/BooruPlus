import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'downloads.dart';
import 'media_viewer.dart';
import 'media_image.dart';
import 'multi_search.dart';
import 'search_guide.dart';
import 'settings.dart';
import 'shorts.dart';
import 'saved_posts.dart';
import 'site_catalog.dart';
import 'tag_input.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state, this.locked});
  final AppState state;

  /// Whether the app lock hides the app; launcher shortcuts wait until it
  /// opens.
  final ValueListenable<bool>? locked;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// The post a tag was opened from, so back can return to it.
class _ViewerSnapshot {
  const _ViewerSnapshot(this.posts, this.board, this.index);
  final List<MediaPost> posts;
  final Board board;
  final int index;
}

class _HistoryEntry {
  _HistoryEntry(this.tags, this.viewer, {this.feed, this.offset = 0});
  final List<String> tags;
  final _ViewerSnapshot? viewer;

  /// The loaded feed and scroll position, so back restores them instead of
  /// searching again. Only the newest entries keep one.
  FeedSnapshot? feed;
  final double offset;
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _restorableEntries = 5;
  final _scroll = ScrollController();
  final _showScrollTop = ValueNotifier(false);
  final _searchHistory = <_HistoryEntry>[];
  final _device = DeviceService();
  StreamSubscription<AppShortcut>? _shortcutSubscription;
  bool _drawerOpen = false;

  /// Whether the keyboard is up, tracked through metrics changes rather
  /// than read in build, which would rebuild the feed on every frame of
  /// the keyboard animation.
  bool _keyboardOpen = false;

  /// The one-handed panel's height; the feed runs underneath it and ends
  /// with this much space so its last row can scroll clear of the panel.
  double _panelHeight = 0;

  /// Whether the one-handed panel has slid away while scrolling down; see
  /// [AppSettings.hidePanelOnScroll].
  final _panelHidden = ValueNotifier(false);
  double _lastScrollOffset = 0;

  /// Distance scrolled in the current direction, so small jitters do not
  /// toggle the panel.
  double _scrollTravel = 0;
  // Feed multi-select: identities of the selected posts, with the posts.
  bool _selecting = false;
  final Map<String, SavedPost> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(() {
      _showScrollTop.value = _scroll.offset > 600;
      _updatePanelOnScroll();
      if (_scroll.position.extentAfter < 700 && widget.state.error == null) {
        widget.state.loadMore();
      }
    });
    widget.state.addListener(_showNotice);
    widget.state.addListener(_jumpToRestoredFeed);
    widget.locked?.addListener(_openPendingShortcut);
    _shortcutSubscription = _device.shortcuts.listen((shortcut) {
      // Clears the native copy kept for a cold start, so it is not reopened.
      _device.takeShortcut();
      _receiveShortcut(shortcut);
    });
    _device.takeShortcut().then((shortcut) {
      if (shortcut != null) _receiveShortcut(shortcut);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.locked?.removeListener(_openPendingShortcut);
    _shortcutSubscription?.cancel();
    widget.state.removeListener(_showNotice);
    widget.state.removeListener(_jumpToRestoredFeed);
    _scroll.dispose();
    _showScrollTop.dispose();
    _panelHidden.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistFeed();
    }
  }

  /// Saves the feed and scroll position for the next launch.
  Future<void> _persistFeed() =>
      widget.state.persistFeed(offset: _scroll.hasClients ? _scroll.offset : 0);

  /// Scrolls a feed reopened from an earlier session back to where it was.
  void _jumpToRestoredFeed() {
    if (!widget.state.initialized || widget.state.posts.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final offset = widget.state.takeRestoredOffset();
      if (offset == null) return;
      _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final open = View.of(context).viewInsets.bottom > 0;
    if (open != _keyboardOpen) setState(() => _keyboardOpen = open);
  }

  /// A launcher shortcut, kept until the app lock opens. Any app can start
  /// this activity with shortcut extras, so nothing runs behind the lock.
  AppShortcut? _pendingShortcut;
  int _linkGeneration = 0;

  void _receiveShortcut(AppShortcut shortcut) {
    _pendingShortcut = shortcut;
    _openPendingShortcut();
  }

  void _openPendingShortcut() {
    final shortcut = _pendingShortcut;
    if (shortcut == null || widget.locked?.value == true) return;
    _pendingShortcut = null;
    _openShortcut(shortcut);
  }

  /// Opens favorites or runs the saved search a launcher shortcut names.
  /// Searches run only when they are one of the website's saved searches,
  /// which the shortcuts are made from.
  Future<void> _openShortcut(AppShortcut shortcut) async {
    if (!mounted) return;
    if (shortcut.kind == 'link') {
      await _openLink(shortcut.url ?? '');
      return;
    }
    if (shortcut.kind == 'downloads') {
      Navigator.of(context).popUntil((route) => route.isFirst);
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DownloadsScreen(state: widget.state),
        ),
      );
      return;
    }
    final state = widget.state;
    final board = shortcut.board;
    if (board?.isRetired == true) return;
    if (board != null) {
      final query = shortcut.tags.join(' ');
      final saved = state.settings
          .savedQueriesFor(board)
          .any((tags) => tags.join(' ') == query);
      if (!saved) return;
    }
    if (board == null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => SavedPostsScreen(state: state)),
      );
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
    _endSelection();
    if (state.board == board) {
      _search(shortcut.tags);
    } else {
      setState(_searchHistory.clear);
      await state.chooseBoard(board, tags: shortcut.tags);
    }
  }

  /// Opens the post or runs the search that a website link names (see
  /// [PostLink]). A post is looked up with `id:` and opens only when the
  /// feed's filters would show it.
  Future<void> _openLink(String text) async {
    final state = widget.state;
    // A newer link replaces one still being looked up.
    final generation = ++_linkGeneration;
    final link = PostLink.parse(text);
    if (link == null) {
      _linkNotice('BooruPlus cannot open this link.');
      return;
    }
    final board = link.board;
    final searchable = await state.searchableBoards(among: [board]);
    if (!mounted || generation != _linkGeneration) return;
    if (searchable.isEmpty) {
      _linkNotice('Connect ${board.label} in Settings to open its links.');
      return;
    }
    final id = link.postId;
    if (id == null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _endSelection();
      if (state.board == board) {
        _search(link.tags);
      } else {
        setState(_searchHistory.clear);
        await state.chooseBoard(board, tags: link.tags);
      }
      return;
    }
    _linkNotice('Opening ${board.label} post…');
    final MediaPost? post;
    try {
      post = await state.postById(board, id);
    } catch (_) {
      if (mounted && generation == _linkGeneration) {
        _linkNotice('Could not open this post. Check your connection.');
      }
      return;
    }
    if (!mounted || generation != _linkGeneration) return;
    if (post == null) {
      _linkNotice('This post was not found, or your filters hide it.');
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    Navigator.of(context).popUntil((route) => route.isFirst);
    _endSelection();
    if (state.board == board) {
      await _openViewer([post], board, 0);
      return;
    }
    // Another website's post: its tags start a search there, since adding
    // to or excluding from the current search would mix websites.
    final result = await Navigator.push<ViewerTagBrowse>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewer(
          post: state.displayPost(post!, board: board),
          board: board,
          savedPosts: [SavedPost(board: board, post: post)],
          state: state,
        ),
      ),
    );
    if (result == null || result.mode != TagBrowseMode.replace || !mounted) {
      return;
    }
    if (state.board == board) {
      _search([result.tag]);
      return;
    }
    setState(_searchHistory.clear);
    await state.chooseBoard(board, tags: [result.tag]);
  }

  void _linkNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Slides the one-handed panel away as the user scrolls down and brings
  /// it back as they scroll up or reach the top. Programmatic jumps (such
  /// as restoring a feed) leave it as it is.
  void _updatePanelOnScroll() {
    final offset = _scroll.offset;
    final delta = offset - _lastScrollOffset;
    _lastScrollOffset = offset;
    if (offset <= 0) {
      _scrollTravel = 0;
      _panelHidden.value = false;
      return;
    }
    final direction = _scroll.position.userScrollDirection;
    if (direction == ScrollDirection.idle) return;
    _scrollTravel = (_scrollTravel >= 0) == (delta >= 0)
        ? _scrollTravel + delta
        : delta;
    if (direction == ScrollDirection.reverse &&
        _scrollTravel > 24 &&
        offset > _panelHeight &&
        _canHidePanel()) {
      _panelHidden.value = true;
    } else if (direction == ScrollDirection.forward && _scrollTravel < -24) {
      _panelHidden.value = false;
    }
  }

  /// The panel stays up while selecting or typing in its search field.
  bool _canHidePanel() {
    final settings = widget.state.settings;
    return settings.oneHanded &&
        settings.hidePanelOnScroll &&
        !_selecting &&
        !_keyboardOpen;
  }

  void _scrollToTop() {
    if (!_scroll.hasClients || _scroll.offset == 0) return;
    if (widget.state.settings.reduceMotion) {
      _scroll.jumpTo(0);
      return;
    }
    // Long feeds jump most of the way first so the animation stays short.
    if (_scroll.offset > 4000) _scroll.jumpTo(2000);
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  void _endSelection() {
    if (!_selecting && _selected.isEmpty) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelected(MediaPost post, Board board) {
    final saved = SavedPost(board: board, post: post);
    setState(() {
      if (_selected.remove(saved.identity) == null) {
        _selected[saved.identity] = saved;
      }
    });
  }

  Future<void> _favoriteSelected() async {
    final state = widget.state;
    final posts = _selected.values.toList();
    var added = 0;
    for (final saved in posts) {
      if (state.isFavorite(saved.post, board: saved.board)) continue;
      await state.favoritePost(saved.post, board: saved.board);
      added++;
    }
    if (!mounted) return;
    _endSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'Those posts are already favorites.'
              : 'Added ${_postCount(added)} to favorites.',
        ),
      ),
    );
  }

  /// Queues the selected posts in the Download Manager.
  Future<void> _downloadSelected() async {
    if (_selected.isEmpty) return;
    final queued = await queueDownloads(
      context,
      widget.state,
      _selected.values.toList(),
    );
    if (queued != null && mounted) _endSelection();
  }

  static String _postCount(int count) => '$count post${count == 1 ? '' : 's'}';

  PreferredSizeWidget _selectionBar(Board board) => AppBar(
    backgroundColor: appBarSurface(board),
    leading: _cancelSelectionButton(),
    title: Text(_selectionTitle),
    actions: [..._selectionActions(board), const SizedBox(width: 8)],
  );

  String get _selectionTitle => '${_selected.length} selected';

  Widget _cancelSelectionButton() => IconButton(
    tooltip: 'Cancel selection',
    icon: const Icon(Icons.close_rounded),
    onPressed: _endSelection,
  );

  List<Widget> _selectionActions(Board board) {
    final state = widget.state;
    return [
      IconButton(
        tooltip: 'Select all loaded posts',
        icon: const Icon(Icons.select_all_rounded),
        onPressed: () => setState(() {
          for (final post in state.posts) {
            final saved = SavedPost(
              board: board,
              post: state.displayPost(post, board: board),
            );
            _selected[saved.identity] = saved;
          }
        }),
      ),
      IconButton(
        tooltip: 'Favorite selected',
        icon: const Icon(Icons.favorite_border_rounded),
        onPressed: _selected.isEmpty ? null : _favoriteSelected,
      ),
      IconButton(
        tooltip: 'Download selected',
        icon: const Icon(Icons.download_outlined),
        onPressed: _selected.isEmpty ? null : _downloadSelected,
      ),
    ];
  }

  List<Widget> _feedActions() {
    final state = widget.state;
    return [
      if (state.posts.isNotEmpty)
        IconButton(
          tooltip: 'Select posts',
          onPressed: () => setState(() => _selecting = true),
          icon: const Icon(Icons.checklist_rounded),
        ),
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
      if (state.recentSearches.isNotEmpty || state.pinnedSearches.isNotEmpty)
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
    ];
  }

  /// One-handed mode's bottom panel: filters, the search field, and the
  /// feed or selection actions, nearest the thumb.
  Widget _bottomPanel(Board board, Widget search, Widget filters) {
    final left = widget.state.settings.handedness == Handedness.left;
    // The hand's side gets the actions; for the left hand they also run
    // in reverse so the most-used one stays at the edge.
    List<Widget> sided(List<Widget> actions) =>
        left ? actions.reversed.toList() : actions;
    final Widget actions;
    if (_selecting) {
      final title = Expanded(
        child: Text(
          _selectionTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: left ? TextAlign.end : TextAlign.start,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      );
      actions = Row(
        key: const ValueKey('one_handed_selection_bar'),
        children: sided([
          _cancelSelectionButton(),
          const SizedBox(width: 4),
          title,
          ..._selectionActions(board),
        ]),
      );
    } else {
      actions = Row(
        key: const ValueKey('one_handed_feed_actions'),
        mainAxisAlignment: left
            ? MainAxisAlignment.start
            : MainAxisAlignment.end,
        children: sided(_feedActions()),
      );
    }
    // Frosted so the feed shows through as it scrolls underneath. The body
    // skips the bottom safe area in this mode, so the panel reaches the
    // screen edge and pads its own content above the system bar.
    return FrostedSurface(
      key: const ValueKey('one_handed_panel'),
      color: appBarSurface(board),
      opacity: panelSurfaceOpacity,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          0,
          8,
          0,
          4 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hidden rather than removed while selecting, so unfinished
            // search text survives. Flexible, so with the keyboard open the
            // search area (and its suggestions) shrinks to the space left
            // instead of pushing the panel past the top of the feed.
            Flexible(
              child: Visibility(
                visible: !_selecting,
                maintainState: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Sort, date, and ratings sit on the holding hand's side.
                    Align(
                      alignment: left
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: filters,
                    ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        // The search lays out its suggestions and scrolls its
                        // own field within this height.
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: search,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: actions,
            ),
          ],
        ),
      ),
    );
  }

  /// One-handed mode's jump-to-top button on the preferred hand's side,
  /// shown once the feed is scrolled.
  /// Follows the panel down when it slides away.
  Widget _scrollTopButton() => ValueListenableBuilder<bool>(
    valueListenable: _panelHidden,
    builder: (context, hidden, child) => AnimatedPositioned(
      duration: _panelSlideDuration,
      curve: Curves.easeOutCubic,
      bottom:
          16 +
          (_panelIsHidden(hidden)
              ? MediaQuery.paddingOf(context).bottom
              : _panelHeight),
      left: widget.state.settings.handedness == Handedness.left ? 16 : null,
      right: widget.state.settings.handedness == Handedness.left ? null : 16,
      child: child!,
    ),
    child: ValueListenableBuilder<bool>(
      valueListenable: _showScrollTop,
      builder: (context, visible, _) => AnimatedScale(
        scale: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: FloatingActionButton.small(
          key: const ValueKey('scroll_to_top'),
          heroTag: null,
          tooltip: 'Scroll to top',
          onPressed: visible ? _scrollToTop : null,
          child: const Icon(Icons.vertical_align_top_rounded),
        ),
      ),
    ),
  );

  Duration get _panelSlideDuration => widget.state.settings.reduceMotion
      ? Duration.zero
      : const Duration(milliseconds: 220);

  /// Whether the panel is slid away now; it always returns once hiding no
  /// longer applies (selection started, setting turned off).
  bool _panelIsHidden(bool hidden) =>
      hidden &&
      !_selecting &&
      widget.state.settings.oneHanded &&
      widget.state.settings.hidePanelOnScroll;

  void _showNotice() {
    if (!mounted) return;
    final notice = widget.state.takeNotice();
    if (notice == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice)));
  }

  void _search(List<String> tags, {_ViewerSnapshot? viewer}) {
    final next = List<String>.unmodifiable(tags);
    final current = widget.state.tags;
    final changed = !_sameQuery(current, next);
    // A tag opened from a post always gets its own entry so back returns
    // to that post, even when the feed already shows that query.
    if (viewer != null ||
        (changed &&
            (_searchHistory.isEmpty ||
                !_sameQuery(_searchHistory.last.tags, current)))) {
      setState(() {
        _searchHistory.add(
          _HistoryEntry(
            List<String>.unmodifiable(current),
            viewer,
            feed: changed ? widget.state.snapshotFeed() : null,
            offset: _scroll.hasClients ? _scroll.offset : 0,
          ),
        );
        // Older entries search again instead of holding their posts.
        final stale = _searchHistory.length - _restorableEntries;
        for (var i = 0; i < stale; i++) {
          _searchHistory[i].feed = null;
        }
      });
    }
    if (!changed) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.state.search(next);
  }

  Future<void> _openViewer(
    List<MediaPost> posts,
    Board board,
    int index,
  ) async {
    final state = widget.state;
    final result = await Navigator.push<ViewerTagBrowse>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewer(
          post: state.displayPost(posts[index], board: board),
          board: board,
          posts: posts,
          initialIndex: index,
          state: state,
        ),
      ),
    );
    if (result == null || !mounted) return;
    // The board may have changed while the viewer was open; its posts and
    // index then no longer belong to the feed.
    if (state.board != board) return;
    final tag = result.tag;
    bool sameTag(String value) {
      final bare = value.substring(searchPrefix(value).length);
      return bare.toLowerCase() == tag.toLowerCase();
    }

    final next = switch (result.mode) {
      TagBrowseMode.replace => [tag],
      TagBrowseMode.add => [...state.tags.where((t) => !sameTag(t)), tag],
      TagBrowseMode.exclude => [
        ...state.tags.where((t) => !sameTag(t)),
        '-$tag',
      ],
    };
    _search(next, viewer: _ViewerSnapshot(posts, board, result.index));
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
    final previous = _searchHistory.last;
    setState(() => _searchHistory.removeLast());
    if (!_sameQuery(widget.state.tags, previous.tags)) {
      final feed = previous.feed;
      if (feed != null &&
          _sameQuery(feed.tags, previous.tags) &&
          widget.state.restoreFeed(feed)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scroll.hasClients) return;
          _scroll.jumpTo(
            previous.offset.clamp(0.0, _scroll.position.maxScrollExtent),
          );
        });
      } else {
        if (_scroll.hasClients) _scroll.jumpTo(0);
        widget.state.search(previous.tags);
      }
    }
    final viewer = previous.viewer;
    if (viewer != null && widget.state.board == viewer.board) {
      _openViewer(viewer.posts, viewer.board, viewer.index);
    }
  }

  Future<void> _saveAndShowQueries() async {
    if (widget.state.tags.isNotEmpty) {
      await widget.state.addSavedQuery(widget.state.tags);
    }
    if (mounted) await _showSavedQueries();
  }

  Future<void> _showSavedQueries() async {
    final queries = widget.state.savedQueries;
    await _showQueryPopup(
      title: 'Saved searches',
      headerIcon: Icons.bookmarks_outlined,
      queries: queries,
      newCounts: {
        for (final query in queries)
          query.join(' '): widget.state.newPostCount(query),
      },
      emptyMessage: 'No saved searches yet. Search tags, then tap the bookmark to save them.',
      deleteTooltip: 'Delete saved search',
      onDelete: widget.state.removeSavedQuery,
    );
  }

  /// The search history: pinned searches first, then recent ones. Each
  /// can be pinned, saved as a bookmark, or swiped away.
  Future<void> _showRecentSearches() async {
    final state = widget.state;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final pinned = state.pinnedSearches;
          final recent = [
            for (final query in state.recentSearches)
              if (!state.isPinnedSearch(query)) query,
          ];
          Widget entry(List<String> query, {required bool isPinned}) {
            final saved = state.isSavedQuery(query);
            return Dismissible(
              key: ValueKey(
                'history:${isPinned ? 'pinned' : 'recent'}:${query.join(' ')}',
              ),
              background: Container(
                color: accent.withValues(alpha: .18),
                alignment: AlignmentDirectional.centerStart,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Icon(Icons.delete_outline, color: ink(.70)),
              ),
              secondaryBackground: Container(
                color: accent.withValues(alpha: .18),
                alignment: AlignmentDirectional.centerEnd,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Icon(Icons.delete_outline, color: ink(.70)),
              ),
              onDismissed: (_) async {
                if (isPinned) await state.togglePinnedSearch(query);
                await state.removeRecentSearch(query);
              },
              child: ListTile(
                title: Text(query.join(' ')),
                leading: Icon(
                  isPinned ? Icons.push_pin_rounded : Icons.history_rounded,
                ),
                onTap: () {
                  Navigator.pop(context);
                  _search(query);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: saved
                          ? 'Saved search'
                          : 'Save as a saved search',
                      icon: Icon(
                        saved
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_add_outlined,
                      ),
                      onPressed: saved
                          ? null
                          : () => state.addSavedQuery(query),
                    ),
                    IconButton(
                      tooltip: isPinned ? 'Unpin' : 'Pin to the top',
                      icon: Icon(
                        isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                      ),
                      onPressed: () => state.togglePinnedSearch(query),
                    ),
                  ],
                ),
              ),
            );
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .75,
              ),
              child: pinned.isEmpty && recent.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'No recent searches yet. Search tags to build your history.',
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          title: const Text('Recent searches'),
                          subtitle: const Text(
                            'Swipe a search away to delete it',
                          ),
                          leading: const Icon(Icons.history_rounded),
                        ),
                        if (pinned.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: SectionLabel('Pinned'),
                          ),
                          for (final query in pinned)
                            entry(query, isPinned: true),
                        ],
                        if (pinned.isNotEmpty && recent.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: SectionLabel('Recent'),
                          ),
                        for (final query in recent)
                          entry(query, isPinned: false),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showQueryPopup({
    required String title,
    required IconData headerIcon,
    required List<List<String>> queries,
    required String emptyMessage,
    required String deleteTooltip,
    required Future<void> Function(List<String>) onDelete,
    Map<String, Future<int?>> newCounts = const {},
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (newCounts[query.join(' ')] case final count?)
                            _NewPostsBadge(count: count),
                          IconButton(
                            tooltip: deleteTooltip,
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await onDelete(query);
                              if (context.mounted) Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  static int _hiddenCount(AppState state) =>
      state.filteredCounts.values.fold(0, (sum, count) => sum + count);

  /// Explains the "hidden" note: how many loaded posts each local filter
  /// left out, with shortcuts to the filters.
  Future<void> _showFiltered() async {
    final counts = widget.state.filteredCounts;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.filter_alt_outlined),
              title: Text('${_hiddenCount(widget.state)} posts hidden'),
              subtitle: const Text(
                'Your filters left these out of the pages loaded so far.',
              ),
            ),
            for (final reason in FilterReason.values)
              if (counts[reason] case final count? when count > 0)
                ListTile(
                  key: ValueKey('filtered_${reason.name}'),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: Text(reason.label),
                  trailing: Text(
                    '$count',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if ((counts[FilterReason.rating] ?? 0) > 0)
                    TextButton(
                      onPressed: () => Navigator.pop(context, 'ratings'),
                      child: const Text('Ratings'),
                    ),
                  FilledButton.tonal(
                    onPressed: () => Navigator.pop(context, 'settings'),
                    child: const Text('Filter settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'ratings':
        await _chooseRatings();
      case 'settings':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(state: widget.state),
          ),
        );
    }
  }

  Future<void> _pickDate() async {
    final board = widget.state.board;
    if (board == null) return;
    if (!board.supportsDateSearch) {
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
      // Sakugabooru (Moebooru) ignores created_at:.
      Board.danbooru || Board.sakugabooru => 'date:>=$value',
      // Sankaku rejects open-ended dates; close the range after today.
      Board.sankaku || Board.idolcomplex =>
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

  Future<void> _editBoardLayout() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _BoardLayoutSheet(state: widget.state),
  );

  Future<void> _chooseRatings() async {
    if (widget.state.board?.hasRatings == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This website does not rate posts, so rating filters do not apply.',
          ),
        ),
      );
      return;
    }
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
    // Nozomi only offers a popularity ordering.
    if (board == Board.nozomi) {
      return filter == 'score' ? 'order:popular' : null;
    }
    if (board.usesGelbooruSyntax) {
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
    if (board.isSankakuFamily) {
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
    listenable: Listenable.merge([widget.state, widget.state.downloads.busy]),
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
      onTap: _selecting
          ? () => _toggleSelected(post, board)
          : () => _openViewer(posts, board, index),
      isFavorite: state.isFavorite(post, board: board),
      isDownloaded: state.isDownloaded(post, board: board),
      selected: _selecting
          ? _selected.containsKey(SavedPost(board: board, post: post).identity)
          : null,
      blur: _shouldBlur(state, post),
      onLongPress: null,
      onLongPressOrigin: _selecting
          ? null
          : (origin, controller) => showQuickPostActions(
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

  /// The grid's columns at [width]: the setting on a phone held upright,
  /// more on wider screens (tablets, landscape) so tiles keep their size.
  static int _columnsFor(int columns, double width) => width <= 600
      ? columns
      : (columns * width / 400).round().clamp(columns, 12);

  // Pinch: the distance between the two fingers when the last column
  // change happened.
  final _pointers = <int, Offset>{};
  double? _pinchStart;

  /// Pinching the feed out makes tiles bigger (fewer columns), pinching in
  /// makes them smaller. Each step of the gesture changes one column.
  Widget _pinchColumns(Widget feed) => Listener(
    onPointerDown: (event) {
      _pointers[event.pointer] = event.position;
      _pinchStart = _pointers.length == 2 ? _pinchDistance() : null;
    },
    onPointerMove: (event) {
      if (!_pointers.containsKey(event.pointer)) return;
      _pointers[event.pointer] = event.position;
      final start = _pinchStart;
      if (start == null || start <= 0 || _pointers.length != 2) return;
      final ratio = _pinchDistance() / start;
      final columns = widget.state.settings.columns;
      final next = ratio > 1.3
          ? columns - 1
          : ratio < .77
          ? columns + 1
          : columns;
      if (next == columns || next < 1 || next > 6) return;
      _pinchStart = _pinchDistance();
      HapticFeedback.selectionClick();
      widget.state.setColumns(next);
    },
    onPointerUp: (event) => _endPointer(event.pointer),
    onPointerCancel: (event) => _endPointer(event.pointer),
    child: feed,
  );

  void _endPointer(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length != 2) _pinchStart = null;
  }

  double _pinchDistance() {
    final points = _pointers.values.toList();
    return (points[0] - points[1]).distance;
  }

  Widget _gallery(
    BuildContext context,
    AppState state,
    List<MediaPost> posts,
    Board board,
    int columns,
    double tileHeight,
    bool hierarchical,
    bool hidePostTags,
  ) {
    if (!hierarchical) {
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
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
        final start = rowIndex * columns;
        final end = (start + columns).clamp(0, posts.length).toInt();
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
      }, childCount: (posts.length / columns).ceil()),
    );
  }

  void _openFromDrawer(WidgetBuilder builder) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute<void>(builder: builder));
  }

  Future<void> _chooseBoardFromDrawer(Board option) async {
    Navigator.pop(context);
    _searchHistory.clear();
    _endSelection();
    await _persistFeed();
    await widget.state.chooseBoard(option);
  }

  /// The navigation drawer: a compact header and a row of shortcuts, so
  /// the website list gets most of the height. Settings can switch back to
  /// [_classicDrawer].
  Widget _drawer(Board board) {
    final state = widget.state;
    final incognito = state.settings.incognito;
    // The header (logo, shortcuts) stays solid; the website list below is
    // frosted so the feed shows through it.
    return Drawer(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: canvas,
            child: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 24, 0),
                    child: Row(
                      children: [
                        // The wordmark shrinks rather than pushing the
                        // icons out of a narrow drawer.
                        Expanded(
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Image(
                              image: AssetImage(logoAsset),
                              height: 30,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        // Compact, so the icons sit close together.
                        IconButton(
                          key: const ValueKey('drawer_safe_mode'),
                          tooltip: state.settings.safeMode
                              ? 'Safe mode is on · turn off'
                              : 'Safe mode: safe posts only, blurred',
                          visualDensity: VisualDensity.compact,
                          isSelected: state.settings.safeMode,
                          color: state.settings.safeMode ? accent : ink(.70),
                          icon: Icon(
                            state.settings.safeMode
                                ? Icons.shield_rounded
                                : Icons.shield_outlined,
                          ),
                          onPressed: () =>
                              state.setSafeMode(!state.settings.safeMode),
                        ),
                        IconButton(
                          tooltip: 'Learn to search',
                          visualDensity: VisualDensity.compact,
                          color: ink(.70),
                          icon: const Icon(Icons.help_outline_rounded),
                          onPressed: () => _openFromDrawer(
                            (_) => SearchGuideScreen(board: board),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('drawer_settings'),
                          tooltip: 'Settings',
                          visualDensity: VisualDensity.compact,
                          color: ink(.70),
                          icon: const Icon(Icons.settings_rounded),
                          onPressed: () => _openFromDrawer(
                            (_) => SettingsScreen(state: state),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
                    child: Text(
                      'Browsing ${board.label}',
                      style: TextStyle(color: ink(.54), fontSize: 13),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        _DrawerShortcut(
                          icon: Icons.favorite_rounded,
                          label: 'Favorites',
                          onTap: () => _openFromDrawer(
                            (_) => SavedPostsScreen(state: state),
                          ),
                        ),
                        _DrawerShortcut(
                          icon: Icons.download_done_rounded,
                          label: 'Downloads',
                          onTap: () => _openFromDrawer(
                            (_) => DownloadsScreen(state: state),
                          ),
                        ),
                        _DrawerShortcut(
                          icon: Icons.travel_explore_rounded,
                          label: 'All sites',
                          onTap: () => _openFromDrawer(
                            (_) => MultiSearchScreen(
                              state: state,
                              initialTags: state.tags,
                            ),
                          ),
                        ),
                        _DrawerShortcut(
                          key: const ValueKey('drawer_incognito'),
                          icon: incognito
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_outlined,
                          label: 'Incognito',
                          active: incognito,
                          onTap: () => state.setIncognito(!incognito),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(15, 6, 15, 0),
                    child: _ShortsEntry(
                      onTap: () =>
                          _openFromDrawer((_) => ShortsScreen(state: state)),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          Expanded(
            // Rounded like the drawer's bottom corner: the blur is clipped
            // by this surface alone, so a square corner would show past it.
            child: FrostedSurface(
              key: const ValueKey('drawer_websites'),
              color: canvas,
              borderRadius: const BorderRadius.only(
                bottomRight: Radius.circular(16),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Websites',
                              style: TextStyle(
                                color: ink(.54),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Reorder or hide websites',
                            visualDensity: VisualDensity.compact,
                            color: ink(.54),
                            icon: const Icon(Icons.tune_rounded, size: 20),
                            onPressed: _editBoardLayout,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                        children: [
                          // The current website stays listed even when hidden
                          // so the drawer always shows where you are.
                          for (final option in state.settings.boardOrder)
                            if (option == board ||
                                !state.settings.hiddenBoards.contains(option))
                              ListTile(
                                selected: option == board,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                leading: SiteLogo(option, size: 36),
                                title: Text(appearanceFor(option).name),
                                trailing: option == board
                                    ? const Icon(Icons.check_rounded, size: 20)
                                    : _BoardIssueBadge(
                                        state.boardIssue(option),
                                      ),
                                onTap: option == board
                                    ? null
                                    : () => _chooseBoardFromDrawer(option),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _classicDrawer(Board board) {
    final state = widget.state;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Everything above the footer scrolls, so short screens and
            // large text keep every entry reachable.
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Row(
                      children: [
                        Image(
                          image: AssetImage(logoAsset),
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
                      style: TextStyle(color: ink(.54)),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_rounded),
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
                  SwitchListTile(
                    secondary: Icon(
                      state.settings.incognito
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_outlined,
                    ),
                    title: const Text('Incognito'),
                    subtitle: const Text("Don't record searches or tags"),
                    value: state.settings.incognito,
                    onChanged: state.setIncognito,
                  ),
                  SwitchListTile(
                    secondary: Icon(
                      state.settings.safeMode
                          ? Icons.shield_rounded
                          : Icons.shield_outlined,
                    ),
                    title: const Text('Safe mode'),
                    subtitle: const Text('Safe posts only, others blurred'),
                    value: state.settings.safeMode,
                    onChanged: state.setSafeMode,
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
                  ListTile(
                    leading: const Icon(Icons.download_done_rounded),
                    title: const Text('Downloads'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => DownloadsScreen(state: state),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.travel_explore_rounded),
                    title: const Text('Search all sites'),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => MultiSearchScreen(
                            state: state,
                            initialTags: state.tags,
                          ),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    key: const ValueKey('drawer_shorts'),
                    leading: const Icon(Icons.smart_display_rounded),
                    title: const Text('booruShorts'),
                    onTap: () =>
                        _openFromDrawer((_) => ShortsScreen(state: state)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Websites',
                            style: TextStyle(
                              color: ink(.54),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Reorder or hide websites',
                          visualDensity: VisualDensity.compact,
                          color: ink(.54),
                          icon: const Icon(Icons.tune_rounded, size: 20),
                          onPressed: _editBoardLayout,
                        ),
                      ],
                    ),
                  ),
                  // The current website stays listed even when hidden
                  // so the drawer always shows where you are.
                  for (final option in state.settings.boardOrder)
                    if (option == board ||
                        !state.settings.hiddenBoards.contains(option))
                      ListTile(
                        dense: true,
                        selected: option == board,
                        leading: SiteLogo(option, size: 32),
                        title: Text(appearanceFor(option).name),
                        trailing: _BoardIssueBadge(state.boardIssue(option)),
                        onTap: option == board
                            ? null
                            : () async {
                                Navigator.pop(context);
                                _searchHistory.clear();
                                _endSelection();
                                await _persistFeed();
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
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Learn to search',
                        style: TextStyle(
                          color: ink(.70),
                          decoration: TextDecoration.underline,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'BooruPlus · Android',
                    style: TextStyle(color: ink(.38), fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
    final oneHanded = state.settings.oneHanded;
    final search = TagInput(
      tags: state.tags,
      onChanged: _search,
      autocomplete: state.autocomplete,
      postCount: state.postCountFor,
      suggestionsAbove: oneHanded,
    );
    final filters = FilterBar(
      board: board,
      tags: state.tags,
      selectedRatings: state.selectedRatings,
      onFilter: _chooseFilter,
      onDate: _pickDate,
      onRatings: _chooseRatings,
    );
    // With the keyboard up, back only closes it rather than leaving the
    // search.
    final keyboardOpen = _keyboardOpen;
    // While downloads run, leaving the app from here sends it to the
    // background instead of closing it, which would stop them.
    final downloading = state.downloads.busy.value;
    return PopScope<void>(
      canPop:
          !_selecting &&
          !keyboardOpen &&
          (_searchHistory.isEmpty || _drawerOpen) &&
          (!downloading || _drawerOpen),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (keyboardOpen) {
          FocusManager.instance.primaryFocus?.unfocus();
          return;
        }
        if (_drawerOpen) return;
        if (_selecting) {
          _endSelection();
        } else if (_searchHistory.isNotEmpty) {
          _handleBack();
        } else if (downloading) {
          _device.moveToBack();
        }
      },
      child: Scaffold(
        onDrawerChanged: (open) {
          // The drawer takes focus while open and hands it back when it
          // closes, which would reopen the keyboard on the search field.
          // Unfocusing also clears that remembered focus.
          FocusManager.instance.primaryFocus?.unfocus();
          if (_drawerOpen != open && mounted) {
            setState(() => _drawerOpen = open);
          }
        },
        drawerEnableOpenDragGesture: state.settings.gesturesEnabled,
        drawerEdgeDragWidth: state.settings.gesturesEnabled
            ? MediaQuery.sizeOf(context).width
            : null,
        appBar: _selecting && !oneHanded
            ? _selectionBar(board)
            : AppBar(
                backgroundColor: appBarSurface(board),
                // Tapping the title returns to the top of the feed.
                title: Semantics(
                  button: true,
                  label: 'Scroll to top',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _scrollToTop,
                    child: Row(
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
                  ),
                ),
                // One-handed mode keeps these in the bottom panel.
                actions: oneHanded
                    ? null
                    : [..._feedActions(), const SizedBox(width: 8)],
              ),
        drawer: state.settings.classicDrawer
            ? _classicDrawer(board)
            : _drawer(board),
        body: SafeArea(
          top: false,
          bottom: !oneHanded,
          child: Column(
            children: [
              // A thin red line under the app bar while incognito is on.
              if (state.settings.incognito)
                Container(
                  key: const ValueKey('incognito_line'),
                  height: 2,
                  color: const Color(0xFFE53935),
                ),
              if (!oneHanded) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(child: search),
                  ),
                ),
                Align(alignment: Alignment.centerLeft, child: filters),
              ],
              Padding(
                padding: EdgeInsets.fromLTRB(18, oneHanded ? 12 : 0, 18, 12),
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
                    if (state.settings.safeMode) ...[
                      Tooltip(
                        message: 'Safe mode is on',
                        child: Icon(
                          Icons.shield_rounded,
                          size: 14,
                          color: ink(.54),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      '${posts.length} posts',
                      style: TextStyle(fontSize: 12, color: ink(.38)),
                    ),
                    if (_hiddenCount(state) case final hidden when hidden > 0)
                      _HiddenNote(count: hidden, onTap: _showFiltered),
                  ],
                ),
              ),
              SizedBox(
                height: 3,
                child: state.loading
                    ? LinearProgressIndicator(
                        key: const ValueKey('feed_progress'),
                        minHeight: 3,
                        color: site.accent,
                        backgroundColor: site.accent.withValues(alpha: .15),
                      )
                    : null,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final columns = _columnsFor(
                      state.settings.columns,
                      bounds.maxWidth,
                    );
                    final tileHeight =
                        ((bounds.maxHeight - 8 * (state.settings.rows - 1)) /
                                state.settings.rows)
                            .clamp(88.0, 600.0);
                    final feed = RefreshIndicator(
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
                              columns,
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
                                          Icon(
                                            Icons.cloud_off_outlined,
                                            size: 32,
                                            color: ink(.54),
                                          ),
                                          const SizedBox(height: 12),
                                          Text(
                                            state.error!,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(color: ink(.60)),
                                          ),
                                          const SizedBox(height: 12),
                                          if (state.retryAt case final at?)
                                            _RetryCountdown(
                                              retryAt: at,
                                              onRetry: state.loadMore,
                                            )
                                          else
                                            OutlinedButton(
                                              onPressed: state.loadMore,
                                              child: const Text('Try again'),
                                            ),
                                        ],
                                      )
                                    : posts.isEmpty
                                    ? Column(
                                        children: [
                                          Icon(
                                            Icons.image_search_rounded,
                                            size: 42,
                                            color: ink(.38),
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
                                          Text(
                                            _hiddenCount(state) > 0
                                                ? 'Your filters hid ${_hiddenCount(state)} posts here.'
                                                : 'Try different tags or review your blacklist.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(color: ink(.54)),
                                          ),
                                          if (_hiddenCount(state) > 0)
                                            TextButton(
                                              onPressed: _showFiltered,
                                              child: const Text('See why'),
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
                                    : Text(
                                        'You’re all caught up',
                                        style: TextStyle(color: ink(.38)),
                                      ),
                              ),
                            ),
                          ),
                          if (oneHanded)
                            SliverToBoxAdapter(
                              child: SizedBox(height: _panelHeight),
                            ),
                        ],
                      ),
                    );
                    if (!oneHanded) return _pinchColumns(feed);
                    return Stack(
                      children: [
                        _pinchColumns(feed),
                        _scrollTopButton(),
                        // Filling the stack bounds the panel by the feed's
                        // height, so its search area shrinks to fit.
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: ValueListenableBuilder<bool>(
                              valueListenable: _panelHidden,
                              builder: (context, hidden, child) =>
                                  AnimatedSlide(
                                    offset: _panelIsHidden(hidden)
                                        ? const Offset(0, 1)
                                        : Offset.zero,
                                    duration: _panelSlideDuration,
                                    curve: Curves.easeOutCubic,
                                    child: child,
                                  ),
                              child: SizeReporter(
                                onHeight: (height) {
                                  if (mounted && height != _panelHeight) {
                                    setState(() => _panelHeight = height);
                                  }
                                },
                                child: _bottomPanel(board, search, filters),
                              ),
                            ),
                          ),
                        ),
                      ],
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

/// "N new" beside a saved search once its count arrives.
/// One of the drawer's shortcut buttons: an icon above a short label.
/// [active] tints it, for a mode that is on.
/// The compact drawer's booruShorts button, under the shortcut row.
class _ShortsEntry extends StatelessWidget {
  const _ShortsEntry({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      key: const ValueKey('drawer_shorts'),
      color: accent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Icon(Icons.smart_display_rounded, color: accent, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'booruShorts',
                      style: TextStyle(
                        color: ink(.87),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Swipe through videos from every site',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: ink(.54), fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: ink(.54)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerShortcut extends StatelessWidget {
  const _DrawerShortcut({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? Theme.of(context).colorScheme.primary : ink(.70);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: active ? color.withValues(alpha: .14) : ink(.05),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
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
}

/// "· 18 hidden" after the feed's post count; opens the reasons.
class _HiddenNote extends StatelessWidget {
  const _HiddenNote({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$count posts hidden by your filters',
    child: InkWell(
      key: const ValueKey('feed_hidden_note'),
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: ExcludeSemantics(
          child: Text(
            ' · $count hidden',
            style: TextStyle(
              fontSize: 12,
              color: ink(.54),
              decoration: TextDecoration.underline,
              decorationColor: ink(.38),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A website-list badge for a recent problem reaching the website.
class _BoardIssueBadge extends StatelessWidget {
  const _BoardIssueBadge(this.issue);
  final BoardIssue? issue;

  @override
  Widget build(BuildContext context) {
    final issue = this.issue;
    if (issue == null) return const SizedBox.shrink();
    return Tooltip(
      message: issue.label,
      child: Icon(
        switch (issue) {
          BoardIssue.rateLimited => Icons.hourglass_top_rounded,
          BoardIssue.apiOff => Icons.power_off_rounded,
          BoardIssue.unreachable => Icons.cloud_off_rounded,
        },
        size: 18,
        color: ink(.54),
        semanticLabel: issue.label,
      ),
    );
  }
}

class _NewPostsBadge extends StatelessWidget {
  const _NewPostsBadge({required this.count});
  final Future<int?> count;

  @override
  Widget build(BuildContext context) => FutureBuilder<int?>(
    future: count,
    builder: (context, snapshot) {
      final value = snapshot.data;
      if (value == null || value == 0) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          value >= 100 ? '99+ new' : '$value new',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    },
  );
}

/// Counts down a rate limit, then retries once by itself.
class _RetryCountdown extends StatefulWidget {
  const _RetryCountdown({required this.retryAt, required this.onRetry});
  final DateTime retryAt;
  final VoidCallback onRetry;

  @override
  State<_RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends State<_RetryCountdown> {
  Timer? _timer;
  bool _retried = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_RetryCountdown old) {
    super.didUpdateWidget(old);
    if (old.retryAt != widget.retryAt) _start();
  }

  void _start() {
    _retried = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    if (_remaining <= 0 && !_retried) {
      _retried = true;
      _timer?.cancel();
      widget.onRetry();
    }
    setState(() {});
  }

  int get _remaining =>
      (widget.retryAt.difference(DateTime.now()).inMilliseconds / 1000).ceil();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remaining;
    return Column(
      children: [
        Text(
          remaining > 0 ? 'Retrying in ${remaining}s' : 'Retrying…',
          style: TextStyle(color: ink(.54), fontSize: 13),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () {
            _timer?.cancel();
            _retried = true;
            widget.onRetry();
          },
          child: const Text('Try now'),
        ),
      ],
    );
  }
}

/// Reorders and hides drawer websites; every change is saved immediately.
class _BoardLayoutSheet extends StatefulWidget {
  const _BoardLayoutSheet({required this.state});
  final AppState state;
  @override
  State<_BoardLayoutSheet> createState() => _BoardLayoutSheetState();
}

class _BoardLayoutSheetState extends State<_BoardLayoutSheet> {
  late final List<Board> _order = [...widget.state.settings.boardOrder];
  late final Set<Board> _hidden = {...widget.state.settings.hiddenBoards};

  void _save() => widget.state.setBoardLayout(_order, _hidden);

  void _move(int from, int to) {
    setState(() => _order.insert(to, _order.removeAt(from)));
    _save();
  }

  void _toggle(Board board, bool visible) {
    setState(() => visible ? _hidden.remove(board) : _hidden.add(board));
    _save();
  }

  void _reset() {
    setState(() {
      _order
        ..clear()
        ..addAll(listedBoards);
      _hidden.clear();
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final visibleCount = _order.length - _hidden.length;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Websites'),
              subtitle: const Text('Drag to reorder. Switch off to hide.'),
              trailing: TextButton(
                onPressed: _reset,
                child: const Text('Reset'),
              ),
            ),
            Flexible(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: _order.length,
                onReorderItem: _move,
                itemBuilder: (context, index) {
                  final board = _order[index];
                  final visible = !_hidden.contains(board);
                  return ListTile(
                    key: ValueKey(board),
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.drag_handle_rounded),
                      ),
                    ),
                    title: Row(
                      children: [
                        Opacity(
                          opacity: visible ? 1 : .4,
                          child: SiteLogo(board, size: 28),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            appearanceFor(board).name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: visible ? null : ink(.38)),
                          ),
                        ),
                      ],
                    ),
                    trailing: Switch(
                      value: visible,
                      // The last visible website cannot be hidden.
                      onChanged: visible && visibleCount <= 1
                          ? null
                          : (value) => _toggle(board, value),
                    ),
                  );
                },
              ),
            ),
          ],
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
    this.isDownloaded = false,
    this.selected,
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
  final bool isDownloaded;

  /// Whether the post is selected; null outside selection mode.
  final bool? selected;
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
        ? Center(
            child: Icon(Icons.image_not_supported_outlined, color: ink(.24)),
          )
        : board == Board.gelbooru || MediaImage.fetchesNatively(board, url)
        ? MediaImage(
            url: url,
            board: board,
            fit: BoxFit.cover,
            cacheWidth: 480,
            errorWidget: Center(
              child: Icon(Icons.broken_image_outlined, color: ink(.24)),
            ),
            progressBuilder: (value) => TileProgress(value: value),
          )
        : Image(
            image: boundedImage(NetworkImage(url), width: 480),
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : TileProgress(
                    value: switch (progress.expectedTotalBytes) {
                      final total? when total > 0 =>
                        (progress.cumulativeBytesLoaded / total).clamp(
                          0.0,
                          1.0,
                        ),
                      _ => null,
                    },
                  ),
            errorBuilder: (_, _, _) => Center(
              child: Icon(Icons.broken_image_outlined, color: ink(.24)),
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
                  if (widget.isDownloaded)
                    Positioned(
                      left: 7,
                      bottom: 7,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.download_done_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
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
                  if (widget.selected case final selected?)
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: selected
                              ? accent.withValues(alpha: .22)
                              : Colors.transparent,
                          border: selected
                              ? Border.all(color: accent, width: 3)
                              : null,
                          borderRadius: BorderRadius.circular(12),
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

/// Whether [post] is covered by the blur settings.
bool shouldBlurPost(AppState state, MediaPost post) => _shouldBlur(state, post);

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
          videoUrl: post.isVideo
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
  } else if (action == 'uploader' && post.uploader.trim().isNotEmpty) {
    await state.hideUploader(post.uploader, board: board);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Posts by ${post.uploader} are hidden on ${board.label}.',
          ),
        ),
      );
    }
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

  /// Stream to autoplay (muted, looping, no controls) for video posts,
  /// once revealed when [blur] applies; null shows only the poster.
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
  final _uploaderKey = GlobalKey();
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
    if (!widget.blur) _startVideoIfAny();
  }

  void _startVideoIfAny() {
    final videoUrl = widget.videoUrl;
    if (_video == null && videoUrl != null && videoUrl.isNotEmpty) {
      _startVideo(videoUrl);
    }
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
      httpHeaders: videoHeaders(widget.board),
    );
    _video = video;
    bool stale() => !mounted || _closing || !identical(_video, video);
    // The poster stays until frames are actually playing, so the switch
    // never shows a black, still-buffering player.
    void showWhenPlaying() {
      final value = video.value;
      if (stale()) {
        video.removeListener(showWhenPlaying);
        return;
      }
      if (value.isPlaying && !value.isBuffering && value.position > .zero) {
        video.removeListener(showWhenPlaying);
        setState(() => _videoReady = true);
      }
    }

    try {
      await video.initialize();
      if (stale()) return;
      await video.setLooping(true);
      // A hold is a quick peek; stay silent until the post is opened.
      await video.setVolume(0);
      if (stale()) return;
      video.addListener(showWhenPlaying);
      await video.play();
    } catch (_) {
      // The poster remains when the stream cannot start.
    }
  }

  void _updateArmed(Offset position) {
    final next = _contains(_favoriteKey, position)
        ? 'favorite'
        : _contains(_hideKey, position)
        ? 'hide'
        : _contains(_uploaderKey, position)
        ? 'uploader'
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
        ? MediaImage.fetchesNatively(widget.board, post.previewUrl)
              ? MediaImage(
                  url: post.previewUrl,
                  board: widget.board,
                  fit: BoxFit.contain,
                  cacheWidth: 480,
                  errorWidget: const SizedBox.shrink(),
                  loadingWidget: const SizedBox.shrink(),
                )
              : Image(
                  image: boundedImage(
                    NetworkImage(post.previewUrl),
                    width: 480,
                  ),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
        : null;
    final Widget media = mediaUrl.isEmpty
        ? const Center(child: Icon(Icons.image_not_supported_outlined))
        : widget.board == Board.gelbooru ||
              MediaImage.fetchesNatively(widget.board, mediaUrl)
        ? MediaImage(
            url: mediaUrl,
            board: widget.board,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            errorWidget: widget.board == Board.gelbooru
                ? null
                : placeholder == null
                ? broken
                : const SizedBox.shrink(),
          )
        : Image(
            image: boundedImage(
              NetworkImage(mediaUrl),
              width: post.isVideo ? 480 : cacheWidth,
            ),
            fit: BoxFit.contain,
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
    final details = _details();
    final tags = post.tagDetails.take(3).toList();
    final chipHeight = 10 + textScaler.scale(15);
    final chrome =
        _inset * 2 +
        _gap * 2 +
        captionHeight +
        buttonHeight +
        (details.isEmpty ? 0 : chipHeight + _gap) +
        (tags.isEmpty ? 0 : chipHeight + _gap);
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
                                          onPressed: () {
                                            setState(() => _revealed = true);
                                            _startVideoIfAny();
                                          },
                                          icon: const Icon(Icons.visibility),
                                          label: const Text('Reveal media'),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (details.isNotEmpty) ...[
                              const SizedBox(height: _gap),
                              _chipRow([
                                for (final detail in details)
                                  _chip(detail, Colors.white),
                              ]),
                            ],
                            // The same tags the grid tile shows.
                            if (tags.isNotEmpty) ...[
                              const SizedBox(height: _gap),
                              _chipRow([
                                for (final tag in tags)
                                  _chip(tag.name, _tagColor(tag.category)),
                              ]),
                            ],
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
                                if (widget.post.uploader.trim().isNotEmpty) ...[
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _actionButton(
                                      key: _uploaderKey,
                                      action: 'uploader',
                                      icon: Icons.person_off_rounded,
                                      label: 'Uploader',
                                    ),
                                  ),
                                ],
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

  /// File type and, for images, resolution.
  List<String> _details() {
    final post = widget.post;
    return [
      if (post.fileType.isNotEmpty)
        '${post.fileType} ${post.isVideo ? 'video' : 'image'}'
      else
        post.isVideo ? 'Video' : 'Image',
      if (!post.isVideo && post.width > 0 && post.height > 0)
        '${post.width} × ${post.height}',
    ];
  }

  /// One line of chips; long ones shorten instead of wrapping, which keeps
  /// the card's height estimate exact.
  Widget _chipRow(List<Widget> chips) => Row(
    children: [
      for (var i = 0; i < chips.length; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Flexible(child: chips[i]),
      ],
    ],
  );

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: .6)),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 11, height: 1.2),
    ),
  );

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
    label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
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
    final noFavoriteOrder = !board.supportsFavoriteOrder;
    final sortItems = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'none', child: Text('Relevance / default')),
      const PopupMenuItem(value: 'score', child: Text('Popularity / score')),
      // Nozomi lists posts newest first or by popularity only.
      if (board != Board.nozomi) ...[
        if (!noFavoriteOrder)
          const PopupMenuItem(value: 'favorites', child: Text('Favorites')),
        const PopupMenuItem(value: 'quality', child: Text('Quality')),
        const PopupMenuItem(value: 'newest', child: Text('Newest')),
        const PopupMenuItem(value: 'oldest', child: Text('Oldest')),
      ],
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

/// A feed tile's loading indicator: a ring that fills as the preview
/// arrives, with the percentage inside, or spins when the size is unknown.
class TileProgress extends StatelessWidget {
  const TileProgress({super.key, required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return Center(
      child: SizedBox.square(
        key: const ValueKey('tile_progress'),
        dimension: 34,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 2.5,
                color: ink(.54),
                backgroundColor: ink(.08),
              ),
            ),
            if (value != null)
              Text(
                '${(value * 100).floor()}%',
                // The ring has a fixed size, so large text scales only a little.
                textScaler: MediaQuery.textScalerOf(context)
                    .clamp(maxScaleFactor: 1.15),
                style: TextStyle(
                  color: ink(.54),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
