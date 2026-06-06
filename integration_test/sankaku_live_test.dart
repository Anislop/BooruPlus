import 'dart:io';
import 'dart:ui' as ui;

import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Opt-in live check of the native Sankaku client: needs an Android device
/// and access to sankakuapi.com. Sankaku's API changes without notice (post
/// IDs switched from numbers to opaque strings), so this covers the parts
/// Dart fakes cannot: paging tokens, parsing, previews, and ID lookups.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final repository = PlatformBoardRepository();

  Future<List<MediaPost>> fetch(
    List<String> tags, {
    int page = 0,
    int limit = 30,
    bool random = false,
  }) async => (await repository.fetch(
    board: Board.sankaku,
    tags: tags,
    limit: limit,
    page: page,
    random: random,
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
      throwsA(isA<PlatformException>()),
    );
  });
}
