import 'dart:async';

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
  final List<List<String>> queries = [];
  Credentials? lastCredentials;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    Credentials? credentials,
  }) async {
    calls++;
    queries.add(tags);
    lastCredentials = credentials;
    return page < pages.length ? pages[page] : const [];
  }
}

Map<String, dynamic> post(int id, {List<String> tags = const []}) => {
  'id': id,
  'url': 'https://x/$id.jpg',
  'previewUrl': 'https://x/$id.jpg',
  'tags': tags,
};

void main() {
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

  test('media post serializes derived media fields', () {
    final value = MediaPost.fromMap(
      post(3, tags: ['cat'])..['url'] = 'https://x/a.webm',
    );
    expect(value.isVideo, isTrue);
    expect(value.extension, 'webm');
    expect(MediaPost.fromMap(value.toMap()).id, 3);
  });

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
    expect(repo.pages, [0, 0]);
    expect(state.posts.map((p) => p.id), [4]);
  });

  test('failed later load retries the same later page', () async {
    final repo = _FailLaterRepo();
    final store = MemoryStore()..selected = Board.safebooru;
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    await state.loadMore();
    expect(repo.pages, [0, 1]);
    await state.loadMore();
    expect(repo.pages, [0, 1, 1]);
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
    Credentials? credentials,
  }) {
    calls++;
    return calls == 1
        ? Future.value(const [])
        : calls == 2
        ? first.future
        : Future.value([post(2)]);
  }
}

class _FailingRepo implements BoardRepository {
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    Credentials? credentials,
  }) => Future.error(StateError('probe failed'));
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
    Credentials? credentials,
  }) {
    if (board == Board.safebooru && safeCalls++ > 0) return oldRequest.future;
    if (board == Board.danbooru) return Future.value([post(2)]);
    return Future.value(const []);
  }
}

class _FailingStore extends MemoryStore {
  @override
  Future<void> saveSettings(AppSettings value) =>
      Future.error(StateError('settings write failed'));
}

class _FailOnceRepo implements BoardRepository {
  final List<int> pages = [];
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    Credentials? credentials,
  }) {
    pages.add(page);
    return pages.length == 1
        ? Future.error(StateError('temporary'))
        : Future.value([post(4)]);
  }
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
}

class _FailingBoardStore extends MemoryStore {
  @override
  Future<void> saveBoard(Board? value) =>
      Future.error(StateError('board write failed'));
}
