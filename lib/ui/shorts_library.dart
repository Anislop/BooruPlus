import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'site_catalog.dart';
import 'theme.dart';

String _display(String tag) => tag.replaceAll('_', ' ');

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String content,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

/// Videos watched in booruShorts for at least two seconds, newest first.
class ShortsHistoryScreen extends StatelessWidget {
  const ShortsHistoryScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final posts = [
        for (final saved in state.shortsProfile.history)
          state.displayReady(saved),
      ];
      return Scaffold(
        appBar: AppBar(
          title: const Text('Watch history'),
          actions: [
            if (posts.isNotEmpty)
              IconButton(
                key: const ValueKey('shorts_history_clear'),
                tooltip: 'Clear watch history',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  if (await _confirm(
                    context,
                    title: 'Clear watch history?',
                    content: 'booruShorts also forgets which videos you have seen, so they can show up again.',
                    action: 'Clear',
                  )) {
                    await state.clearShortsHistory();
                  }
                },
              ),
          ],
        ),
        body: posts.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    state.settings.incognito
                        ? 'Incognito is on, so booruShorts is not keeping a history.'
                        : 'Videos you watch in booruShorts appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink(.54)),
                  ),
                ),
              )
            : GridView.builder(
                key: const ValueKey('shorts_history'),
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  childAspectRatio: 9 / 14,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
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
                        blur: shouldBlurPost(state, saved.post),
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
                        left: 6,
                        bottom: 6,
                        child: IgnorePointer(
                          child: SiteLogo(saved.board, size: 18),
                        ),
                      ),
                    ],
                  );
                },
              ),
      );
    },
  );
}

/// What booruShorts learned: liked tags, tags shown less, and muted tags,
/// each removable, plus a full reset.
class ShortsInterestsScreen extends StatelessWidget {
  const ShortsInterestsScreen({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final profile = state.shortsProfile;
      final weights = profile.tagWeights.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final liked = weights.where((entry) => entry.value > 0).take(40);
      final disliked = weights.reversed
          .where((entry) => entry.value < 0)
          .take(40);
      final muted = profile.mutedTags.toList()..sort();
      final hasAny = weights.isNotEmpty || muted.isNotEmpty;
      Widget tag(MapEntry<String, double> entry) => ListTile(
        title: Text(_display(entry.key)),
        subtitle: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (entry.value.abs() / 3).clamp(0.0, 1.0),
            minHeight: 5,
            color: entry.value > 0 ? null : Theme.of(context).colorScheme.error,
          ),
        ),
        trailing: IconButton(
          tooltip: 'Forget',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => state.forgetShortsTag(entry.key),
        ),
      );
      Widget label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            color: ink(.54),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      return Scaffold(
        appBar: AppBar(
          title: const Text('Your booruShorts interests'),
          actions: [
            if (weights.isNotEmpty)
              IconButton(
                key: const ValueKey('shorts_interests_reset'),
                tooltip: 'Reset recommendations',
                icon: const Icon(Icons.restart_alt_rounded),
                onPressed: () async {
                  if (await _confirm(
                    context,
                    title: 'Reset recommendations?',
                    content: 'booruShorts forgets what you liked and disliked and goes back to random videos. Muted tags and your watch history stay.',
                    action: 'Reset',
                  )) {
                    await state.resetShortsInterests();
                  }
                },
              ),
          ],
        ),
        body: ListView(
          key: const ValueKey('shorts_interests'),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                state.settings.shortsPersonalized
                    ? 'Learned on this device from likes, dislikes, and how long you watch. Nothing is sent to the websites.'
                    : 'Personalization is off in Settings › booruShorts, so videos play in random order and nothing new is learned.',
                style: TextStyle(color: ink(.60), fontSize: 13, height: 1.4),
              ),
            ),
            if (!hasAny)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing learned yet. Like or skip a few videos in booruShorts.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ink(.54)),
                ),
              ),
            if (liked.isNotEmpty) ...[
              label('More of'),
              for (final entry in liked) tag(entry),
            ],
            if (disliked.isNotEmpty) ...[
              label('Less of'),
              for (final entry in disliked) tag(entry),
            ],
            if (muted.isNotEmpty) ...[
              label('Not interested'),
              for (final name in muted)
                ListTile(
                  leading: const Icon(Icons.block_rounded),
                  title: Text(_display(name)),
                  trailing: TextButton(
                    onPressed: () => state.unmuteShortsTag(name),
                    child: const Text('Show again'),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

/// Opens the watch history from anywhere booruShorts is reachable.
Future<void> openShortsHistory(BuildContext context, AppState state) =>
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ShortsHistoryScreen(state: state),
      ),
    );

Future<void> openShortsInterests(BuildContext context, AppState state) =>
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ShortsInterestsScreen(state: state),
      ),
    );
