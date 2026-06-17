import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';

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
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
  }) async {
    if (board != Board.sankaku ||
        tags.isEmpty ||
        !tags.first.startsWith('id:')) {
      return const [];
    }
    refreshQueries.add(tags);
    return [fresh];
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

  test('search and browse usage are counted independently', () async {
    final store = MemoryStore()..selected = Board.konachan;
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: store,
    );
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

  test('Konachan rating filters query and locally filter returned posts', () async {
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
  });

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

  test(
    'recent searches normalize, persist independently, and move to front',
    () async {
      final store = MemoryStore()
        ..selected = Board.safebooru
        ..settings = const AppSettings(
          savedQueries: [
            ['saved'],
          ],
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
    expect(state.displayReady(saved).post.url, fresh);
    expect(
      state.isFavorite(state.displayReady(saved).post, board: Board.sankaku),
      isTrue,
    );
  });

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
    expect(
      AppSettings.decode(store.settings.encode()).videoQuality,
      720,
    );
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
    final again = MediaService(
      channel: channel,
    ).fetchMedia(board: Board.gelbooru, url: a);
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
