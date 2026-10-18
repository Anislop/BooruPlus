import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'models.dart';
import 'services.dart';
import 'shorts_profile.dart';

export 'shorts_profile.dart';

class AppState extends ChangeNotifier {
  AppState({
    BoardRepository? repository,
    SettingsStore? store,
    PostStore? postStore,
    AccountRepository? accounts,
    DownloadService? downloads,
    ShortsProfileStore? shortsStore,
  }) : _repository = repository ?? PlatformBoardRepository(),
       _accounts = accounts ?? PlatformAccountRepository(),
       _downloads = downloads ?? DownloadService(),
       _store = store ?? LocalSettingsStore(),
       _postStore =
           postStore ??
           (store == null || store is LocalSettingsStore
               ? LocalPostStore()
               : MemoryPostStore()),
       _shortsStore =
           shortsStore ??
           (store == null || store is LocalSettingsStore
               ? LocalShortsProfileStore()
               : MemoryShortsProfileStore());
  final BoardRepository _repository;
  final AccountRepository _accounts;
  final DownloadService _downloads;
  final SettingsStore _store;
  final PostStore _postStore;
  final ShortsProfileStore _shortsStore;
  final ShortsProfile _shortsProfile = ShortsProfile();
  bool _shortsSaving = false, _shortsDirty = false;
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
  // Only Sankaku Complex has sign-in, so the limit is not per board.
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
  // On-demand media lookups in flight, by post identity, so a viewer and
  // Shorts opening the same post share one request.
  final Map<String, Future<bool>> _mediaLookups = {};
  final Map<String, DateTime> _refreshAttempts = {};
  final Map<String, SavedPost> _refreshQueue = {};
  bool _refreshScheduled = false;
  List<DownloadRecord> _downloadRecords = const [];
  Set<String> _downloadedIds = const {};
  // Post counts from autocomplete, per website, for the search chips.
  final Map<Board, Map<String, int>> _postCounts = {};
  // When a rate-limited feed may be retried.
  DateTime? _retryAt;
  // Recent new-post counts per saved search, so reopening the list does not
  // query every search again.
  final Map<String, (DateTime, int?)> _newPostCounts = {};

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

  /// The bookmarked searches of the current website, or the shared ones
  /// when [AppSettings.globalSavedQueries] is on.
  List<List<String>> get savedQueries =>
      List.unmodifiable(_settings.savedQueriesFor(_board));
  List<List<String>> get recentSearches =>
      List.unmodifiable(_settings.recentSearches);
  List<Rating> get selectedRatings =>
      List.unmodifiable(_settings.selectedRatings);
  Map<String, int> get searchedTagCounts =>
      Map.unmodifiable(_settings.searchedTagCounts);
  Map<String, int> get browsedTagCounts =>
      Map.unmodifiable(_settings.browsedTagCounts);
  List<String> get topSearchedTags => _topTags(_settings.searchedTagCounts);
  List<String> get topBrowsedTags => _topTags(_settings.browsedTagCounts);
  List<SavedPost> get favoritePosts => List.unmodifiable(_favoritePosts);
  List<SavedPost> get hiddenPosts => List.unmodifiable(_hiddenPosts);
  bool isFavorite(MediaPost post, {Board? board}) =>
      _savedIn(_favoriteIds, post, board);
  bool isHidden(MediaPost post, {Board? board}) =>
      _savedIn(_hiddenIds, post, board);

  /// Whether [post] is among [ids], including by its pre-ID identity.
  bool _savedIn(Set<String> ids, MediaPost post, Board? board) {
    final saved = SavedPost(
      board: board ?? _board ?? Board.safebooru,
      post: post,
    );
    if (ids.contains(saved.identity)) return true;
    final legacy = saved.legacyIdentity;
    return legacy != null && ids.contains(legacy);
  }

  /// Saved posts that are [post], including by its pre-ID identity.
  bool Function(SavedPost) _same(MediaPost post, Board? board) {
    final saved = SavedPost(
      board: board ?? _board ?? Board.safebooru,
      post: post,
    );
    final keys = {saved.identity, ?saved.legacyIdentity};
    return (value) => keys.contains(value.identity);
  }

  /// Download history, newest last.
  List<DownloadRecord> get downloadHistory =>
      List.unmodifiable(_downloadRecords);
  bool isDownloaded(MediaPost post, {Board? board}) =>
      _downloadedIds.contains(_identity(post, board));

  /// When the rate-limited feed can be retried, while its error shows.
  DateTime? get retryAt => _error == null ? null : _retryAt;

  /// The post count autocomplete last reported for [tag] on this website.
  int? postCountFor(String tag) {
    final board = _board;
    if (board == null) return null;
    return _postCounts[board]?[_normalize(tag)];
  }

  SavedPost displayReady(SavedPost post) {
    final authorized = post.authorized(_credentialsByBoard[post.board]);
    if (!authorized.board.isSankakuFamily || !authorized.post.hasId) {
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
      board.isSankakuFamily
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
    if (_savedIn(_favoriteIds, post, board)) return;
    _setFavorites([..._favoritePosts, saved]);
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  Future<void> unfavoritePost(MediaPost post, {Board? board}) async {
    final same = _same(post, board);
    _setFavorites(
      _favoritePosts.where((value) => !same(value)).toList(growable: false),
    );
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  Future<void> hidePost(MediaPost post, {Board? board}) async {
    final saved = _saved(post, board);
    if (!_savedIn(_hiddenIds, post, board)) {
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
    final same = _same(post, board);
    _setHidden(
      _hiddenPosts.where((value) => !same(value)).toList(growable: false),
    );
    await _postStore.saveHidden(_hiddenPosts);
    notifyListeners();
  }

  /// Removes several favorites with one write.
  Future<void> unfavoritePosts(Iterable<SavedPost> posts) async {
    final remove = {for (final saved in posts) saved.identity};
    if (remove.isEmpty) return;
    _setFavorites(
      _favoritePosts
          .where((value) => !remove.contains(value.identity))
          .toList(growable: false),
    );
    await _postStore.saveFavorites(_favoritePosts);
    notifyListeners();
  }

  /// Unhides several posts with one write. Unhidden posts return to the
  /// feed on its next load.
  Future<void> unhidePosts(Iterable<SavedPost> posts) async {
    final remove = {for (final saved in posts) saved.identity};
    if (remove.isEmpty) return;
    _setHidden(
      _hiddenPosts
          .where((value) => !remove.contains(value.identity))
          .toList(growable: false),
    );
    await _postStore.saveHidden(_hiddenPosts);
    notifyListeners();
  }

  /// Blocks [tag] on [board], or on every website when [board] is null, and
  /// drops matching posts from the current feed without reloading it.
  Future<void> blockTag(String tag, {Board? board}) async {
    var value = _normalize(tag);
    if (value.startsWith('-')) value = value.substring(1);
    if (value.isEmpty) return;
    await _enqueueSettingsUpdate(() async {
      final next = board == null
          ? _settings.copyWith(blacklist: [..._settings.blacklist, value])
          : _settings.copyWith(
              boardBlacklists: {
                ..._settings.boardBlacklists,
                board: [...?_settings.boardBlacklists[board], value],
              },
            );
      if (next == _settings) return;
      await _store.saveSettings(next);
      _settings = next;
    });
    _posts = _posts.where(_allowed).toList(growable: false);
    notifyListeners();
  }

  /// Hides every post by [uploader] on [board] and drops them from the
  /// current feed without reloading it.
  Future<void> hideUploader(String uploader, {required Board board}) async {
    final name = _normalize(uploader);
    if (name.isEmpty) return;
    await _enqueueSettingsUpdate(() async {
      final next = _settings.copyWith(
        boardHiddenUploaders: {
          ..._settings.boardHiddenUploaders,
          board: [...?_settings.boardHiddenUploaders[board], name],
        },
      );
      if (next == _settings) return;
      await _store.saveSettings(next);
      _settings = next;
    });
    _posts = _posts.where(_allowed).toList(growable: false);
    notifyListeners();
  }

  /// Saves [post]'s original media with the file name template, records it
  /// in the download history, and favorites it when that setting is on.
  /// Returns the saved file's location; platform errors are rethrown.
  Future<String> downloadPost(
    MediaPost post, {
    Board? board,
    DownloadProgress? onProgress,
  }) async {
    final display = displayReady(_saved(post, board));
    final url = display.post.url;
    if (url.isEmpty) throw StateError('Missing media URL');
    final location = await _downloads.download(
      url: url,
      name: mediaFileName(
        display.board,
        display.post,
        url,
        template: _settings.filenameTemplate,
      ),
      directory: _settings.downloadDirectory,
      onProgress: onProgress,
    );
    final record = DownloadRecord(
      saved: display.sanitized(),
      savedAt: DateTime.now(),
      location: location,
    );
    final identity = record.saved.identity;
    final records = [
      ..._downloadRecords.where((value) => value.saved.identity != identity),
      record,
    ];
    _setDownloads(
      records.length > _maxDownloadRecords
          ? records.sublist(records.length - _maxDownloadRecords)
          : records,
    );
    try {
      await _postStore.saveDownloads(_downloadRecords);
    } catch (_) {
      // The file is saved; only its history entry may be lost.
    }
    if (_settings.autoFavoriteOnDownload) {
      await favoritePost(post, board: display.board);
    }
    notifyListeners();
    return location;
  }

  static const _maxDownloadRecords = 1000;

  /// The size in bytes of [post]'s original media (what [downloadPost]
  /// saves), or null when unknown.
  Future<int?> mediaSize(MediaPost post, {Board? board}) {
    final url = displayReady(_saved(post, board)).post.url;
    return url.isEmpty ? Future.value() : _downloads.mediaSize(url);
  }

  /// Downloads [posts] one at a time. Stops early when the download folder
  /// needs to be chosen again.
  Future<DownloadSummary> downloadPosts(
    List<SavedPost> posts, {
    void Function(int index, int total)? onProgress,
  }) async {
    var saved = 0, failed = 0;
    var folderLost = false;
    for (var i = 0; i < posts.length; i++) {
      onProgress?.call(i, posts.length);
      try {
        await downloadPost(posts[i].post, board: posts[i].board);
        saved++;
      } on PlatformException catch (error) {
        failed++;
        if (error.code == 'DIRECTORY_ACCESS' ||
            error.code == 'DIRECTORY_REQUIRED') {
          folderLost = true;
          break;
        }
      } catch (_) {
        failed++;
      }
    }
    return DownloadSummary(
      saved: saved,
      failed: failed,
      folderLost: folderLost,
    );
  }

  /// Removes entries from the download history; the files stay.
  Future<void> removeDownloadRecords(Iterable<DownloadRecord> records) async {
    final remove = {for (final record in records) record.saved.identity};
    if (remove.isEmpty) return;
    _setDownloads(
      _downloadRecords
          .where((record) => !remove.contains(record.saved.identity))
          .toList(growable: false),
    );
    await _postStore.saveDownloads(_downloadRecords);
    notifyListeners();
  }

  /// The visible feed's state, so going back to it can restore its posts
  /// and pages instead of searching again.
  FeedSnapshot? snapshotFeed() {
    final board = _board;
    if (board == null || _posts.isEmpty) return null;
    return FeedSnapshot._(
      board: board,
      tags: _tags,
      posts: _posts,
      page: _page,
      hasMore: _hasMore,
      randomSeed: _randomSeed,
    );
  }

  /// Shows [snapshot] again without fetching. Returns false when it belongs
  /// to another website.
  bool restoreFeed(FeedSnapshot snapshot) {
    if (snapshot.board != _board) return false;
    _invalidate();
    _tags = snapshot.tags;
    // Settings or hidden posts may have changed since it was taken.
    _posts = snapshot.posts.where(_allowed).toList(growable: false);
    _page = snapshot.page;
    _hasMore = snapshot.hasMore;
    _randomSeed = snapshot.randomSeed;
    _error = null;
    _retryAt = null;
    notifyListeners();
    return true;
  }

  /// How many posts newer than the last visit [query] has on this website,
  /// up to 100; null when unknown (never visited, Sankaku's opaque IDs, a
  /// custom sort order, or a failed request). Results are kept briefly.
  Future<int?> newPostCount(List<String> query) async {
    final board = _board;
    if (board == null || board.isSankakuFamily) return null;
    final key = AppSettings.savedSearchKey(board, query);
    final mark = _settings.savedSearchMarks[key];
    if (mark == null ||
        query.any(
          (tag) => tag.startsWith('order:') || tag.startsWith('sort:'),
        )) {
      return null;
    }
    if (board.requiresAuth && _credentialsByBoard[board] == null) return null;
    final cached = _newPostCounts[key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 5)) {
      return cached.$2;
    }
    int? count;
    try {
      final raw = await _withSession(
        board,
        (credentials) => _repository.fetch(
          board: board,
          tags: _queryTagsFor(board, query, signedIn: credentials != null),
          limit: 100,
          page: 0,
          random: false,
          credentials: credentials,
        ),
      );
      count = raw
          .map(MediaPost.fromMap)
          .where((post) => post.id > mark && _allowedOn(post, board))
          .length;
    } catch (_) {
      count = null;
    }
    _newPostCounts[key] = (DateTime.now(), count);
    return count;
  }

  /// Remembers the newest post ID seen for a saved search on [board].
  void _markSavedSearch(Board board, List<String> tags, int highest) {
    if (board.isSankakuFamily || tags.isEmpty || highest <= 0) return;
    final key = AppSettings.savedSearchKey(board, tags);
    final saved = _settings
        .savedQueriesFor(board)
        .any((query) => AppSettings.savedSearchKey(board, query) == key);
    if (!saved || (_settings.savedSearchMarks[key] ?? 0) >= highest) return;
    _newPostCounts.remove(key);
    unawaited(
      _enqueueSettingsUpdate(() async {
        if ((_settings.savedSearchMarks[key] ?? 0) >= highest) return;
        // Re-inserted last, so the newest marks survive trimming.
        final marks = {..._settings.savedSearchMarks}..remove(key);
        marks[key] = highest;
        final next = _settings.copyWith(savedSearchMarks: marks);
        try {
          await _store.saveSettings(next);
        } catch (_) {
          return;
        }
        _settings = next;
        notifyListeners();
      }),
    );
  }

  /// Websites that can search now: those not needing credentials, or with
  /// credentials saved.
  Future<List<Board>> searchableBoards({Iterable<Board>? among}) async {
    final boards = (among ?? Board.values).toList();
    for (final board in boards) {
      if (board.supportsAuth && !_credentialsByBoard.containsKey(board)) {
        try {
          _credentialsByBoard[board] = await _store.loadCredentials(board);
        } catch (_) {
          _credentialsByBoard[board] = null;
        }
      }
    }
    return boards
        .where(
          (board) => !board.requiresAuth || _credentialsByBoard[board] != null,
        )
        .toList(growable: false);
  }

  /// The same file (by MD5 hash) on other websites, using each website's
  /// `md5:` search. Results must report the same hash.
  Future<List<SavedPost>> findOnOtherSites(
    MediaPost post, {
    required Board board,
  }) async {
    final md5 = post.md5;
    if (md5.isEmpty) return const [];
    final boards = await searchableBoards(
      among: Board.values.where((other) => other != board),
    );
    final found = await Future.wait(
      boards.map((other) async {
        try {
          final raw = await _withSession(
            other,
            (credentials) => _repository.fetch(
              board: other,
              tags: ['md5:$md5'],
              limit: 5,
              page: 0,
              random: false,
              credentials: credentials,
            ),
          );
          return raw
              .map(MediaPost.fromMap)
              .where((match) => match.md5 == md5 && _allowedOn(match, other))
              .map((match) => SavedPost(board: other, post: match))
              .toList(growable: false);
        } catch (_) {
          return const <SavedPost>[];
        }
      }),
    );
    return [for (final posts in found) ...posts];
  }

  /// Fetches one page of [tags] on [board] for a lookup outside the feed
  /// (never sent as a feed request, so it cannot cancel the feed), keeping
  /// only posts the local filters allow. Failures are rethrown so callers
  /// can offer a retry rather than report no posts.
  Future<List<MediaPost>> _lookup(
    Board board,
    List<String> tags, {
    int limit = 40,
  }) async {
    final raw = await _withSession(
      board,
      (credentials) => _repository.fetch(
        board: board,
        tags: _queryTagsFor(board, tags, signedIn: credentials != null),
        limit: limit,
        page: 0,
        random: false,
        credentials: credentials,
      ),
    );
    return raw
        .map(MediaPost.fromMap)
        .where((post) => _allowedOn(post, board))
        .toList(growable: false);
  }

  /// The parent of [post] and its child posts, when the website reports
  /// them. Either part is empty when missing; throws when a lookup fails.
  Future<({MediaPost? parent, List<MediaPost> children})> postFamily(
    MediaPost post, {
    required Board board,
  }) async {
    final parentId = post.parentId;
    final results = await Future.wait([
      parentId == null
          ? Future.value(const <MediaPost>[])
          : _lookup(board, ['id:$parentId'], limit: 5),
      post.hasChildren && post.hasId
          ? _lookup(board, ['parent:${post.displayId}'])
          : Future.value(const <MediaPost>[]),
    ]);
    final self = SavedPost(board: board, post: post).identity;
    bool other(MediaPost candidate) =>
        SavedPost(board: board, post: candidate).identity != self;
    return (
      parent: results[0]
          .where(
            (candidate) =>
                candidate.displayId == parentId ||
                '${candidate.id}' == parentId,
          )
          .firstOrNull,
      children: results[1]
          .where(
            (candidate) => other(candidate) && candidate.displayId != parentId,
          )
          .toList(growable: false),
    );
  }

  /// How much a shared tag of each category says two posts are related:
  /// the same artist or character counts most.
  static double _relatedWeight(TagCategory category) => switch (category) {
    TagCategory.artist => 4,
    TagCategory.character => 3,
    TagCategory.copyright => 2,
    TagCategory.species || TagCategory.lore => 1.5,
    TagCategory.meta => 0,
    _ => 1,
  };

  // Placeholder or catch-all names that do not identify a creator or work.
  static const _vagueRelatedTags = {
    'original',
    'unknown_artist',
    'anonymous_artist',
    'artist_request',
    'character_request',
    'copyright_request',
    'conditional_dnp',
    'avoid_posting',
    'sound_warning',
    'third-party_edit',
  };

  /// Posts related to [post] on [board], best first: posts by its artists
  /// and of its characters are searched, then ranked by the tags they share
  /// with [post], where artist and character tags weigh most. Websites
  /// without tag categories fall back to its first general tags.
  Future<List<MediaPost>> relatedPosts(
    MediaPost post, {
    required Board board,
    int limit = 24,
  }) async {
    final details = post.tagDetails.isEmpty
        ? [
            for (final name in post.tags)
              TagInfo(name: name, category: TagCategory.general),
          ]
        : post.tagDetails;
    final weights = <String, double>{
      for (final tag in details)
        if (tag.name.isNotEmpty) tag.name: _relatedWeight(tag.category),
    };
    String? strongest(TagCategory category) => details
        .where(
          (tag) =>
              tag.category == category &&
              tag.name.isNotEmpty &&
              !_vagueRelatedTags.contains(tag.name),
        )
        .firstOrNull
        ?.name;
    final queries = <List<String>>[
      for (final category in [TagCategory.artist, TagCategory.character])
        if (strongest(category) case final tag?) [tag],
    ];
    if (queries.isEmpty) {
      final copyright = strongest(TagCategory.copyright);
      final general = details
          .where(
            (tag) =>
                tag.category == TagCategory.general &&
                !_vagueRelatedTags.contains(tag.name),
          )
          .map((tag) => tag.name)
          .take(2)
          .toList();
      if (copyright != null) {
        queries.add([copyright]);
      } else if (general.isNotEmpty) {
        queries.add(general);
      }
    }
    if (queries.isEmpty) return const [];
    final batches = await Future.wait(
      queries.map((query) => _lookup(board, query)),
    );
    final self = SavedPost(board: board, post: post).identity;
    final scored = <String, (MediaPost, double)>{};
    for (final candidate in batches.expand((batch) => batch)) {
      final identity = SavedPost(board: board, post: candidate).identity;
      if (identity == self || scored.containsKey(identity)) continue;
      if (post.md5.isNotEmpty && candidate.md5 == post.md5) continue;
      final score = candidate.tags.fold<double>(
        0,
        (total, tag) => total + (weights[tag] ?? 0),
      );
      scored[identity] = (candidate, score);
    }
    final ranked = scored.values.toList()
      ..sort((a, b) {
        final byScore = b.$2.compareTo(a.$2);
        return byScore != 0 ? byScore : b.$1.id.compareTo(a.$1.id);
      });
    return [for (final (candidate, _) in ranked.take(limit)) candidate];
  }

  /// A search across several websites at once; see [MultiSiteSearch].
  MultiSiteSearch multiSiteSearch() => MultiSiteSearch._(this);

  /// The booruShorts video feed; see [ShortsFeed]. [random] makes its
  /// ranking repeatable in tests.
  ShortsFeed shortsFeed({Random? random}) => ShortsFeed._(this, random: random);

  /// The booruShorts interests learned on this device.
  ShortsProfile get shortsProfile => _shortsProfile;

  /// Whether booruShorts learns now: personalization is on and incognito
  /// is off.
  bool get _shortsLearning =>
      _settings.shortsPersonalized && !_settings.incognito;

  /// Learns [signal] from [saved] for booruShorts' order; [undo] takes back
  /// an earlier one.
  void learnShorts(SavedPost saved, ShortsSignal signal, {bool undo = false}) {
    if (!_shortsLearning) return;
    _shortsProfile.learn(saved, signal, undo: undo);
    unawaited(_saveShortsProfile());
  }

  /// Learns interest in one tag, such as one tapped in booruShorts.
  void learnShortsTag(String tag, {double amount = .5}) {
    if (!_shortsLearning) return;
    _shortsProfile.learnTag(tag, amount);
    unawaited(_saveShortsProfile());
  }

  /// Remembers one visit to a booruShorts video: it counts as seen, joins
  /// the watch history when played for two seconds, and its watch time is
  /// learned from. Nothing is kept in incognito.
  void watchedShorts(SavedPost saved, ShortsWatch watch) {
    if (_settings.incognito || watch.duration <= Duration.zero) return;
    _shortsProfile.observe(
      saved,
      watched: watch.played >= const Duration(seconds: 2),
    );
    if (_settings.shortsPersonalized) {
      for (final signal in watch.signals) {
        _shortsProfile.learn(saved, signal);
      }
    }
    unawaited(_saveShortsProfile());
  }

  /// Never shows booruShorts videos with [tag] again.
  Future<void> muteShortsTag(String tag) =>
      _changeShortsProfile((profile) => profile.mute(tag));

  Future<void> unmuteShortsTag(String tag) =>
      _changeShortsProfile((profile) => profile.unmute(tag));

  /// Forgets what booruShorts learned about [tag].
  Future<void> forgetShortsTag(String tag) =>
      _changeShortsProfile((profile) => profile.forgetTag(tag));

  /// Forgets every booruShorts interest; muted tags and history stay.
  Future<void> resetShortsInterests() =>
      _changeShortsProfile((profile) => profile.resetInterests());

  /// Clears the booruShorts watch history and the videos marked seen.
  Future<void> clearShortsHistory() =>
      _changeShortsProfile((profile) => profile.clearHistory());

  Future<void> _changeShortsProfile(void Function(ShortsProfile) change) {
    change(_shortsProfile);
    notifyListeners();
    return _saveShortsProfile();
  }

  /// Saves the profile. Changes made while a save runs are written once it
  /// finishes, so frequent updates never queue up writes.
  Future<void> _saveShortsProfile() async {
    if (_shortsSaving) {
      _shortsDirty = true;
      return;
    }
    _shortsSaving = true;
    try {
      do {
        _shortsDirty = false;
        try {
          await _shortsStore.save(_shortsProfile.toMap());
        } catch (_) {
          // The profile is optional; the next change saves it again.
        }
      } while (_shortsDirty);
    } finally {
      _shortsSaving = false;
    }
  }

  /// Saves the tags followed in booruShorts' Following tab.
  Future<void> setShortsFollowing(List<String> tags) =>
      _saveQuietly((settings) => settings.copyWith(shortsFollowing: tags));

  bool followsShortsTag(String tag) =>
      _settings.shortsFollowing.contains(tag.trim().toLowerCase());

  /// Follows or unfollows [tag] in booruShorts.
  Future<void> toggleShortsFollow(String tag) {
    final name = tag.trim().toLowerCase();
    final following = _settings.shortsFollowing;
    return setShortsFollowing(
      following.contains(name)
          ? following.where((other) => other != name).toList()
          : [...following, name],
    );
  }

  /// Websites booruShorts can show now: visible, hosting video, switched on
  /// for Shorts, and usable (credentials saved where required).
  Future<List<Board>> shortsBoards() => searchableBoards(
    among: _settings.visibleBoards.where(
      (board) => board.hasShorts && !_settings.shortsOff.contains(board),
    ),
  );

  /// Saves the booruShorts tags, without reloading the feed.
  Future<void> setShortsTags(List<String> tags) =>
      _saveQuietly((settings) => settings.copyWith(shortsTags: tags));

  /// Saves the websites switched off in booruShorts.
  Future<void> setShortsOff(Iterable<Board> boards) =>
      _saveQuietly((settings) => settings.copyWith(shortsOff: boards.toList()));

  /// Remembers whether booruShorts plays without sound.
  Future<void> setShortsMuted(bool muted) =>
      _saveQuietly((settings) => settings.copyWith(shortsMuted: muted));

  /// Saves a settings change made outside the Settings screen, without
  /// reloading the feed. A failed save keeps the previous settings.
  Future<void> _saveQuietly(AppSettings Function(AppSettings) change) =>
      _enqueueSettingsUpdate(() async {
        final next = change(_settings);
        if (next == _settings) return;
        try {
          await _store.saveSettings(next);
        } catch (_) {
          return;
        }
        _settings = next;
        notifyListeners();
      });

  /// Saves which websites are switched off in Search all sites, without
  /// reloading the feed.
  Future<void> setMultiSearchOff(Iterable<Board> boards) =>
      _enqueueSettingsUpdate(() async {
        final next = _settings.copyWith(multiSearchOff: boards.toList());
        if (next == _settings) return;
        try {
          await _store.saveSettings(next);
        } catch (_) {
          return;
        }
        _settings = next;
        notifyListeners();
      });

  /// Turns incognito on or off without reloading the feed.
  Future<void> setIncognito(bool enabled) => _enqueueSettingsUpdate(() async {
    final next = _settings.copyWith(incognito: enabled);
    if (next == _settings) return;
    try {
      await _store.saveSettings(next);
    } catch (_) {
      return;
    }
    _settings = next;
    notifyListeners();
  });

  /// Turns the app lock off without reloading the feed, for when the device
  /// no longer has a screen lock to verify with.
  Future<void> disableAppLock() => _enqueueSettingsUpdate(() async {
    final next = _settings.copyWith(appLock: false);
    if (next == _settings) return;
    try {
      await _store.saveSettings(next);
    } catch (_) {
      return;
    }
    _settings = next;
    notifyListeners();
  });

  static const backupFormat = 'booruplus-backup';

  /// Settings, saved searches, blocked tags, favorites, and hidden posts as
  /// JSON. Credentials and the device-specific download folder are left out;
  /// saved posts are stored without API keys.
  String exportBackup() => jsonEncode({
    'format': backupFormat,
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'settings': _settings.copyWith(downloadDirectory: null).toMap(),
    'favorites': [
      for (final saved in _favoritePosts) saved.sanitized().toMap(),
    ],
    'hidden': [for (final saved in _hiddenPosts) saved.sanitized().toMap()],
    'shortsProfile': _shortsProfile.interestsToMap(),
  });

  /// Restores an [exportBackup] file: its settings replace the current ones
  /// (keeping this device's download folder and app lock), and its favorites
  /// and hidden posts are merged with the current ones.
  Future<BackupSummary> importBackup(String source) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('This file is not a BooruPlus backup.');
    }
    if (decoded is! Map || decoded['format'] != backupFormat) {
      throw const FormatException('This file is not a BooruPlus backup.');
    }
    List<SavedPost> posts(Object? value) => value is List
        ? value
              .whereType<Map>()
              .map((map) {
                try {
                  return SavedPost.fromMap(map).sanitized();
                } catch (_) {
                  return null;
                }
              })
              .whereType<SavedPost>()
              .toList(growable: false)
        : const [];
    final settings = decoded['settings'];
    if (settings is Map) {
      await _enqueueSettingsUpdate(() async {
        final next = AppSettings.fromMap(settings).copyWith(
          downloadDirectory: _settings.downloadDirectory,
          appLock: _settings.appLock,
        );
        await _store.saveSettings(next);
        _settings = next;
      });
    }
    // SavedPost equality is its identity, so the sets also drop duplicates
    // inside the backup.
    final newFavorites = posts(decoded['favorites'])
        .where((saved) => !_favoriteIds.contains(saved.identity))
        .toSet();
    final newHidden = posts(decoded['hidden'])
        .where((saved) => !_hiddenIds.contains(saved.identity))
        .toSet();
    if (newFavorites.isNotEmpty) {
      _setFavorites([..._favoritePosts, ...newFavorites]);
      await _postStore.saveFavorites(_favoritePosts);
    }
    if (newHidden.isNotEmpty) {
      _setHidden([..._hiddenPosts, ...newHidden]);
      await _postStore.saveHidden(_hiddenPosts);
    }
    // Interests only: the watch history stays this device's.
    final shortsProfile = decoded['shortsProfile'];
    if (shortsProfile is Map) {
      _shortsProfile.loadMap({
        for (final key in ['tags', 'boards', 'uploaders', 'muted', 'updatedAt'])
          if (shortsProfile.containsKey(key)) key: shortsProfile[key],
      });
      await _saveShortsProfile();
    }
    for (final saved in [...newFavorites, ...newHidden]) {
      if (saved.board.supportsAuth &&
          !_credentialsByBoard.containsKey(saved.board)) {
        _credentialsByBoard[saved.board] = await _store.loadCredentials(
          saved.board,
        );
      }
    }
    _invalidate();
    _clearResults();
    notifyListeners();
    unawaited(_load(reset: true, generation: _generation));
    return BackupSummary(
      settings: settings is Map,
      favorites: newFavorites.length,
      hidden: newHidden.length,
    );
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
      final suggestions = response
          .map(TagSuggestion.fromMap)
          .where((item) => item.name.isNotEmpty)
          .toList();
      final counts = _postCounts.putIfAbsent(board, () => {});
      for (final suggestion in suggestions) {
        final count = suggestion.postCount;
        if (count == null) continue;
        final key = _normalize(suggestion.name);
        counts.remove(key);
        counts[key] = count;
      }
      while (counts.length > 500) {
        counts.remove(counts.keys.first);
      }
      return suggestions;
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
      _noteIgnoredAiSetting(board);
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
      try {
        _setDownloads(await _postStore.loadDownloads());
      } catch (_) {
        // History is optional; a damaged list starts empty.
      }
      try {
        final profile = await _shortsStore.load();
        if (profile != null) _shortsProfile.loadMap(profile);
      } catch (_) {
        // The booruShorts profile is optional; a damaged one starts empty.
      }
      for (final saved in [
        ..._favoritePosts,
        ..._hiddenPosts,
        for (final record in _downloadRecords) record.saved,
      ]) {
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

  /// Switches to [value], showing a search for [tags] when given.
  Future<void> chooseBoard(
    Board value, {
    Credentials? credentials,
    List<String> tags = const [],
  }) async {
    _invalidate();
    final generation = _generation;
    try {
      final loadedCredentials =
          credentials ?? await _store.loadCredentials(value);
      if (generation != _generation) return;
      await _store.saveBoard(value);
      if (generation != _generation) return;
      _board = value;
      _noteIgnoredAiSetting(value);
      _credentials = loadedCredentials;
      _credentialsByBoard[value] = loadedCredentials;
      _clearResults();
      _tags = List.unmodifiable(tags);
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

  /// Persists the drawer's website order and hidden set without reloading
  /// the feed.
  Future<void> setBoardLayout(List<Board> order, Iterable<Board> hidden) =>
      _enqueueSettingsUpdate(() async {
        final next = _settings.copyWith(
          boardOrder: order,
          hiddenBoards: hidden.toList(),
        );
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
    if (_settings.incognito) return Future<void>.value();
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
    if (_settings.incognito) return Future<void>.value();
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

  Set<String> _usageTags(Iterable<String> values, {required bool searched}) =>
      values
          .map(_normalize)
          .map(
            (tag) => tag.startsWith('-') || tag.startsWith('~')
                ? tag.substring(1)
                : tag,
          )
          .where((tag) => tag.isNotEmpty && (!searched || _isOrdinaryTag(tag)))
          .toSet();

  List<String> _topTags(Map<String, int> counts) =>
      (counts.entries.toList()..sort((a, b) {
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
    final board = _board;
    await _enqueueSettingsUpdate(() async {
      final next = [query, ..._settings.savedQueriesFor(board)];
      final normalized = _withSavedQueries(board, next);
      await _store.saveSettings(normalized);
      _settings = normalized;
      notifyListeners();
    });
    // Saving the search on screen counts as visiting it.
    if (board != null &&
        AppSettings.savedSearchKey(board, _tags) ==
            AppSettings.savedSearchKey(board, query)) {
      _markSavedSearch(board, query, _posts.fold(0, (a, b) => max(a, b.id)));
    }
  }

  /// [_settings] with [queries] as [board]'s bookmarks, or as the shared
  /// bookmarks when they are global.
  AppSettings _withSavedQueries(Board? board, List<List<String>> queries) =>
      _settings.globalSavedQueries || board == null
      ? _settings.copyWith(savedQueries: queries)
      : _settings.copyWith(
          boardSavedQueries: {..._settings.boardSavedQueries, board: queries},
        );

  Future<void> removeSavedQuery(List<String> value) async {
    final key = value
        .map(_normalize)
        .where((e) => e.isNotEmpty)
        .toSet()
        .join('\u0000');
    final board = _board;
    await _enqueueSettingsUpdate(() async {
      final next = _settings
          .savedQueriesFor(board)
          .where((query) => query.map(_normalize).toSet().join('\u0000') != key)
          .toList();
      final normalized = _withSavedQueries(board, next);
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
            boardSavedQueries: _settings.boardSavedQueries,
            recentSearches: _settings.recentSearches,
            selectedRatings: _settings.selectedRatings,
            searchedTagCounts: _settings.searchedTagCounts,
            browsedTagCounts: _settings.browsedTagCounts,
            boardOrder: _settings.boardOrder,
            hiddenBoards: _settings.hiddenBoards,
            savedSearchMarks: _settings.savedSearchMarks,
            aiNoticeShown: _settings.aiNoticeShown,
            multiSearchOff: _settings.multiSearchOff,
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
    _retryAt = null;
    notifyListeners();
    final page = reset ? 0 : _page + 1;
    if (reset && _tags.isEmpty) _randomSeed = Random().nextInt(1 << 31);
    var superseded = false;
    final board = _board!;
    final tags = _tags;
    var highest = 0;
    try {
      var accepted = <MediaPost>[];
      var currentPage = page;
      var lastFetchedPage = page;
      for (
        var attempt = 0;
        attempt < 3 && accepted.length < _settings.batchSize;
        attempt++
      ) {
        final raw = await _fetchFeedPage(_board!, currentPage, generation);
        if (generation != _generation) return;
        lastFetchedPage = currentPage;
        if (raw.isEmpty) {
          _hasMore = false;
          break;
        }
        final parsed = raw.map(MediaPost.fromMap).toList(growable: false);
        for (final post in parsed) {
          if (post.id > highest) highest = post.id;
        }
        final incoming = parsed.where(_allowed).toList();
        final seen = {
          ...(reset ? const <String>[] : _posts.map(_postKey)),
          ...accepted.map(_postKey),
        };
        accepted.addAll(incoming.where((post) => seen.add(_postKey(post))));
        currentPage++;
        // Sankaku deliberately returns short batches when some records have
        // no accessible media. Show usable posts now instead of multiplying
        // the native page search to fill the configured batch size.
        if (_board!.isSankakuFamily && accepted.isNotEmpty) break;
      }
      if (generation != _generation) return;
      _page = lastFetchedPage;
      if (accepted.length >= _settings.batchSize) _hasMore = true;
      _posts = [...(reset ? const <MediaPost>[] : _posts), ...accepted];
      if (reset) _markSavedSearch(board, tags, highest);
    } on RequestCancelledException {
      // A newer feed request superseded this one natively. A newer
      // generation discards it anyway; within this generation the newer
      // load owns the loading state.
      superseded = true;
    } catch (error) {
      if (generation == _generation) {
        _error = _friendly(error);
        if (error is RateLimitedException) {
          _retryAt = DateTime.now().add(
            error.retryAfter ?? const Duration(seconds: 15),
          );
        }
      }
    } finally {
      if (generation == _generation && !superseded) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Fetches a feed page as a `feed` request, which cancels the previous
  /// feed request natively. A stale [generation] (for example after a
  /// session renewal) sends nothing, so it cannot cancel a newer feed.
  Future<List<Map<String, dynamic>>> _fetchFeedPage(
    Board board,
    int page,
    int generation,
  ) {
    Future<List<Map<String, dynamic>>> fetch() =>
        _withSession(board, (credentials) async {
          if (generation != _generation) return const [];
          return _repository.fetch(
            board: board,
            tags: _queryTags(signedIn: credentials != null),
            limit: _settings.batchSize,
            page: page,
            random: _tags.isEmpty,
            randomSeed: _randomSeed,
            credentials: credentials,
            feed: true,
          );
        });
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

  List<String> _queryTags({bool signedIn = false}) =>
      _queryTagsFor(_board, _tags, signedIn: signedIn);

  /// The provider query for [tags] on [board]: the user's tags plus rating
  /// and blocked-tag exclusions within the website's tag budget.
  List<String> _queryTagsFor(
    Board? board,
    List<String> tags, {
    bool signedIn = false,
  }) {
    final exclusions = [
      ..._settings.blacklistFor(board).map((tag) => '-$tag'),
      if (_excludesAiOn(board)) '-${_aiTagFor(board)}',
    ];
    final rating = _singleProviderRatingFor(board);
    // Anonymous Sankaku searches allow four counted tags: ordinary tags,
    // negated or not, plus rating:q/rating:e (order:, rating:s and other
    // metatags are free). Exclusions are rejected unless a positive tag is
    // present, so the unfiltered feed relies on local filtering instead.
    // Signed-in searches allow more; their limit is learned on refusal.
    // Idol Complex uses the same API and is treated the same way.
    if (board?.isSankakuFamily == true) {
      final query = [
        ...tags,
        if (rating != null) 'rating:${rating.shortQueryValue}',
      ];
      final hasPositive = tags.any(
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
    // provider-side "too many tags" error. AIBooru runs Danbooru with a
    // four-tag limit.
    if (board == Board.danbooru || board == Board.aibooru) {
      final limit = board == Board.aibooru ? 4 : 2;
      final ordinary = tags.where(_isOrdinaryTag).length;
      final budget = (limit - ordinary).clamp(0, limit);
      return [
        ...tags,
        if (rating != null)
          'rating:${board == Board.konachan ? rating.shortQueryValue : rating.queryValue}',
        ...exclusions.take(budget),
      ];
    }
    return [
      ...tags,
      if (rating != null)
        'rating:${board == Board.konachan ? rating.shortQueryValue : rating.queryValue}',
      ...exclusions,
    ];
  }

  Rating? _singleProviderRatingFor(Board? board) =>
      _settings.selectedRatings.length == 1 &&
          board?.usesGelbooruSyntax != true &&
          board?.hasRatings != false
      ? _settings.selectedRatings.single
      : null;

  /// Tells the user, once, that the AI-only [board] ignores the no-AI
  /// setting, when it is chosen or restored at startup.
  void _noteIgnoredAiSetting(Board? board) {
    if (board == null ||
        !board.isAiBoard ||
        !_settings.excludeAi ||
        _settings.excludesAiOn(board) ||
        _settings.aiNoticeShown) {
      return;
    }
    _notice =
        '${board.label} only hosts AI-generated posts, so the "No AI-generated posts" setting is ignored here.';
    unawaited(
      _enqueueSettingsUpdate(() async {
        if (_settings.aiNoticeShown) return;
        final next = _settings.copyWith(aiNoticeShown: true);
        try {
          await _store.saveSettings(next);
        } catch (_) {
          return;
        }
        _settings = next;
      }),
    );
  }

  /// Whether the no-AI setting applies on [board]; exempt boards ignore it.
  bool _excludesAiOn(Board? board) => _settings.excludesAiOn(board);

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
  String _aiTagFor(Board? board) =>
      board?.isSankakuFamily == true ? 'ai-created' : 'ai_generated';

  bool _allowed(MediaPost post) => _allowedOn(post, _board);

  /// The local no-AI, blocked-tag, uploader, rating, and hidden-post checks
  /// for [post] on [board].
  bool _allowedOn(MediaPost post, Board? board) {
    final aiTag = _aiTagFor(board);
    if (_excludesAiOn(board) &&
        post.tags.any((tag) => _normalize(tag) == aiTag)) {
      return false;
    }
    final blocked = _settings.blacklistFor(board);
    if (blocked.isNotEmpty) {
      final tags = post.tags.map(_normalize).toSet();
      if (blocked.any((tag) => tags.contains(_normalize(tag)))) return false;
    }
    if (_settings.hidesUploader(board, post.uploader)) return false;
    return (board?.hasRatings == false || _ratingAllowed(post)) &&
        !isHidden(post, board: board);
  }

  Rating? _postRating(MediaPost post) => RatingInfo.parse(post.rating);
  bool _ratingAllowed(MediaPost post) {
    if (_settings.selectedRatings.length == Rating.values.length) return true;
    final rating = _postRating(post);
    return rating != null && _settings.selectedRatings.contains(rating);
  }

  SavedPost _saved(MediaPost post, Board? board) => SavedPost(
    board: board ?? _board ?? Board.safebooru,
    post: post,
  ).sanitized();
  // identity already strips credentials, so it needs no sanitized copy.
  String _identity(MediaPost post, Board? board) =>
      SavedPost(board: board ?? _board ?? Board.safebooru, post: post).identity;
  String _postKey(MediaPost post) => _identity(post, _board);
  void _setFavorites(List<SavedPost> value) {
    _favoritePosts = value;
    _favoriteIds = {for (final saved in value) saved.identity};
  }

  void _setHidden(List<SavedPost> value) {
    _hiddenPosts = value;
    _hiddenIds = {for (final saved in value) saved.identity};
  }

  void _setDownloads(List<DownloadRecord> value) {
    _downloadRecords = value;
    _downloadedIds = {for (final record in value) record.saved.identity};
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

  /// [post] with media URLs that can be streamed now. Sankaku's signed URLs
  /// expire about an hour after a fetch and then answer 403, so a player
  /// must not start from one that is (nearly) expired; such a post is looked
  /// up again first. [force] looks it up even when the URLs look current,
  /// for a stream that failed anyway. Other boards, and failed lookups,
  /// return the URLs [displayPost] would.
  Future<MediaPost> streamablePost(
    MediaPost post, {
    required Board board,
    bool force = false,
  }) async {
    final ready = displayReady(SavedPost(board: board, post: post));
    if (!board.isSankakuFamily || !ready.post.hasId) return ready.post;
    if (!force && !_mediaExpired(ready.post)) return ready.post;
    final key = ready.identity;
    final lookup = _mediaLookups[key] ??= _lookUpMedia(board, [ready])
        .whenComplete(
          // A block body: returning the removed future would await itself.
          () {
            _mediaLookups.remove(key);
          },
        );
    if (await lookup) notifyListeners();
    return displayReady(SavedPost(board: board, post: post)).post;
  }

  /// Fetches [batch] (one board's posts) again and keeps their current
  /// media URLs in [_refreshedMedia]; whether any arrived.
  Future<bool> _lookUpMedia(Board board, List<SavedPost> batch) async {
    final wanted = {for (final saved in batch) saved.identity};
    var changed = false;
    try {
      final raw = await _withSession(
        board,
        (credentials) => _repository.fetch(
          board: board,
          tags: ['id:${batch.map((saved) => saved.post.displayId).join(',')}'],
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
    return changed;
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
        if (await _lookUpMedia(board, batch)) changed = true;
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

  String _friendly(Object error) => _friendlyFor(_board, error);

  String _friendlyFor(Board? board, Object error) {
    if (error is TagLimitException && board != null) {
      final limit = error.limit == null
          ? 'fewer tags'
          : 'up to ${error.limit} tags';
      final hint = board.supportsSignIn && _credentialsByBoard[board] == null
          ? ' Sign in from Settings to search with more tags.'
          : '';
      return '${board.label} allows $limit per search, including rating and excluded tags.$hint';
    }
    if (error is RateLimitedException) {
      final seconds = error.retryAfter?.inSeconds ?? 0;
      final wait = seconds > 1 ? 'about $seconds seconds' : 'a moment';
      return '${board?.label ?? 'This website'} is busy or limiting requests. Wait $wait, then try again.';
    }
    return 'Unable to load ${board?.label ?? 'the selected board'}. Check your connection and search tag limits. If this website needs an API key, reconnect in Settings.';
  }
}

/// The feed as it was before a search, from [AppState.snapshotFeed].
class FeedSnapshot {
  const FeedSnapshot._({
    required this.board,
    required this.tags,
    required this.posts,
    required this.page,
    required this.hasMore,
    required this.randomSeed,
  });
  final Board board;
  final List<String> tags;
  final List<MediaPost> posts;
  final int page;
  final bool hasMore;
  final int? randomSeed;
}

/// What [AppState.downloadPosts] saved.
class DownloadSummary {
  const DownloadSummary({
    required this.saved,
    required this.failed,
    this.folderLost = false,
  });
  final int saved, failed;

  /// The download folder must be chosen again; the rest were not tried.
  final bool folderLost;
}

/// One search on several websites at once, merged into a single feed.
/// Each website keeps its own page, tag budget, and error, and a newer
/// search discards responses from an older one. It never sends `feed`, so
/// it does not cancel the main feed's requests.
class MultiSiteSearch extends ChangeNotifier {
  MultiSiteSearch._(this._app);
  final AppState _app;
  static const _pageSize = 40;

  List<String> _tags = const [];
  List<Board> _boards = const [];
  // Websites switched on; results from the others stay fetched but hidden.
  Set<Board> _enabled = const {};
  List<SavedPost> _results = const [];
  List<SavedPost>? _visible;
  final Map<Board, int> _pages = {};
  final Set<Board> _exhausted = {};
  final Map<Board, String> _errors = {};
  final Set<String> _seen = {};
  int _generation = 0;
  bool _loading = false;
  bool _disposed = false;

  List<String> get tags => _tags;
  List<Board> get boards => _boards;

  /// Fetched results from the websites currently switched on.
  List<SavedPost> get results => _visible ??= List.unmodifiable(
    _results.where((saved) => _enabled.contains(saved.board)),
  );
  bool get loading => _loading;

  /// Why a switched-on website stopped returning results, by website.
  Map<Board, String> get errors => Map.unmodifiable({
    for (final entry in _errors.entries)
      if (_enabled.contains(entry.key)) entry.key: entry.value,
  });
  bool get hasMore => _boards.any(_active);
  bool _active(Board board) =>
      _enabled.contains(board) &&
      !_exhausted.contains(board) &&
      !_errors.containsKey(board);

  Future<void> search(List<String> tags, Iterable<Board> boards) async {
    _generation++;
    _tags = List.unmodifiable(
      tags.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty),
    );
    _boards = List.unmodifiable(boards);
    _enabled = _boards.toSet();
    _results = const [];
    _visible = null;
    _pages.clear();
    _exhausted.clear();
    _errors.clear();
    _seen.clear();
    _loading = false;
    _notify();
    await loadMore();
  }

  Future<void> loadMore() async {
    final boards = _boards.where(_active).toList(growable: false);
    if (_loading || boards.isEmpty) return;
    final generation = _generation;
    _loading = true;
    _notify();
    final batches = await Future.wait(
      boards.map((board) => _fetch(board, generation)),
    );
    if (generation != _generation || _disposed) return;
    // Interleave so every website's newest posts appear near the top.
    final merged = <SavedPost>[];
    for (var i = 0; ; i++) {
      var added = false;
      for (final batch in batches) {
        if (i < batch.length) {
          merged.add(batch[i]);
          added = true;
        }
      }
      if (!added) break;
    }
    _results = [..._results, ...merged];
    _visible = null;
    _loading = false;
    _notify();
    // A website switched on while this page loaded has not been asked yet.
    if (_boards.any((board) => _active(board) && !_pages.containsKey(board))) {
      await loadMore();
    }
  }

  /// Switches websites on or off for the current search without starting
  /// over. Results already fetched from a website switched off are hidden
  /// (and come back if it is switched on again); loading more asks only the
  /// websites switched on. A website not yet in the search joins it from
  /// its first page.
  Future<void> setEnabled(Iterable<Board> boards) async {
    final enabled = boards.toSet();
    _enabled = enabled;
    final added = enabled.where((board) => !_boards.contains(board));
    if (added.isNotEmpty) _boards = List.unmodifiable([..._boards, ...added]);
    _visible = null;
    _notify();
    if (_tags.isEmpty) return;
    // Fetch when a website has not been asked yet, or when hiding left
    // nothing to show.
    final unasked = _boards.any(
      (board) => _active(board) && !_pages.containsKey(board),
    );
    if (unasked || results.isEmpty) await loadMore();
  }

  Future<List<SavedPost>> _fetch(Board board, int generation) async {
    final page = (_pages[board] ?? -1) + 1;
    try {
      final raw = await _app._withSession(
        board,
        (credentials) => _app._repository.fetch(
          board: board,
          tags: _app._queryTagsFor(board, _tags, signedIn: credentials != null),
          limit: _pageSize,
          page: page,
          random: false,
          credentials: credentials,
        ),
      );
      if (generation != _generation) return const [];
      _pages[board] = page;
      if (raw.isEmpty) {
        _exhausted.add(board);
        return const [];
      }
      return raw
          .map(MediaPost.fromMap)
          .where((post) => _app._allowedOn(post, board))
          .map((post) => SavedPost(board: board, post: post))
          .where((saved) => _seen.add(saved.identity))
          .toList(growable: false);
    } catch (error) {
      if (generation == _generation) {
        _errors[board] = _app._friendlyFor(board, error);
      }
      return const [];
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

/// Which booruShorts tab a [ShortsFeed] fills.
enum ShortsMode {
  /// Random videos, ordered by the viewer's interests once there are some.
  forYou,

  /// Newest videos with the followed tags, in the websites' order.
  following,
}

/// The booruShorts feed: videos from several websites, merged into one
/// list. Each Shorts tag is its own stream per website (any tag matches),
/// combined with the website's video query, so every request stays within
/// the website's tag budget. Like [MultiSiteSearch] it keeps its own
/// generation and never sends `feed`, so it does not cancel the main feed's
/// requests.
///
/// Fetched videos wait in a pool. Without interests they move to the feed
/// in the order they arrived; with interests ([ShortsProfile]) a few at a
/// time are picked by [ShortsRanker], so feedback changes what comes next
/// within a few videos, and up to three liked tags get streams of their
/// own.
class ShortsFeed extends ChangeNotifier {
  ShortsFeed._(this._app, {Random? random}) : _random = random ?? Random();
  final AppState _app;
  final Random _random;
  static const _pageSize = 40;
  // Streams asked per round, so many tags times many websites do not fire
  // dozens of requests at once.
  static const _perRound = 6;
  // Videos moved from the pool to the feed at a time while ranking.
  static const _chunk = 5;
  // The pool is refilled once fewer unseen videos than this wait in it.
  static const _refillAt = 20;
  static const _interestStreams = 3;

  ShortsMode _mode = ShortsMode.forYou;
  bool _ranked = false;
  late ShortsRanker _ranker = ShortsRanker(
    _app._shortsProfile,
    random: _random,
  );
  List<String> _tags = const [];
  List<String> _interestTags = const [];
  List<Board> _boards = const [];
  List<(Board, String?)> _streams = const [];
  List<SavedPost> _posts = const [];
  List<SavedPost> _pool = [];
  final Set<String> _explored = {};
  final Map<(Board, String?), int> _pages = {};
  final Set<(Board, String?)> _exhausted = {};
  final Map<(Board, String?), String> _errors = {};
  // Pages in a row that added nothing playable, by stream.
  final Map<(Board, String?), int> _barren = {};
  final Set<String> _seen = {};
  int _seed = 0;
  bool _retryPending = false;
  int _cursor = 0;
  int _generation = 0;
  bool _loading = false;
  bool _disposed = false;

  ShortsMode get mode => _mode;

  /// The tags this feed matches (any of them); empty for every video.
  List<String> get tags => _tags;
  List<Board> get boards => _boards;
  List<SavedPost> get posts => _posts;
  bool get loading => _loading;
  bool get hasMore => _pool.isNotEmpty || _streams.any(_active);

  /// Whether videos are ordered by the viewer's interests this session.
  bool get personalized => _ranked;

  /// Liked tags asked for in streams of their own this session.
  List<String> get interestTags => _interestTags;

  /// Whether [saved] was picked at random rather than for its interests.
  bool explored(SavedPost saved) => _explored.contains(saved.identity);

  /// Why a website stopped returning videos, by website.
  Map<Board, String> get errors => Map.unmodifiable({
    for (final entry in _errors.entries) entry.key.$1: entry.value,
  });

  bool _active((Board, String?) stream) =>
      !_exhausted.contains(stream) && !_errors.containsKey(stream);

  ShortsProfile get _profile => _app._shortsProfile;

  /// Starts over with videos matching any of [tags] on [boards]. Boards
  /// without video are skipped. The Following tab without [tags] has
  /// nothing to show.
  Future<void> start({
    required List<String> tags,
    required Iterable<Board> boards,
    ShortsMode mode = ShortsMode.forYou,
  }) async {
    _generation++;
    _mode = mode;
    _ranked =
        mode == ShortsMode.forYou &&
        _app.settings.shortsPersonalized &&
        !_profile.isEmpty;
    _ranker = ShortsRanker(_profile, random: _random);
    _tags = List.unmodifiable(
      tags.map((tag) => tag.trim()).where((tag) => tag.isNotEmpty).toSet(),
    );
    _boards = List.unmodifiable(boards.where((board) => board.hasShorts));
    _interestTags = _ranked && _tags.isEmpty
        ? List.unmodifiable(_profile.topTags(_interestStreams))
        : const [];
    _streams = mode == ShortsMode.following && _tags.isEmpty
        ? const []
        : List.unmodifiable([
            for (final board in _boards)
              if (_tags.isEmpty)
                (board, null)
              else
                for (final tag in _tags) (board, tag),
            for (final tag in _interestTags)
              for (final board in _boards) (board, tag),
          ]);
    _posts = const [];
    _pool = [];
    _explored.clear();
    _pages.clear();
    _exhausted.clear();
    _errors.clear();
    _barren.clear();
    _seen.clear();
    _seed = Random().nextInt(1 << 31);
    _retryPending = false;
    _cursor = 0;
    _loading = false;
    _notify();
    await loadMore();
  }

  /// Asks the websites that stopped with an error again.
  Future<void> retry() async {
    if (_errors.isEmpty) return;
    // A round in progress could report the same errors again; retry once
    // it finishes.
    if (_loading) {
      _retryPending = true;
      return;
    }
    _errors.clear();
    _notify();
    await loadMore();
  }

  /// Shows the next videos waiting in the pool, and fetches more once the
  /// pool runs low.
  Future<void> loadMore() async {
    final committed = _commit();
    if (committed) _notify();
    if (_loading || !_streams.any(_active) || _fresh >= _refillAt) return;
    final generation = _generation;
    _loading = true;
    _notify();
    // A round can come back with nothing playable (all filtered out); ask
    // the next streams instead of stalling at the end of the list.
    var added = 0;
    for (var round = 0; round < 3 && added == 0; round++) {
      final streams = _nextStreams();
      if (streams.isEmpty) break;
      final batches = await Future.wait(
        streams.map((stream) => _fetch(stream, generation)),
      );
      if (generation != _generation || _disposed) return;
      // Interleave so the websites and tags mix.
      final merged = <SavedPost>[];
      final accepted = List.filled(batches.length, 0);
      for (var i = 0; ; i++) {
        var any = false;
        for (var b = 0; b < batches.length; b++) {
          final batch = batches[b];
          if (i >= batch.length) continue;
          any = true;
          if (_accept(batch[i])) {
            merged.add(batch[i]);
            // While ranking, videos already watched wait at the back and
            // do not keep a stream going.
            if (!_ranked || !_profile.hasSeen(batch[i])) accepted[b]++;
          }
        }
        if (!any) break;
      }
      // A stream whose pages keep adding nothing playable (all filtered
      // out or already shown) is treated as finished, so the end of the
      // list cannot keep asking forever.
      for (var b = 0; b < streams.length; b++) {
        final stream = streams[b];
        if (!_pages.containsKey(stream) || !_active(stream)) continue;
        if (accepted[b] > 0) {
          _barren.remove(stream);
        } else if ((_barren[stream] = (_barren[stream] ?? 0) + 1) >= 2) {
          _exhausted.add(stream);
        }
      }
      _pool.addAll(merged);
      added += accepted.fold(0, (sum, count) => sum + count);
    }
    _loading = false;
    if (!committed || !_ranked) _commit();
    _notify();
    if (_retryPending) {
      _retryPending = false;
      await retry();
    }
  }

  /// Unseen videos waiting in the pool.
  int get _fresh => _ranked
      ? _pool.where((saved) => !_profile.hasSeen(saved)).length
      : _pool.length;

  /// Moves the next videos from the pool to the feed: all of them in
  /// arrival order, or the best few while ranking.
  bool _commit() {
    if (_pool.isEmpty) return false;
    final List<SavedPost> next;
    if (_ranked) {
      next = _ranker.take(
        _pool,
        _chunk,
        exploration: _app.settings.shortsExploration,
        recent: _posts.length > 3 ? _posts.sublist(_posts.length - 3) : _posts,
        explored: _explored,
      );
    } else {
      next = _pool;
      _pool = [];
    }
    _posts = List.unmodifiable([..._posts, ...next]);
    return true;
  }

  /// The next streams to ask, rotating through the active ones.
  List<(Board, String?)> _nextStreams() {
    final active = _streams.where(_active).toList(growable: false);
    if (active.length <= _perRound) return active;
    final start = _cursor % active.length;
    _cursor += _perRound;
    return [
      for (var i = 0; i < _perRound; i++) active[(start + i) % active.length],
    ];
  }

  /// Whether [saved] is new to the feed, by identity and, across websites,
  /// by file hash, and not muted (or, while ranking, clearly disliked).
  bool _accept(SavedPost saved) {
    final md5 = saved.post.md5;
    if (_seen.contains(saved.identity) ||
        (md5.isNotEmpty && _seen.contains('md5:$md5'))) {
      return false;
    }
    _seen.add(saved.identity);
    if (md5.isNotEmpty) _seen.add('md5:$md5');
    if (_profile.isMuted(saved)) return false;
    return !_ranked || !_profile.isDisliked(saved);
  }

  /// Learns [signal] from [saved] (see [AppState.learnShorts]); videos
  /// still in the pool are picked with it.
  void feedback(SavedPost saved, ShortsSignal signal, {bool undo = false}) =>
      _app.learnShorts(saved, signal, undo: undo);

  /// Learns from one visit to [saved] (see [AppState.watchedShorts]).
  void watched(SavedPost saved, ShortsWatch watch) =>
      _app.watchedShorts(saved, watch);

  /// Mutes [tag] and drops the videos with it that wait in the pool.
  Future<void> muteTag(String tag) async {
    await _app.muteShortsTag(tag);
    _pool.removeWhere(_profile.isMuted);
  }

  Future<List<SavedPost>> _fetch(
    (Board, String?) stream,
    int generation,
  ) async {
    final (board, tag) = stream;
    final page = (_pages[stream] ?? -1) + 1;
    final query = [...board.shortsVideoQuery!, ?tag];
    final random = _mode == ShortsMode.forYou;
    try {
      final raw = await _app._withSession(
        board,
        (credentials) => _app._repository.fetch(
          board: board,
          tags: _app._queryTagsFor(board, query, signedIn: credentials != null),
          limit: _pageSize,
          page: page,
          random: random,
          randomSeed: random ? _seed : null,
          credentials: credentials,
        ),
      );
      if (generation != _generation) return const [];
      _pages[stream] = page;
      if (raw.isEmpty) {
        _exhausted.add(stream);
        return const [];
      }
      return raw
          .map(MediaPost.fromMap)
          .where((post) => post.isVideo && _app._allowedOn(post, board))
          .map((post) => SavedPost(board: board, post: post))
          .toList(growable: false);
    } catch (error) {
      if (generation == _generation) {
        _errors[stream] = _app._friendlyFor(board, error);
      }
      return const [];
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

/// What [AppState.importBackup] restored.
class BackupSummary {
  const BackupSummary({
    required this.settings,
    required this.favorites,
    required this.hidden,
  });
  final bool settings;
  final int favorites, hidden;
}
