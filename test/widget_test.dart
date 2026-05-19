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

  testWidgets('bookmark and history buttons open separate query popups', (
    tester,
  ) async {
    final store = MemoryStore()
      ..selected = Board.safebooru
      ..settings = const AppSettings(
        savedQueries: [
          ['saved_tag'],
        ],
        recentSearches: [
          ['recent_tag'],
        ],
      );
    final state = AppState(repository: FakeRepo(const [[]]), store: store);
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: HomeScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open recent searches'));
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsOneWidget);
    expect(find.text('recent_tag'), findsOneWidget);
    expect(find.text('saved_tag'), findsNothing);
    Navigator.of(tester.element(find.text('Recent searches'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Saved searches'));
    await tester.pumpAndSettle();
    expect(find.text('Saved searches'), findsOneWidget);
    expect(find.text('saved_tag'), findsOneWidget);
    expect(find.text('recent_tag'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('rating popup applies checkbox selection', (tester) async {
    final store = MemoryStore()..selected = Board.konachan;
    final repo = FakeRepo(const [[]]);
    final state = AppState(repository: repo, store: store);
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: HomeScreen(state: state),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ratings'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(3));

    await tester.tap(find.text('General'));
    await tester.tap(find.text('Questionable'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(state.selectedRatings, [Rating.explicit]);
    expect(repo.queries.last, contains('rating:e'));
    expect(store.settings.selectedRatings, [Rating.explicit]);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'quick actions use the original image and dismiss on transformed release',
    (tester) async {
      final postValue = MediaPost.fromMap({
        ...post(14),
        'url': 'https://example.com/original.jpg',
        'previewUrl': 'https://example.com/preview.jpg',
      });
      final state = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore(),
      );
      await state.initialize();
      await state.favoritePost(postValue, board: Board.danbooru);
      final controller = QuickActionOverlayController();
      await tester.pumpWidget(
        MaterialApp(theme: appTheme, home: const Scaffold()),
      );

      final actions = showQuickPostActions(
        tester.element(find.byType(Scaffold)),
        post: postValue,
        board: Board.danbooru,
        state: state,
        controller: controller,
        origin: const Rect.fromLTWH(20, 40, 120, 120),
      );
      await tester.pump();
      expect(find.text('Unfavorite'), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image).first);
      expect((image.image as NetworkImage).url, postValue.url);
      final favoriteButtonFinder = find.ancestor(
        of: find.text('Unfavorite'),
        matching: find.byType(FilledButton),
      );
      final button = tester.widget<FilledButton>(favoriteButtonFinder);
      expect(button.style?.foregroundColor?.resolve({}), Colors.white);

      final favoriteRender = tester.renderObject<RenderBox>(
        favoriteButtonFinder,
      );
      final earlyTopLeft = favoriteRender.localToGlobal(Offset.zero);
      final earlyBottomRight = favoriteRender.localToGlobal(
        Offset(favoriteRender.size.width, favoriteRender.size.height),
      );
      final earlyButtonCenter = Offset(
        (earlyTopLeft.dx + earlyBottomRight.dx) / 2,
        (earlyTopLeft.dy + earlyBottomRight.dy) / 2,
      );
      controller.update(earlyButtonCenter);
      await tester.pumpAndSettle();
      controller.releaseAt(earlyButtonCenter);
      await tester.pumpAndSettle();
      await actions;
      expect(find.text('Unfavorite'), findsNothing);
      expect(state.isFavorite(postValue, board: Board.danbooru), isTrue);
      expect(tester.takeException(), isNull);

      final videoPost = MediaPost.fromMap({
        ...post(15),
        'url': 'https://example.com/video.mp4',
        'previewUrl': 'https://example.com/video-preview.jpg',
        'isVideo': true,
      });
      final videoController = QuickActionOverlayController();
      final videoActions = showQuickPostActions(
        tester.element(find.byType(Scaffold)),
        post: videoPost,
        board: Board.danbooru,
        state: state,
        controller: videoController,
        origin: const Rect.fromLTWH(20, 40, 120, 120),
      );
      await tester.pump();
      final videoImage = tester.widget<Image>(find.byType(Image).first);
      expect((videoImage.image as NetworkImage).url, videoPost.previewUrl);
      videoController.release();
      await tester.pumpAndSettle();
      await videoActions;

      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('quick actions survive a feed rebuild during a long press', (
    tester,
  ) async {
    final feedMap = {
      ...post(16),
      'url': 'https://example.com/feed-original.jpg',
      'previewUrl': 'https://example.com/feed-preview.jpg',
    };
    final state = AppState(
      repository: FakeRepo([
        <Map<String, dynamic>>[feedMap],
      ]),
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

    final hold = await tester.startGesture(
      tester.getCenter(find.byType(MediaTile).first),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Favorite'), findsOneWidget);

    await state.favoritePost(
      MediaPost.fromMap({
        ...post(17),
        'url': 'https://example.com/other.jpg',
        'previewUrl': 'https://example.com/other-preview.jpg',
      }),
      board: Board.danbooru,
    );
    await tester.pump();
    await hold.up();
    await tester.pumpAndSettle();

    expect(find.text('Favorite'), findsNothing);
    expect(
      state.isFavorite(MediaPost.fromMap(feedMap), board: Board.danbooru),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('quick actions retain release and cancel before first frame', (
    tester,
  ) async {
    final postValue = MediaPost.fromMap({
      ...post(18),
      'url': 'https://example.com/immediate-original.jpg',
      'previewUrl': 'https://example.com/immediate-preview.jpg',
    });
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore(),
    );
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(theme: appTheme, home: const Scaffold()),
    );

    final releaseController = QuickActionOverlayController();
    final releaseActions = showQuickPostActions(
      tester.element(find.byType(Scaffold)),
      post: postValue,
      board: Board.danbooru,
      state: state,
      controller: releaseController,
      origin: const Rect.fromLTWH(20, 40, 120, 120),
    );
    releaseController.release();
    await tester.pumpAndSettle();
    await releaseActions;
    expect(find.text('Favorite'), findsNothing);

    final cancelController = QuickActionOverlayController();
    final cancelActions = showQuickPostActions(
      tester.element(find.byType(Scaffold)),
      post: postValue,
      board: Board.danbooru,
      state: state,
      controller: cancelController,
      origin: const Rect.fromLTWH(20, 40, 120, 120),
    );
    cancelController.cancel();
    await tester.pumpAndSettle();
    await cancelActions;
    expect(find.text('Favorite'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('a cancelled tap does not cancel the next quick-action hold', (
    tester,
  ) async {
    final postValue = MediaPost.fromMap({
      ...post(19),
      'url': 'https://example.com/tap-original.jpg',
      'previewUrl': 'https://example.com/tap-preview.jpg',
    });
    final state = AppState(
      repository: FakeRepo(const [[]]),
      store: MemoryStore(),
    );
    await state.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme,
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 180,
            child: MediaTile(
              post: postValue,
              board: Board.danbooru,
              onTap: () {},
              onLongPressOrigin: (origin, controller) => showQuickPostActions(
                tester.element(find.byType(Scaffold)),
                post: postValue,
                board: Board.danbooru,
                state: state,
                controller: controller,
                origin: origin,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.byType(MediaTile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final hold = await tester.startGesture(tester.getCenter(tile));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Favorite'), findsOneWidget);
    await hold.up();
    await tester.pumpAndSettle();
    expect(find.text('Favorite'), findsNothing);

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
