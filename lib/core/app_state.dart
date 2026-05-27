import 'dart:collection';
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
  Future<void> _settingsQueue = Future<void>.value();
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
  // Identity indexes keep favorite/hidden checks O(1) per tile and per
  // incoming post instead of scanning every saved post.
  Set<String> _favoriteIds = const {};
  Set<String> _hiddenIds = const {};

  AppSettings get settings => _settings;
  Board? get board => _board;
  // _posts is always replaced, never mutated in place, so a view is a
  // stable snapshot without copying the whole feed on every access.
  List<MediaPost> get posts => UnmodifiableListView(_posts);
  List<String> get tags => List.unmodifiable(_tags);
  bool get loading => _loading;
  String? get error => _error;
  bool get hasMore => _hasMore;
  bool get initialized => _initialized;
  List<List<String>> get savedQueries =>
      List.unmodifiable(_settings.savedQueries);
  List<List<String>> get recentSearches =>
      List.unmodifiable(_settings.recentSearches);
  List<Rating> get selectedRatings => List.unmodifiable(_settings.selectedRatings);
  Map<String, int> get searchedTagCounts =>
      Map.unmodifiable(_settings.searchedTagCounts);
  Map<String, int> get browsedTagCounts =>
      Map.unmodifiable(_settings.browsedTagCounts);
  List<String> get topSearchedTags => _topTags(_settings.searchedTagCounts);
  List<String> get topBrowsedTags => _topTags(_settings.browsedTagCounts);
  List<SavedPost> get favoritePosts => List.unmodifiable(_favoritePosts);
  List<SavedPost> get hiddenPosts => List.unmodifiable(_hiddenPosts);
  bool isFavorite(MediaPost post, {Board? board}) =>
      _favoriteIds.contains(_identity(post, board));
  bool isHidden(MediaPost post, {Board? board}) =>
      _hiddenIds.contains(_identity(post, board));

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
    if (_favoriteIds.contains(saved.identity)) return;
    _setFavorites([..._favoritePosts, saved]);
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  Future<void> unfavoritePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    _setFavorites(
      _favoritePosts
          .where((value) => value.identity != saved.identity)
          .toList(growable: false),
    );
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  Future<void> hidePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    if (!_hiddenIds.contains(saved.identity)) {
      _setHidden([..._hiddenPosts, saved]);
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
    _setHidden(
      _hiddenPosts
          .where((value) => value.identity != saved.identity)
          .toList(growable: false),
    );
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
      _setFavorites(
        (await _postStore.loadFavorites())
            .map((saved) => saved.sanitized())
            .toList(growable: false),
      );
      _setHidden(
        (await _postStore.loadHidden())
            .map((saved) => saved.sanitized())
            .toList(growable: false),
      );
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
    final generation = _generation;
    _tags = value
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    _clearResults();
    notifyListeners();
    final recent = _recordRecentSearch(value);
    if (_board != null) {
      await Future.wait<void>([
        recent,
        _load(reset: true, generation: generation),
      ]);
    } else {
      await recent;
    }
  }

  Future<void> recordBrowsedTags(Iterable<String> tags) =>
      _recordTagCounts(tags, searched: false);

  Future<void> recordBrowsedTag(String tag) =>
      _recordTagCounts([tag], searched: false);

  Future<void> setRatingFilters(Iterable<Rating> ratings) async {
    final normalized = ratings.toSet().toList();
    await _enqueueSettingsUpdate(() async {
      final next = _settings.copyWith(selectedRatings: normalized);
      try {
        await _store.saveSettings(next);
      } catch (_) {
        return;
      }
      _settings = next;
    });
    _invalidate();
    _clearResults();
    notifyListeners();
    await _load(reset: true, generation: _generation);
  }

  /// Persists the preferred video height without reloading the feed.
  Future<void> setVideoQuality(int maxHeight) =>
      _enqueueSettingsUpdate(() async {
        final next = _settings.copyWith(videoQuality: maxHeight);
        if (next == _settings) return;
        try {
          await _store.saveSettings(next);
        } catch (_) {
          return;
        }
        _settings = next;
        notifyListeners();
      });

  Future<void> _recordRecentSearch(List<String> value) {
    final query = value
        .map(_normalize)
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
    final searchedTags = _usageTags(value, searched: true);
    if (query.isEmpty && searchedTags.isEmpty) return Future<void>.value();
    return _enqueueSettingsUpdate(() async {
      final counts = {..._settings.searchedTagCounts};
      for (final tag in searchedTags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
      final normalized = _settings.copyWith(
        recentSearches: query.isEmpty
            ? _settings.recentSearches
            : [query, ..._settings.recentSearches],
        searchedTagCounts: counts,
      );
      try {
        await _store.saveSettings(normalized);
      } catch (_) {
        return;
      }
      _settings = normalized;
      notifyListeners();
    });
  }

  Future<void> _recordTagCounts(
    Iterable<String> values, {
    required bool searched,
  }) {
    final tags = _usageTags(values, searched: searched);
    if (tags.isEmpty) return Future<void>.value();
    return _enqueueSettingsUpdate(() async {
      final source = searched
          ? _settings.searchedTagCounts
          : _settings.browsedTagCounts;
      final counts = {...source};
      for (final tag in tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
      final next = _settings.copyWith(
        searchedTagCounts: searched ? counts : _settings.searchedTagCounts,
        browsedTagCounts: searched ? _settings.browsedTagCounts : counts,
      );
      try {
        await _store.saveSettings(next);
      } catch (_) {
        return;
      }
      _settings = next;
      notifyListeners();
    });
  }

  Set<String> _usageTags(
    Iterable<String> values, {
    required bool searched,
  }) => values
        .map(_normalize)
        .map(
          (tag) => tag.startsWith('-') || tag.startsWith('~')
              ? tag.substring(1)
              : tag,
        )
        .where((tag) => tag.isNotEmpty && (!searched || _isOrdinaryTag(tag)))
        .toSet();

  List<String> _topTags(Map<String, int> counts) => (counts.entries.toList()
        ..sort((a, b) {
          final byCount = b.value.compareTo(a.value);
          return byCount == 0 ? a.key.compareTo(b.key) : byCount;
        }))
      .take(10)
      .map((entry) => entry.key)
      .toList(growable: false);

  Future<void> removeRecentSearch(List<String> value) async {
    final key = value
        .map(_normalize)
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .join('\u0000');
    await _enqueueSettingsUpdate(() async {
      final next = _settings.recentSearches
          .where(
            (query) =>
                query
                    .map(_normalize)
                    .where((tag) => tag.isNotEmpty)
                    .toSet()
                    .join('\u0000') !=
                key,
          )
          .toList();
      final normalized = _settings.copyWith(recentSearches: next);
      try {
        await _store.saveSettings(normalized);
      } catch (_) {
        return;
      }
      _settings = normalized;
      notifyListeners();
    });
  }

  Future<T> _enqueueSettingsUpdate<T>(Future<T> Function() update) {
    final operation = _settingsQueue.then<T>((_) => update());
    _settingsQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> addSavedQuery(List<String> value) async {
    final query = value
        .map(_normalize)
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (query.isEmpty) return;
    await _enqueueSettingsUpdate(() async {
      final next = [query, ..._settings.savedQueries];
      final normalized = _settings.copyWith(savedQueries: next);
      await _store.saveSettings(normalized);
      _settings = normalized;
      notifyListeners();
    });
  }

  Future<void> removeSavedQuery(List<String> value) async {
    final key = value
        .map(_normalize)
        .where((e) => e.isNotEmpty)
        .toSet()
        .join('\u0000');
    await _enqueueSettingsUpdate(() async {
      final next = _settings.savedQueries
          .where((query) => query.map(_normalize).toSet().join('\u0000') != key)
          .toList();
      final normalized = _settings.copyWith(savedQueries: next);
      await _store.saveSettings(normalized);
      _settings = normalized;
      notifyListeners();
    });
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
    await _enqueueSettingsUpdate(() async {
      final normalized = value
          .copyWith(
            savedQueries: _settings.savedQueries,
            recentSearches: _settings.recentSearches,
            selectedRatings: _settings.selectedRatings,
            searchedTagCounts: _settings.searchedTagCounts,
            browsedTagCounts: _settings.browsedTagCounts,
          )
          .normalized();
      await _store.saveSettings(normalized);
      _settings = normalized;
    });
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
    final rating = _singleProviderRating;
    // Anonymous Danbooru searches accept only two ordinary tags. Keep the
    // user's search intact and let the local filter enforce any remaining
    // blacklist/no-AI exclusions instead of turning a valid query into a
    // provider-side "too many tags" error.
    if (_board == Board.danbooru) {
      final ordinary = _tags.where(_isOrdinaryTag).length;
      final budget = (2 - ordinary).clamp(0, 2);
      return [
        ..._tags,
        if (rating != null)
          'rating:${_board == Board.konachan ? rating.shortQueryValue : rating.queryValue}',
        ...exclusions.take(budget),
      ];
    }
    return [
      ..._tags,
      if (rating != null)
        'rating:${_board == Board.konachan ? rating.shortQueryValue : rating.queryValue}',
      ...exclusions,
    ];
  }

  Rating? get _singleProviderRating =>
      _settings.selectedRatings.length == 1 &&
          _board != Board.gelbooru &&
          _board != Board.rule34
      ? _settings.selectedRatings.single
      : null;

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
      _ratingAllowed(post) &&
      !_isHidden(post);

  Rating? _postRating(MediaPost post) => RatingInfo.parse(post.rating);
  bool _ratingAllowed(MediaPost post) {
    if (_settings.selectedRatings.length == Rating.values.length) return true;
    final rating = _postRating(post);
    return rating != null && _settings.selectedRatings.contains(rating);
  }

  bool _isHidden(MediaPost post) => isHidden(post, board: _board);

  SavedPost _saved(MediaPost post, Board? board) => SavedPost(
    board: board ?? _board ?? Board.safebooru,
    post: post,
  ).sanitized();
  // identity already strips credentials, so it needs no sanitized copy.
  String _identity(MediaPost post, Board? board) => SavedPost(
    board: board ?? _board ?? Board.safebooru,
    post: post,
  ).identity;
  String _postKey(MediaPost post) => _identity(post, _board);
  void _setFavorites(List<SavedPost> value) {
    _favoritePosts = value;
    _favoriteIds = {for (final saved in value) saved.identity};
  }

  void _setHidden(List<SavedPost> value) {
    _hiddenPosts = value;
    _hiddenIds = {for (final saved in value) saved.identity};
  }

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
