import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/shell/view.dart';

import '../support/catalog_fixture.dart';
import '../support/production_shell_harness.dart';

void main() {
  setUpAll(loadHarnessFonts);
  late Directory root;
  late CatalogClient catalog;
  setUp(() {
    root = Directory.systemTemp.createTempSync('shosai-browse-');
    catalog = createCatalogFixture(root);
  });
  tearDown(() async {
    await catalog.close();
    root.deleteSync(recursive: true);
  });

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 80 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
    expect(ready(), isTrue, reason: 'catalog state did not settle');
    expect(tester.takeException(), isNull);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (Platform.environment.containsKey(harnessArtifactDirVariable)) {
      writeHarnessArtifact(
        name,
        await captureHarnessPng(tester, pixelRatio: 2),
      );
    }
    expectOnlyKnownDefects(await findRenderDefects(tester), const []);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'Search navigation queries the local catalog and selects edition rights',
    (tester) async {
      const HarnessView(size: Size(1280, 900)).apply(tester);
      await tester.pumpWidget(
        productionShell(
          home: ProductShell(
            bridgeFactory: () => CatalogHarnessBridge(catalog),
            readerBuilder: (_, book, _, _, _, _, _, _, _, _) =>
                Text('Reading ${book.title}'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(ShellSidebar),
              matching: find.text('Search'),
            )
            .last,
      );
      await until(
        tester,
        () =>
            find.byType(ShellBrowsePage).evaluate().isNotEmpty &&
            !tester
                .widget<ShellBrowsePage>(find.byType(ShellBrowsePage))
                .model
                .busy &&
            !tester
                .widget<ShellBrowsePage>(find.byType(ShellBrowsePage))
                .model
                .refreshing,
      );
      expect(find.text('Browse by category'), findsOneWidget);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      tester.testTextInput.enterText('Pride');
      await until(
        tester,
        () =>
            tester
                .widget<ShellBrowsePage>(find.byType(ShellBrowsePage))
                .model
                .books
                .length ==
            1,
      );
      final page = tester.widget<ShellBrowsePage>(find.byType(ShellBrowsePage));
      expect(page.model.books.single.id, '0');
      expect(page.model.offline, isTrue);
      expect(find.text('Pride and Prejudice'), findsWidgets);
      await capture(tester, 'catalog-desktop-results');
      await tester.tap(find.text('Pride and Prejudice').first);
      await until(
        tester,
        () => find.text('Choose an edition').evaluate().isNotEmpty,
      );
      expect(
        find.text('Public domain in the USA. Check the law where you live.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Project Gutenberg · Without images'));
      await tester.pumpAndSettle();
      expect(
        find.text('Alternate edition rights — check the source.'),
        findsOneWidget,
      );
      expect(
        find.text('Public domain in the USA. Check the law where you live.'),
        findsNothing,
      );
      await capture(tester, 'catalog-desktop-details');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Choose an edition'), findsNothing);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.tap(find.text('Pride and Prejudice').first);
      await until(
        tester,
        () => find.text('Choose an edition').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Back to Search'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ShellBrowsePage>(find.byType(ShellBrowsePage))
            .model
            .criteria
            .query,
        'Pride',
      );
      expect(find.text('Pride and Prejudice'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'paging, authors, filters and superseded selections remain local',
    (tester) async {
      final links = <Uri>[];
      final controller = BrowseController(
        bridge: CatalogHarnessBridge(catalog),
        openLink: (uri) async => links.add(uri),
      );
      addTearDown(controller.dispose);
      controller.dispatch(const BrowseOpened());
      await until(
        tester,
        () => !controller.model.busy && !controller.model.refreshing,
      );
      expect(controller.model.books, hasLength(30));
      expect(controller.model.more, isTrue);
      controller.dispatch(const BrowseMoreRequested());
      await until(tester, () => !controller.model.busy);
      expect(controller.model.books, hasLength(37));
      expect(controller.model.books.map((b) => b.id).toSet(), hasLength(37));
      expect(controller.model.more, isFalse);
      controller.dispatch(
        const BrowseChanged((
          query: 'Austen',
          filter: BrowseFilter.authors,
          category: null,
          language: null,
          source: null,
          author: null,
        )),
      );
      await until(tester, () => !controller.model.busy);
      expect(controller.model.authors.single.books, 36);
      final austen = controller.model.authors.single;
      controller.dispatch(
        BrowseChanged((
          query: '',
          filter: BrowseFilter.freeBooks,
          category: 'fiction',
          language: 'ja',
          source: 'gutenberg',
          author: austen,
        )),
      );
      await until(tester, () => !controller.model.busy);
      expect(
        controller.model.books,
        isEmpty,
        reason: 'Japanese book belongs to a different author',
      );
      controller.dispatch(
        const BrowseChanged((
          query: 'Pride',
          filter: BrowseFilter.freeBooks,
          category: null,
          language: null,
          source: null,
          author: null,
        )),
      );
      controller.dispatch(
        const BrowseChanged((
          query: '猫',
          filter: BrowseFilter.freeBooks,
          category: null,
          language: null,
          source: null,
          author: null,
        )),
      );
      await until(tester, () => !controller.model.busy);
      expect(controller.model.books.single.id, '1');
      controller.dispatch(const BrowseBookRequested('0'));
      controller.dispatch(const BrowseBackRequested());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump();
      expect(controller.model.details, isNull);
      expect(controller.model.detailFailed, isFalse);
      controller.dispatch(const BrowseLinkRequested('file:///not-a-source'));
      controller.dispatch(
        const BrowseLinkRequested('https://www.gutenberg.org/ebooks/1342'),
      );
      await tester.pump();
      expect(links.map((u) => u.scheme), ['https']);
    },
  );

  testWidgets('personal title matches page without losing earlier results', (
    tester,
  ) async {
    final controller = BrowseController(
      bridge: CatalogHarnessBridge(
        catalog,
        books: [
          for (var i = 0; i < 37; i++)
            FlutterLibraryBook(
              bookId: i,
              title: 'Personal story $i',
              format: FlutterBookFormat.epub,
              pathKey: '/books/$i.epub',
              managed: true,
              progress: 0,
              dateAdded: '2026-11-21',
            ),
        ],
      ),
      openLink: (_) async {},
    );
    addTearDown(controller.dispose);
    controller.dispatch(
      const BrowseChanged((
        query: 'Personal',
        filter: BrowseFilter.yourBooks,
        category: null,
        language: null,
        source: null,
        author: null,
      )),
    );
    await until(tester, () => !controller.local.model.busy);
    expect(controller.local.model.books, hasLength(30));
    expect(controller.local.model.titlesMore, isTrue);
    controller.dispatch(const BrowseLocalMoreRequested());
    await until(tester, () => !controller.local.model.busy);
    expect(controller.local.model.books.map((b) => b.bookId).toList(), [
      for (var i = 0; i < 37; i++) i,
    ]);
    expect(controller.local.model.titlesMore, isFalse);
  });

  for (final corrupt in [false, true]) {
    testWidgets(
      'catalog ${corrupt ? 'read failure' : 'first use'} stays usable',
      (tester) async {
        const HarnessView(size: Size(430, 932)).apply(tester);
        final database = File('${root.path}/catalog.sqlite3');
        if (corrupt) {
          database.writeAsBytesSync([0]);
        } else {
          database.deleteSync();
        }
        final controller = BrowseController(
          bridge: CatalogHarnessBridge(catalog),
          openLink: (_) async {},
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          productionShell(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => ShellBrowsePage(
                  layout: ShellLayout.phone,
                  model: controller.model,
                  local: controller.local.model,
                  dispatch: controller.dispatch,
                  onChosen: (_) {},
                ),
              ),
            ),
          ),
        );
        controller.dispatch(const BrowseOpened());
        await tester.pump();
        await capture(tester, 'catalog-phone-updating');
        await until(
          tester,
          () => !controller.model.busy && !controller.model.refreshing,
        );
        expect(controller.model.failed, corrupt);
        expect(
          find.text(
            corrupt
                ? 'The catalog could not be read. Leave Search and try again.'
                : 'Connect to the internet to get the free-book catalog on this device.',
          ),
          findsOneWidget,
        );
        await capture(
          tester,
          'catalog-phone-${corrupt ? 'read-failure' : 'first-use'}',
        );
        await tester.enterText(
          find.byKey(const ValueKey('browse-search-field')),
          'Quiet',
        );
        await until(tester, () => !controller.local.model.busy);
        expect(find.text('The Quiet Cartographer'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final (name, size, dark, scale, locale) in [
    ('desktop', const Size(1280, 900), false, 1.0, const Locale('en')),
    ('desktop-dark', const Size(1280, 900), true, 1.0, const Locale('en')),
    ('tablet', const Size(834, 1112), false, 1.0, const Locale('en')),
    ('phone', const Size(430, 932), false, 1.0, const Locale('en')),
    ('phone-dark', const Size(430, 932), true, 1.0, const Locale('en')),
    ('phone-ja-large', const Size(430, 932), false, 2.0, const Locale('ja')),
  ]) {
    testWidgets('$name browse and detail render with real catalog data', (
      tester,
    ) async {
      HarnessView(size: size, textScale: scale).apply(tester);
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final controller = BrowseController(
        bridge: CatalogHarnessBridge(catalog),
        openLink: (_) async {},
      );
      addTearDown(controller.dispose);
      final layout = ShellLayout.forWidth(size.width);
      await tester.pumpWidget(
        productionShell(
          locale: locale,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => ShellFrame(
                layout: layout,
                model: const ShellModel(place: ShellPlace.search),
                covers: const {},
                actions: ShellActions(
                  selectPlace: (_) {},
                  openBook: (_) {},
                  closeBook: (_) {},
                  addBooks: null,
                  loadCover: (_) => false,
                ),
                child: ShellBrowsePage(
                  layout: layout,
                  model: controller.model,
                  local: controller.local.model,
                  dispatch: controller.dispatch,
                  onChosen: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      controller.dispatch(const BrowseOpened());
      await until(
        tester,
        () => !controller.model.busy && !controller.model.refreshing,
      );
      await capture(tester, 'catalog-$name-browse');
      controller.dispatch(
        const BrowseChanged((
          query: 'Pride',
          filter: BrowseFilter.freeBooks,
          category: null,
          language: null,
          source: null,
          author: null,
        )),
      );
      await until(tester, () => !controller.model.busy);
      await capture(tester, 'catalog-$name-results');
      await tester.tap(find.text('Pride and Prejudice').first);
      await until(tester, () => controller.model.details != null);
      await capture(tester, 'catalog-$name-book');
      // Reach the alternate edition through the actual scrollable surface,
      // including at large text where it falls below the initial viewport.
      final radio = find.text('Project Gutenberg · Without images');
      await tester.ensureVisible(radio);
      await tester.pumpAndSettle();
      await tester.tap(radio);
      await tester.pumpAndSettle();
      expect(controller.model.edition, 1);
      await capture(tester, 'catalog-$name-edition');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
