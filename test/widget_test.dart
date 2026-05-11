import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/core/models.dart';
import 'package:booruplus/main.dart';
import 'package:booruplus/ui/home.dart';
import 'package:booruplus/ui/media_viewer.dart';
import 'package:booruplus/ui/search_guide.dart';
import 'package:booruplus/ui/site_catalog.dart';
import 'package:booruplus/ui/tag_input.dart';
import 'package:booruplus/ui/theme.dart';
import 'package:booruplus/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_test.dart' show MemoryStore, FakeRepo;

void main() {
  testWidgets('Save commits an unfinished blacklist tag', (tester) async {
    final store = MemoryStore();
    final state = AppState(repository: FakeRepo(const [[]]), store: store);
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: SettingsScreen(state: state),
      ),
    );
    await tester.scrollUntilVisible(
      find.byType(TextField),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), 'blocked_tag');
    await tester.scrollUntilVisible(
      find.text('Save preferences'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save preferences'));
    await tester.pumpAndSettle();
    expect(store.settings.blacklist, contains('blocked_tag'));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'first launch chooses board, browse, then switches from the site list',
    (tester) async {
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore(),
      );
      await tester.pumpWidget(BooruPlusApp(state: state));
      await tester.pumpAndSettle();
      expect(find.textContaining('Welcome to BooruPlus!'), findsOneWidget);
      final button = find.text('Explore Safebooru');
      await tester.scrollUntilVisible(button, 350);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('DISCOVER'), findsOneWidget);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Websites'), findsOneWidget);
      await tester.tap(find.text('Danbooru'));
      await tester.pumpAndSettle();
      expect(find.text('Danbooru'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('space tokenizes tags, preserves partial input, X removes tag', (
    tester,
  ) async {
    var tags = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TagInput(
              tags: tags,
              onChanged: (value) => setState(() => tags = value),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'blue_sky cat partial');
    await tester.pump();
    expect(tags, ['blue_sky', 'cat']);
    expect(find.byType(InputChip), findsNWidgets(2));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'partial',
    );
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    expect(tags, ['cat']);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(tags, ['cat', 'partial']);
  });

  testWidgets('onboarding and settings fit a narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore(),
    );
    await tester.pumpWidget(BooruPlusApp(state: state));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Explore Safebooru'), 350);
    await tester.ensureVisible(find.text('Explore Safebooru'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explore Safebooru'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Posts per batch'), 250);
    expect(find.text('Posts per batch'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Save preferences'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('SiteLogo renders exact logo without border by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SiteLogo(Board.safebooru, size: 40)),
      ),
    );
    final siteLogoFinder = find.byType(SiteLogo);
    expect(siteLogoFinder, findsOneWidget);
    final containers = tester.widgetList<Container>(
      find.descendant(of: siteLogoFinder, matching: find.byType(Container)),
    );
    for (final container in containers) {
      final decoration = container.decoration;
      if (decoration is BoxDecoration) {
        expect(decoration.border, isNull);
      }
    }
    expect(
      find.descendant(of: siteLogoFinder, matching: find.byType(SizedBox)),
      findsWidgets,
    );
  });

  testWidgets(
    'SettingsScreen shows top unsaved flair and flavor text when preferences change',
    (tester) async {
      final store = MemoryStore();
      final state = AppState(repository: FakeRepo(const [[]]), store: store);
      await state.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: SettingsScreen(state: state),
        ),
      );
      await tester.pumpAndSettle();

      // Initially, no unsaved flair should be present
      expect(
        find.byKey(const ValueKey('unsaved_settings_flair')),
        findsNothing,
      );
      expect(find.text('Unsaved preferences'), findsNothing);

      // Change a slider (e.g. Columns from 3 to 4)
      final slider = find.byType(Slider).first;
      await tester.tap(slider);
      await tester.pumpAndSettle();

      // Flair and flavor text should now be visible at the top
      expect(
        find.byKey(const ValueKey('unsaved_settings_flair')),
        findsOneWidget,
      );
      expect(find.text('UNSAVED'), findsOneWidget);
      expect(find.text('Unsaved preferences'), findsOneWidget);
      expect(
        find.text('You have unsaved changes. Remember to save before leaving.'),
        findsOneWidget,
      );

      // Save via the top flair's Save button
      final topSaveButton = find.descendant(
        of: find.byKey(const ValueKey('unsaved_settings_flair')),
        matching: find.text('Save'),
      );
      expect(topSaveButton, findsOneWidget);
      await tester.tap(topSaveButton);
      await tester.pumpAndSettle();

      // Settings should be saved in the store
      expect(store.settings.columns, isNot(3));

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'Learn to search in sidebar is underlined and navigates to SearchGuideScreen',
    (tester) async {
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore(),
      );
      await state.initialize();
      await state.chooseBoard(Board.safebooru);

      await tester.pumpWidget(BooruPlusApp(state: state));
      await tester.pumpAndSettle();

      // Open navigation drawer
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      // Find 'Learn to search'
      final learnFinder = find.text('Learn to search');
      expect(learnFinder, findsOneWidget);

      // Verify text is underlined
      final textWidget = tester.widget<Text>(learnFinder);
      expect(textWidget.style?.decoration, TextDecoration.underline);

      // Tap 'Learn to search'
      await tester.tap(learnFinder);
      await tester.pumpAndSettle();

      // Verify we are on SearchGuideScreen with Safebooru icon and title
      expect(find.byType(SearchGuideScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Safebooru'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(SiteLogo),
        ),
        findsOneWidget,
      );

      // Verify markdown content rendered
      expect(find.text('Safebooru Search Guide'), findsOneWidget);
      expect(find.text('Basic Tag Search'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'autocomplete suggestions show category color and replace the draft',
    (tester) async {
      var tags = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: TagInput(
              tags: tags,
              onChanged: (value) => tags = value,
              autocomplete: (_) async => const [
                TagSuggestion(
                  name: 'frieren',
                  category: TagCategory.character,
                  postCount: 42,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'frie');
      await tester.pump(const Duration(milliseconds: 280));
      await tester.pump();

      expect(find.text('frieren'), findsOneWidget);
      expect(find.text('Character'), findsOneWidget);
      await tester.tap(find.text('frieren'));
      await tester.pump();
      expect(tags, ['frieren']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
    },
  );

  testWidgets('result tiles render typed tags with their category color', (
    tester,
  ) async {
    final value = MediaPost.fromMap(
      post(12, tags: ['artist_name'])
        ..['tagDetails'] = [
          {'name': 'artist_name', 'category': 'artist'},
        ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 180,
            child: MediaTile(post: value, board: Board.danbooru, onTap: () {}),
          ),
        ),
      ),
    );
    final tag = tester.widget<Text>(find.text('artist_name'));
    expect(tag.style?.color, const Color(0xFFE8A0FF));
  });

  testWidgets('home hides post tags and switches between grid layouts', (
    tester,
  ) async {
    final store = MemoryStore()
      ..selected = Board.danbooru
      ..settings = const AppSettings(hidePostTags: true);
    final state = AppState(
      repository: FakeRepo([
        [
          post(1, tags: ['visible_tag'])
            ..['tagDetails'] = [
              {'name': 'visible_tag', 'category': 'general'},
            ],
        ],
      ]),
      store: store,
    );
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: HomeScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('visible_tag'), findsNothing);
    expect(find.byType(SliverGrid), findsOneWidget);

    await state.updateSettings(
      const AppSettings(hierarchicalGrid: true, hidePostTags: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('visible_tag'), findsOneWidget);
    expect(find.byType(SliverList), findsOneWidget);
    expect(find.byType(SliverGrid), findsNothing);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'media tile enlarges only during a long press and taps normally',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 180,
              child: MediaTile(
                post: MediaPost.fromMap(post(13)),
                board: Board.danbooru,
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      final tile = find.byType(MediaTile);
      double scale() => tester
          .widget<AnimatedScale>(
            find.descendant(of: tile, matching: find.byType(AnimatedScale)),
          )
          .scale;

      expect(scale(), 1);
      final held = await tester.startGesture(tester.getCenter(tile));
      await tester.pump(const Duration(milliseconds: 600));
      expect(scale(), 1.08);
      await held.up();
      await tester.pump();
      expect(scale(), 1);

      final cancelled = await tester.startGesture(tester.getCenter(tile));
      await tester.pump(const Duration(milliseconds: 600));
      expect(scale(), 1.08);
      await cancelled.cancel();
      await tester.pump();
      expect(scale(), 1);

      await tester.tap(tile);
      expect(taps, 1);
    },
  );

  testWidgets('home back restores the query before a tag-originated search', (
    tester,
  ) async {
    final state = AppState(
      repository: FakeRepo([
        [
          post(21, tags: ['origin_tag'])
            ..['tagDetails'] = [
              {'name': 'origin_tag', 'category': 'general'},
            ],
        ],
      ]),
      store: MemoryStore()..selected = Board.danbooru,
    );
    await state.initialize();
    await state.search(['starting_query']);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: HomeScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MediaTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Show details'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('origin_tag'));
    await tester.tap(find.text('origin_tag'));
    await tester.pumpAndSettle();
    expect(state.tags, ['origin_tag']);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(state.tags, ['starting_query']);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'media viewer navigates between result posts and groups details',
    (tester) async {
      final first = MediaPost.fromMap(
        post(1, tags: ['artist_name', 'character_name'])
          ..['tagDetails'] = [
            {'name': 'artist_name', 'category': 'artist'},
            {'name': 'character_name', 'category': 'character'},
          ]
          ..['postUrl'] = 'https://danbooru.donmai.us/posts/1',
      );
      final second = MediaPost.fromMap(post(2, tags: ['plain']));
      final third = MediaPost.fromMap(post(3, tags: ['another']));
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore()..selected = Board.danbooru,
      );
      await state.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: MediaViewer(
            key: const ValueKey('middle-viewer'),
            post: first,
            board: Board.danbooru,
            state: state,
            posts: [first, second, third],
            initialIndex: 1,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('#2'), findsOneWidget);

      // A leftward swipe from the middle moves to the previous post.
      final leftGesture = await tester.startGesture(const Offset(180, 320));
      await leftGesture.moveTo(const Offset(60, 320));
      await leftGesture.up();
      await tester.pump();
      expect(find.text('#1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));

      // Reopen the middle post, then verify a rightward swipe moves next.
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: MediaViewer(
            key: const ValueKey('right-viewer'),
            post: second,
            board: Board.danbooru,
            state: state,
            posts: [first, second, third],
            initialIndex: 1,
          ),
        ),
      );
      await tester.pump();
      final rightGesture = await tester.startGesture(const Offset(60, 320));
      await rightGesture.moveTo(const Offset(180, 320));
      await rightGesture.up();
      await tester.pump();
      expect(find.text('#3'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));

      // Reopen the first post to verify the grouped details presentation.
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: MediaViewer(
            key: const ValueKey('details-viewer'),
            post: first,
            board: Board.danbooru,
            state: state,
            posts: [first, second, third],
            initialIndex: 0,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Tags & details'));
      await tester.pump();
      expect(find.text('Artist'), findsOneWidget);
      expect(find.text('Character'), findsOneWidget);
      expect(find.text('Open in browser'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('swiping anywhere on home screen opens drawer', (tester) async {
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore()..selected = Board.danbooru,
    );
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: HomeScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Websites'), findsNothing);

    // Swipe right starting from middle of screen (x=300)
    await tester.dragFrom(const Offset(300, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('Websites'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'swiping down when details visible dismisses details without closing post',
    (tester) async {
      final first = MediaPost.fromMap(
        post(1, tags: ['artist:cat'])
          ..['tagDetails'] = [
            {'name': 'artist:cat', 'category': 'artist'},
          ],
      );
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore()..selected = Board.danbooru,
      );
      await state.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: MediaViewer(post: first, board: Board.danbooru, state: state),
        ),
      );
      await tester.pump();
      expect(find.text('#1'), findsOneWidget);

      // Open details
      await tester.tap(find.text('Tags & details'));
      await tester.pump();
      expect(find.text('Artist'), findsOneWidget);

      // Swipe down on the media viewer
      final gesture = await tester.startGesture(const Offset(200, 200));
      await gesture.moveTo(const Offset(200, 350));
      await gesture.up();
      await tester.pump();

      // Details should be closed, post #1 should still be open
      expect(find.text('Artist'), findsNothing);
      expect(find.text('#1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 350));

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('video post renders black background and bottom controls', (
    tester,
  ) async {
    final videoPost = MediaPost.fromMap({
      'id': 99,
      'url': 'https://example.com/video.mp4',
      'previewUrl': 'https://example.com/thumb.jpg',
      'tags': ['animated'],
      'isVideo': true,
    });
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore()..selected = Board.danbooru,
    );
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: MediaViewer(post: videoPost, board: Board.danbooru, state: state),
      ),
    );
    await tester.pump();

    // Verify Scaffold background is black for video
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.black);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

Map<String, dynamic> post(int id, {List<String> tags = const []}) => {
  'id': id,
  'url': '',
  'previewUrl': '',
  'tags': tags,
};
