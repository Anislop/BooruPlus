import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'theme.dart';

class SavedPostsScreen extends StatelessWidget {
  const SavedPostsScreen({super.key, required this.state, this.hidden = false});

  final AppState state;
  final bool hidden;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final posts = hidden ? state.hiddenPosts : state.favoritePosts;
      return Scaffold(
        appBar: AppBar(title: Text(hidden ? 'Hidden posts' : 'Favorites')),
        body: posts.isEmpty
            ? Center(
                child: Text(hidden ? 'No hidden posts.' : 'No favorites yet.'),
              )
            : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300,
                  mainAxisExtent: 354,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: posts.length,
                itemBuilder: (context, index) {
                  final saved = posts[index];
                  return _SavedPostCard(
                    state: state,
                    saved: saved,
                    display: state.displayReady(saved),
                    hidden: hidden,
                    allPosts: posts,
                    index: index,
                  );
                },
              ),
      );
    },
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
  });

  final AppState state;
  final SavedPost saved;
  final SavedPost display;
  final bool hidden;
  final List<SavedPost> allPosts;
  final int index;

  @override
  Widget build(BuildContext context) {
    final post = display.post;
    final quickActions = QuickActionOverlayController();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MediaTile(
            post: post,
            board: saved.board,
            isFavorite: !hidden,
            blur: _shouldBlur(post),
            onTap: () {
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
            onLongPress: hidden
                ? null
                : () => showQuickPostActions(
                    context,
                    post: post,
                    board: saved.board,
                    state: state,
                    isFavorite: state.isFavorite(post, board: saved.board),
                    controller: quickActions,
                  ),
            onLongPressMove: quickActions.update,
            onLongPressEnd: quickActions.release,
            onLongPressCancel: quickActions.cancel,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          post.description.isEmpty ? 'No description' : post.description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
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
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        if (hidden)
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
