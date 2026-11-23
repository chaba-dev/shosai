import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

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

  for (final dark in [false, true]) {
    testWidgets(
      'Add stays in details; only Read opens an identical existing book (dark: $dark)',
      (tester) async {
        const HarnessView(size: Size(390, 844)).apply(tester);
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final bridge = _AcquiringBridge(catalog);
        FlutterLibraryBook? opened;
        var changes = 0;
        final controller = BrowseController(
          bridge: bridge,
          openLink: (_) async {},
          openBook: (book) => opened = book,
          libraryChanged: () => changes++,
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
        controller.dispatch(const BrowseBookRequested('0'));
        await until(
          tester,
          () =>
              controller.model.details != null &&
              controller.model.saveOptions != null,
        );
        await tester.ensureVisible(find.text('Add to library'));
        await tester.pumpAndSettle();
        await capture(
          tester,
          'catalog-acquire-${dark ? 'dark' : 'light'}-ready',
        );
        await tester.tap(find.text('Add to library'));
        await until(tester, () => controller.model.acquisition.busy);
        await tester.ensureVisible(find.text('Cancel'));
        await tester.pump();
        await capture(
          tester,
          'catalog-acquire-${dark ? 'dark' : 'light'}-progress',
        );
        expect(opened, isNull);
        // Cancellation after publication must still report the committed book,
        // rather than pretend that a committed save was undone.
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        expect(controller.model.acquisition.cancelling, true);
        bridge.pending.complete((
          book: harnessLibraryBooks().first,
          existing: true,
        ));
        await until(tester, () => controller.model.acquisition.result != null);
        expect(find.text('Already in your library'), findsOneWidget);
        expect(opened, isNull);
        expect(changes, 1);
        await tester.ensureVisible(find.text('Read'));
        await tester.pumpAndSettle();
        await capture(
          tester,
          'catalog-acquire-${dark ? 'dark' : 'light'}-existing',
        );
        await tester.tap(find.text('Read'));
        await tester.pump();
        expect(opened?.bookId, harnessLibraryBooks().first.bookId);
        controller.dispatch(const BrowseEditionSelected(1));
        bridge.pending = Completer<CatalogAddedBook>();
        await tester.pump();
        await tester.ensureVisible(find.text('Add to library'));
        await tester.tap(find.text('Add to library'));
        await tester.pump();
        bridge.pending.completeError(
          const FlutterBridgeError(
            kind: FlutterBridgeErrorKind.invalidRequest,
            message: 'Book downloads require HTTPS.',
          ),
        );
        await until(tester, () => controller.model.acquisition.failed);
        expect(controller.model.acquisition.locationChanged, false);
        await tester.ensureVisible(find.text('Add to library'));
        await tester.pumpAndSettle();
        await capture(
          tester,
          'catalog-acquire-${dark ? 'dark' : 'light'}-failed',
        );
        // An old completion cannot replace the new book's acquisition state.
        bridge.pending = Completer<CatalogAddedBook>();
        controller.dispatch(const BrowseAddRequested());
        expect(controller.model.acquisition.busy, true);
        controller.dispatch(const BrowseBookRequested('1'));
        bridge.pending.complete((
          book: harnessLibraryBooks().first,
          existing: false,
        ));
        await until(
          tester,
          () => controller.model.details?.book.id == '1' && changes == 2,
        );
        expect(controller.model.acquisition.result, isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a changed destination reloads its label and requires a fresh choice before retry',
    (tester) async {
      const HarnessView(size: Size(1440, 900)).apply(tester);
      final semantics = tester.ensureSemantics();
      final addButtonSemantics = find.ancestor(
        of: find.text('Add to library'),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.button == true,
        ),
      );
      final bridge = _AcquiringBridge(catalog)
        ..options = (
          locations: [
            (
              id: 'drive',
              label: 'Google Drive · Original',
              generation: 1,
              directory: 'original',
            ),
          ],
          selected: 'drive',
        );
      final controller = BrowseController(
        bridge: bridge,
        openLink: (_) async {},
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        productionShell(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => ShellBrowsePage(
                layout: ShellLayout.desktop,
                model: controller.model,
                local: controller.local.model,
                dispatch: controller.dispatch,
                onChosen: (_) {},
              ),
            ),
          ),
        ),
      );
      controller.dispatch(const BrowseBookRequested('0'));
      await until(
        tester,
        () =>
            controller.model.details != null &&
            controller.model.saveOptions != null,
      );
      await tester.ensureVisible(find.text('Add to library'));
      await tester.tap(find.text('Add to library'));
      bridge.options = (
        locations: [
          (
            id: 'drive',
            label: 'Google Drive · Changed',
            generation: 1,
            directory: 'changed',
          ),
        ],
        selected: 'drive',
      );
      bridge.pending.completeError(const CatalogDestinationChanged());
      await until(
        tester,
        () =>
            controller.model.acquisition.locationChanged &&
            controller.model.saveOptions?.locations.single.directory ==
                'changed',
      );
      expect(find.text('Google Drive · Original'), findsNothing);
      expect(find.text('Google Drive · Changed'), findsOneWidget);
      expect(
        find.text(
          'The save location changed. Choose a save location again before adding.',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Add to library'));
      await tester.tapAt(tester.getCenter(find.text('Add to library')));
      await tester.pump();
      expect(controller.model.acquisition.busy, false);
      expect(
        tester.getSemantics(addButtonSemantics).flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      await capture(tester, 'catalog-review-location-changed');
      // Choosing another edition must not bypass the destination confirmation.
      await tester.ensureVisible(
        find.text('Project Gutenberg · Without images'),
      );
      await tester.tap(find.text('Project Gutenberg · Without images'));
      await tester.pump();
      expect(controller.model.acquisition.locationChanged, true);
      bridge.selectionFailure = StateError('preference write failed');
      await tester.ensureVisible(find.text('Google Drive · Changed'));
      await tester.tap(find.text('Google Drive · Changed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private library on this device').last);
      await tester.pumpAndSettle();
      await until(
        tester,
        () =>
            !controller.model.locationBusy &&
            controller.model.acquisition.failed,
      );
      bridge.pending = Completer<CatalogAddedBook>();
      await tester.ensureVisible(find.text('Add to library'));
      await tester.tapAt(tester.getCenter(find.text('Add to library')));
      await tester.pump();
      expect(controller.model.acquisition.locationChanged, true);
      expect(controller.model.acquisition.busy, false);
      expect(
        tester.getSemantics(addButtonSemantics).flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      bridge.selectionFailure = null;
      await tester.ensureVisible(find.text('Google Drive · Changed'));
      await tester.tap(find.text('Google Drive · Changed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Drive · Changed').last);
      await tester.pumpAndSettle();
      await until(
        tester,
        () =>
            !controller.model.acquisition.locationChanged &&
            !controller.model.locationBusy,
      );
      await tester.ensureVisible(find.text('Add to library'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(addButtonSemantics).flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      bridge.pending = Completer<CatalogAddedBook>();
      await tester.tap(find.text('Add to library'));
      await tester.pump();
      expect(controller.model.acquisition.busy, true);
      bridge.pending.complete((
        book: harnessLibraryBooks().first,
        existing: false,
      ));
      await until(tester, () => controller.model.acquisition.result != null);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );

  testWidgets(
    'Add refreshes personal matches; first Read works during shelf refresh and rail Search stays in the reader',
    (tester) async {
      const HarnessView(size: Size(1440, 900)).apply(tester);
      final bridge = _AcquiringBridge(catalog);
      await tester.pumpWidget(
        productionShell(
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, book, _, _, _, _, _, _, _, _) =>
                Scaffold(body: Center(child: Text('Reading ${book.title}'))),
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
        () => find
            .byKey(const ValueKey('browse-search-field'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('browse-search-field')),
        'Pride',
      );
      ShellBrowsePage page() => tester.widget(find.byType(ShellBrowsePage));
      await until(
        tester,
        () =>
            !page().model.busy &&
            !page().model.refreshing &&
            !page().local.busy &&
            page().model.books.length == 1,
      );
      expect(page().local.books, isEmpty);
      await tester.tap(find.text('Pride and Prejudice').first);
      await until(tester, () => page().model.saveOptions != null);
      await tester.ensureVisible(find.text('Add to library'));
      await tester.tap(find.text('Add to library'));
      const added = FlutterLibraryBook(
        bookId: 999,
        title: 'Pride and Prejudice',
        format: FlutterBookFormat.epub,
        pathKey: '/test/added.epub',
        managed: true,
        progress: 0,
        dateAdded: '2026-11-20',
      );
      bridge.books.add(added);
      bridge.shelfRefresh = Completer<void>();
      addTearDown(() {
        if (!bridge.shelfRefresh!.isCompleted) bridge.shelfRefresh!.complete();
      });
      bridge.pending.complete((book: added, existing: false));
      await until(
        tester,
        () => find.text('Read').evaluate().isNotEmpty && !page().local.busy,
      );
      expect(page().local.books.map((b) => b.bookId), [999]);
      expect(find.text('Reading Pride and Prejudice'), findsNothing);
      await tester.ensureVisible(find.text('Read'));
      await tester.pumpAndSettle();
      await capture(tester, 'catalog-review-added');
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
      expect(find.text('Reading Pride and Prejudice'), findsOneWidget);
      // The background shelf request is still held: no second Read tap needed.
      expect(bridge.shelfRefresh!.isCompleted, false);
      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();
      expect(find.byType(ShellSearchPalette), findsOneWidget);
      expect(find.text('Reading Pride and Prejudice'), findsOneWidget);
      expect(find.byType(ShellBrowsePage), findsNothing);
      await capture(tester, 'catalog-review-reader-search');
      bridge.shelfRefresh!.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

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

class _AcquiringBridge extends CatalogHarnessBridge {
  _AcquiringBridge(super.catalog) : super(books: [...harnessLibraryBooks()]);
  Completer<CatalogAddedBook> pending = Completer<CatalogAddedBook>();
  Completer<void>? shelfRefresh;
  CatalogSaveOptions? options;
  Object? selectionFailure;

  @override
  Future<void> selectCatalogSaveLocation(String? id) async {
    if (selectionFailure case final failure?) throw failure;
  }

  @override
  Future<CatalogSaveOptions> catalogSaveOptions() async =>
      options ?? await super.catalogSaveOptions();

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    FlutterLibrarySort sort = FlutterLibrarySort.recent,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async {
    if ((query ?? '').isEmpty) await shelfRefresh?.future;
    return super.libraryPage(
      query: query,
      format: format,
      sort: sort,
      limit: limit,
      offset: offset,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<CatalogAddedBook> addCatalogBook({
    required String bookId,
    required String sourceId,
    required String editionId,
    required String? locationId,
    required ({int generation, String? directory})? destination,
    required BigInt cancellationId,
    void Function(int, int?)? progress,
  }) {
    progress?.call(4096, 8192);
    return pending.future;
  }
}
