import 'package:flutter/foundation.dart';

import 'models.dart';
import 'services.dart';

class AppState extends ChangeNotifier {
  AppState({BoardRepository? repository, SettingsStore? store})
    : _repository = repository ?? PlatformBoardRepository(),
      _store = store ?? LocalSettingsStore();
  final BoardRepository _repository;
  final SettingsStore _store;
  AppSettings _settings = const AppSettings();
  Board? _board;
  List<MediaPost> _posts = const [];
  List<String> _tags = const [];
  bool _loading = false, _hasMore = true, _initialized = false;
  String? _error;
  int _generation = 0, _page = -1;
  Credentials? _credentials;

  AppSettings get settings => _settings;
  Board? get board => _board;
  List<MediaPost> get posts => List.unmodifiable(_posts);
  List<String> get tags => List.unmodifiable(_tags);
  bool get loading => _loading;
  String? get error => _error;
  bool get hasMore => _hasMore;
  bool get initialized => _initialized;

  Future<void> initialize() async {
    try {
      final settings = await _store.loadSettings();
      final board = await _store.loadBoard();
      final credentials = board == null
          ? null
          : await _store.loadCredentials(board);
      _settings = settings;
      _board = board;
      _credentials = credentials;
    } catch (error) {
      _error = _friendly(error);
    }
    _initialized = true;
    notifyListeners();
    if (_board != null && _error == null) {
      await _load(reset: true, generation: _generation);
    }
  }

  Future<void> chooseBoard(Board value, {Credentials? credentials}) async {
    _invalidate();
    final generation = _generation;
    try {
      final loadedCredentials =
          credentials ?? await _store.loadCredentials(value);
      if (generation != _generation) return;
      await _store.saveBoard(value);
      if (generation != _generation) return;
      _board = value;
      _credentials = loadedCredentials;
      _clearResults();
      _tags = const [];
      notifyListeners();
      await _load(reset: true, generation: generation);
    } catch (error) {
      if (generation == _generation) {
        _error = _friendly(error);
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> changeWebsite() async {
    try {
      await _store.saveBoard(null);
    } catch (error) {
      _error = _friendly(error);
      notifyListeners();
      return;
    }
    _invalidate();
    _board = null;
    _credentials = null;
    _clearResults();
    _tags = const [];
    _error = null;
    notifyListeners();
  }

  Future<void> search(List<String> value) async {
    _invalidate();
    _tags = value
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    _clearResults();
    notifyListeners();
    if (_board != null) await _load(reset: true, generation: _generation);
  }

  Future<void> refresh() async {
    _invalidate();
    _clearResults();
    notifyListeners();
    await _load(reset: true, generation: _generation);
  }

  Future<void> loadMore() async {
    if (!_loading && _hasMore) {
      await _load(reset: false, generation: _generation);
    }
  }

  Future<void> updateSettings(AppSettings value) async {
    final normalized = value.normalized();
    await _store.saveSettings(normalized);
    _settings = normalized;
    _invalidate();
    _clearResults();
    notifyListeners();
    await _load(reset: true, generation: _generation);
  }

  Future<Credentials?> credentialsFor(Board value) =>
      _store.loadCredentials(value);
  Future<void> saveCredentials(Board value, Credentials credentials) async {
    await _store.saveCredentials(value, credentials);
    if (value == _board) _credentials = credentials;
    notifyListeners();
  }

  Future<void> forgetCredentials(Board value) async {
    await _store.removeCredentials(value);
    if (value == _board) {
      _invalidate();
      _credentials = null;
      _clearResults();
      _error = value.requiresAuth
          ? 'Authentication is required for ${value.label}.'
          : null;
    }
    notifyListeners();
  }

  Future<bool> authenticate(Board value, Credentials credentials) async {
    if (!credentials.isValid) {
      throw ArgumentError('A user ID and API key are required.');
    }
    await _repository.fetch(
      board: value,
      tags: const [],
      limit: 1,
      page: 0,
      random: false,
      credentials: credentials,
    );
    await _store.saveCredentials(value, credentials);
    if (value == _board) {
      _invalidate();
      _credentials = credentials;
      _clearResults();
      notifyListeners();
      await _load(reset: true, generation: _generation);
    }
    return true;
  }

  Future<void> _load({required bool reset, required int generation}) async {
    if (generation != _generation || _board == null) return;
    if (_board!.requiresAuth && _credentials == null) {
      _error = 'Authentication is required for ${_board!.label}.';
      notifyListeners();
      return;
    }
    _loading = true;
    _error = null;
    notifyListeners();
    final page = reset ? 0 : _page + 1;
    try {
      var accepted = <MediaPost>[];
      var currentPage = page;
      var lastFetchedPage = page;
      for (var attempt = 0; attempt < 3 && accepted.isEmpty; attempt++) {
        final raw = await _repository.fetch(
          board: _board!,
          tags: _queryTags(),
          limit: _settings.batchSize,
          page: currentPage,
          random: _tags.isEmpty,
          credentials: _credentials,
        );
        if (generation != _generation) return;
        lastFetchedPage = currentPage;
        if (raw.isEmpty) {
          _hasMore = false;
          break;
        }
        final incoming = raw.map(MediaPost.fromMap).where(_allowed).toList();
        final seen = _posts.map((post) => post.id).toSet();
        accepted = incoming.where((post) => seen.add(post.id)).toList();
        if (raw.length < _settings.batchSize) {
          _hasMore = false;
          if (accepted.isEmpty) break;
        }
        if (accepted.isEmpty && raw.length >= _settings.batchSize) {
          currentPage++;
        }
      }
      if (generation != _generation) return;
      _page = lastFetchedPage;
      _posts = [...(reset ? const <MediaPost>[] : _posts), ...accepted];
    } catch (error) {
      if (generation == _generation) _error = _friendly(error);
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  List<String> _queryTags() => [
    ..._tags,
    ..._settings.blacklist.map((tag) => '-$tag'),
  ];
  bool _allowed(MediaPost post) => !_settings.blacklist.any(
    (blocked) =>
        post.tags.any((tag) => tag.toLowerCase() == blocked.toLowerCase()),
  );
  void _clearResults() {
    _posts = const [];
    _page = -1;
    _hasMore = true;
  }

  void _invalidate() {
    _generation++;
    _loading = false;
  }

  String _friendly(Object error) =>
      'Unable to load ${_board?.label ?? 'the selected board'}. Check your connection and search tag limits. If this website needs an API key, reconnect in Settings.';
}
