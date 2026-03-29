import 'package:booruplus/core/app_state.dart';
import 'package:booruplus/main.dart';
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
      expect(
        find.text('A world of images.\nYour way to explore.'),
        findsOneWidget,
      );
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
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Explore Safebooru'), 350);
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
}
