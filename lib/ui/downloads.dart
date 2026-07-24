import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'site_catalog.dart';
import 'theme.dart';

/// Posts saved to the download folder, newest first. Removing an entry
/// only forgets it; the file stays.
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key, required this.state});
  final AppState state;

  Future<void> _clear(BuildContext context, List<DownloadRecord> all) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear download history?'),
        content: const Text(
          'Downloaded files stay in your download folder; only this list is cleared.',
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
    if (confirmed == true) await state.removeDownloadRecords(all);
  }

  static String _date(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final records = state.downloadHistory.reversed.toList(growable: false);
      final posts = [
        for (final record in records) state.displayReady(record.saved),
      ];
      return Scaffold(
        appBar: AppBar(
          title: const Text('Downloads'),
          actions: [
            if (records.isNotEmpty)
              IconButton(
                tooltip: 'Clear download history',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _clear(context, records),
              ),
          ],
        ),
        body: records.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Downloaded posts appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink(.54)),
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final record = records[index];
                  final saved = posts[index];
                  void open() => Navigator.push(
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
                  );
                  return ListTile(
                    onTap: open,
                    leading: SizedBox.square(
                      dimension: 56,
                      child: MediaTile(
                        key: ValueKey(record.saved.identity),
                        post: saved.post,
                        board: saved.board,
                        hidePostTags: true,
                        blur: shouldBlurPost(state, saved.post),
                        onTap: open,
                      ),
                    ),
                    title: Row(
                      children: [
                        SiteLogo(saved.board, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${saved.board.label} · #${saved.post.displayId}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Text(
                      _date(record.savedAt),
                      style: TextStyle(color: ink(.54)),
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove from history',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => state.removeDownloadRecords([record]),
                    ),
                  );
                },
              ),
      );
    },
  );
}
