// Audit probes: these PASS when the documented exposure is present.
// Synthetic data only; provider/platform requests are mocked.
import 'dart:convert';

import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:booruplus/main.dart';
import 'package:booruplus/ui/media_image.dart';
import 'package:booruplus/ui/media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/core_test.dart' show FakeRepo, MemoryStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('S1: locked app publishes saved search text to launcher', (
    tester,
  ) async {
    const channel = MethodChannel('booruplus/platform');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'authenticate' ? false : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore()
        ..selected = Board.safebooru
        ..settings = const AppSettings(
          appLock: true,
          secureScreen: true,
          boardSavedQueries: {
            Board.safebooru: [
              ['audit_private_interest'],
            ],
          },
        ),
    );
    await tester.pumpWidget(BooruPlusApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('BooruPlus is locked'), findsOneWidget);
    final published = calls.where((call) => call.method == 'setShortcuts');
    expect(published, isNotEmpty);
    expect(
      jsonEncode(published.last.arguments),
      contains('audit_private_interest'),
    );
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test('S2: incognito Shorts requests a previously learned interest', () async {
    final repo = FakeRepo(const [[]]);
    final state = AppState(repository: repo, store: MemoryStore());
    await state.initialize();
    state.learnShortsTag('audit_private_interest', amount: 3);
    await state.setIncognito(true);
    final feed = state.shortsFeed();
    await feed.start(tags: [], boards: [Board.e621]);
    expect(feed.interestTags, contains('audit_private_interest'));
    expect(
      repo.queries.any((q) => q.contains('audit_private_interest')),
      isTrue,
    );
    feed.dispose();
    state.dispose();
  });

  test('S3: imported backup preserves a local-network preview URL', () async {
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore(),
    );
    await state.initialize();
    const url = 'https://127.0.0.1:8443/audit-preview.jpg';
    await state.importBackup(
      jsonEncode({
        'format': AppState.backupFormat,
        'version': 1,
        'favorites': [
          {
            'board': 'safebooru',
            'post': {'id': 123, 'url': url, 'previewUrl': url},
          },
        ],
      }),
    );
    final saved = state.favoritePosts.single;
    expect(saved.post.previewUrl, url);
    expect(MediaImage.fetchesNatively(saved.board, url), isFalse);
    state.dispose();
  });

  test(
    'S4: sanitizer leaves credentials in secondary URLs and signed media',
    () {
      final saved = SavedPost(
        board: Board.gelbooru,
        post: MediaPost.fromMap({
          'id': 123,
          'url': 'https://gelbooru.com/123.jpg?api_key=SYNTHETIC&user_id=42',
          'postUrl': 'https://gelbooru.com/index.php?id=123&api_key=SYNTHETIC',
          'source': 'https://example.invalid/?api_key=SYNTHETIC',
          'videoVariants': [
            {'url': 'https://gelbooru.com/123.mp4?api_key=SYNTHETIC'},
          ],
        }),
      ).sanitized();
      expect(saved.post.url, isNot(contains('SYNTHETIC')));
      expect(jsonEncode(saved.toMap()), contains('SYNTHETIC'));
      expect(postBrowserUrl(saved.board, saved.post), contains('SYNTHETIC'));
      final signed = SavedPost(
        board: Board.sankaku,
        post: MediaPost.fromMap({
          'id': 'abc123',
          'url': 'https://s.sankakucomplex.com/123.jpg?token=SYNTHETIC&expires=9999999999',
        }),
      ).sanitized();
      expect(signed.post.url, contains('token=SYNTHETIC'));
    },
  );

  test(
    'S5: leaving incognito allows its existing feed to be persisted',
    () async {
      final posts = MemoryPostStore();
      final state = AppState(
        repository: FakeRepo([
          [
            {
              'id': 123,
              'url': 'https://example.invalid/123.jpg',
              'tags': ['audit_private_search'],
            },
          ],
        ]),
        store: MemoryStore()
          ..selected = Board.safebooru
          ..settings = const AppSettings(incognito: true, resumeFeed: true),
        postStore: posts,
      );
      await state.initialize();
      await state.search(['audit_private_search']);
      await state.persistFeed();
      expect(await posts.loadFeeds(), isEmpty);
      await state.setIncognito(false);
      await state.persistFeed();
      expect(
        jsonEncode(await posts.loadFeeds()),
        contains('audit_private_search'),
      );
      state.dispose();
    },
  );
}
