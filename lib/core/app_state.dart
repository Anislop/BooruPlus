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
    AccountRepository? accounts,
  }) : _repository = repository ?? PlatformBoardRepository(),
       _accounts = accounts ?? PlatformAccountRepository(),
       _store = store ?? LocalSettingsStore(),
       _postStore =
           postStore ??
           (store == null || store is LocalSettingsStore
               ? LocalPostStore()
               : MemoryPostStore());
  final BoardRepository _repository;
  final AccountRepository _accounts;
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
  // One renewal per board at a time: concurrent requests share it, so a
  // rotated refresh token is never spent twice.
  final Map<Board, Future<Credentials?>> _sessionRenewals = {};
  // Sankaku's signed-in tag limit is not documented. It is learned from the
  // provider's tag-limit refusal; until then exclusions are not trimmed.
  int? _sankakuSignedInTagLimit;
  String? _notice;
  List<SavedPost> _favoritePosts = const [];
  List<SavedPost> _hiddenPosts = const [];
  // Identity indexes keep favorite/hidden checks O(1) per tile and per
  // incoming post instead of scanning every saved post.
  Set<String> _favoriteIds = const {};
  Set<String> _hiddenIds = const {};
  // Sankaku signs media URLs with an expiry of about an hour. Saved and
  // long-open posts are looked up again by ID; fresh copies are kept by
  // identity, and attempts are throttled so a deleted post is not re-queried
  // on every rebuild.
  final Map<String, MediaPost> _refreshedMedia = {};
  final Map<String, DateTime> _refreshAttempts = {};
  final Map<String, SavedPost> _refreshQueue = {};
  bool _refreshScheduled = false;

  AppSettings get settings => _settings;
  Board? get board => _board;
  // _posts is always replaced, never mutated in place, so a view is a
  // stable snapshot without copying the whole feed on every access.
  List<MediaPost> get posts => UnmodifiableListView(_posts);
  List<String> get tags => List.unmodifiable(_tags);
  bool get loading => _loading;
  String? get error => _error;

  /// A one-time message for the user, such as an expired sign-in. Reading it
  /// clears it.
  String? takeNotice() {
    final notice = _notice;
    _notice = null;
    return notice;
  }

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

  SavedPost displayReady(SavedPost post) {
    final authorized = post.authorized(_credentialsByBoard[post.board]);
    if (authorized.board != Board.sankaku || !authorized.post.hasId) {
      return authorized;
    }
    final fresh = _refreshedMedia[authorized.identity];
    if (fresh != null && !_mediaExpired(fresh)) {
      return SavedPost(
        board: authorized.board,
        post: authorized.post.withUrls(
          url: fresh.url,
          previewUrl: fresh.previewUrl,
        ),
      );
    }
    if (_mediaExpired(authorized.post)) _queueMediaRefresh(authorized);
    return authorized;
  }

  MediaPost authorizedPost(MediaPost post, {Board? board}) =>
      displayReady(_saved(post, board)).post;

  /// [post] with media URLs that are still valid for display. Only boards
  /// with expiring media URLs are rewritten; other posts pass through.
  MediaPost displayPost(MediaPost post, {required Board board}) =>
      board == Board.sankaku
      ? displayReady(SavedPost(board: board, post: post)).post
      : post;

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
      final response = await _withSession(
        board,
        (credentials) => _repository.autocomplete(
          board: board,
          query: value,
          limit: 20,
          credentials: credentials,
        ),
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
        if (saved.board.supportsAuth &&
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
    if (value == Board.sankaku) _sankakuSignedInTagLimit = null;
    if (value == _board) {
      _invalidate();
      _credentials = null;
      _clearResults();
      _error = value.requiresAuth
          ? 'Authentication is required for ${value.label}.'
          : null;
    }
    notifyListeners();
    // Optional sign-in: keep browsing anonymously.
    if (value == _board && !value.requiresAuth) {
      await _load(reset: true, generation: _generation);
    }
  }

  /// Signs in to a [BoardInfo.supportsSignIn] board. Only the returned
  /// session is stored; [password] is passed to the platform and dropped.
  Future<void> signIn(Board value, String login, String password) async {
    if (!value.supportsSignIn) {
      throw ArgumentError('${value.label} does not support signing in.');
    }
    if (login.trim().isEmpty || password.isEmpty) {
      throw ArgumentError('A username and password are required.');
    }
    final credentials = await _accounts.signIn(
      board: value,
      login: login.trim(),
      password: password,
    );
    if (value == Board.sankaku) _sankakuSignedInTagLimit = null;
    await _useCredentials(value, credentials);
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
    await _useCredentials(value, credentials);
    return true;
  }

  Future<void> _useCredentials(Board value, Credentials credentials) async {
    await _store.saveCredentials(value, credentials);
    _credentialsByBoard[value] = credentials;
    if (value == _board) {
      _invalidate();
      _credentials = credentials;
      _clearResults();
      notifyListeners();
      await _load(reset: true, generation: _generation);
    }
  }

  /// Runs [request] with [board]'s stored credentials. A sign-in session is
  /// renewed when it is about to expire or the provider refuses it; one that
  /// can no longer be renewed is dropped so browsing continues anonymously.
  Future<T> _withSession<T>(
    Board board,
    Future<T> Function(Credentials? credentials) request,
  ) async {
    var credentials = _credentialsByBoard[board];
    if (!board.supportsSignIn || credentials == null) {
      return request(credentials);
    }
    if (credentials.expiresSoon(DateTime.now())) {
      try {
        credentials = await _renewSession(board, credentials);
      } catch (_) {
        // A renewal that failed for another reason (such as the network)
        // keeps the stored session; the request itself decides.
      }
    }
    try {
      return await request(credentials);
    } on AuthExpiredException {
      if (credentials == null) rethrow;
      return request(await _renewSession(board, credentials));
    }
  }

  Future<Credentials?> _renewSession(Board board, Credentials stale) =>
      _sessionRenewals[board] ??= _replaceSession(board, stale).whenComplete(
        // A block body: returning the removed future would await itself.
        () {
          _sessionRenewals.remove(board);
        },
      );

  Future<Credentials?> _replaceSession(Board board, Credentials stale) async {
    Credentials? fresh;
    try {
      if (stale.refreshToken.isNotEmpty) {
        fresh = await _accounts.refreshSignIn(board: board, credentials: stale);
      }
    } on SignInRejectedException {
      fresh = null;
    }
    // The user signed out or in again while the renewal was in flight.
    if (!identical(_credentialsByBoard[board], stale)) {
      return _credentialsByBoard[board];
    }
    _credentialsByBoard[board] = fresh;
    if (board == _board) _credentials = fresh;
    if (fresh == null) {
      if (board == Board.sankaku) _sankakuSignedInTagLimit = null;
      _notice =
          'Your ${board.label} sign-in expired. Sign in again in Settings.';
      notifyListeners();
      await _store.removeCredentials(board);
    } else {
      await _store.saveCredentials(board, fresh);
    }
    return fresh;
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
        final raw = await _fetchFeedPage(_board!, currentPage);
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

  Future<List<Map<String, dynamic>>> _fetchFeedPage(Board board, int page) {
    Future<List<Map<String, dynamic>>> fetch() => _withSession(
      board,
      (credentials) => _repository.fetch(
        board: board,
        tags: _queryTags(signedIn: credentials != null),
        limit: _settings.batchSize,
        page: page,
        random: _tags.isEmpty,
        randomSeed: _randomSeed,
        credentials: credentials,
      ),
    );
    return fetch().catchError((Object error) {
      // A signed-in Sankaku search hit the account's limit: remember it and
      // retry once with the exclusions trimmed to fit.
      final limit = (error as TagLimitException).limit;
      final signedIn = _credentialsByBoard[board] != null;
      final before = _queryTags(signedIn: signedIn);
      if (board != Board.sankaku ||
          !signedIn ||
          limit == null ||
          limit == _sankakuSignedInTagLimit) {
        throw error;
      }
      _sankakuSignedInTagLimit = limit;
      if (listEquals(before, _queryTags(signedIn: signedIn))) throw error;
      return fetch();
    }, test: (error) => error is TagLimitException);
  }

  List<String> _queryTags({bool signedIn = false}) {
    final exclusions = [
      ..._settings.blacklist.map((tag) => '-$tag'),
      if (_settings.excludeAi) '-$_aiTag',
    ];
    final rating = _singleProviderRating;
    // Anonymous Sankaku searches allow four counted tags: ordinary tags,
    // negated or not, plus rating:q/rating:e (order:, rating:s and other
    // metatags are free). Exclusions are rejected unless a positive tag is
    // present, so the unfiltered feed relies on local filtering instead.
    // Signed-in searches allow more; their limit is learned on refusal.
    if (_board == Board.sankaku) {
      final query = [
        ..._tags,
        if (rating != null) 'rating:${rating.shortQueryValue}',
      ];
      final hasPositive = _tags.any(
        (tag) => _isOrdinaryTag(tag) && !tag.startsWith('-'),
      );
      final limit = signedIn ? _sankakuSignedInTagLimit : 4;
      final budget = limit == null
          ? exclusions.length
          : (limit - query.where(_countsTowardSankakuLimit).length).clamp(
              0,
              limit,
            );
      return [...query, if (hasPositive) ...exclusions.take(budget)];
    }
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

  bool _countsTowardSankakuLimit(String value) {
    final tag = value.toLowerCase();
    return _isOrdinaryTag(tag) ||
        const {
          'rating:q',
          'rating:questionable',
          'rating:e',
          'rating:explicit',
        }.contains(tag);
  }

  /// The provider's tag for AI-generated media.
  String get _aiTag => _board == Board.sankaku ? 'ai-created' : 'ai_generated';

  bool _allowed(MediaPost post) =>
      !(_settings.excludeAi &&
          post.tags.any((tag) => _normalize(tag) == _aiTag)) &&
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

  static bool _mediaExpired(MediaPost post) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final value in [post.url, post.previewUrl]) {
      final query = Uri.tryParse(value)?.queryParameters ?? const {};
      final expiry = int.tryParse(query['e'] ?? query['expires'] ?? '');
      // Refresh slightly early so a URL does not expire mid-download.
      if (expiry != null && now >= expiry - 120) return true;
    }
    return false;
  }

  void _queueMediaRefresh(SavedPost saved) {
    final key = saved.identity;
    final now = DateTime.now();
    final last = _refreshAttempts[key];
    if (last != null && now.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    _refreshAttempts[key] = now;
    _refreshQueue[key] = saved;
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    // A separate task batches every post queued by the current build and
    // keeps notifyListeners out of the build phase.
    Future<void>(_refreshExpiredMedia);
  }

  Future<void> _refreshExpiredMedia() async {
    _refreshScheduled = false;
    final queued = _refreshQueue.values.toList(growable: false);
    _refreshQueue.clear();
    var changed = false;
    for (final board in queued.map((saved) => saved.board).toSet()) {
      final posts = queued.where((saved) => saved.board == board).toList();
      for (var start = 0; start < posts.length; start += 40) {
        final batch = posts.skip(start).take(40).toList(growable: false);
        final wanted = {for (final saved in batch) saved.identity};
        try {
          final raw = await _withSession(
            board,
            (credentials) => _repository.fetch(
              board: board,
              tags: [
                'id:${batch.map((saved) => saved.post.displayId).join(',')}',
              ],
              limit: batch.length,
              page: 0,
              random: false,
              credentials: credentials,
            ),
          );
          for (final fresh in raw.map(MediaPost.fromMap)) {
            final identity = SavedPost(board: board, post: fresh).identity;
            if (!wanted.contains(identity)) continue;
            _refreshedMedia.remove(identity);
            _refreshedMedia[identity] = fresh;
            changed = true;
          }
        } catch (_) {
          // Keep the stored URLs; the post is retried after the cooldown.
        }
      }
    }
    while (_refreshedMedia.length > 500) {
      _refreshedMedia.remove(_refreshedMedia.keys.first);
    }
    if (_refreshAttempts.length > 1000) {
      _refreshAttempts.removeWhere(
        (_, time) =>
            DateTime.now().difference(time) >= const Duration(minutes: 5),
      );
    }
    if (changed) notifyListeners();
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

  String _friendly(Object error) {
    final board = _board;
    if (error is TagLimitException && board != null) {
      final limit = error.limit == null
          ? 'fewer tags'
          : 'up to ${error.limit} tags';
      final hint = board.supportsSignIn && _credentials == null
          ? ' Sign in from Settings to search with more tags.'
          : '';
      return '${board.label} allows $limit per search, including rating and excluded tags.$hint';
    }
    return 'Unable to load ${board?.label ?? 'the selected board'}. Check your connection and search tag limits. If this website needs an API key, reconnect in Settings.';
  }
}
