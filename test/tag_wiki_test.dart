import 'package:booruplus/core/models.dart';
import 'package:booruplus/core/services.dart';
import 'package:booruplus/ui/tag_wiki.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DText articles become headings, lists, and links', () {
    final blocks = parseDText(
      'For [[hair]] longer than the [[shoulders|shoulder line]].\r\n\r\n'
      'h4.See also\r\n'
      '* [[very long hair]]\r\n'
      '** [[iyowa (igusuri_please)|]] [b]bold[/b] plain\r\n'
      'Pixiv: https://www.pixiv.net/en/users/1 and "site":https://example.com',
    );
    expect(blocks.map((block) => block.text), [
      'For hair longer than the shoulder line.',
      'See also',
      'very long hair',
      'iyowa bold plain',
      'Pixiv: https://www.pixiv.net/en/users/1 and site',
    ]);
    expect(blocks[1].heading, isTrue);
    expect(blocks[2].indent, 1);
    expect(blocks[3].indent, 2);
    expect(blocks[0].spans[1].tag, 'hair');
    expect(blocks[0].spans[3].tag, 'shoulders');
    expect(blocks[2].spans.single.tag, 'very_long_hair');
    expect(blocks[3].spans.first.tag, 'iyowa_(igusuri_please)');
    expect(blocks[3].spans[2].bold, isTrue);
    expect(blocks[3].spans.last.bold, isFalse);
    expect(blocks[4].spans[1].url, 'https://www.pixiv.net/en/users/1');
    expect(blocks[4].spans.last.url, 'https://example.com');
  });

  test('tag wiki maps tolerate missing fields', () {
    final wiki = TagWiki.fromMap({
      'name': 'hatsune_miku',
      'category': 'character',
      'postCount': 5,
      'updatedAt': 1623894540000,
      'alias': 'miku_hatsune',
      'aliasOf': null,
    });
    expect(wiki.category, TagCategory.character);
    expect(wiki.body, isEmpty);
    expect(wiki.alias, 'miku_hatsune');
    expect(wiki.aliasOf, isNull);
    expect(wiki.updatedAt, DateTime.fromMillisecondsSinceEpoch(1623894540000));
  });

  test(
    'tag wiki channel call is board-scoped and null for unknown tags',
    () async {
      const channel = MethodChannel('booruplus/platform');
      final messenger =
          TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.arguments['tag'] == 'long_hair'
            ? {'name': 'long_hair', 'body': 'Hair.'}
            : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final device = DeviceService();
      final wiki = await device.tagWiki(board: Board.sankaku, tag: 'long_hair');
      expect(wiki?.body, 'Hair.');
      expect(
        await device.tagWiki(board: Board.idolcomplex, tag: 'missing'),
        isNull,
      );
      expect(calls.map((call) => call.method), ['tagWiki', 'tagWiki']);
      expect(calls.last.arguments, {'board': 'idolcomplex', 'tag': 'missing'});
    },
  );

  testWidgets('About tag shows the article and follows its links', (
    tester,
  ) async {
    final requested = <String>[];
    String? searched;
    Future<TagWiki?> load(Board board, String tag) async {
      requested.add(tag);
      return switch (tag) {
        'long_hair' => const TagWiki(
          name: 'long_hair',
          displayName: 'Long hair',
          japaneseName: 'ロングヘア',
          postCount: 18,
          body: 'Longer than [[medium hair]].',
        ),
        'medium_hair' => const TagWiki(name: 'medium_hair'),
        _ => null,
      };
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTagWiki(
              context,
              board: Board.sankaku,
              tag: 'long_hair',
              onSearch: (tag) => searched = tag,
              load: load,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Long hair'), findsOneWidget);
    expect(find.text('ロングヘア'), findsOneWidget);
    expect(find.textContaining('18 posts'), findsOneWidget);

    await tester.tapOnText(find.textRange.ofSubstring('medium hair'));
    await tester.pumpAndSettle();
    expect(requested, ['long_hair', 'medium_hair']);
    expect(find.text('This tag has no description yet.'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Long hair'), findsOneWidget);

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(searched, 'long_hair');
    expect(find.byKey(const ValueKey('tag_wiki_sheet')), findsNothing);
  });

  testWidgets('About tag reports an unknown tag', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TagWikiSheet(
            board: Board.idolcomplex,
            tag: 'nothing',
            onSearch: (_) {},
            load: (_, _) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Idol Complex has no tag named nothing.'), findsOneWidget);
  });
}
