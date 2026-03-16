import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'media_viewer.dart';
import 'settings.dart';
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

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final board = state.board!;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(
              child: Text(
                board.label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white38,
              size: 19,
            ),
          ],
        ),
        actions: [
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
              const Padding(
                padding: EdgeInsets.all(24),
                child: Row(
                  children: [
                    BrandMark(),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'BooruPlus',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
                leading: const Icon(Icons.swap_horiz_rounded),
                title: const Text('Change website'),
                onTap: () async {
                  Navigator.pop(context);
                  try {
                    await state.changeWebsite();
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not save the website change. Please try again.',
                          ),
                        ),
                      );
                    }
                  }
                },
              ),
              const Spacer(),
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
  const MediaTile({super.key, required this.post, required this.onTap});
  final MediaPost post;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
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
            Image.network(
              post.previewUrl.isNotEmpty ? post.previewUrl : post.url,
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
            ),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
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
