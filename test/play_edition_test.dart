import 'package:flutter_test/flutter_test.dart';
import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/core/models.dart';
import 'package:booruplus/ui/ads.dart';

import 'core_test.dart' show FakeRepo, MemoryStore;

MediaPost _post({
  String rating = 'g',
  List<String> tags = const ['a', 'b', 'c', 'd', 'e'],
}) => MediaPost(
  id: 1,
  url: 'https://x/1.png',
  previewUrl: 'https://x/1.png',
  tags: tags,
  rating: rating,
  uploader: '',
  source: '',
  width: 1,
  height: 1,
  score: 0,
  description: '',
  isVideo: false,
  extension: 'png',
);

Map<String, dynamic> _row(int id, {String rating = 'g', String? tags}) => {
  'id': id,
  'url': 'https://x/$id.png',
  'rating': rating,
  'tags': tags ?? 'cat dog tree sky cloud',
};

AppState _playState(
  FakeRepo repo, {
  ManualPremium? premium,
  MemoryStore? store,
}) => AppState(
  repository: repo,
  store: store ?? (MemoryStore()..selected = Board.safebooru),
  policy: ContentPolicy.play,
  premium: premium ?? ManualPremium(),
);

void main() {
  group('ContentPolicy.play', () {
    const policy = ContentPolicy.play;

    test('offers the Play websites only, some behind Premium', () {
      expect(policy.offers(Board.safebooru), isTrue);
      expect(policy.offers(Board.sankaku), isTrue);
      expect(policy.needsPremium(Board.safebooru), isFalse);
      expect(policy.needsPremium(Board.derpibooru), isTrue);
      expect(policy.needsPremium(Board.yandere), isTrue);
      for (final board in [
        Board.e621,
        Board.rule34,
        Board.xbooru,
        Board.nozomi,
        Board.realbooru,
      ]) {
        expect(policy.offers(board), isFalse, reason: board.name);
      }
      expect(ContentPolicy.full.offers(Board.e621), isTrue);
      expect(ContentPolicy.full.needsPremium(Board.derpibooru), isFalse);
    });

    test('allows signing in only where a website requires it', () {
      expect(policy.allowsSignIn(Board.gelbooru), Board.gelbooru.requiresAuth);
      expect(policy.allowsSignIn(Board.danbooru), isFalse);
      expect(ContentPolicy.full.allowsSignIn(Board.danbooru), isTrue);
    });

    test('blocks tags loosely, and real-person tags on Idol Complex', () {
      expect(policy.blocks('Completely Nude'), isTrue);
      expect(policy.blocks('nude_(artist)'), isTrue);
      expect(policy.blocks('cat'), isFalse);
      expect(policy.blocks('swimsuit'), isFalse);
      expect(policy.blocks('swimsuit', board: Board.idolcomplex), isTrue);
      expect(ContentPolicy.full.blocks('nude'), isFalse);
    });

    test('sanitizes searches but keeps excluded blocked tags', () {
      final result = policy.sanitize([
        'cat',
        'rating:explicit',
        '~nude',
        '{dog ~ nude}',
        'pus*',
        'ca*',
        '-nude',
        'status:deleted',
      ], board: Board.danbooru);
      expect(result.tags, ['cat', '-nude']);
      expect(result.removed, [
        'rating:explicit',
        '~nude',
        '{dog ~ nude}',
        'pus*',
        'ca*',
        'status:deleted',
      ]);
      expect(ContentPolicy.full.sanitize(['rating:explicit']).tags, [
        'rating:explicit',
      ]);
    });

    test('shows general, well-tagged, unblocked posts only', () {
      expect(policy.allowsPost(Board.safebooru, _post()), isTrue);
      expect(
        policy.allowsPost(Board.danbooru, _post(rating: 'sensitive')),
        isFalse,
      );
      expect(
        policy.allowsPost(Board.safebooru, _post(tags: ['a', 'b', 'c', 'd'])),
        isFalse,
      );
      expect(
        policy.allowsPost(
          Board.safebooru,
          _post(tags: ['a', 'b', 'c', 'd', 'nude']),
        ),
        isFalse,
      );
      expect(policy.allowsPost(Board.e621, _post()), isFalse);
      // E-Shuushuu has no ratings and tags lightly.
      expect(
        policy.allowsPost(
          Board.eshuushuu,
          _post(rating: '', tags: ['a', 'b', 'c']),
        ),
        isTrue,
      );
      expect(
        ContentPolicy.full.allowsPost(Board.e621, _post(rating: 'e')),
        isTrue,
      );
    });
  });

  group('Play edition app state', () {
    test(
      'searches with the forced rating and leaves out blocked terms',
      () async {
        final repo = FakeRepo([
          [
            _row(1),
            _row(2, rating: 'q'),
            _row(3, tags: 'cat dog tree sky nude'),
            _row(4, tags: 'cat dog'),
          ],
        ]);
        final state = _playState(repo);
        await state.initialize();
        await state.search(['cat', 'nude', 'rating:explicit']);
        expect(state.takeNotice(), contains('nude'));
        final sent = repo.queries.last;
        expect(sent, contains('cat'));
        expect(sent, isNot(contains('nude')));
        expect(sent, isNot(contains('rating:explicit')));
        expect(
          sent,
          contains(ContentPolicy.play.forcedRatingTag(Board.safebooru)),
        );
        expect(state.posts.map((post) => post.id), [1]);
      },
    );

    test('Premium websites open only with Premium', () async {
      final premium = ManualPremium();
      final state = _playState(FakeRepo(const [[]]), premium: premium);
      await state.initialize();
      expect(state.boardLocked(Board.yandere), isTrue);
      await state.chooseBoard(Board.yandere);
      expect(state.board, Board.safebooru);
      await state.chooseBoard(Board.e621);
      expect(state.board, Board.safebooru);

      premium.active = true;
      expect(state.boardLocked(Board.yandere), isFalse);
      await state.chooseBoard(Board.yandere);
      expect(state.board, Board.yandere);
      await state.chooseBoard(Board.e621);
      expect(state.board, Board.yandere);

      // Losing Premium leaves the Premium website.
      premium.active = false;
      await pumpEventQueue();
      expect(state.board, isNot(Board.yandere));
    });

    test('settings keep the edition rules and, without Premium, the free '
        'limits', () async {
      final premium = ManualPremium();
      final store = MemoryStore()
        ..selected = Board.safebooru
        ..settings = const AppSettings().copyWith(
          theme: ThemeChoice.amoled,
          classicDrawer: true,
          noShare: true,
          downloadConcurrency: 3,
          videoQuality: 0,
          safeMode: true,
          checkUpdates: true,
          selectedRatings: Rating.values,
          boardOrder: [Board.e926, ...const AppSettings().boardOrder],
        );
      final state = _playState(
        FakeRepo(const [[]]),
        premium: premium,
        store: store,
      );
      await state.initialize();
      var settings = state.settings;
      expect(settings.selectedRatings, [Rating.general]);
      expect(settings.safeMode, isFalse);
      expect(settings.checkUpdates, isFalse);
      expect(settings.shortsContent, ShortsContent.safeOnly);
      expect(settings.theme, ThemeChoice.standard);
      expect(settings.classicDrawer, isFalse);
      expect(settings.noShare, isFalse);
      expect(settings.downloadConcurrency, 1);
      expect(settings.videoQuality, 720);
      // Without Premium the websites keep the default order. (Settings
      // drop the websites the build's own edition leaves out.)
      expect(
        settings.boardOrder.where(ContentPolicy.play.offers).first,
        Board.safebooru,
      );

      // A change saved without Premium (before the store confirms it, say)
      // keeps the Premium choices on disk.
      await state.setIncognito(true);
      expect(store.settings.incognito, isTrue);
      expect(store.settings.theme, ThemeChoice.amoled);
      expect(store.settings.downloadConcurrency, 3);
      expect(store.settings.boardOrder.first, Board.e926);
      expect(state.settings.theme, ThemeChoice.standard);

      // Premium brings back what was chosen; the edition rules stay.
      premium.active = true;
      settings = state.settings;
      expect(settings.theme, ThemeChoice.amoled);
      expect(settings.classicDrawer, isTrue);
      expect(settings.noShare, isTrue);
      expect(settings.downloadConcurrency, 3);
      expect(settings.videoQuality, 0);
      expect(settings.boardOrder.first, Board.e926);
      expect(settings.selectedRatings, [Rating.general]);
      expect(settings.safeMode, isFalse);
    });

    test('backups restore only posts the edition allows', () async {
      final full = AppState(
        repository: FakeRepo(const [[]]),
        store: MemoryStore()..selected = Board.safebooru,
      );
      await full.initialize();
      await full.toggleFavorite(_post(), board: Board.safebooru);
      await full.toggleFavorite(_post(rating: 'e'), board: Board.e621);
      final backup = full.exportBackup();

      final state = _playState(FakeRepo(const [[]]));
      await state.initialize();
      final summary = await state.importBackup(backup);
      expect(summary.favorites, 1);
      expect(summary.skipped, 1);
      expect(state.favoritePosts.map((saved) => saved.board), [
        Board.safebooru,
      ]);
    });
  });

  group('AdLayout', () {
    test('places one ad after every few posts', () {
      const layout = AdLayout(3);
      // p p p A p p p A p
      expect(layout.slots(7), 9);
      // Never ending on an ad.
      expect(layout.slots(6), 7);
      expect(layout.slots(3), 3);
      expect(layout.slots(0), 0);
      expect(
        [for (var slot = 0; slot < 9; slot++) layout.isAd(slot)],
        [false, false, false, true, false, false, false, true, false],
      );
      expect(layout.adIndex(3), 0);
      expect(layout.adIndex(7), 1);
      expect(layout.postIndex(3), 3);
      for (var post = 0; post < 20; post++) {
        final slot = layout.slotOf(post);
        expect(layout.isAd(slot), isFalse);
        expect(layout.postIndex(slot), post);
      }
    });

    test('none keeps posts where they are', () {
      const layout = AdLayout.none;
      expect(layout.slots(5), 5);
      expect(layout.isAd(3), isFalse);
      expect(layout.postIndex(3), 3);
      expect(layout.slotOf(3), 3);
    });
  });
}
