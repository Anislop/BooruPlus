import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'services.dart';

class AppState extends ChangeNotifier {
  AppState({
    BoardRepository? repository,
    SettingsStore? store,
    PostStore? postStore,
  }) : _repository = repository ?? PlatformBoardRepository(),
       _store = store ?? LocalSettingsStore(),
       _postStore =
           postStore ??
           (store == null || store is LocalSettingsStore
               ? LocalPostStore()
               : MemoryPostStore());
  final BoardRepository _repository;
  final SettingsStore _store;
  final PostStore _postStore;
  AppSettings _settings = const AppSettings();
  Board? _board;
  List<MediaPost> _posts = const [];
  List<String> _tags = const [];
  bool _loading = false, _hasMore = true, _initialized = false;
  String? _error;
  int _generation = 0, _page = -1;
  int _autocompleteGeneration = 0;
  int? _randomSeed;
  Credentials? _credentials;
  final Map<Board, Credentials?> _credentialsByBoard = {};
  List<SavedPost> _favoritePosts = const [];
  List<SavedPost> _hiddenPosts = const [];

  AppSettings get settings => _settings;
  Board? get board => _board;
  List<MediaPost> get posts => List.unmodifiable(_posts);
  List<String> get tags => List.unmodifiable(_tags);
  bool get loading => _loading;
  String? get error => _error;
  bool get hasMore => _hasMore;
  bool get initialized => _initialized;
  List<List<String>> get savedQueries =>
      List.unmodifiable(_settings.savedQueries);
  List<SavedPost> get favoritePosts => List.unmodifiable(_favoritePosts);
  List<SavedPost> get hiddenPosts => List.unmodifiable(_hiddenPosts);
  bool isFavorite(MediaPost post, {Board? board}) => _favoritePosts.any(
    (saved) => saved.identity == _saved(post, board).identity,
  );
  bool isHidden(MediaPost post, {Board? board}) => _hiddenPosts.any(
    (saved) => saved.identity == _saved(post, board).identity,
  );

  SavedPost displayReady(SavedPost post) =>
      post.authorized(_credentialsByBoard[post.board]);
  MediaPost authorizedPost(MediaPost post, {Board? board}) =>
      displayReady(_saved(post, board)).post;

  Future<void> toggleFavorite(MediaPost post, {Board? board}) async {
    if (isFavorite(post, board: board)) {
      await unfavoritePost(post, board: board);
    } else {
      await favoritePost(post, board: board);
    }
  }

  Future<void> favoritePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    if (_favoritePosts.any((value) => value.identity == saved.identity)) return;
    _favoritePosts = [..._favoritePosts, saved];
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  Future<void> unfavoritePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    _favoritePosts = _favoritePosts
        .where((value) => value.identity != saved.identity)
        .toList(growable: false);
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  Future<void> hidePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    if (!_hiddenPosts.any((value) => value.identity == saved.identity)) {
      _hiddenPosts = [..._hiddenPosts, saved];
      await _postStore.saveHidden(_hiddenPosts);
    }
    if (saved.board == _board) {
      _posts = _posts
          .where((value) => _postKey(value) != _postKey(post))
          .toList();
    }
    notifyListeners();
  }

  Future<void> unhidePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    _hiddenPosts = _hiddenPosts
        .where((value) => value.identity != saved.identity)
        .toList(growable: false);
    await _postStore.saveHidden(_hiddenPosts);
    notifyListeners();
  }

  Future<List<TagSuggestion>> autocomplete(String query) async {
    final generation = ++_autocompleteGeneration;
    final value = query.trim();
    final board = _board;
    if (value.length < 2 ||
        board == null ||
        (board.requiresAuth && _credentials == null)) {
      return const [];
    }
    try {
      final response = await _repository.autocomplete(
        board: board,
        query: value,
        limit: 20,
        credentials: _credentials,
      );
      if (generation != _autocompleteGeneration) return const [];
      return response
          .map(TagSuggestion.fromMap)
          .where((item) => item.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

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
      if (board != null) _credentialsByBoard[board] = credentials;
      _favoritePosts = (await _postStore.loadFavorites())
          .map((saved) => saved.sanitized())
          .toList(growable: false);
      _hiddenPosts = (await _postStore.loadHidden())
          .map((saved) => saved.sanitized())
          .toList(growable: false);
      for (final saved in [..._favoritePosts, ..._hiddenPosts]) {
        if (saved.board.requiresAuth &&
            !_credentialsByBoard.containsKey(saved.board)) {
          _credentialsByBoard[saved.board] = await _store.loadCredentials(
            saved.board,
          );
        }
      }
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
      _credentialsByBoard[value] = loadedCredentials;
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

  Future<void> addSavedQuery(List<String> value) async {
    final query = value
        .map(_normalize)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (query.isEmpty) return;
    final next = [query, ..._settings.savedQueries];
    final normalized = _settings.copyWith(savedQueries: next);
    await _store.saveSettings(normalized);
    _settings = normalized;
    notifyListeners();
  }

  Future<void> removeSavedQuery(List<String> value) async {
    final key = value
        .map(_normalize)
        .where((e) => e.isNotEmpty)
        .toSet()
        .join('\u0000');
    final next = _settings.savedQueries
        .where((query) => query.map(_normalize).toSet().join('\u0000') != key)
        .toList();
    final normalized = _settings.copyWith(savedQueries: next);
    await _store.saveSettings(normalized);
    _settings = normalized;
    notifyListeners();
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

  Future<Credentials?> credentialsFor(Board value) async {
    final credentials = await _store.loadCredentials(value);
    _credentialsByBoard[value] = credentials;
    return credentials;
  }

  Future<void> saveCredentials(Board value, Credentials credentials) async {
    await _store.saveCredentials(value, credentials);
    _credentialsByBoard[value] = credentials;
    if (value == _board) _credentials = credentials;
    notifyListeners();
  }

  Future<void> forgetCredentials(Board value) async {
    await _store.removeCredentials(value);
    _credentialsByBoard.remove(value);
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
    _credentialsByBoard[value] = credentials;
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
    if (reset && _tags.isEmpty) _randomSeed = Random().nextInt(1 << 31);
    try {
      var accepted = <MediaPost>[];
      var currentPage = page;
      var lastFetchedPage = page;
      for (
        var attempt = 0;
        attempt < 3 && accepted.length < _settings.batchSize;
        attempt++
      ) {
        final raw = await _repository.fetch(
          board: _board!,
          tags: _queryTags(),
          limit: _settings.batchSize,
          page: currentPage,
          random: _tags.isEmpty,
          randomSeed: _randomSeed,
          credentials: _credentials,
        );
        if (generation != _generation) return;
        lastFetchedPage = currentPage;
        if (raw.isEmpty) {
          _hasMore = false;
          break;
        }
        final incoming = raw.map(MediaPost.fromMap).where(_allowed).toList();
        final seen = {
          ...(reset ? const <String>[] : _posts.map(_postKey)),
          ...accepted.map(_postKey),
        };
        accepted.addAll(incoming.where((post) => seen.add(_postKey(post))));
        currentPage++;
      }
      if (generation != _generation) return;
      _page = lastFetchedPage;
      if (accepted.length >= _settings.batchSize) _hasMore = true;
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

  List<String> _queryTags() {
    final exclusions = [
      ..._settings.blacklist.map((tag) => '-$tag'),
      if (_settings.excludeAi) '-ai_generated',
    ];
    // Anonymous Danbooru searches accept only two ordinary tags. Keep the
    // user's search intact and let the local filter enforce any remaining
    // blacklist/no-AI exclusions instead of turning a valid query into a
    // provider-side "too many tags" error.
    if (_board == Board.danbooru) {
      final ordinary = _tags.where(_isOrdinaryTag).length;
      final budget = (2 - ordinary).clamp(0, 2);
      return [..._tags, ...exclusions.take(budget)];
    }
    return [..._tags, ...exclusions];
  }

  bool _isOrdinaryTag(String value) {
    final tag = value.startsWith('-') ? value.substring(1) : value;
    return tag.isNotEmpty && !tag.contains(':');
  }

  bool _allowed(MediaPost post) =>
      !(_settings.excludeAi &&
          post.tags.any((tag) => _normalize(tag) == 'ai_generated')) &&
      !_settings.blacklist.any(
        (blocked) =>
            post.tags.any((tag) => _normalize(tag) == _normalize(blocked)),
      ) &&
      !_isHidden(post);

  bool _isHidden(MediaPost post) => isHidden(post, board: _board);

  SavedPost _saved(MediaPost post, Board? board) => SavedPost(
    board: board ?? _board ?? Board.safebooru,
    post: post,
  ).sanitized();
  String _postKey(MediaPost post) => _saved(post, _board).identity;
  String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  void _clearResults() {
    _posts = const [];
    _page = -1;
    _hasMore = true;
  }

  void _invalidate() {
    _generation++;
    _autocompleteGeneration++;
    _loading = false;
  }

  String _friendly(Object error) =>
      'Unable to load ${_board?.label ?? 'the selected board'}. Check your connection and search tag limits. If this website needs an API key, reconnect in Settings.';
}
