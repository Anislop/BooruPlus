import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'site_catalog.dart';
import 'theme.dart';

/// Posts opened in the viewer from any website, newest first. Holding a
/// post removes it; the app bar clears them all.
class RecentlyViewedScreen extends StatelessWidget {
  const RecentlyViewedScreen({super.key, required this.state});
  final AppState state;

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear recently viewed?'),
        content: const Text(
          'Posts you opened are removed from this list. Favorites and downloads stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await state.clearRecentlyViewed();
  }

  Future<void> _remove(BuildContext context, SavedPost saved) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          key: const ValueKey('recently_viewed_remove'),
          leading: const Icon(Icons.delete_outline_rounded),
          title: const Text('Remove from recently viewed'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (remove == true) await state.removeRecentlyViewed([saved]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      // Refreshes expired media links (Sankaku) and Gelbooru credentials.
      final posts = [
        for (final saved in state.recentlyViewed) state.displayReady(saved),
      ];
      return Scaffold(
        appBar: AppBar(
          title: const Text('Recently viewed'),
          actions: [
            if (posts.isNotEmpty)
              IconButton(
                key: const ValueKey('recently_viewed_clear'),
                tooltip: 'Clear recently viewed',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _clear(context),
              ),
          ],
        ),
        body: posts.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    state.settings.incognito
                        ? 'Incognito is on, so posts you open are not recorded.'
                        : 'Posts you open from any website appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink(.54)),
                  ),
                ),
              )
            : SafeArea(
                top: false,
                child: GridView.builder(
                  key: const ValueKey('recently_viewed_grid'),
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: state.settings.columns,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: posts.length,
                  itemBuilder: (context, index) {
                    final saved = posts[index];
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
                          onLongPress: () => _remove(context, saved),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => MediaViewer(
                                post: saved.post,
                                board: saved.board,
                                state: state,
                                savedPosts: posts,
                                initialIndex: index,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 6,
                          left: 6,
                          child: IgnorePointer(
                            child: SiteLogo(
                              saved.board,
                              size: 20,
                              showBorder: true,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
      );
    },
  );
}
