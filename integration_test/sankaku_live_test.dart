import 'dart:io';
import 'dart:ui' as ui;

import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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

    // The engine must decode the preview format chosen for this API level
    // (AVIF from API 31, a WebP/JPEG sample below).
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(first.first.previewUrl));
      final response = await request.close();
      expect(response.statusCode, 200);
      final bytes = await consolidateHttpClientResponseBytes(response);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
    } finally {
      client.close();
    }
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
