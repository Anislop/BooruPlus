import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'media_viewer.dart';
import 'media_image.dart';
import 'settings.dart';
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
  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 700 && widget.state.error == null) {
        widget.state.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _search(List<String> tags) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.state.search(tags);
  }

  Future<void> _saveAndShowQueries() async {
    if (widget.state.tags.isNotEmpty) {
      await widget.state.addSavedQuery(widget.state.tags);
    }
    if (mounted) await _showSavedQueries();
  }

  Future<void> _showSavedQueries() async {
    final savedQueries = widget.state.savedQueries;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: savedQueries.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'No saved searches yet. Search tags, then tap the bookmark to save them.',
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text('Saved searches'),
                    leading: Icon(Icons.bookmarks_outlined),
                  ),
                  for (final query in savedQueries)
                    ListTile(
                      title: Text(query.join(' ')),
                      leading: const Icon(Icons.search_rounded),
                      onTap: () {
                        Navigator.pop(context);
                        _search(query);
                      },
                      trailing: IconButton(
                        tooltip: 'Delete saved search',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await widget.state.removeSavedQuery(query);
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
    final value =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final dateTag = board == Board.danbooru
        ? 'date:>=$value'
        : 'created_at:>=$value';
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

  Widget _build(BuildContext context) {
    final state = widget.state;
    final board = state.board;
    if (board == null) return const SizedBox.shrink();
    final site = appearanceFor(board);
    return Scaffold(
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
          if (state.savedQueries.isNotEmpty)
            IconButton(
              tooltip: 'Open saved searches',
              onPressed: _showSavedQueries,
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
                      image: AssetImage('assets/LogoFullColor.png'),
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
                                await state.chooseBoard(option);
                              },
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Your boards. Your perspective.\nBooruPlus · Android',
                  style: TextStyle(color: Colors.white38, height: 1.7),
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
                  child: TagInput(tags: state.tags, onChanged: _search),
                ),
              ),
            ),
            FilterBar(
              board: board,
              tags: state.tags,
              onFilter: _chooseFilter,
              onDate: _pickDate,
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
                    '${state.posts.length} posts',
                    style: const TextStyle(fontSize: 12, color: Colors.white38),
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
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: state.settings.columns,
                                  mainAxisExtent: tileHeight,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final post = state.posts[index];
                              return MediaTile(
                                post: post,
                                board: board,
                                onTap: () async {
                                  final tag = await Navigator.push<String>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => MediaViewer(
                                        post: post,
                                        board: board,
                                        state: state,
                                      ),
                                    ),
                                  );
                                  if (tag != null && mounted) _search([tag]);
                                },
                              );
                            }, childCount: state.posts.length),
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
                                  : state.posts.isEmpty
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
    );
  }
}

class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.post,
    required this.board,
    required this.onTap,
  });
  final MediaPost post;
  final Board board;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
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
    return Semantics(
      label:
          '${post.isVideo ? 'Video' : 'Image'} ${post.id}, rating ${post.rating}',
      button: true,
      child: Material(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              media,
              if (post.isVideo)
                const Center(
                  child: CircleAvatar(
                    backgroundColor: Colors.black54,
                    radius: 20,
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white),
                  ),
                ),
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    post.rating.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.board,
    required this.tags,
    required this.onFilter,
    required this.onDate,
  });
  final Board board;
  final List<String> tags;
  final ValueChanged<String> onFilter;
  final VoidCallback onDate;

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
    final gelbooruSyntax = board == Board.gelbooru || board == Board.rule34;
    final sortItems = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'none', child: Text('Relevance / default')),
      const PopupMenuItem(value: 'score', child: Text('Popularity / score')),
      if (!gelbooruSyntax)
        const PopupMenuItem(value: 'favorites', child: Text('Favorites')),
      const PopupMenuItem(value: 'quality', child: Text('Quality')),
      const PopupMenuItem(value: 'newest', child: Text('Newest')),
      const PopupMenuItem(value: 'oldest', child: Text('Oldest')),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
            label: Text(date == null ? 'Date' : date.split('>=').last),
            onPressed: onDate,
          ),
        ],
      ),
    );
  }
}
