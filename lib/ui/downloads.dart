import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'home.dart';
import 'media_viewer.dart';
import 'settings.dart';
import 'site_catalog.dart';
import 'theme.dart';

/// Queues [posts] in the Download Manager. Posts already downloaded are
/// skipped or downloaded again, as the user chooses; returns how many were
/// queued, or null when cancelled. A notice offers to open the manager.
Future<int?> queueDownloads(
  BuildContext context,
  AppState state,
  List<SavedPost> posts,
) async {
  if (posts.isEmpty) return 0;
  var queue = posts;
  final downloaded = posts
      .where((saved) => state.isDownloaded(saved.post, board: saved.board))
      .length;
  if (downloaded > 0) {
    final skip = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          downloaded == posts.length
              ? 'Already downloaded'
              : '$downloaded already downloaded',
        ),
        content: Text(
          downloaded == posts.length
              ? 'You have downloaded ${downloaded == 1 ? 'this post' : 'these posts'} before.'
              : '$downloaded of the ${posts.length} selected posts were downloaded before.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Download again'),
          ),
          if (downloaded < posts.length)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Skip them'),
            ),
        ],
      ),
    );
    if (skip == null || !context.mounted) return null;
    if (skip) {
      queue = [
        for (final saved in posts)
          if (!state.isDownloaded(saved.post, board: saved.board)) saved,
      ];
    }
  }
  state.downloads.addAll(queue);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          'Added ${queue.length} post${queue.length == 1 ? '' : 's'} to downloads.',
        ),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => DownloadsScreen(state: state),
            ),
          ),
        ),
      ),
    );
  return queue.length;
}

/// The Download Manager: downloads in progress (running, waiting, paused,
/// failed) above the completed ones, each section collapsible. Removing a
/// completed entry only forgets it; the file stays.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _activeOpen = true;
  bool _completedOpen = true;

  AppState get _state => widget.state;

  Future<void> _clearHistory(List<DownloadRecord> all) async {
    final confirmed = await _confirm(
      title: 'Clear download history?',
      content: 'Downloaded files stay in your download folder; only this list is cleared.',
      action: 'Clear',
    );
    if (confirmed) await _state.removeDownloadRecords(all);
  }

  Future<void> _cancelAll() async {
    final confirmed = await _confirm(
      title: 'Cancel all downloads?',
      content: 'Unfinished downloads are removed, with what they saved so far.',
      action: 'Cancel all',
    );
    if (confirmed) await _state.downloads.removeAll();
  }

  Future<bool> _confirm({
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
              child: const Text('Keep'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _chooseConcurrency() async {
    final current = _state.settings.downloadConcurrency;
    final value = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.speed_rounded),
              title: Text('Downloads at once'),
              subtitle: Text('More at once can finish a batch sooner.'),
            ),
            for (
              var count = 1;
              count <= AppSettings.maxDownloadConcurrency;
              count++
            )
              ListTile(
                title: Text('$count'),
                selected: count == current,
                trailing: count == current
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, count),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value != null) await _state.setDownloadConcurrency(value);
  }

  void _open(List<SavedPost> posts, int index) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => MediaViewer(
        post: posts[index].post,
        board: posts[index].board,
        state: _state,
        savedPosts: posts,
        initialIndex: index,
      ),
    ),
  );

  static String _date(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_state, _state.downloads]),
    builder: (context, _) {
      final queue = _state.downloads;
      final tasks = queue.tasks;
      final records = _state.downloadHistory.reversed.toList(growable: false);
      final completed = [
        for (final record in records) _state.displayReady(record.saved),
      ];
      final queued = [
        for (final task in tasks) _state.displayReady(task.saved),
      ];
      final anyActive = tasks.any((task) => task.active);
      final anyStopped = tasks.any((task) => !task.active);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Downloads'),
          actions: [
            if (anyActive)
              IconButton(
                tooltip: 'Pause all',
                icon: const Icon(Icons.pause_rounded),
                onPressed: queue.pauseAll,
              )
            else if (anyStopped)
              IconButton(
                tooltip: 'Resume all',
                icon: const Icon(Icons.play_arrow_rounded),
                onPressed: queue.resumeAll,
              ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) => switch (value) {
                'concurrency' => _chooseConcurrency(),
                'retry' => queue.resumeAll(),
                'removeFailed' => queue.removeAll(failedOnly: true),
                'cancelAll' => _cancelAll(),
                'clear' => _clearHistory(records),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'concurrency',
                  child: Text(
                    'Downloads at once: ${_state.settings.downloadConcurrency}',
                  ),
                ),
                if (queue.count(DownloadStatus.failed) > 0) ...[
                  const PopupMenuItem(
                    value: 'retry',
                    child: Text('Retry failed'),
                  ),
                  const PopupMenuItem(
                    value: 'removeFailed',
                    child: Text('Remove failed'),
                  ),
                ],
                if (tasks.isNotEmpty)
                  const PopupMenuItem(
                    value: 'cancelAll',
                    child: Text('Cancel all downloads'),
                  ),
                if (records.isNotEmpty)
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text('Clear download history'),
                  ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: tasks.isEmpty && records.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Downloads in progress and downloaded posts appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: ink(.54)),
                  ),
                ),
              )
            : CustomScrollView(
                slivers: [
                  if (queue.folderLost)
                    SliverToBoxAdapter(child: _folderNotice(context)),
                  if (tasks.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        key: const ValueKey('downloads_active_header'),
                        title: 'In progress',
                        count: tasks.length,
                        summary: _summary(queue),
                        open: _activeOpen,
                        onTap: () => setState(() => _activeOpen = !_activeOpen),
                      ),
                    ),
                    if (_activeOpen)
                      SliverList.builder(
                        itemCount: tasks.length,
                        itemBuilder: (context, index) => _TaskTile(
                          key: ValueKey(
                            'download_task:${tasks[index].identity}',
                          ),
                          task: tasks[index],
                          shown: queued[index],
                          state: _state,
                          onOpen: () => _open(queued, index),
                        ),
                      ),
                  ],
                  if (records.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        key: const ValueKey('downloads_completed_header'),
                        title: 'Completed',
                        count: records.length,
                        open: _completedOpen,
                        onTap: () =>
                            setState(() => _completedOpen = !_completedOpen),
                      ),
                    ),
                    if (_completedOpen)
                      SliverList.builder(
                        itemCount: records.length,
                        itemBuilder: (context, index) {
                          final record = records[index];
                          final saved = completed[index];
                          return ListTile(
                            key: ValueKey(
                              'download_record:${record.saved.identity}',
                            ),
                            onTap: () => _open(completed, index),
                            leading: _Thumbnail(
                              saved: saved,
                              state: _state,
                              onTap: () => _open(completed, index),
                            ),
                            title: _PostTitle(saved: saved),
                            subtitle: Text(
                              _date(record.savedAt),
                              style: TextStyle(color: ink(.54)),
                            ),
                            trailing: IconButton(
                              tooltip: 'Remove from history',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () =>
                                  _state.removeDownloadRecords([record]),
                            ),
                          );
                        },
                      ),
                  ],
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 16 + MediaQuery.paddingOf(context).bottom,
                    ),
                  ),
                ],
              ),
      );
    },
  );

  static String _summary(DownloadQueue queue) => [
    for (final (status, label) in const [
      (DownloadStatus.running, 'downloading'),
      (DownloadStatus.waiting, 'waiting'),
      (DownloadStatus.paused, 'paused'),
      (DownloadStatus.failed, 'failed'),
    ])
      if (queue.count(status) case final count when count > 0) '$count $label',
  ].join(' · ');

  Widget _folderNotice(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Material(
      color: accent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Folder access expired. Choose your download folder again in Settings, then resume.',
              style: TextStyle(color: ink(.87)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(state: _state),
                  ),
                ),
                child: const Text('Open Settings'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A collapsible section title: label, count, an optional summary line, and
/// a chevron that turns as it opens.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.open,
    required this.onTap,
    this.summary = '',
  });
  final String title, summary;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${title.toUpperCase()} · $count',
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        summary,
                        style: TextStyle(color: ink(.54), fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              AnimatedRotation(
                turns: open ? 0 : -.25,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.expand_more_rounded,
                  color: ink(.54),
                  semanticLabel: open ? 'Collapse $title' : 'Expand $title',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.saved,
    required this.state,
    required this.onTap,
  });
  final SavedPost saved;
  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 56,
    child: MediaTile(
      key: ValueKey(saved.identity),
      post: saved.post,
      board: saved.board,
      hidePostTags: true,
      blur: shouldBlurPost(state, saved.post),
      onTap: onTap,
    ),
  );
}

class _PostTitle extends StatelessWidget {
  const _PostTitle({required this.saved});
  final SavedPost saved;

  @override
  Widget build(BuildContext context) => Row(
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
  );
}

/// One unfinished download: progress, sizes and speed, and pause, resume
/// (retry), or cancel.
class _TaskTile extends StatelessWidget {
  const _TaskTile({
    super.key,
    required this.task,
    required this.shown,
    required this.state,
    required this.onOpen,
  });
  final DownloadTask task;
  final SavedPost shown;
  final AppState state;
  final VoidCallback onOpen;

  String get _status {
    final total = task.total;
    final sizes = total == null
        ? task.received > 0
              ? formatBytes(task.received)
              : ''
        : '${formatBytes(task.received)} of ${formatBytes(total)}';
    return switch (task.status) {
      DownloadStatus.running => [
        if (sizes.isNotEmpty) sizes else 'Starting…',
        if (task.bytesPerSecond > 0) '${formatBytes(task.bytesPerSecond)}/s',
      ].join(' · '),
      DownloadStatus.waiting => 'Waiting',
      DownloadStatus.paused => sizes.isEmpty ? 'Paused' : 'Paused · $sizes',
      DownloadStatus.failed => task.error ?? 'Download failed.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final queue = state.downloads;
    final failed = task.status == DownloadStatus.failed;
    return ListTile(
      onTap: onOpen,
      leading: _Thumbnail(saved: shown, state: state, onTap: onOpen),
      title: _PostTitle(saved: shown),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: task.status == DownloadStatus.running
                  ? task.fraction
                  : task.fraction ?? 0,
              color: failed ? ink(.38) : accent,
              backgroundColor: ink(.12),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ink(failed ? .70 : .54), fontSize: 12),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.active)
            IconButton(
              tooltip: 'Pause',
              icon: const Icon(Icons.pause_rounded),
              onPressed: () => queue.pause(task),
            )
          else
            IconButton(
              tooltip: failed ? 'Retry' : 'Resume',
              icon: Icon(
                failed ? Icons.refresh_rounded : Icons.play_arrow_rounded,
              ),
              onPressed: () => queue.resume(task),
            ),
          IconButton(
            tooltip: 'Cancel download',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => queue.remove(task),
          ),
        ],
      ),
    );
  }
}
