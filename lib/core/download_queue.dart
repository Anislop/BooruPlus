part of 'app_state.dart';

enum DownloadStatus { waiting, running, paused, failed }

/// How a [DownloadTask] ended.
enum DownloadResult {
  saved,
  failed,

  /// The download folder must be chosen again.
  folderLost,
  removed,
}

/// One post in [DownloadQueue].
class DownloadTask {
  DownloadTask._(this.saved, this.addedAt);

  /// The post, without credentials.
  final SavedPost saved;
  final DateTime addedAt;
  String get identity => saved.identity;

  DownloadStatus _status = DownloadStatus.waiting;
  DownloadStatus get status => _status;

  int _received = 0;
  int? _total;

  /// Bytes saved so far in this attempt (a resumed download counts what it
  /// saved before).
  int get received => _received;

  /// The file's size, once the host reports it.
  int? get total => _total;

  /// The share saved, or null while the size is unknown.
  double? get fraction {
    final total = _total;
    if (total == null || total <= 0) return null;
    return (_received / total).clamp(0.0, 1.0);
  }

  int _speed = 0;
  DateTime? _sampledAt;
  int _sampledBytes = 0;

  /// Recent transfer speed while running.
  int get bytesPerSecond => _status == DownloadStatus.running ? _speed : 0;

  String? _error;

  /// Why the last attempt failed.
  String? get error => _error;

  /// The partly written file a paused or interrupted download continues,
  /// the download folder it is in (null: Download/BooruPlus), and the size
  /// the website reported for it.
  String _partial = '';
  String? _partialDirectory;
  int? _partialTotal;

  void _forgetPartial() {
    _partial = '';
    _partialDirectory = null;
    _partialTotal = null;
  }

  DownloadControl? _control;
  bool _removed = false;
  Completer<DownloadResult> _settled = Completer<DownloadResult>();

  /// Completes when the post is saved, fails, or is removed; a pause does
  /// not complete it.
  Future<DownloadResult> get settled => _settled.future;

  bool get active =>
      _status == DownloadStatus.waiting || _status == DownloadStatus.running;

  void _settle(DownloadResult result) {
    if (!_settled.isCompleted) _settled.complete(result);
  }

  void _progress(int received, int? total) {
    _received = received;
    if (total != null) _total = total;
    final now = DateTime.now();
    final since = _sampledAt;
    if (since == null) {
      _sampledAt = now;
      _sampledBytes = received;
      return;
    }
    final elapsed = now.difference(since).inMilliseconds;
    if (elapsed >= 1000) {
      _speed = ((received - _sampledBytes) * 1000 / elapsed).round().clamp(
        0,
        1 << 40,
      );
      _sampledAt = now;
      _sampledBytes = received;
    }
  }

  PendingDownload _record() => PendingDownload(
    saved: saved,
    addedAt: addedAt,
    paused: _status == DownloadStatus.paused,
    failed: _status == DownloadStatus.failed,
    partial: _partial,
    partialDirectory: _partialDirectory,
    total: _partialTotal,
  );
}

/// The Download Manager's queue: posts waiting, running (at most
/// [AppSettings.downloadConcurrency] at once), paused, or failed. Finished
/// downloads leave it for the download history. It survives restarts
/// ([PostStore.saveDownloadQueue]); a paused or interrupted download keeps
/// its partial file and continues it with a range request when the website
/// allows. While downloads run, a foreground service keeps the app alive in
/// the background ([DownloadService.keepAlive]).
class DownloadQueue extends ChangeNotifier {
  DownloadQueue._(this._app);
  final AppState _app;
  final _tasks = <DownloadTask>[];
  final _byIdentity = <String, DownloadTask>{};
  Future<void> _saving = Future<void>.value();
  bool _disposed = false;
  bool _restored = false;

  /// Whether anything is running or waiting; changes far less often than
  /// the queue itself, for screens that only need that.
  final busy = ValueNotifier(false);

  /// The download folder must be chosen again; waiting downloads were
  /// paused.
  bool get folderLost => _folderLost;
  bool _folderLost = false;

  /// Downloads in the order they were added.
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  bool get isEmpty => _tasks.isEmpty;
  int count(DownloadStatus status) =>
      _tasks.where((task) => task.status == status).length;

  /// The queued download of [post], if any.
  DownloadTask? taskFor(MediaPost post, {Board? board}) =>
      _byIdentity[_app._identity(post, board)];

  /// Queues [saved] and returns its task. A post already in the queue is
  /// not added twice: a paused or failed one is resumed instead.
  DownloadTask add(SavedPost saved) {
    final post = saved.sanitized();
    final existing = _byIdentity[post.identity];
    if (existing != null) {
      if (!existing.active) resume(existing);
      return existing;
    }
    final task = DownloadTask._(post, DateTime.now());
    _tasks.add(task);
    _byIdentity[task.identity] = task;
    _changed(persist: true);
    _pump();
    return task;
  }

  /// Queues every post in [posts]; see [add].
  List<DownloadTask> addAll(Iterable<SavedPost> posts) => [
    for (final saved in posts) add(saved),
  ];

  /// Stops [task], keeping what it saved so far.
  void pause(DownloadTask task) {
    if (!task.active) return;
    if (task._status == DownloadStatus.running) {
      // _run marks it paused once the transfer stops.
      unawaited(task._control?.pause());
    }
    task._status = DownloadStatus.paused;
    _changed(persist: true);
    _pump();
  }

  /// Queues a paused or failed [task] again.
  void resume(DownloadTask task) {
    if (task.active || task._removed) return;
    if (task._settled.isCompleted) {
      task._settled = Completer<DownloadResult>();
    }
    task._status = DownloadStatus.waiting;
    task._error = null;
    _changed(persist: true);
    _pump();
  }

  /// Removes [task]; its partial file is deleted.
  Future<void> remove(DownloadTask task) async {
    if (task._removed) return;
    task._removed = true;
    _tasks.remove(task);
    _byIdentity.remove(task.identity);
    final control = task._control;
    if (control != null) {
      // Running: _run deletes the partial file once the transfer stops, and
      // reports whether it finished first.
      _stopping.add(task);
      await control.pause();
    } else {
      await _discardPartial(task);
      task._settle(DownloadResult.removed);
    }
    _changed(persist: true);
    _pump();
  }

  /// Removed downloads whose transfer is still stopping; they count toward
  /// the limit until it has.
  final _stopping = <DownloadTask>{};

  Future<void> _discardPartial(DownloadTask task) async {
    if (task._partial.isEmpty) return;
    await _app._downloads.discard(
      task._partial,
      directory: task._partialDirectory,
    );
    task._forgetPartial();
  }

  void pauseAll() {
    for (final task in _tasks) {
      if (task.active) pause(task);
    }
  }

  void resumeAll() {
    _folderLost = false;
    for (final task in [..._tasks]) {
      resume(task);
    }
  }

  /// Removes every download in the queue, or only the failed ones.
  Future<void> removeAll({bool failedOnly = false}) async {
    for (final task in [..._tasks]) {
      if (!failedOnly || task.status == DownloadStatus.failed) {
        await remove(task);
      }
    }
  }

  /// Loads the queue saved before the app closed and continues it.
  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    final List<PendingDownload> saved;
    try {
      saved = await _app._postStore.loadDownloadQueue();
    } catch (_) {
      return;
    }
    for (final record in saved) {
      final identity = record.saved.identity;
      if (_byIdentity.containsKey(identity)) continue;
      final task = DownloadTask._(record.saved, record.addedAt)
        .._status = record.failed
            ? DownloadStatus.failed
            : record.paused
            ? DownloadStatus.paused
            : DownloadStatus.waiting
        .._partial = record.partial
        .._partialDirectory = record.partialDirectory
        .._partialTotal = record.total;
      if (record.failed) task._error = 'Download failed.';
      _tasks.add(task);
      _byIdentity[identity] = task;
    }
    if (_tasks.isEmpty) return;
    _changed();
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    final limit = _app._settings.downloadConcurrency;
    // Transfers still stopping after a pause hold a download thread too.
    var running =
        _tasks.where((task) => task._control != null).length + _stopping.length;
    for (final task in [..._tasks]) {
      if (running >= limit) break;
      // A task resumed while its last transfer is still stopping waits for
      // that transfer to end; _run's cleanup pumps again.
      if (task._status != DownloadStatus.waiting || task._control != null) {
        continue;
      }
      running++;
      unawaited(_run(task));
    }
  }

  Future<void> _run(DownloadTask task) async {
    final directory = _app._settings.downloadDirectory;
    task
      .._status = DownloadStatus.running
      .._control = DownloadControl()
      .._error = null
      .._received = 0
      .._total = null
      .._speed = 0
      .._sampledAt = null;
    _changed(persist: true);
    DownloadResult? result;
    try {
      // A partial file in another folder than the current one cannot be
      // continued there.
      if (task._partial.isNotEmpty && task._partialDirectory != directory) {
        await _discardPartial(task);
      }
      final control = task._control = DownloadControl(
        resume: task._partial.isEmpty ? null : task._partial,
        resumeTotal: task._partialTotal,
      );
      if (control.resume == null) task._forgetPartial();
      control.onTarget = (uri) {
        task
          .._partial = uri
          .._partialDirectory = directory;
        _changed(persist: true);
      };
      if (task._removed || task._status != DownloadStatus.running) {
        // Paused or removed while an old partial file was being discarded.
        await control.pause();
      }
      await _app.downloadPost(
        task.saved.post,
        board: task.saved.board,
        control: control,
        onProgress: (received, total) {
          if (total != null) task._partialTotal = total;
          if (task._status != DownloadStatus.running) return;
          task._progress(received, total);
          _changed();
        },
      );
      task._forgetPartial();
      _tasks.remove(task);
      if (identical(_byIdentity[task.identity], task)) {
        _byIdentity.remove(task.identity);
      }
      result = DownloadResult.saved;
    } on DownloadPausedException catch (paused) {
      // Paused by the user, or resumed again meanwhile; a pause from the
      // app closing is marked below.
      final partial = paused.partial ?? task._control?.target;
      if (partial != null && partial != task._partial) {
        task
          .._partial = partial
          .._partialDirectory = directory;
      }
    } on PlatformException catch (error) {
      final folder =
          error.code == 'DIRECTORY_ACCESS' ||
          error.code == 'DIRECTORY_REQUIRED';
      result = _fail(
        task,
        folder
            ? 'Folder access expired. Choose your download folder again in Settings.'
            : 'Download failed. Check your connection, folder access, and free space.',
        folderLost: folder,
      );
    } catch (_) {
      result = _fail(task, 'Download unavailable. Try again later.');
    } finally {
      task._control = null;
      if (task._status == DownloadStatus.running) {
        task._status = DownloadStatus.paused;
      }
    }
    if (task._removed) {
      _stopping.remove(task);
      // Removed while running: whatever was saved meanwhile is kept.
      if (result != DownloadResult.saved) await _discardPartial(task);
      result = result == DownloadResult.saved
          ? DownloadResult.saved
          : DownloadResult.removed;
    }
    if (result != null) task._settle(result);
    _changed(persist: true);
    _pump();
  }

  /// Marks [task] failed. Its partial file stays for a retry to continue
  /// (the platform deletes one it cannot use).
  DownloadResult _fail(
    DownloadTask task,
    String message, {
    bool folderLost = false,
  }) {
    final result = folderLost
        ? DownloadResult.folderLost
        : DownloadResult.failed;
    if (task._removed) return result;
    task
      .._status = DownloadStatus.failed
      .._error = message;
    if (!folderLost) return result;
    // Every other download would fail the same way.
    _folderLost = true;
    for (final other in _tasks) {
      if (other._status == DownloadStatus.waiting) {
        other._status = DownloadStatus.paused;
      }
    }
    return result;
  }

  DateTime? _keptAliveAt;
  bool _keptAlive = false;

  void _changed({bool persist = false}) {
    if (_disposed) return;
    final active = _tasks.any((task) => task.active);
    busy.value = active;
    _keepAlive(active);
    if (persist) _persist();
    notifyListeners();
  }

  /// Starts, updates (at most once a second), or stops the foreground
  /// service that keeps downloads running in the background.
  void _keepAlive(bool active) {
    if (!active) {
      if (_keptAlive) {
        _keptAlive = false;
        _keptAliveAt = null;
        unawaited(_app._downloads.keepAlive(active: false));
      }
      return;
    }
    final now = DateTime.now();
    final last = _keptAliveAt;
    if (_keptAlive &&
        last != null &&
        now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _keptAlive = true;
    _keptAliveAt = now;
    final running = _tasks.where(
      (task) => task._status == DownloadStatus.running,
    );
    final waiting = count(DownloadStatus.waiting);
    var received = 0, total = 0;
    var known = true;
    for (final task in running) {
      final size = task.total;
      if (size == null) {
        known = false;
        break;
      }
      received += task.received;
      total += size;
    }
    final text = [
      if (running.isNotEmpty) '${running.length} downloading',
      if (waiting > 0) '$waiting waiting',
    ].join(' · ');
    unawaited(
      _app._downloads.keepAlive(
        active: true,
        text: text,
        percent: known && total > 0 ? received * 100 ~/ total : null,
      ),
    );
  }

  void _persist() {
    final records = [for (final task in _tasks) task._record()];
    _saving = _saving.then((_) async {
      try {
        await _app._postStore.saveDownloadQueue(records);
      } catch (_) {
        // The queue still runs; only a restart could lose it.
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    busy.dispose();
    super.dispose();
  }
}
