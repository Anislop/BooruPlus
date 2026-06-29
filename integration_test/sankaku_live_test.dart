import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:booruplus/ui/home.dart';
import 'package:booruplus/ui/media_image.dart';
import 'package:booruplus/ui/media_viewer.dart';
import 'package:booruplus/ui/theme.dart';
import 'package:flutter/foundation.dart'
    show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/core_test.dart' show MemoryStore;

/// Opt-in live check of the native Sankaku client: needs an Android device
/// and access to sankakuapi.com. Sankaku's API changes without notice (post
/// IDs switched from numbers to opaque strings), so this covers the parts
/// Dart fakes cannot: paging tokens, parsing, previews, and ID lookups.
///
/// Sign-in checks that need an account run only when one is supplied:
/// `--dart-define=SANKAKU_LOGIN=... --dart-define=SANKAKU_PASSWORD=...`.
/// The values are compiled into the test build, so use a disposable account
/// and never commit them.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final repository = PlatformBoardRepository();
  final accounts = PlatformAccountRepository();
  const login = String.fromEnvironment('SANKAKU_LOGIN');
  const password = String.fromEnvironment('SANKAKU_PASSWORD');

  Future<List<MediaPost>> fetch(
    List<String> tags, {
    int page = 0,
    int limit = 30,
    bool random = false,
    Credentials? credentials,
  }) async => (await repository.fetch(
    board: Board.sankaku,
    tags: tags,
    limit: limit,
    page: page,
    random: random,
    credentials: credentials,
  )).map(MediaPost.fromMap).toList();

  String key(MediaPost post) =>
      SavedPost(board: Board.sankaku, post: post).identity;

  testWidgets('Sankaku feed and viewer remain interactive during live loads', (
    tester,
  ) async {
    final state = AppState(
      repository: repository,
      store: MemoryStore()
        ..settings = const AppSettings(selectedRatings: [Rating.general]),
    );
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(board: Board.sankaku),
        home: HomeScreen(state: state),
      ),
    );
    final loading = state.chooseBoard(Board.sankaku);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.board, Board.sankaku);

    // Opening and closing navigation must work while the real native fetch
    // is in flight, and again while thumbnails/originals are decoding.
    Future<void> pumpUntil(bool Function() ready) async {
      // Wait only for the interaction: pumpAndSettle would also wait for
      // network loading spinners, and drawer springs can outlast 350ms.
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (ready()) return;
      }
      expect(
        ready(),
        isTrue,
        reason: 'UI interaction did not finish within 2s',
      );
    }

    Future<void> navigationResponds() async {
      final menu = find.byTooltip('Open navigation menu').hitTestable();
      await pumpUntil(() => menu.evaluate().length == 1);
      await tester.tap(menu);
      final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      await pumpUntil(() => scaffold.isDrawerOpen);
      scaffold.closeDrawer();
      await pumpUntil(() => menu.evaluate().length == 1);
      expect(scaffold.isDrawerOpen, isFalse);
    }

    await navigationResponds();
    await loading.timeout(const Duration(seconds: 60));
    expect(state.error, isNull);
    await state.search(['landscape']).timeout(const Duration(seconds: 60));
    expect(state.error, isNull);
    expect(state.posts, isNotEmpty);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await navigationResponds();

    final earlier = state.posts.map(key).toSet();
    final more = state.loadMore();
    await navigationResponds();
    await more.timeout(const Duration(seconds: 60));
    expect(state.error, isNull);
    expect(state.posts.length, greaterThan(earlier.length));
    expect(state.posts.map(key).toSet().length, state.posts.length);
    await tester.pump();

    await tester.tap(find.byType(MediaTile).first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(MediaViewer), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    final viewerContext = tester.element(find.byType(MediaViewer));
    Navigator.of(viewerContext).pop();
    await pumpUntil(() => find.byType(MediaViewer).evaluate().isEmpty);
    expect(find.byType(MediaViewer), findsNothing);
    await navigationResponds();
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('Sankaku pages, parses, and looks up posts by ID', (
    tester,
  ) async {
    final first = await fetch(const ['blue_eyes']);
    expect(first, isNotEmpty);
    expect(first.every((post) => post.hasId), isTrue);
    expect(first.map(key).toSet().length, first.length);
    for (final post in first) {
      expect(post.url, startsWith('https://'));
      expect(post.previewUrl, startsWith('https://'));
      expect(
        post.postUrl,
        'https://www.sankakucomplex.com/posts/${post.displayId}',
      );
      expect(RatingInfo.parse(post.rating), isNotNull);
    }
    expect(
      first
          .expand((post) => post.tagDetails)
          .any((tag) => tag.category != TagCategory.general),
      isTrue,
    );

    final second = await fetch(const ['blue_eyes'], page: 1);
    expect(second, isNotEmpty);
    expect(
      second.map(key).toSet().intersection(first.map(key).toSet()),
      isEmpty,
    );

    final ids = first.take(3).map((post) => post.displayId).join(',');
    final refreshed = await fetch(['id:$ids']);
    expect(refreshed.map(key).toSet(), first.take(3).map(key).toSet());

    expect(await fetch(const [], random: true), isNotEmpty);

    // The preview chosen for this API level (AVIF from API 31, a WebP/JPEG
    // sample below) must decode the way MediaImage loads it. AVIF goes
    // through fetchMedia, which must hand back a format the engine decodes
    // off the UI thread rather than AVIF itself.
    final previewUrl = first.first.previewUrl;
    late final Uint8List bytes;
    if (MediaImage.fetchesNatively(Board.sankaku, previewUrl)) {
      bytes = await MediaService().fetchMedia(
        board: Board.sankaku,
        url: previewUrl,
      );
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
    } else {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(previewUrl));
        final response = await request.close();
        expect(response.statusCode, 200);
        bytes = await consolidateHttpClientResponseBytes(response);
      } finally {
        client.close();
      }
    }
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, greaterThan(0));
  });

  testWidgets('Sankaku autocomplete and anonymous tag limit', (tester) async {
    final suggestions = (await repository.autocomplete(
      board: Board.sankaku,
      query: 'blue_e',
      limit: 10,
    )).map(TagSuggestion.fromMap).toList();
    final blueEyes = suggestions.where((tag) => tag.name == 'blue_eyes');
    expect(blueEyes, isNotEmpty);
    expect(blueEyes.first.category, TagCategory.general);
    expect(suggestions.every((tag) => (tag.postCount ?? 0) > 0), isTrue);

    await expectLater(
      fetch(const ['blue_eyes', 'long_hair', 'smile', 'dress', 'bow']),
      throwsA(isA<TagLimitException>().having((e) => e.limit, 'limit', 4)),
    );
  });

  testWidgets('Sankaku refuses bad sign-ins and stale tokens', (tester) async {
    await expectLater(
      accounts.signIn(
        board: Board.sankaku,
        login: 'booruplus-invalid-login-probe',
        password: 'not-a-password',
      ),
      throwsA(isA<SignInRejectedException>()),
    );
    await expectLater(
      accounts.refreshSignIn(
        board: Board.sankaku,
        credentials: const Credentials(
          userId: 'probe',
          apiKey: 'invalid',
          refreshToken: 'invalid',
        ),
      ),
      throwsA(isA<SignInRejectedException>()),
    );
    await expectLater(
      fetch(const [
        'blue_eyes',
      ], credentials: const Credentials(userId: 'probe', apiKey: 'invalid')),
      throwsA(isA<AuthExpiredException>()),
    );
  });

  testWidgets('Sankaku sign-in lifts the tag limit and renews', (tester) async {
    final session = await accounts.signIn(
      board: Board.sankaku,
      login: login,
      password: password,
    );
    expect(session.isValid, isTrue);
    expect(session.refreshToken, isNotEmpty);
    final tags = [
      'blue_eyes',
      'long_hair',
      'smile',
      'dress',
      'bow',
      '-twintails',
    ];
    expect(await fetch(tags, credentials: session), isNotEmpty);

    // Measure the signed-in limit with tags every post can satisfy.
    int? limit;
    final probe = ['blue_eyes'];
    while (limit == null && probe.length < 40) {
      probe.add('-booruplus_absent_tag_${probe.length}');
      try {
        await fetch(probe, limit: 1, credentials: session);
      } on TagLimitException catch (error) {
        limit = error.limit ?? probe.length - 1;
      }
    }
    debugPrint('Sankaku signed-in tag limit: ${limit ?? '40 or more'}');
    expect(limit ?? 40, greaterThan(4));

    final renewed = await accounts.refreshSignIn(
      board: Board.sankaku,
      credentials: session,
    );
    expect(renewed.isValid, isTrue);
    expect(await fetch(const ['blue_eyes'], credentials: renewed), isNotEmpty);
  }, skip: login.isEmpty || password.isEmpty);
}
