import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Opt-in live check: needs an Android device and access to safebooru.org.
/// Kept outside test/ so ordinary tests remain deterministic and offline.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native library fetches distinct safe posts and streams a download',
      (tester) async {
    final repository = PlatformBoardRepository();
    final first = await repository.fetch(
      board: Board.safebooru,
      tags: const ['rating:safe'],
      limit: 10,
      page: 0,
      random: false,
    );
    expect(first, isNotEmpty);
    final posts = first.map(MediaPost.fromMap).toList();
    expect(posts.map((post) => post.id).toSet().length, posts.length);
    expect(posts.every((post) => post.id > 0), isTrue);
    expect(posts.first.url, startsWith('https://'));
    expect(posts.first.previewUrl, startsWith('https://'));
    final next = await repository.fetch(
      board: Board.safebooru,
      tags: const ['rating:safe'],
      limit: 10,
      page: 1,
      random: false,
    );
    final nextIds = next.map(MediaPost.fromMap).map((post) => post.id).toSet();
    expect(nextIds.intersection(posts.map((post) => post.id).toSet()), isEmpty);
    // Download only a thumbnail into the disposable test emulator.
    final location = await DownloadService().download(
      url: posts.first.previewUrl,
      name: 'booruplus_smoke_thumbnail.jpg',
    );
    expect(location, startsWith('content://'));
    await expectLater(
      const MethodChannel('booruplus/platform').invokeMethod('download', {
        'url': 'http://example.com/insecure.jpg',
        'name': 'rejected.jpg',
      }),
      throwsA(isA<PlatformException>()),
    );
  });
}
