import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:booruplus/core/updates.dart';

class MemoryStore implements SettingsStore {
  AppSettings settings = const AppSettings();
  Board? selected;
  final Map<Board, Credentials> credentials = {};
  @override
  Future<AppSettings> loadSettings() async => settings;
  @override
  Future<void> saveSettings(AppSettings value) async => settings = value;
  @override
  Future<Board?> loadBoard() async => selected;
  @override
  Future<void> saveBoard(Board? value) async => selected = value;
  @override
  Future<Credentials?> loadCredentials(Board value) async => credentials[value];
  @override
  Future<void> saveCredentials(Board value, Credentials value2) async =>
      credentials[value] = value2;
  @override
  Future<void> removeCredentials(Board value) async =>
      credentials.remove(value);
}

/// Removes credentials at once but reports it only when [removeGate] opens,
/// like a slow secure-storage delete.
class _SlowRemoveStore extends MemoryStore {
  final removeGate = Completer<void>();
  @override
  Future<void> removeCredentials(Board value) async {
    credentials.remove(value);
    await removeGate.future;
  }
}

class FakeRepo implements BoardRepository {
  final List<List<Map<String, dynamic>>> pages;
  FakeRepo(this.pages);
  int calls = 0;
  int autocompleteCalls = 0;
  final List<List<String>> queries = [];
  final List<String> autocompleteQueries = [];
  Credentials? lastCredentials;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) async {
    calls++;
    queries.add(tags);
    lastCredentials = credentials;
    return page < pages.length ? pages[page] : const [];
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) async {
    autocompleteCalls++;
    autocompleteQueries.add(query);
    return const [];
  }
}

/// Answers `id:` lookups with [fresh]; other fetches return no posts.
class _RefreshRepo extends FakeRepo {
  _RefreshRepo(this.fresh) : super(const [[]]);
  final Map<String, dynamic> fresh;
  final List<List<String>> refreshQueries = [];
  final List<bool> refreshFeedFlags = [];
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) async {
    if (board != Board.sankaku ||
        tags.isEmpty ||
        !tags.first.startsWith('id:')) {
      return const [];
    }
    refreshQueries.add(tags);
    refreshFeedFlags.add(feed);
    return [fresh];
  }
}

/// Records download and size requests instead of calling the platform.
class _RecordingDownloads extends DownloadService {
  final List<String> urls = [];
  @override
  Future<String> download({
    required String url,
    required String name,
    String? directory,
    DownloadProgress? onProgress,
  }) async {
    urls.add(url);
    return 'content://saved';
  }

  @override
  Future<int?> mediaSize(String url) async {
    urls.add(url);
    return 1;
  }
}

/// Answers every fetch through [answer], by the request's tags.
class _ScriptedRepo extends FakeRepo {
  _ScriptedRepo(this.answer) : super(const [[]]);
  final Future<List<Map<String, dynamic>>> Function(List<String> tags) answer;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) {
    calls++;
    queries.add(tags);
    return page == 0
        ? answer(tags.isEmpty ? const [''] : tags)
        : Future.value(const []);
  }
}

/// Records the credentials of every request; [fail] can reject a request.
class _SessionRepo extends FakeRepo {
  _SessionRepo(this.fail, [super.pages = const [[]]]);
  final Object? Function(List<String> tags, Credentials? credentials) fail;
  final List<Credentials?> autocompleteCredentials = [];
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) async {
    final error = fail(tags, credentials);
    if (error != null) {
      lastCredentials = credentials;
      queries.add(tags);
      throw error;
    }
    return super.fetch(
      board: board,
      tags: tags,
      limit: limit,
      page: page,
      random: random,
      randomSeed: randomSeed,
      credentials: credentials,
      feed: feed,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) {
    autocompleteCredentials.add(credentials);
    return super.autocomplete(
      board: board,
      query: query,
      limit: limit,
      credentials: credentials,
    );
  }
}

class FakeAccounts implements AccountRepository {
  FakeAccounts({this.signInResult, this.refreshResult, this.refreshError});
  final Credentials? signInResult;
  final Credentials? refreshResult;
  final Object? refreshError;
  Completer<void>? refreshGate;
  final List<(String, String)> logins = [];
  int refreshes = 0;

  @override
  Future<Credentials> signIn({
    required Board board,
    required String login,
    required String password,
  }) async {
    logins.add((login, password));
    return signInResult ?? (throw const SignInRejectedException());
  }

  @override
  Future<Credentials> refreshSignIn({
    required Board board,
    required Credentials credentials,
  }) async {
    refreshes++;
    await refreshGate?.future;
    if (refreshError != null) throw refreshError!;
    return refreshResult ?? (throw const SignInRejectedException());
  }
}

Map<String, dynamic> post(int id, {List<String> tags = const []}) => {
  'id': id,
  'url': 'https://x/$id.jpg',
  'previewUrl': 'https://x/$id.jpg',
  'tags': tags,
};

void main() {
  test(
    'grid and tag visibility settings persist and legacy data gets defaults',
    () {
      final legacy = AppSettings.fromMap({'columns': 4});
      expect(legacy.hierarchicalGrid, isFalse);
      expect(legacy.hidePostTags, isFalse);
      expect(legacy.toMap(), containsPair('hierarchicalGrid', isFalse));
      expect(legacy.toMap(), containsPair('hidePostTags', isFalse));

      final settings = const AppSettings(
        hierarchicalGrid: true,
        hidePostTags: true,
      );
      final restored = AppSettings.decode(settings.encode());
      expect(restored.hierarchicalGrid, isTrue);
      expect(restored.hidePostTags, isTrue);
    },
  );

  test('no share defaults off, persists, and changes equality', () {
    expect(AppSettings.fromMap({'columns': 3}).noShare, isFalse);
    const settings = AppSettings(noShare: true);
    expect(AppSettings.decode(settings.encode()).noShare, isTrue);
    expect(settings, isNot(const AppSettings()));
    expect(settings.copyWith(noShare: false), const AppSettings());
  });

  test('settings default no-AI and legacy JSON migration are compatible', () {
    expect(const AppSettings().excludeAi, isTrue);
    expect(const AppSettings().gesturesEnabled, isTrue);
    expect(const AppSettings().selectedRatings, Rating.values);
    final migrated = AppSettings.fromMap({'columns': 3});
    expect(migrated.excludeAi, isTrue);
    expect(
      AppSettings.fromMap({
        'noAi': false,
        'savedQueries': [
          [' Cat ', 'cat', ' dog '],
        ],
      }).excludeAi,
      isFalse,
    );
    expect(migrated.toMap(), containsPair('excludeAi', isTrue));
    expect(migrated.toMap(), containsPair('gesturesEnabled', isTrue));
    expect(
      AppSettings.fromMap({'gesturesEnabled': false}).gesturesEnabled,
      isFalse,
    );
  });

  test('rating filters and tag usage counters persist with normalization', () {
    const settings = AppSettings(
      selectedRatings: [Rating.explicit],
      searchedTagCounts: {' Cat ': 2, 'cat': 3},
      browsedTagCounts: {'Dog': 4},
    );
    final restored = AppSettings.decode(settings.encode());

    expect(restored.selectedRatings, [Rating.explicit]);
    expect(restored.searchedTagCounts, {'cat': 5});
    expect(restored.browsedTagCounts, {'dog': 4});
  });

  test('surface opacity and blur persist, clamp, and default for old data', () {
    final legacy = AppSettings.fromMap({'columns': 3});
    expect(legacy.surfaceOpacity, 80);
    expect(legacy.surfaceBlur, 16);

    final restored = AppSettings.decode(
      const AppSettings(surfaceOpacity: 45, surfaceBlur: 4).encode(),
    );
    expect(restored.surfaceOpacity, 45);
    expect(restored.surfaceBlur, 4);

    final clamped = AppSettings.fromMap({
      'surfaceOpacity': 5,
      'surfaceBlur': 99,
    });
    expect(clamped.surfaceOpacity, 20);
    expect(clamped.surfaceBlur, 30);
  });

  test('AIBooru ignores the no-AI setting and says so', () async {
    final repo = FakeRepo([
      [
        {'id': 1, 'url': 'https://x/1.png', 'tags': 'ai_generated cat'},
      ],
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    expect(state.settings.excludeAi, isTrue);
    await state.chooseBoard(Board.aibooru);
    expect(state.takeNotice(), contains('ignored'));
    expect(repo.queries.last, isNot(contains('-ai_generated')));
    expect(state.posts.map((post) => post.id), [1]);

    await state.chooseBoard(Board.safebooru);
    expect(state.takeNotice(), isNull);
    expect(repo.queries.last, contains('-ai_generated'));
    expect(state.posts, isEmpty);
  });

  test('AIBooru is retired from website lists and the startup board', () async {
    final legacy = AppSettings.fromMap({
      'boardOrder': ['aibooru', 'danbooru'],
      'hiddenBoards': ['aibooru'],
    });
    expect(legacy.boardOrder, isNot(contains(Board.aibooru)));
    expect(legacy.boardOrder.first, Board.danbooru);
    // Websites added later are appended.
    expect(legacy.boardOrder, containsAll([Board.sakugabooru, Board.nanbooru]));
    expect(legacy.hiddenBoards, isEmpty);
    // The constant default must list every offered website.
    expect(const AppSettings().boardOrder, listedBoards);

    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore()
        ..settings = legacy
        ..selected = Board.aibooru,
    );
    await state.initialize();
    expect(state.board, Board.danbooru);
    expect(await state.searchableBoards(), isNot(contains(Board.aibooru)));
  });

  test('rating filters skip Nozomi and stay local on TBIB', () async {
    final repo = FakeRepo([
      [
        {
          'id': 1,
          'url': 'https://x/1.webp',
          'tags': 'cat',
          'rating': 'Unknown',
        },
      ],
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.nozomi,
    );
    await state.initialize();
    await state.setRatingFilters({Rating.general});
    await state.search(['cat']);
    expect(
      repo.queries.last.where((tag) => tag.startsWith('rating:')),
      isEmpty,
    );
    expect(state.posts.map((post) => post.id), [1]);

    await state.chooseBoard(Board.tbib, tags: ['cat']);
    expect(
      repo.queries.last.where((tag) => tag.startsWith('rating:')),
      isEmpty,
    );
    // Unrated posts are filtered out where ratings exist.
    expect(state.posts, isEmpty);
  });

  test('search and browse usage are counted independently', () async {
    final store = MemoryStore()..selected = Board.konachan;
    final state = AppState(repository: FakeRepo(const [[]]), store: store);
    await state.initialize();

    await state.search([' Cat ', '-dog', 'order:score', 'cat']);
    await state.recordBrowsedTags(['cat', 'bird', 'bird']);

    expect(state.searchedTagCounts, {'cat': 1, 'dog': 1});
    expect(state.browsedTagCounts, {'bird': 1, 'cat': 1});
    expect(state.topSearchedTags, ['cat', 'dog']);
    expect(state.topBrowsedTags, ['bird', 'cat']);
    expect(store.settings.searchedTagCounts, state.searchedTagCounts);
    expect(store.settings.browsedTagCounts, state.browsedTagCounts);
  });

  test(
    'Konachan rating filters query and locally filter returned posts',
    () async {
      final general = post(101)..['rating'] = 'safe';
      final explicit = post(102)..['rating'] = 'explicit';
      final repo = FakeRepo([
        [general, explicit],
      ]);
      final state = AppState(
        repository: repo,
        store: MemoryStore()
          ..selected = Board.konachan
          ..settings = const AppSettings(selectedRatings: [Rating.general]),
      );
      await state.initialize();

      expect(repo.queries.first, contains('rating:s'));
      expect(state.posts.map((value) => value.id), [101]);

      await state.setRatingFilters([Rating.explicit]);
      expect(repo.queries.last, contains('rating:e'));
      expect(state.posts.map((value) => value.id), [102]);
    },
  );

  test(
    'typed tags preserve categories while raw tags fall back to general',
    () {
      final typed = MediaPost.fromMap(
        post(7, tags: ['artist_name', 'character_name', 'plain'])
          ..['tagDetails'] = [
            {'name': 'artist_name', 'category': 'artist'},
            {'name': 'character_name', 'category': 'character'},
          ]
          ..['postUrl'] = 'https://danbooru.donmai.us/posts/7',
      );
      expect(
        typed.tagDetails.map((tag) => '${tag.name}:${tag.category.name}'),
        ['artist_name:artist', 'character_name:character', 'plain:unknown'],
      );
      expect(typed.postUrl, 'https://danbooru.donmai.us/posts/7');
      final roundTrip = MediaPost.fromMap(typed.toMap());
      expect(roundTrip.tagDetails, hasLength(3));

      final fallback = MediaPost.fromMap(post(8, tags: ['cat', 'dog']));
      expect(fallback.tagDetails.map((tag) => tag.category), [
        TagCategory.general,
        TagCategory.general,
      ]);
    },
  );

  test(
    'provider numeric category values stay unknown at the shared boundary',
    () {
      expect(TagCategoryInfo.parse(5), TagCategory.unknown);
      expect(TagCategoryInfo.parse('species'), TagCategory.species);
    },
  );

  test('saved queries persist without reloading the active feed', () async {
    final repo = FakeRepo(const [[]]);
    final store = MemoryStore()..selected = Board.safebooru;
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    await state.addSavedQuery([' Cat ', 'cat']);
    expect(state.savedQueries, [
      ['cat'],
    ]);
    expect(repo.calls, 1);
    await state.removeSavedQuery(['CAT']);
    expect(state.savedQueries, isEmpty);
  });

  test('saved queries are per website unless shared globally', () async {
    final store = MemoryStore()..selected = Board.safebooru;
    final state = AppState(repository: FakeRepo(const [[]]), store: store);
    await state.initialize();
    await state.addSavedQuery(['cat']);
    await state.chooseBoard(Board.danbooru);
    expect(state.savedQueries, isEmpty);
    await state.addSavedQuery(['dog']);
    expect(store.settings.boardSavedQueries[Board.safebooru], [
      ['cat'],
    ]);
    expect(store.settings.savedQueries, isEmpty);

    await state.updateSettings(
      state.settings.copyWith(globalSavedQueries: true),
    );
    expect(state.savedQueries, isEmpty);
    await state.addSavedQuery(['bird']);
    await state.chooseBoard(Board.safebooru);
    expect(state.savedQueries, [
      ['bird'],
    ]);
    // Per-website searches survive the shared mode.
    expect(store.settings.boardSavedQueries[Board.danbooru], [
      ['dog'],
    ]);
  });

  test('per-website blocked tags round-trip and apply to their site', () async {
    final settings = AppSettings(
      blacklist: const ['shared'],
      boardBlacklists: const {
        Board.safebooru: [' Only_Here ', 'shared'],
        Board.danbooru: [],
      },
      boardSavedQueries: const {
        Board.e621: [
          ['wolf'],
        ],
      },
      globalSavedQueries: true,
    ).normalized();
    final restored = AppSettings.decode(settings.encode());
    expect(restored, settings);
    expect(restored.boardBlacklists.keys, [Board.safebooru]);
    expect(restored.blacklistFor(Board.safebooru), ['shared', 'only_here']);
    expect(restored.blacklistFor(Board.danbooru), ['shared']);
    expect(restored.savedQueriesFor(Board.e621), isEmpty);
    expect(
      restored.copyWith(globalSavedQueries: false).savedQueriesFor(Board.e621),
      [
        ['wolf'],
      ],
    );
    final legacy = AppSettings.decode('{"blacklist": ["a"]}');
    expect(legacy.boardBlacklists, isEmpty);
    expect(legacy.globalSavedQueries, isFalse);

    final repo = FakeRepo([
      [
        {'id': 1, 'url': 'https://x/1.jpg', 'tags': 'only_here'},
        {'id': 2, 'url': 'https://x/2.jpg', 'tags': 'cat'},
      ],
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    await state.updateSettings(settings.copyWith(excludeAi: false));
    await state.search(['cat']);
    expect(repo.queries.last, ['cat', '-shared', '-only_here']);
    expect(state.posts.map((post) => post.id), [2]);
  });

  test(
    'recent searches normalize, persist independently, and move to front',
    () async {
      final store = MemoryStore()
        ..selected = Board.safebooru
        ..settings = const AppSettings(
          boardSavedQueries: {
            Board.safebooru: [
              ['saved'],
            ],
          },
        );
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      await state.initialize();
      await state.search([' Cat ', 'cat', '', ' DOG ']);
      await state.search(['dog', 'CAT']);
      await state.search([' DOG ', 'cat', 'dog']);

      expect(state.recentSearches, [
        ['dog', 'cat'],
        ['cat', 'dog'],
      ]);
      expect(state.savedQueries, [
        ['saved'],
      ]);
      expect(store.settings.recentSearches, state.recentSearches);
      final restored = AppSettings.decode(store.settings.encode());
      expect(restored.recentSearches, state.recentSearches);
    },
  );

  test(
    'recent searches discard empty queries and keep the latest 30',
    () async {
      final store = MemoryStore();
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      for (var index = 0; index < 35; index++) {
        await state.search([' tag_$index ']);
      }
      expect(state.recentSearches, hasLength(30));
      expect(state.recentSearches.first, ['tag_34']);
      expect(state.recentSearches.last, ['tag_5']);
      await state.search(['  ', '']);
      expect(state.recentSearches, hasLength(30));
      expect(
        AppSettings(
          recentSearches: [
            [],
            ['  '],
            ['A', 'a'],
          ],
        ).normalized().recentSearches,
        [
          ['a'],
        ],
      );
    },
  );

  test('overlapping searches preserve ordered recent history', () async {
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore(),
    );
    final first = state.search(['first']);
    final second = state.search(['second']);
    await Future.wait([first, second]);

    expect(state.tags, ['second']);
    expect(state.recentSearches, [
      ['second'],
      ['first'],
    ]);
  });

  test('search continues when recent-history persistence fails', () async {
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: _FailingStore(),
    );
    await state.search(['searchable']);

    expect(state.tags, ['searchable']);
    expect(state.recentSearches, isEmpty);
  });

  test(
    'pending history and saved-search writes preserve both query lists',
    () async {
      final store = _DelayedSettingsStore();
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      await state.initialize();

      final recent = state.search(['recent']);
      await Future<void>.delayed(Duration.zero);
      final saved = state.addSavedQuery(['saved']);
      expect(store.writes, hasLength(1));

      store.gates.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, hasLength(2));
      store.gates.last.complete();
      await Future.wait([recent, saved]);

      expect(state.recentSearches, [
        ['recent'],
      ]);
      expect(state.savedQueries, [
        ['saved'],
      ]);
    },
  );

  test('filtered pages continue until an allowed post is found', () async {
    final repo = FakeRepo([
      [
        post(1, tags: [' AI_GENERATED ']),
      ],
      [
        post(2, tags: ['allowed']),
      ],
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    expect(state.posts.map((value) => value.id), [2]);
    expect(repo.calls, greaterThanOrEqualTo(2));
  });

  test('no-AI query and local filtering can be disabled', () async {
    final repo = FakeRepo([
      [
        post(1, tags: ['ai_generated']),
      ],
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    expect(state.posts, isEmpty);
    expect(repo.queries.first, contains('-ai_generated'));
    await state.updateSettings(const AppSettings(excludeAi: false));
    expect(state.posts.map((value) => value.id), [1]);
    expect(repo.queries.last, isNot(contains('-ai_generated')));
  });

  test('search query composes blacklist and no-AI exclusions', () async {
    final repo = FakeRepo(const [[]]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    await state.updateSettings(const AppSettings(blacklist: [' Blocked ']));
    await state.search([' Cat ']);
    expect(repo.queries.last, ['Cat', '-blocked', '-ai_generated']);
  });

  test(
    'Danbooru keeps a two-tag search within the anonymous tag budget',
    () async {
      final repo = FakeRepo(const [[]]);
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.danbooru,
      );
      await state.initialize();
      await state.search(['artist_tag', 'character_tag']);
      expect(repo.queries.last, ['artist_tag', 'character_tag']);
    },
  );

  test('Sankaku fits exclusions into the anonymous four-tag budget', () async {
    final repo = FakeRepo(const [[]]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.sankaku,
    );
    await state.initialize();
    await state.updateSettings(
      const AppSettings(blacklist: ['blocked', 'other']),
    );
    await state.setRatingFilters({Rating.explicit});
    await state.search(['cat', 'dog']);
    // rating:e counts toward the limit, leaving one slot for exclusions.
    expect(repo.queries.last, ['cat', 'dog', 'rating:e', '-blocked']);
    await state.updateSettings(const AppSettings(blacklist: ['blocked']));
    // rating:s is free, so both exclusions fit.
    await state.setRatingFilters({Rating.general});
    expect(repo.queries.last, [
      'cat',
      'dog',
      'rating:s',
      '-blocked',
      '-ai-created',
    ]);
  });

  test(
    'unfiltered Sankaku feed sends no exclusions and filters AI locally',
    () async {
      final repo = FakeRepo([
        [
          post(1, tags: ['ai-created']),
          post(2),
        ],
      ]);
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.sankaku,
      );
      await state.initialize();
      expect(repo.queries.first, isEmpty);
      expect(state.posts.map((value) => value.id), [2]);
    },
  );

  test(
    'Sankaku displays short pages immediately and keeps loading more',
    () async {
      final repo = FakeRepo([
        [post(1)],
        [post(2)],
        const [],
      ]);
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.sankaku,
      );
      await state.initialize();
      expect(repo.calls, 1);
      expect(state.posts.map((value) => value.id), [1]);
      expect(state.loading, isFalse);
      expect(state.hasMore, isTrue);
      await state.loadMore();
      expect(repo.calls, 2);
      expect(state.posts.map((value) => value.id), [1, 2]);
      expect(state.hasMore, isTrue);
      await state.loadMore();
      expect(repo.calls, 3);
      expect(state.hasMore, isFalse);
    },
  );

  test('Sankaku short page is not lost to a later request failure', () async {
    var calls = 0;
    final repo = _SessionRepo(
      (_, _) => ++calls == 2 ? const RateLimitedException() : null,
      [
        [post(1)],
        [post(2)],
      ],
    );
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.sankaku,
    );
    await state.initialize();
    expect(calls, 1);
    expect(state.error, isNull);
    expect(state.posts.map((value) => value.id), [1]);
    await state.loadMore();
    expect(state.error, isNotNull);
    expect(state.loading, isFalse);
    expect(state.posts.map((value) => value.id), [1]);
    await state.loadMore();
    expect(state.error, isNull);
    expect(state.posts.map((value) => value.id), [1, 2]);
  });

  test(
    'Sankaku still skips locally filtered pages before displaying posts',
    () async {
      final repo = FakeRepo([
        [
          post(1, tags: ['ai-created']),
        ],
        [
          post(2, tags: ['blocked']),
        ],
        [post(3)],
        [post(4)],
      ]);
      final state = AppState(
        repository: repo,
        store: MemoryStore()
          ..selected = Board.sankaku
          ..settings = const AppSettings(blacklist: ['blocked']),
      );
      await state.initialize();
      expect(repo.calls, 3);
      expect(state.posts.map((value) => value.id), [3]);
      expect(state.hasMore, isTrue);
      await state.loadMore();
      expect(repo.calls, 4);
      expect(state.posts.map((value) => value.id), [3, 4]);
    },
  );

  group('Sankaku sign-in', () {
    const session = Credentials(
      userId: 'reader',
      apiKey: 'access-1',
      refreshToken: 'refresh-1',
    );
    const renewed = Credentials(
      userId: 'reader',
      apiKey: 'access-2',
      refreshToken: 'refresh-2',
    );
    MemoryStore signedIn(Credentials credentials) => MemoryStore()
      ..selected = Board.sankaku
      ..credentials[Board.sankaku] = credentials;

    test('session credentials round-trip and legacy entries still load', () {
      final expiry = DateTime.fromMillisecondsSinceEpoch(4102444800000);
      final restored = Credentials.fromMap(
        Credentials(
          userId: 'reader',
          apiKey: 'access-1',
          refreshToken: 'refresh-1',
          expiresAt: expiry,
        ).toMap(),
      );
      expect(
        (
          restored.userId,
          restored.apiKey,
          restored.refreshToken,
          restored.expiresAt,
        ),
        ('reader', 'access-1', 'refresh-1', expiry),
      );
      final legacy = Credentials.fromMap({'userId': '1', 'apiKey': 'key'});
      expect(legacy.toMap(), {'userId': '1', 'apiKey': 'key'});
      expect(legacy.expiresSoon(DateTime.now()), isFalse);
      expect(
        Credentials(
          userId: 'a',
          apiKey: 'b',
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
        ).expiresSoon(DateTime.now()),
        isTrue,
      );
    });

    test('signing in stores the session and lifts the tag budget', () async {
      final repo = FakeRepo(const [[]]);
      final store = MemoryStore()..selected = Board.sankaku;
      final accounts = FakeAccounts(signInResult: session);
      final state = AppState(
        repository: repo,
        store: store,
        accounts: accounts,
      );
      await state.initialize();
      await state.updateSettings(
        const AppSettings(blacklist: ['blocked', 'other']),
      );
      await state.setRatingFilters({Rating.explicit});
      await state.search(['cat', 'dog', 'fox']);
      expect(repo.queries.last, ['cat', 'dog', 'fox', 'rating:e']);

      await state.signIn(Board.sankaku, ' reader ', 'secret pass');
      expect(accounts.logins, [('reader', 'secret pass')]);
      expect(store.credentials[Board.sankaku]!.toMap(), session.toMap());
      expect(repo.lastCredentials?.apiKey, 'access-1');
      expect(repo.queries.last, [
        'cat',
        'dog',
        'fox',
        'rating:e',
        '-blocked',
        '-other',
        '-ai-created',
      ]);
    });

    test('a refused signed-in search learns the limit and trims', () async {
      final repo = _SessionRepo(
        (tags, _) => tags.length > 5 ? const TagLimitException(5) : null,
      );
      final state = AppState(
        repository: repo,
        store: signedIn(session),
        accounts: FakeAccounts(),
      );
      await state.initialize();
      await state.updateSettings(
        const AppSettings(blacklist: ['blocked', 'other']),
      );
      await state.search(['cat', 'dog', 'fox']);
      expect(state.error, isNull);
      expect(repo.queries.last, ['cat', 'dog', 'fox', '-blocked', '-other']);
    });

    test('an over-limit anonymous search explains the limit', () async {
      final repo = _SessionRepo(
        (tags, _) => tags.length > 4 ? const TagLimitException(4) : null,
      );
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.sankaku,
        accounts: FakeAccounts(),
      );
      await state.initialize();
      await state.search(['a', 'b', 'c', 'd', 'e']);
      expect(state.error, contains('up to 4 tags'));
      expect(state.error, contains('Sign in'));
    });

    test('an expired session is renewed and saved', () async {
      final repo = _SessionRepo(
        (_, credentials) => credentials?.apiKey == 'access-1'
            ? const AuthExpiredException()
            : null,
        [
          [post(1)],
        ],
      );
      final store = signedIn(session);
      final accounts = FakeAccounts(refreshResult: renewed);
      final state = AppState(
        repository: repo,
        store: store,
        accounts: accounts,
      );
      await state.initialize();
      expect(state.error, isNull);
      expect(state.posts.map((value) => value.id), [1]);
      expect(accounts.refreshes, 1);
      expect(repo.lastCredentials?.apiKey, 'access-2');
      expect(store.credentials[Board.sankaku]?.refreshToken, 'refresh-2');
    });

    test('concurrent requests share one renewal of a stale session', () async {
      final repo = _SessionRepo((_, _) => null);
      final accounts = FakeAccounts(refreshResult: renewed)
        ..refreshGate = Completer<void>();
      final state = AppState(
        repository: repo,
        store: signedIn(
          Credentials(
            userId: 'reader',
            apiKey: 'access-1',
            refreshToken: 'refresh-1',
            expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
        ),
        accounts: accounts,
      );
      final loading = state.initialize();
      await pumpEventQueue();
      final suggestions = state.autocomplete('cat');
      await pumpEventQueue();
      accounts.refreshGate!.complete();
      await loading;
      await suggestions;
      expect(accounts.refreshes, 1);
      expect(repo.lastCredentials?.apiKey, 'access-2');
      expect(repo.autocompleteCredentials.single?.apiKey, 'access-2');
    });

    test('a session that cannot be renewed falls back to anonymous', () async {
      final repo = _SessionRepo(
        (_, credentials) =>
            credentials == null ? null : const AuthExpiredException(),
        [
          [post(1)],
        ],
      );
      final store = signedIn(session);
      final state = AppState(
        repository: repo,
        store: store,
        accounts: FakeAccounts(),
      );
      await state.initialize();
      expect(state.error, isNull);
      expect(state.posts.map((value) => value.id), [1]);
      expect(repo.lastCredentials, isNull);
      expect(store.credentials, isNot(contains(Board.sankaku)));
      expect(state.takeNotice(), contains('sign-in expired'));
      expect(state.takeNotice(), isNull);
    });

    test('a failed renewal for other reasons keeps the session', () async {
      final repo = _SessionRepo(
        (_, credentials) =>
            credentials == null ? null : const AuthExpiredException(),
      );
      final store = signedIn(session);
      final state = AppState(
        repository: repo,
        store: store,
        accounts: FakeAccounts(refreshError: StateError('offline')),
      );
      await state.initialize();
      expect(state.error, isNotNull);
      expect(store.credentials[Board.sankaku], same(session));
      expect(state.takeNotice(), isNull);
    });

    test('signing out reloads the feed anonymously', () async {
      final repo = FakeRepo([
        [post(1)],
      ]);
      final store = signedIn(session);
      final state = AppState(repository: repo, store: store);
      await state.initialize();
      expect(repo.lastCredentials?.apiKey, 'access-1');
      await state.forgetCredentials(Board.sankaku);
      expect(store.credentials, isNot(contains(Board.sankaku)));
      expect(repo.lastCredentials, isNull);
      expect(state.error, isNull);
      expect(state.posts.map((value) => value.id), [1]);
    });

    test('a renewal finishing during sign-out is not stored', () async {
      final repo = _SessionRepo((_, _) => null);
      final accounts = FakeAccounts(refreshResult: renewed)
        ..refreshGate = Completer<void>();
      final store = _SlowRemoveStore()
        ..selected = Board.sankaku
        ..credentials[Board.sankaku] = Credentials(
          userId: 'reader',
          apiKey: 'access-1',
          refreshToken: 'refresh-1',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        );
      final state = AppState(
        repository: repo,
        store: store,
        accounts: accounts,
      );
      final loading = state.initialize();
      await pumpEventQueue();
      expect(accounts.refreshes, 1);
      final signingOut = state.forgetCredentials(Board.sankaku);
      await pumpEventQueue();
      accounts.refreshGate!.complete();
      await pumpEventQueue();
      store.removeGate.complete();
      await signingOut;
      await loading;
      expect(store.credentials, isNot(contains(Board.sankaku)));
      expect(repo.lastCredentials, isNull);
      expect(await state.credentialsFor(Board.sankaku), isNull);
    });

    test('bridge auth, tag-limit, and rate-limit errors are typed', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('booruplus/test-sankaku');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final codes = [
        'AUTH_EXPIRED',
        'TAG_LIMIT',
        'RATE_LIMITED',
        'AUTH_REJECTED',
      ];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'refreshSignIn') {
          expect(call.arguments, containsPair('refreshToken', 'refresh-1'));
          return {
            'userId': 'reader',
            'accessToken': 'access-2',
            'refreshToken': 'refresh-2',
            'expiresAt': 4102444800000,
          };
        }
        final code = codes.removeAt(0);
        throw PlatformException(
          code: code,
          details: switch (code) {
            'TAG_LIMIT' => {'limit': 8},
            'RATE_LIMITED' => {'retryAfter': 3},
            _ => null,
          },
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final repository = PlatformBoardRepository(channel: channel);
      final accounts = PlatformAccountRepository(channel: channel);
      Future<void> fetch() => repository.fetch(
        board: Board.sankaku,
        tags: const ['cat'],
        limit: 1,
        page: 0,
        random: false,
        credentials: session,
      );
      await expectLater(fetch(), throwsA(isA<AuthExpiredException>()));
      await expectLater(
        fetch(),
        throwsA(isA<TagLimitException>().having((e) => e.limit, 'limit', 8)),
      );
      await expectLater(
        fetch(),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 3),
          ),
        ),
      );
      await expectLater(
        accounts.signIn(board: Board.sankaku, login: 'a', password: 'b'),
        throwsA(isA<SignInRejectedException>()),
      );
      final fresh = await accounts.refreshSignIn(
        board: Board.sankaku,
        credentials: session,
      );
      expect(fresh.apiKey, 'access-2');
      expect(fresh.refreshToken, 'refresh-2');
      expect(fresh.expiresAt?.millisecondsSinceEpoch, 4102444800000);
    });
  });

  test('alphanumeric provider IDs keep a stable identity and round-trip', () {
    final restored = MediaPost.fromMap(
      MediaPost.fromMap({
        'id': 'PVaDxP30Lab',
        'url': 'https://s.example/o/a.mp4?e=1',
      }).toMap(),
    );
    expect(restored.id, 0);
    expect(restored.providerId, 'PVaDxP30Lab');
    expect(restored.displayId, 'PVaDxP30Lab');
    expect(
      SavedPost(board: Board.sankaku, post: restored).identity,
      'sankaku:id:PVaDxP30Lab',
    );
    expect(
      MediaPost.fromMap({'id': '0', 'url': 'https://x/a.jpg'}).hasId,
      isFalse,
    );
    final numeric = MediaPost.fromMap({'id': '42', 'url': 'https://x/a.jpg'});
    expect((numeric.id, numeric.providerId), (42, null));
  });

  test('expired Sankaku favorites are refreshed by ID', () async {
    const stale = 'https://s.example/o/a.jpg?e=1&m=old';
    const fresh = 'https://s.example/o/a.jpg?e=4102444800&m=new';
    final repo = _RefreshRepo({
      'id': 'abc123X',
      'url': fresh,
      'previewUrl': 'https://v.example/p/a.avif?e=4102444800',
    });
    final postStore = MemoryPostStore();
    await postStore.saveFavorites([
      SavedPost(
        board: Board.sankaku,
        post: MediaPost.fromMap({
          'id': 'abc123X',
          'url': stale,
          'previewUrl': 'https://v.example/p/a.avif?e=1',
        }),
      ),
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
      postStore: postStore,
    );
    await state.initialize();
    final saved = state.favoritePosts.single;
    expect(state.displayReady(saved).post.url, stale);
    await pumpEventQueue();
    expect(repo.refreshQueries, [
      ['id:abc123X'],
    ]);
    // ID lookups must not cancel, or be cancelled by, the visible feed.
    expect(repo.refreshFeedFlags, [false]);
    expect(state.displayReady(saved).post.url, fresh);
    expect(
      state.isFavorite(state.displayReady(saved).post, board: Board.sankaku),
      isTrue,
    );
  });

  test(
    'Sankaku videos start from a looked-up URL once theirs expired',
    () async {
      const stale = 'https://v.example/d/a.mp4?e=1&m=old';
      const fresh = 'https://v.example/d/a.mp4?e=4102444800&m=new';
      final repo = _RefreshRepo({
        'id': 'abc123X',
        'url': fresh,
        'previewUrl': 'https://v.example/p/a.avif?e=4102444800',
      });
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.safebooru,
        postStore: MemoryPostStore(),
      );
      await state.initialize();
      final expired = MediaPost.fromMap({
        'id': 'abc123X',
        'url': stale,
        'previewUrl': 'https://v.example/p/a.avif?e=1',
      });

      // The lookup is awaited, unlike displayReady's background refresh.
      final ready = await state.streamablePost(expired, board: Board.sankaku);
      expect(ready.url, fresh);
      expect(repo.refreshQueries.first, ['id:abc123X']);

      // A current URL is used as is unless a failed stream forces a lookup.
      await pumpEventQueue();
      final lookups = repo.refreshQueries.length;
      await state.streamablePost(expired, board: Board.sankaku);
      expect(repo.refreshQueries, hasLength(lookups));
      await state.streamablePost(expired, board: Board.sankaku, force: true);
      expect(repo.refreshQueries, hasLength(lookups + 1));

      // Other boards' URLs pass through without a request.
      final other = MediaPost.fromMap({'id': 5, 'url': stale});
      expect(
        (await state.streamablePost(other, board: Board.danbooru)).url,
        stale,
      );
      expect(repo.refreshQueries, hasLength(lookups + 1));
    },
  );

  test('Realbooru posts read their file from the post page once', () async {
    const thumb = 'https://realbooru.com/thumbnails/ab/cd/thumbnail_x.jpg';
    const file = 'https://video.realbooru.com/images/ab/cd/x.mp4';
    final lookups = <List<String>>[];
    final lookup = Completer<void>();
    final repo = _ScriptedRepo((tags) async {
      if (!tags.first.startsWith('id:')) {
        return [
          {
            'id': '7',
            'url': thumb,
            'previewUrl': thumb,
            'tags': ['a'],
          },
        ];
      }
      lookups.add(tags);
      await lookup.future;
      return [
        {
          'id': '7',
          'url': file,
          'previewUrl': '',
          'tags': ['a', 'b'],
        },
      ];
    });
    final downloads = _RecordingDownloads();
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.realbooru,
      downloads: downloads,
    );
    await state.initialize();
    final listed = state.posts.single;
    // The listing's thumbnail stands in until the page is read.
    expect(state.displayPost(listed, board: Board.realbooru).url, thumb);
    expect(listed.isVideo, isFalse);

    final first = state.resolveMedia(listed, board: Board.realbooru);
    final second = state.resolveMedia(listed, board: Board.realbooru);
    lookup.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(lookups, [
      ['id:7'],
    ]);
    final shown = state.displayPost(listed, board: Board.realbooru);
    expect(shown.url, file);
    expect(shown.isVideo, isTrue);
    // The page gave no preview, so the listing's thumbnail is kept.
    expect(shown.previewUrl, thumb);
    expect(await state.resolveMedia(listed, board: Board.realbooru), isFalse);

    await state.downloadPost(listed, board: Board.realbooru);
    expect(downloads.urls, [file]);
    expect(lookups, hasLength(1));
  });

  test(
    'a Realbooru post whose page cannot be read is not downloaded',
    () async {
      const thumb = 'https://realbooru.com/thumbnails/ab/cd/thumbnail_x.jpg';
      final repo = _ScriptedRepo((tags) async {
        if (tags.first.startsWith('id:')) throw Exception('offline');
        return [
          {'id': '7', 'url': thumb, 'previewUrl': thumb},
        ];
      });
      final downloads = _RecordingDownloads();
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.realbooru,
        downloads: downloads,
      );
      await state.initialize();
      final listed = state.posts.single;
      expect(await state.resolveMedia(listed, board: Board.realbooru), isFalse);
      await expectLater(
        state.downloadPost(listed, board: Board.realbooru),
        throwsStateError,
      );
      expect(await state.mediaSize(listed, board: Board.realbooru), isNull);
      expect(downloads.urls, isEmpty);
    },
  );

  test('settings clamp and directory can be cleared', () {
    final settings = const AppSettings(
      columns: 99,
      rows: 0,
      batchSize: 77,
    ).normalized();
    expect(settings.columns, 6);
    expect(settings.rows, 2);
    expect(settings.batchSize, 70);
    expect(
      const AppSettings(downloadDirectory: 'x')
          .copyWith(downloadDirectory: null)
          .downloadDirectory,
      isNull,
    );
  });

  test('sensitive-media blur preferences persist independently', () {
    const settings = AppSettings(blurExplicit: true, blurQuestionable: false);
    final restored = AppSettings.decode(settings.encode());
    expect(restored.blurExplicit, isTrue);
    expect(restored.blurQuestionable, isFalse);
  });

  test(
    'favorites and hidden posts persist locally and filter the feed',
    () async {
      final postOne = post(31);
      final postTwo = post(32);
      final postStore = MemoryPostStore();
      final state = AppState(
        repository: FakeRepo([
          [postOne, postTwo],
        ]),
        store: MemoryStore()..selected = Board.danbooru,
        postStore: postStore,
      );
      await state.initialize();
      await state.favoritePost(MediaPost.fromMap(postOne));
      await state.hidePost(MediaPost.fromMap(postTwo));

      expect(state.favoritePosts.single.post.id, 31);
      expect(state.hiddenPosts.single.post.id, 32);
      expect(state.posts.map((value) => value.id), [31]);

      final restored = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore()..selected = Board.danbooru,
        postStore: postStore,
      );
      await restored.initialize();
      expect(restored.favoritePosts.single.post.id, 31);
      expect(restored.hiddenPosts.single.post.id, 32);
    },
  );

  test('saved Gelbooru URLs reauthorize only their own host', () {
    const credentials = Credentials(userId: 'u', apiKey: 'k');
    final gelbooru = SavedPost(
      board: Board.gelbooru,
      post: MediaPost.fromMap({
        'id': 33,
        'url': 'https://gelbooru.com/images/33.jpg',
      }),
    );
    final external = SavedPost(
      board: Board.gelbooru,
      post: MediaPost.fromMap({
        'id': 34,
        'url': 'https://cdn.example.com/images/34.jpg',
      }),
    );
    expect(gelbooru.authorized(credentials).post.url, contains('api_key=k'));
    expect(external.authorized(credentials).post.url, external.post.url);
  });

  test('media post serializes derived media fields', () {
    final value = MediaPost.fromMap(
      post(3, tags: ['cat'])..['url'] = 'https://x/a.webm',
    );
    expect(value.isVideo, isTrue);
    expect(value.extension, 'webm');
    expect(MediaPost.fromMap(value.toMap()).id, 3);
  });

  test('video variants round-trip and pick the closest stream', () {
    final value = MediaPost.fromMap({
      ...post(4),
      'url': 'https://x/original.webm',
      'height': 1080,
      'videoVariants': [
        {'label': '720p', 'url': 'https://x/720.mp4', 'height': 720},
        {'url': 'https://x/480.mp4', 'height': 480},
        // The original itself is never listed as a rendition.
        {'label': 'dup', 'url': 'https://x/original.webm', 'height': 1080},
      ],
    });
    expect(value.videoVariants.map((v) => v.label), ['720p', '480p']);
    expect(value.videoVariantFor(0), isNull);
    expect(value.videoVariantFor(1080), isNull);
    expect(value.videoVariantFor(720)?.url, 'https://x/720.mp4');
    expect(value.videoVariantFor(600)?.url, 'https://x/480.mp4');
    // Below every rendition, the smallest is still the closest match.
    expect(value.videoVariantFor(240)?.url, 'https://x/480.mp4');
    final restored = MediaPost.fromMap(value.toMap());
    expect(restored.videoVariants.length, 2);
    expect(restored.videoVariantFor(720)?.label, '720p');
    final sanitized = value.withUrls(url: 'https://y/a.webm', previewUrl: '');
    expect(sanitized.videoVariants.length, 2);
  });

  test('portrait video tiers follow the short side like e621 labels', () {
    // Mirrors a live e926 response for a 1080x1920 WebM.
    final value = MediaPost.fromMap({
      ...post(5),
      'url': 'https://x/original.webm',
      'width': 1080,
      'height': 1920,
      'videoVariants': [
        {
          'label': '1080p MP4',
          'url': 'https://x/alt.mp4',
          'width': 1080,
          'height': 1920,
          'quality': 1080,
        },
        {
          'label': '720p',
          'url': 'https://x/720p.mp4',
          'width': 810,
          'height': 1440,
          'quality': 720,
        },
        // Legacy maps without "quality" fall back to the label, then the
        // short side.
        {'url': 'https://x/480p.mp4', 'width': 540, 'height': 960},
      ],
    });
    expect(value.videoQuality, 1080);
    expect(value.videoVariants.map((v) => v.quality), [1080, 720, 540]);
    expect(value.videoVariantFor(1080), isNull);
    expect(value.videoVariantFor(720)?.url, 'https://x/720p.mp4');
    expect(value.videoVariantFor(600)?.url, 'https://x/480p.mp4');
  });

  test('video quality persists without reloading the feed', () async {
    final store = MemoryStore()..selected = Board.e621;
    final repo = FakeRepo([
      [post(1)],
    ]);
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    final calls = repo.calls;
    await state.setVideoQuality(720);
    expect(state.settings.videoQuality, 720);
    expect(store.settings.videoQuality, 720);
    expect(repo.calls, calls);
    expect(AppSettings.decode(store.settings.encode()).videoQuality, 720);
    expect(AppSettings.decode('{}').videoQuality, 0);
  });

  test('favorite and hidden lookups follow add and remove', () async {
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore()..selected = Board.danbooru,
    );
    await state.initialize();
    final value = MediaPost.fromMap(post(9));
    expect(state.isFavorite(value), isFalse);
    await state.favoritePost(value);
    expect(state.isFavorite(value), isTrue);
    expect(state.isFavorite(value, board: Board.e621), isFalse);
    await state.unfavoritePost(value);
    expect(state.isFavorite(value), isFalse);
    await state.hidePost(value);
    expect(state.isHidden(value), isTrue);
    await state.unhidePost(value);
    expect(state.isHidden(value), isFalse);
  });

  test(
    'autocomplete converts repository maps and records the active board',
    () async {
      final repo = _SuggestionRepo();
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.danbooru,
      );
      await state.initialize();
      final suggestions = await state.autocomplete('fri');
      expect(suggestions.single.name, 'frieren');
      expect(suggestions.single.category, TagCategory.character);
      expect(repo.lastBoard, Board.danbooru);
      expect(repo.lastQuery, 'fri');
    },
  );

  test('board metadata allows anonymous Danbooru/e621 and requires Rule34/Gelbooru auth', () {
    expect(Board.danbooru.requiresAuth, isFalse);
    expect(Board.e621.requiresAuth, isFalse);
    expect(Board.rule34.requiresAuth, isTrue);
    expect(Board.gelbooru.requiresAuth, isTrue);
    expect(
      Board.rule34.authUrl,
      'https://rule34.xxx/index.php?page=account&s=options',
    );
    expect(
      Board.gelbooru.authUrl,
      'https://gelbooru.com/index.php?page=account&s=options',
    );
  });

  test(
    'onboarding starts without a board and changeWebsite persists clearing it',
    () async {
      final store = MemoryStore()..selected = Board.safebooru;
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      await state.initialize();
      await state.changeWebsite();
      expect(state.board, isNull);
      expect(store.selected, isNull);
    },
  );

  test(
    'initialize restores persisted board, settings, and secure credentials',
    () async {
      final store = MemoryStore()
        ..selected = Board.e621
        ..settings = const AppSettings(columns: 5)
        ..credentials[Board.e621] = const Credentials(userId: 'u', apiKey: 'k');
      final repo = FakeRepo(const [[]]);
      final state = AppState(repository: repo, store: store);
      await state.initialize();
      expect(state.board, Board.e621);
      expect(state.settings.columns, 5);
      expect(repo.lastCredentials?.userId, 'u');
    },
  );

  test(
    'authenticate throws and does not persist invalid or failed credentials',
    () async {
      final store = MemoryStore();
      final repo = _FailingRepo();
      final state = AppState(repository: repo, store: store);
      await expectLater(
        state.authenticate(
          Board.rule34,
          const Credentials(userId: '', apiKey: 'key'),
        ),
        throwsArgumentError,
      );
      await expectLater(
        state.authenticate(
          Board.rule34,
          const Credentials(userId: 'u', apiKey: 'k'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await state.credentialsFor(Board.rule34), isNull);
    },
  );

  test('blacklist is sent as negative query and filtered client side with deduplication', () async {
    final repo = FakeRepo([
      [
        post(1, tags: ['cat']),
        post(1),
        post(2, tags: ['blocked']),
      ],
    ]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    await state.updateSettings(const AppSettings(blacklist: ['blocked']));
    expect(state.posts.map((p) => p.id), [1]);
    expect(repo.queries.last, contains('-blocked'));
    expect(repo.calls, greaterThanOrEqualTo(2));
  });

  test('excluded and either-or tags reach the provider query', () async {
    final repo = FakeRepo([[]]);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    await state.updateSettings(const AppSettings(excludeAi: false));
    await state.search(['-1girl', '~cat', '~dog', 'solo']);
    expect(repo.queries.last.take(4), ['-1girl', '~cat', '~dog', 'solo']);
  });

  test('excluded tags match loosely across website naming', () {
    bool excluded(List<String> tags, List<String> query) =>
        AppState.excludedByQuery(tags, query);
    expect(excluded(['Long Hair'], ['-long_hair']), isTrue);
    expect(excluded(['ai-created'], ['-ai_created']), isTrue);
    expect(excluded(['hu_tao_(genshin_impact)'], ['-hu_tao']), isTrue);
    expect(excluded(['hu_tao'], ['-hu_tao_(genshin_impact)']), isTrue);
    expect(excluded(['hu_tao'], ['hu_tao']), isFalse);
    expect(
      excluded(['hu_tao_(cosplay)'], ['-hu_tao_(genshin_impact)']),
      isFalse,
    );
    expect(excluded(['long_hair_ornament'], ['-long_hair']), isFalse);
    expect(excluded(['cat_ears'], ['-cat*', '-', '-rating:e']), isFalse);
  });

  test(
    'excluded tags are enforced locally when a website skips them',
    () async {
      final repo = FakeRepo([
        [
          post(1, tags: ['cat']),
          post(2, tags: ['cat', 'Dog Girl']),
          post(3, tags: ['cat', 'saber_(fate)']),
        ],
      ]);
      final state = AppState(
        repository: repo,
        store: MemoryStore()..selected = Board.safebooru,
      );
      await state.initialize();
      await state.updateSettings(const AppSettings(excludeAi: false));
      await state.search(['cat', '-dog_girl', '-saber']);
      expect(state.posts.map((p) => p.id), [1]);

      final search = state.multiSiteSearch();
      addTearDown(search.dispose);
      await search.search(
        ['cat', '-dog_girl', '-saber'],
        [Board.safebooru, Board.e621],
      );
      expect(search.results.map((saved) => saved.post.id), [1, 1]);
    },
  );

  test('Gelbooru-syntax boards group either-or tags', () {
    expect(
      AppState.providerSyntax(Board.gelbooru, [
        '-1girl',
        '~cat',
        'solo',
        '~dog',
      ]),
      ['-1girl', '{cat ~ dog}', 'solo'],
    );
    expect(AppState.providerSyntax(Board.rule34, ['~cat', '~dog']), [
      '( cat ~ dog )',
    ]);
    expect(AppState.providerSyntax(Board.tbib, ['~cat', 'solo']), [
      'cat',
      'solo',
    ]);
    expect(AppState.providerSyntax(Board.danbooru, ['~cat', '~dog']), [
      '~cat',
      '~dog',
    ]);
  });

  test('new search invalidates an older in-flight request', () async {
    final first = Completer<List<Map<String, dynamic>>>();
    final repo = _DelayedRepo(first);
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    await state.initialize();
    final old = state.search(['old']);
    await Future<void>.delayed(Duration.zero);
    await state.search(['new']);
    first.complete([post(1)]);
    await old;
    expect(state.posts.map((p) => p.id), [2]);
  });

  test('board switch invalidates an in-flight old-board request', () async {
    final oldRequest = Completer<List<Map<String, dynamic>>>();
    final repo = _BoardSwitchRepo(oldRequest);
    final store = MemoryStore()..selected = Board.safebooru;
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    final old = state.chooseBoard(Board.safebooru);
    await Future<void>.delayed(Duration.zero);
    await state.chooseBoard(Board.danbooru);
    oldRequest.complete([post(1)]);
    await old;
    expect(state.board, Board.danbooru);
    expect(state.posts.map((p) => p.id), [2]);
  });

  test('a superseded feed fetch is cancelled without an error', () async {
    final repo = _CancellingRepo();
    final state = AppState(
      repository: repo,
      store: MemoryStore()..selected = Board.safebooru,
    );
    final errors = <String>[];
    state.addListener(() {
      if (state.error != null) errors.add(state.error!);
    });
    final initial = state.initialize();
    await pumpEventQueue();
    expect(repo.feeds, hasLength(1));
    await state.chooseBoard(Board.danbooru);
    await initial;
    expect(repo.cancelled, 1);
    expect(errors, isEmpty);
    expect(state.error, isNull);
    expect(state.loading, isFalse);
    expect(state.board, Board.danbooru);
    expect(state.posts.map((p) => p.id), [2]);
    expect(repo.feedFlags, everyElement(isTrue));
  });

  test(
    'settings persistence failure leaves in-memory settings unchanged',
    () async {
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: _FailingStore(),
      );
      await expectLater(
        state.updateSettings(const AppSettings(columns: 6)),
        throwsA(isA<StateError>()),
      );
      expect(state.settings.columns, 3);
    },
  );

  test('failed initial load retries page zero on loadMore', () async {
    final repo = _FailOnceRepo();
    final store = MemoryStore()..selected = Board.safebooru;
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    expect(state.posts, isEmpty);
    await state.loadMore();
    expect(repo.pages, [0, 0, 1, 2]);
    expect(state.posts.map((p) => p.id), [4]);
  });

  test('a rate-limited board switch explains the wait and retries', () async {
    final repo = _FailOnceRepo(
      const RateLimitedException(Duration(seconds: 4)),
    );
    final state = AppState(repository: repo, store: MemoryStore());
    await state.initialize();
    await state.chooseBoard(Board.danbooru);
    expect(state.error, contains('Danbooru is busy or limiting requests'));
    expect(state.error, contains('about 4 seconds'));
    await state.loadMore();
    expect(state.error, isNull);
    expect(state.posts.map((p) => p.id), [4]);
  });

  test('media fetches share in-flight bytes and retry failures', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('booruplus/test-media');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final requested = <String>[];
    var fail = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final url = (call.arguments as Map)['url'] as String;
      requested.add(url);
      if (url.endsWith('b.jpg') && fail) {
        fail = false;
        throw PlatformException(code: 'REQUEST_FAILED');
      }
      return Uint8List.fromList([1, 2, 3]);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final media = MediaService(channel: channel);
    const a = 'https://img.gelbooru.com/a.jpg';
    const b = 'https://img.gelbooru.com/b.jpg';
    final first = media.fetchMedia(board: Board.gelbooru, url: a);
    final again = MediaService(channel: channel)
        .fetchMedia(board: Board.gelbooru, url: a);
    expect(await first, [1, 2, 3]);
    expect(await again, [1, 2, 3]);
    await media.fetchMedia(board: Board.gelbooru, url: a);
    expect(requested, [a]);
    await expectLater(
      media.fetchMedia(board: Board.gelbooru, url: b),
      throwsA(isA<PlatformException>()),
    );
    expect(await media.fetchMedia(board: Board.gelbooru, url: b), [1, 2, 3]);
    expect(requested, [a, b, b]);
  });

  test('failed later load retries the same later page', () async {
    final repo = _FailLaterRepo();
    final store = MemoryStore()..selected = Board.safebooru;
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    await state.loadMore();
    expect(repo.pages, [0, 1]);
    await state.loadMore();
    expect(repo.pages, [0, 1, 1, 2, 3]);
    expect(state.posts.map((p) => p.id), contains(100));
  });

  test('forgetting active required credentials invalidates old results and shows auth state', () async {
    final store = MemoryStore()
      ..selected = Board.rule34
      ..credentials[Board.rule34] = const Credentials(userId: 'u', apiKey: 'k');
    final state = AppState(repository: FakeRepo(const [[]]), store: store);
    await state.initialize();
    await state.forgetCredentials(Board.rule34);
    expect(state.error, contains('Authentication is required'));
    expect(state.posts, isEmpty);
  });

  test(
    'website clear persistence failure preserves the visible board',
    () async {
      final store = _FailingBoardStore()..selected = Board.safebooru;
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      await state.initialize();
      await state.changeWebsite();
      expect(state.board, Board.safebooru);
      expect(state.error, isNotNull);
    },
  );

  test('restoring a backup can turn secure screen on but never off', () async {
    final plain = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore(),
    );
    await plain.initialize();
    final secure = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore()..settings = const AppSettings(secureScreen: true),
    );
    await secure.initialize();
    await secure.importBackup(plain.exportBackup());
    expect(secure.settings.secureScreen, isTrue);
    await plain.importBackup(secure.exportBackup());
    expect(plain.settings.secureScreen, isTrue);
  });

  group('updates', () {
    Map<String, Object?> release(
      String tag,
      List<String> assets, {
      bool draft = false,
      bool prerelease = false,
    }) => {
      'tag_name': tag,
      'name': 'BooruPlus $tag',
      'body': 'Notes for $tag',
      'html_url': 'https://github.com/Anislop/BooruPlus/releases/tag/$tag',
      'draft': draft,
      'prerelease': prerelease,
      'assets': [
        for (final name in assets)
          {
            'name': name,
            'state': 'uploaded',
            'size': 1024,
            'browser_download_url':
                'https://github.com/Anislop/BooruPlus/releases/download/$tag/$name',
          },
      ],
    };

    test('the launch check setting defaults on and round-trips', () {
      expect(const AppSettings().checkUpdates, isTrue);
      expect(AppSettings.decode('{"blacklist": ["a"]}').checkUpdates, isTrue);
      final off = const AppSettings().copyWith(checkUpdates: false);
      expect(off, isNot(const AppSettings()));
      expect(AppSettings.decode(off.encode()).checkUpdates, isFalse);
      expect(AppSettings.decode(off.encode()), off);
    });

    test('picks the newest uncensored APK built after the installed one', () {
      final listing = [
        release('nightly', [
          'booruplus-1.0.0-42-uncensored.apk',
          'booruplus-1.0.0-42-uncensored-debug.apk',
        ], prerelease: true),
        release('v1.0.0', ['booruplus-1.0.0-40-uncensored.apk']),
        release('draft', ['booruplus-1.0.0-99-uncensored.apk'], draft: true),
        release('old-name', ['booruplus-1.0.0-60-release.apk']),
      ];
      final newest = AppRelease.newest(listing, installedBuild: 39)!;
      expect(newest.build, 42);
      expect(newest.version, '1.0.0');
      expect(newest.tag, 'nightly');
      expect(newest.prerelease, isTrue);
      expect(newest.size, 1024);
      expect(
        newest.apkUrl,
        'https://github.com/Anislop/BooruPlus/releases/download/nightly/'
        'booruplus-1.0.0-42-uncensored.apk',
      );
      expect(AppRelease.newest(listing, installedBuild: 42), isNull);
      expect(AppRelease.newest('not a listing', installedBuild: 0), isNull);
    });

    test('splits nightly notes into the commit title and description', () {
      AppRelease withNotes(String notes) => AppRelease(
        tag: 'nightly',
        title: 'Nightly (abc1234)',
        version: '1.0.0',
        build: 2,
        apkUrl: 'https://github.com/o/r/releases/download/nightly/a.apk',
        pageUrl: 'https://github.com/o/r/releases/tag/nightly',
        notes: notes,
      );
      final full = withNotes(
        'Fix sign-in\r\n\r\nKeeps the user ID.\r\nAnd the key.\r\n\r\n'
        '${AppRelease.commitEnd}\r\nBuilt from abc1234.',
      ).change;
      expect(full.title, 'Fix sign-in');
      expect(full.description, 'Keeps the user ID.\nAnd the key.');

      final bare = withNotes('Fix sign-in\n\n${AppRelease.commitEnd}\n').change;
      expect(bare.title, 'Fix sign-in');
      expect(bare.description, isEmpty);

      final versioned = withNotes('## What changed\n* Things').change;
      expect(versioned.title, 'Nightly (abc1234)');
      expect(versioned.description, '## What changed\n* Things');
    });

    test('ignores APKs hosted outside GitHub', () {
      final listing = [
        {
          'tag_name': 'nightly',
          'assets': [
            {
              'name': 'booruplus-1.0.0-50-uncensored.apk',
              'browser_download_url': 'https://example.com/booruplus.apk',
            },
          ],
        },
      ];
      expect(AppRelease.newest(listing, installedBuild: 1), isNull);
    });

    test('checks the repository releases against the installed build and '
        'maps installer refusals', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('booruplus/test-updates');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final installs = <Object?>[];
      var refusal = 'UPDATE_SIGNATURE';
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'appVersion') return {'name': '1.0.0', 'build': 41};
        installs.add(call.arguments);
        throw PlatformException(code: refusal);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final requested = <Uri>[];
      final updates = UpdateService(
        channel: channel,
        repository: 'owner/repo',
        get: (uri) async {
          requested.add(uri);
          return jsonEncode([
            release('nightly', ['booruplus-1.0.0-42-uncensored.apk']),
          ]);
        },
      );
      expect((await updates.installedVersion())!.label, '1.0.0 (build 41)');
      final found = (await updates.check())!;
      expect(found.build, 42);
      expect(requested.single.host, 'api.github.com');
      expect(requested.single.path, '/repos/owner/repo/releases');

      await expectLater(
        updates.install(found),
        throwsA(
          isA<UpdateException>()
              .having((e) => e.failure, 'failure', UpdateFailure.signature)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      expect((installs.single as Map)['url'], found.apkUrl);
      refusal = 'REQUEST_FAILED';
      await expectLater(
        updates.install(found),
        throwsA(
          isA<UpdateException>().having((e) => e.retryable, 'retryable', true),
        ),
      );
    });
  });

  group('booruShorts', () {
    test('settings round-trip and older settings load defaults', () {
      final settings = const AppSettings().copyWith(
        shortsTags: [' Cat ', 'cat', 'dog'],
        shortsOff: [Board.nozomi, Board.danbooru],
        shortsMuted: true,
        shortsAutoAdvance: true,
      );
      expect(settings.shortsTags, ['cat', 'dog']);
      // Kept in enum order.
      expect(settings.shortsOff, [Board.danbooru, Board.nozomi]);
      expect(AppSettings.decode(settings.encode()), settings);

      final legacy = AppSettings.decode('{"blacklist": ["a"]}');
      expect(legacy.shortsTags, isEmpty);
      expect(legacy.shortsOff, isEmpty);
      expect(legacy.shortsMuted, isFalse);
      expect(legacy.shortsAutoAdvance, isFalse);
    });

    test('only websites with video take part', () {
      expect(Board.danbooru.shortsVideoQuery, ['filetype:mp4,webm']);
      expect(Board.e621.shortsVideoQuery, ['~type:webm', '~type:mp4']);
      expect(Board.sankaku.shortsVideoQuery, ['video']);
      expect(Board.sakugabooru.shortsVideoQuery, ['animated']);
      for (final board in [
        Board.safebooru,
        Board.tbib,
        Board.konachan,
        Board.yandere,
        Board.mspabooru,
        Board.eshuushuu,
        Board.mikubooru,
      ]) {
        expect(board.hasShorts, isFalse, reason: board.name);
      }
    });

    test('each tag is its own random stream per website, never a feed '
        'request, keeping only allowed videos once', () async {
      final repo = _ShortsRepo({
        (Board.danbooru, 'cat'): [
          _video(1, md5: 'a' * 32),
          {'id': 2, 'url': 'https://x/2.png', 'tags': 'cat'},
          _video(3, tags: 'cat blocked'),
        ],
        (Board.danbooru, 'dog'): [_video(4)],
        // The same file as Danbooru post 1, found on e621.
        (Board.e621, 'cat'): [_video(1, md5: 'a' * 32), _video(5)],
      });
      final store = MemoryStore()
        ..settings = const AppSettings(blacklist: ['blocked']);
      final state = AppState(repository: repo, store: store);
      await state.initialize();
      final feed = state.shortsFeed();
      await feed.start(
        tags: ['cat', 'dog'],
        boards: [Board.danbooru, Board.e621, Board.safebooru],
      );

      expect(
        feed.posts.map((saved) => '${saved.board.name}:${saved.post.id}'),
        unorderedEquals(['danbooru:1', 'danbooru:4', 'e621:5']),
      );
      expect(repo.calls.map((call) => call.board).toSet(), {
        Board.danbooru,
        Board.e621,
      });
      final danbooruCat = repo.calls.firstWhere(
        (call) => call.board == Board.danbooru && call.tags.contains('cat'),
      );
      expect(danbooruCat.tags.first, 'filetype:mp4,webm');
      expect(danbooruCat.tags, isNot(contains('dog')));
      expect(repo.calls.every((call) => call.random && !call.feed), isTrue);
      expect(repo.calls.map((call) => call.seed).toSet(), hasLength(1));
      feed.dispose();
    });

    test('the Shorts content setting drops explicit, questionable, and '
        'unrated videos', () async {
      final repo = _ShortsRepo({
        (Board.danbooru, null): [
          _video(1),
          _video(2, rating: 'q'),
          _video(3, rating: 'explicit'),
        ],
        (Board.nozomi, null): [_video(4, rating: '')],
      });
      Future<List<String>> shown(ShortsContent content) async {
        final store = MemoryStore()
          ..settings = AppSettings(shortsContent: content);
        final state = AppState(repository: repo, store: store);
        await state.initialize();
        final feed = state.shortsFeed();
        await feed.start(
          tags: const [],
          boards: [Board.danbooru, Board.nozomi],
        );
        final posts = [
          for (final saved in feed.posts)
            '${saved.board.name}:${saved.post.id}',
        ];
        feed.dispose();
        return posts;
      }

      expect(
        await shown(ShortsContent.all),
        unorderedEquals(['danbooru:1', 'danbooru:2', 'danbooru:3', 'nozomi:4']),
      );
      expect(
        await shown(ShortsContent.noExplicit),
        unorderedEquals(['danbooru:1', 'danbooru:2']),
      );
      expect(await shown(ShortsContent.safeOnly), ['danbooru:1']);
    });

    test('without tags every video is asked for', () async {
      final repo = _ShortsRepo({
        (Board.sankaku, null): [_video(7)],
      });
      final state = AppState(repository: repo, store: MemoryStore());
      await state.initialize();
      final feed = state.shortsFeed();
      await feed.start(tags: const [], boards: [Board.sankaku]);
      expect(feed.posts.single.post.id, 7);
      expect(repo.calls.single.tags.first, 'video');
      feed.dispose();
    });

    test('a failing website is reported and can be retried', () async {
      final repo = _ShortsRepo({
        (Board.e621, null): [_video(8)],
      })..failing.add(Board.danbooru);
      final state = AppState(repository: repo, store: MemoryStore());
      await state.initialize();
      final feed = state.shortsFeed();
      await feed.start(tags: const [], boards: [Board.danbooru, Board.e621]);
      expect(feed.posts.single.post.id, 8);
      expect(feed.errors.keys, [Board.danbooru]);

      repo.failing.clear();
      repo.results[(Board.danbooru, null)] = [_video(9)];
      await feed.retry();
      expect(feed.errors, isEmpty);
      expect(feed.posts.map((saved) => saved.post.id), contains(9));
      feed.dispose();
    });

    test('a snapshot restores the feed after a detour', () async {
      final repo = _ShortsRepo({
        (Board.danbooru, null): [_video(1), _video(2)],
        (Board.danbooru, 'cat'): [_video(3)],
      });
      final state = AppState(repository: repo, store: MemoryStore());
      await state.initialize();
      final feed = state.shortsFeed();
      await feed.start(tags: const [], boards: [Board.danbooru]);
      final before = feed.posts.map((saved) => saved.post.id).toList();
      final snapshot = feed.snapshot();

      await feed.start(tags: ['cat'], boards: [Board.danbooru]);
      expect(feed.posts.map((saved) => saved.post.id), [3]);

      feed.restore(snapshot);
      expect(feed.tags, isEmpty);
      expect(feed.posts.map((saved) => saved.post.id), before);
      expect(feed.loading, isFalse);
      feed.dispose();
    });

    test('a website that only repeats itself stops being asked', () async {
      final repo = _ShortsRepo({
        (Board.danbooru, null): [_video(1)],
      })..repeat = true;
      final state = AppState(repository: repo, store: MemoryStore());
      await state.initialize();
      final feed = state.shortsFeed();
      await feed.start(tags: const [], boards: [Board.danbooru]);
      expect(feed.posts, hasLength(1));
      await feed.loadMore();
      expect(feed.hasMore, isFalse);
      final calls = repo.calls.length;
      await feed.loadMore();
      expect(repo.calls, hasLength(calls));
      feed.dispose();
    });

    test('websites need video, Shorts switched on, and credentials', () async {
      final store = MemoryStore()
        ..settings = const AppSettings(shortsOff: [Board.e926]);
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      await state.initialize();
      final boards = await state.shortsBoards();
      expect(boards, contains(Board.danbooru));
      expect(boards, isNot(contains(Board.e926)));
      expect(boards, isNot(contains(Board.safebooru)));
      expect(boards, isNot(contains(Board.gelbooru)));
    });

    test('saving Shorts tags and mute does not reload the feed', () async {
      final repo = FakeRepo(const [[]]);
      final store = MemoryStore()..selected = Board.safebooru;
      final state = AppState(repository: repo, store: store);
      await state.initialize();
      final calls = repo.calls;
      await state.setShortsTags(['Cat']);
      await state.setShortsMuted(true);
      await state.setShortsOff([Board.nozomi]);
      await state.setShortsContent(ShortsContent.noExplicit);
      expect(repo.calls, calls);
      expect(store.settings.shortsContent, ShortsContent.noExplicit);
      expect(store.settings.shortsTags, ['cat']);
      expect(store.settings.shortsMuted, isTrue);
      expect(store.settings.shortsOff, [Board.nozomi]);
    });

    test('personalization settings round-trip, normalize, and default', () {
      final settings = const AppSettings().copyWith(
        shortsPersonalized: false,
        shortsExploration: ShortsExploration.high,
        shortsContent: ShortsContent.safeOnly,
        shortsFollowing: [' Artist_A ', 'artist_a', 'b'],
        shortsAutoScrollSeconds: 30,
        shortsPictureInPicture: false,
      );
      expect(settings.shortsFollowing, ['artist_a', 'b']);
      expect(AppSettings.decode(settings.encode()), settings);
      expect(
        const AppSettings()
            .copyWith(shortsAutoScrollSeconds: 7)
            .shortsAutoScrollSeconds,
        0,
      );

      final legacy = AppSettings.decode('{"blacklist": ["a"]}');
      expect(legacy.shortsPersonalized, isTrue);
      expect(legacy.shortsExploration, ShortsExploration.normal);
      expect(legacy.shortsContent, ShortsContent.all);
      expect(
        AppSettings.decode('{"shortsContent": "unknown"}').shortsContent,
        ShortsContent.all,
      );
      expect(legacy.shortsFollowing, isEmpty);
      expect(legacy.shortsAutoScrollSeconds, 0);
      expect(legacy.shortsPictureInPicture, isTrue);
    });

    test('likes weigh artists above general tags and skip tags every '
        'video has', () {
      final profile = ShortsProfile();
      final post = _shortsPost(1, {
        'artist_a': 'artist',
        'smile': 'general',
        'video': 'meta',
        'animated': 'general',
      });
      profile.learn(post, ShortsSignal.like);
      final weights = profile.tagWeights;
      expect(weights['artist_a'], greaterThan(weights['smile']!));
      expect(weights, isNot(contains('animated')));
      expect(weights, isNot(contains('video')));
      expect(profile.topTags(3, atLeast: 0), ['artist_a', 'smile']);

      profile.learn(post, ShortsSignal.like, undo: true);
      expect(profile.tagWeights, isEmpty);

      profile.learn(post, ShortsSignal.dislike);
      expect(profile.tagWeights['artist_a'], lessThan(0));
      expect(profile.score(post), lessThan(0));
    });

    test('interests fade by half every two weeks', () {
      var now = DateTime(2026, 1, 1);
      final profile = ShortsProfile(clock: () => now);
      final post = _shortsPost(1, {'artist_a': 'artist'});
      profile.learn(post, ShortsSignal.like);
      final before = profile.tagWeights['artist_a']!;
      now = now.add(const Duration(days: 14));
      profile.learnTag('other', .5);
      expect(profile.tagWeights['artist_a'], closeTo(before / 2, .01));
    });

    test('watch time gives signals only for videos that could be seen', () {
      expect(
        const ShortsWatch(
          played: Duration.zero,
          duration: Duration(seconds: 20),
        ).signals,
        [ShortsSignal.quickSkip],
      );
      expect(
        const ShortsWatch(
          played: Duration(seconds: 8),
          duration: Duration(seconds: 20),
        ).signals,
        isEmpty,
      );
      expect(
        const ShortsWatch(
          played: Duration(seconds: 19),
          duration: Duration(seconds: 20),
        ).signals,
        [ShortsSignal.completed],
      );
      expect(
        const ShortsWatch(
          played: Duration(seconds: 40),
          duration: Duration(seconds: 20),
          loops: 2,
        ).signals,
        [ShortsSignal.completed, ShortsSignal.looped, ShortsSignal.looped],
      );
      expect(
        const ShortsWatch(
          played: Duration.zero,
          duration: Duration(seconds: 20),
          visible: false,
        ).signals,
        isEmpty,
      );
      // A video that never loaded says nothing.
      expect(
        const ShortsWatch(
          played: Duration.zero,
          duration: Duration.zero,
        ).signals,
        isEmpty,
      );
    });

    test('the profile round-trips, and muted tags stop matching', () {
      final profile = ShortsProfile();
      final liked = _shortsPost(1, {
        'artist_a': 'artist',
      }, uploader: 'Uploader');
      profile
        ..learn(liked, ShortsSignal.favorite)
        ..observe(liked, watched: true)
        ..mute('Gore');
      final copy = ShortsProfile()..loadMap(profile.toMap());
      expect(copy.tagWeights, profile.tagWeights);
      expect(copy.mutedTags, {'gore'});
      expect(copy.hasSeen(liked), isTrue);
      expect(copy.history.single.identity, liked.identity);
      expect(copy.score(liked), closeTo(profile.score(liked), 1e-9));
      expect(copy.isMuted(_shortsPost(2, {'gore': 'general'})), isTrue);

      // Damaged values are skipped.
      final damaged = ShortsProfile()
        ..loadMap({
          'tags': {'a': 'x', 'b': 9},
          'boards': {'nowhere': 1, 'e621': 1},
          'history': ['x', 1],
        });
      expect(damaged.tagWeights, {'b': 3.0});
      expect(damaged.history, isEmpty);
    });

    test('the ranker puts liked videos first without long runs of one '
        'artist, and unseen videos before seen ones', () {
      final profile = ShortsProfile();
      final liked = [
        for (var id = 1; id <= 3; id++) _shortsPost(id, {'artist_a': 'artist'}),
      ];
      final other = [
        for (var id = 4; id <= 6; id++)
          _shortsPost(id, {'artist_$id': 'artist'}),
      ];
      profile.learn(liked.first, ShortsSignal.like);
      final ranker = ShortsRanker(profile, random: _FixedRandom());
      final picked = ranker.take(
        [...other, ...liked],
        6,
        exploration: ShortsExploration.normal,
      );
      expect(picked.take(2), liked.take(2));
      // A third artist_a video in a row waits for another artist.
      expect(picked[2].post.id, isNot(3));
      expect(picked.map((saved) => saved.post.id), contains(3));

      profile.observe(liked[1], watched: false);
      final again = ShortsRanker(profile, random: _FixedRandom()).take(
        [liked[1], liked[2], ...other],
        5,
        exploration: ShortsExploration.normal,
      );
      expect(again.last, liked[1]);
    });

    test('with interests, For you asks for liked tags and orders by them; '
        'switched off, it keeps the arrival order', () async {
      final repo = _ShortsRepo({
        (Board.danbooru, null): [
          for (var id = 1; id <= 6; id++) _video(id, tags: 'plain_$id'),
          _video(7, tags: 'fox'),
        ],
        (Board.danbooru, 'fox'): [_video(8, tags: 'fox')],
      });
      final store = MemoryStore();
      final state = AppState(repository: repo, store: store);
      await state.initialize();
      final fox = SavedPost(
        board: Board.danbooru,
        post: MediaPost.fromMap(_video(99, tags: 'fox')),
      );
      for (var i = 0; i < 3; i++) {
        state.learnShorts(fox, ShortsSignal.like);
      }
      expect(state.shortsProfile.topTags(1), ['fox']);

      final feed = state.shortsFeed(random: _FixedRandom());
      await feed.start(tags: const [], boards: [Board.danbooru]);
      expect(feed.personalized, isTrue);
      expect(feed.interestTags, ['fox']);
      expect(repo.calls.any((call) => call.tags.contains('fox')), isTrue);
      expect(feed.posts.take(2).map((saved) => saved.post.id).toSet(), {7, 8});
      expect(feed.posts, hasLength(5));
      await feed.loadMore();
      expect(feed.posts, hasLength(8));
      feed.dispose();

      store.settings = store.settings.copyWith(shortsPersonalized: false);
      await state.updateSettings(store.settings);
      repo.calls.clear();
      final plain = state.shortsFeed(random: _FixedRandom());
      await plain.start(tags: const [], boards: [Board.danbooru]);
      expect(plain.personalized, isFalse);
      expect(repo.calls.any((call) => call.tags.contains('fox')), isFalse);
      expect(plain.posts.map((saved) => saved.post.id), [1, 2, 3, 4, 5, 6, 7]);
      // Nothing is learned while personalization is off.
      final weights = state.shortsProfile.tagWeights;
      state.learnShorts(fox, ShortsSignal.dislike);
      expect(state.shortsProfile.tagWeights, weights);
      plain.dispose();
    });

    test('Following asks for the newest videos with followed tags only, and '
        'muted tags never show', () async {
      final repo = _ShortsRepo({
        (Board.danbooru, 'artist_a'): [
          _video(1, tags: 'artist_a'),
          _video(2, tags: 'artist_a gore'),
        ],
      });
      final state = AppState(repository: repo, store: MemoryStore());
      await state.initialize();
      await state.muteShortsTag('gore');

      final empty = state.shortsFeed();
      await empty.start(
        tags: const [],
        boards: [Board.danbooru],
        mode: ShortsMode.following,
      );
      expect(repo.calls, isEmpty);
      expect(empty.posts, isEmpty);
      expect(empty.hasMore, isFalse);
      empty.dispose();

      await state.toggleShortsFollow('Artist_A');
      expect(state.settings.shortsFollowing, ['artist_a']);
      final feed = state.shortsFeed();
      await feed.start(
        tags: state.settings.shortsFollowing,
        boards: [Board.danbooru],
        mode: ShortsMode.following,
      );
      expect(feed.posts.map((saved) => saved.post.id), [1]);
      expect(repo.calls.every((call) => !call.random && !call.feed), isTrue);
      feed.dispose();
    });

    test('watching records history and seen videos, except in incognito; '
        'backups carry interests only', () async {
      final shortsStore = MemoryShortsProfileStore();
      final store = MemoryStore();
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: store,
        shortsStore: shortsStore,
      );
      await state.initialize();
      final post = _shortsPost(1, {'artist_a': 'artist'});
      state.watchedShorts(
        post,
        const ShortsWatch(
          played: Duration(seconds: 10),
          duration: Duration(seconds: 10),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(state.shortsProfile.history.single.identity, post.identity);
      expect(state.shortsProfile.tagWeights['artist_a'], greaterThan(0));
      expect(shortsStore.profile?['history'], hasLength(1));

      final reloaded = AppState(
        repository: FakeRepo(const [[]]),
        store: store,
        shortsStore: shortsStore,
      );
      await reloaded.initialize();
      expect(reloaded.shortsProfile.hasSeen(post), isTrue);

      final backup = jsonDecode(state.exportBackup()) as Map;
      expect(backup['shortsProfile']['tags'], contains('artist_a'));
      expect(backup['shortsProfile'], isNot(contains('history')));
      final fresh = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore(),
      );
      await fresh.initialize();
      await fresh.importBackup(state.exportBackup());
      expect(fresh.shortsProfile.tagWeights, contains('artist_a'));
      expect(fresh.shortsProfile.history, isEmpty);

      await state.setIncognito(true);
      final other = _shortsPost(2, {'artist_b': 'artist'});
      state.watchedShorts(
        other,
        const ShortsWatch(
          played: Duration(seconds: 10),
          duration: Duration(seconds: 10),
        ),
      );
      state.learnShorts(other, ShortsSignal.like);
      expect(state.shortsProfile.hasSeen(other), isFalse);
      expect(state.shortsProfile.tagWeights, isNot(contains('artist_b')));

      await state.clearShortsHistory();
      await state.resetShortsInterests();
      expect(state.shortsProfile.isEmpty, isTrue);
    });
  });
}

class _DelayedRepo implements BoardRepository {
  _DelayedRepo(this.first);
  final Completer<List<Map<String, dynamic>>> first;
  int calls = 0;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) {
    calls++;
    return calls == 1
        ? Future.value(const [])
        : calls == 2
        ? first.future
        : Future.value([post(2)]);
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) => Future.value(const []);
}

class _FailingRepo implements BoardRepository {
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) => Future.error(StateError('probe failed'));

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) => Future.value(const []);
}

class _SuggestionRepo implements BoardRepository {
  Board? lastBoard;
  String? lastQuery;

  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) => Future.value(const []);

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) async {
    lastBoard = board;
    lastQuery = query;
    return const [
      {'name': 'frieren', 'category': 'character', 'postCount': 42},
    ];
  }
}

class _BoardSwitchRepo implements BoardRepository {
  _BoardSwitchRepo(this.oldRequest);
  final Completer<List<Map<String, dynamic>>> oldRequest;
  int safeCalls = 0;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) {
    if (board == Board.safebooru && safeCalls++ > 0) return oldRequest.future;
    if (board == Board.danbooru) return Future.value([post(2)]);
    return Future.value(const []);
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) => Future.value(const []);
}

/// Mimics the bridge: a new feed fetch fails the pending one as cancelled.
/// Only the first feed fetch stays pending; Danbooru then answers one post.
class _CancellingRepo implements BoardRepository {
  final List<Completer<List<Map<String, dynamic>>>> feeds = [];
  final List<bool> feedFlags = [];
  int cancelled = 0;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) {
    feedFlags.add(feed);
    if (!feed) return Future.value(const []);
    if (feeds.isNotEmpty && !feeds.last.isCompleted) {
      cancelled++;
      feeds.last.completeError(const RequestCancelledException());
    }
    final next = Completer<List<Map<String, dynamic>>>();
    if (feeds.isNotEmpty) {
      next.complete(board == Board.danbooru && page == 0 ? [post(2)] : []);
    }
    feeds.add(next);
    return next.future;
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) => Future.value(const []);
}

class _FailingStore extends MemoryStore {
  @override
  Future<void> saveSettings(AppSettings value) =>
      Future.error(StateError('settings write failed'));
}

class _DelayedSettingsStore extends MemoryStore {
  final writes = <AppSettings>[];
  final gates = <Completer<void>>[];

  @override
  Future<void> saveSettings(AppSettings value) async {
    writes.add(value);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    settings = value;
  }
}

class _FailOnceRepo implements BoardRepository {
  _FailOnceRepo([this.error = const _TemporaryFailure()]);
  final Object error;
  final List<int> pages = [];
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) {
    pages.add(page);
    return pages.length == 1 ? Future.error(error) : Future.value([post(4)]);
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) => Future.value(const []);
}

class _TemporaryFailure implements Exception {
  const _TemporaryFailure();
}

class _FailLaterRepo implements BoardRepository {
  final List<int> pages = [];
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) {
    pages.add(page);
    if (page == 0) {
      return Future.value(List.generate(50, (index) => post(5 + index)));
    }
    if (pages.where((value) => value == 1).length == 1) {
      return Future.error(StateError('temporary later failure'));
    }
    return Future.value([post(100)]);
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) => Future.value(const []);
}

class _FailingBoardStore extends MemoryStore {
  @override
  Future<void> saveBoard(Board? value) =>
      Future.error(StateError('board write failed'));
}

Map<String, dynamic> _video(
  int id, {
  String md5 = '',
  String tags = 'cat',
  String rating = 'general',
}) => {
  'id': id,
  'url': 'https://x/$id.mp4',
  'tags': tags,
  'rating': rating,
  'md5': md5,
};

SavedPost _shortsPost(
  int id,
  Map<String, String> tags, {
  Board board = Board.danbooru,
  String uploader = '',
}) => SavedPost(
  board: board,
  post: MediaPost.fromMap({
    'id': id,
    'url': 'https://x/$id.mp4',
    'tags': tags.keys.join(' '),
    'tagDetails': [
      for (final MapEntry(:key, :value) in tags.entries)
        {'name': key, 'category': value},
    ],
    'uploader': uploader,
  }),
);

/// Never explores, and adds the same noise to every score.
class _FixedRandom implements Random {
  @override
  double nextDouble() => .99;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

/// Answers booruShorts streams by website and Shorts tag (the user's tag
/// that follows the video query); the first page only.
class _ShortsRepo implements BoardRepository {
  _ShortsRepo(this.results);
  final Map<(Board, String?), List<Map<String, dynamic>>> results;
  final Set<Board> failing = {};
  // Every page repeats the first page's posts.
  bool repeat = false;
  final List<
    ({Board board, List<String> tags, bool random, bool feed, int? seed})
  >
  calls = [];

  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  }) async {
    calls.add((
      board: board,
      tags: tags,
      random: random,
      feed: feed,
      seed: randomSeed,
    ));
    if (failing.contains(board)) throw StateError('offline');
    if (page > 0 && !repeat) return const [];
    final video = board.shortsVideoQuery ?? const [];
    final rest = tags.skip(video.length);
    final tag =
        rest.isEmpty || rest.first.contains(':') || rest.first.startsWith('-')
        ? null
        : rest.first;
    return results[(board, tag)] ?? const [];
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) async => const [];
}
