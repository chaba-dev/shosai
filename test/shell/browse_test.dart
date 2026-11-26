import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction, Tristate, instantiateImageCodec;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/shell/catalog_artwork.dart';
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

  testWidgets('every registered category artwork is bundled and decodable', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final provenance =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/catalog/categories/sources.json',
                ),
              )
              as Map<String, dynamic>;
      final categories = provenance['categories'] as List<dynamic>;
      expect(catalogCategoryArtwork, {
        for (final dynamic row in categories)
          row['id'] as String: 'assets/catalog/categories/${row['image']}',
      });
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      expect(
        manifest.listAssets().where(
          (path) =>
              path.startsWith('assets/catalog/categories/') &&
              path.endsWith('.png'),
        ),
        unorderedEquals(
          categories.map(
            (dynamic row) => 'assets/catalog/categories/${row['image']}',
          ),
        ),
      );
      for (final dynamic row in categories) {
        final data = await rootBundle.load(
          'assets/catalog/categories/${row['image']}',
        );
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        expect(sha256.convert(bytes).toString(), row['sha256']);
        final codec = await instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(1));
        expect(frame.image.height, greaterThan(1));
        frame.image.dispose();
        codec.dispose();
      }
    });
  });

  testWidgets('book covers use the primary, then mirror, then text fallback', (
    tester,
  ) async {
    final primaryPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAABQAAAAeAQMAAAAW3KwoAAAAA1BMVEVNXob/23WGAAAADElEQVQI12NgGBgAAAB4AAHa7aJXAAAAAElFTkSuQmCC',
    );
    final mirrorPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAoAAAAPAQMAAADnMcxNAAAAA1BMVEVFfWV2YuCdAAAADElEQVQI12NgIAEAAAAtAAEU9N/ZAAAAAElFTkSuQmCC',
    );
    var primaryStatus = 200;
    var mirrorStatus = 200;
    var mirrorFinished = false;
    var id = 1342;
    final server = (await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        final primary =
            path == '/www.gutenberg.org/cache/epub/$id/pg$id.cover.medium.jpg';
        final mirror =
            path ==
            '/gutenberg.pglaf.org/cache/epub/$id/pg$id.cover.medium.jpg';
        request.response.statusCode =
            !(request.headers.value('User-Agent')?.contains(catalogUserAgent) ??
                false)
            ? 403
            : primary
            ? primaryStatus
            : mirror
            ? mirrorStatus
            : 404;
        if (request.response.statusCode == 200) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(primary ? primaryPng : mirrorPng);
        }
        await request.response.close();
        if (mirror) mirrorFinished = true;
      });
      return server;
    }))!;
    final client = _CoverHttpClient(server.port);
    debugNetworkImageHttpClientProvider = () => client;
    try {
      for (final scenario in [
        (primary: 200, mirror: 200, width: 20),
        (primary: 503, mirror: 200, width: 10),
        (primary: 503, mirror: 503, width: null),
      ]) {
        primaryStatus = scenario.primary;
        mirrorStatus = scenario.mirror;
        mirrorFinished = false;
        await tester.pumpWidget(
          productionShell(
            home: Scaffold(
              body: ShellBrowsePage(
                layout: ShellLayout.phone,
                model: BrowseModel(
                  criteria: (
                    query: 'Cover probe',
                    filter: BrowseFilter.freeBooks,
                    category: null,
                    language: null,
                    source: null,
                    author: null,
                  ),
                  books: [
                    (
                      id: 'gutenberg:$id',
                      title: 'Cover probe',
                      authors: const ['Author'],
                      sources: const ['Project Gutenberg'],
                      coverUrl:
                          'https://www.gutenberg.org/cache/epub/$id/pg$id.cover.medium.jpg',
                    ),
                  ],
                ),
                local: const ShellSearchModel(),
                dispatch: (_) {},
                onChosen: (_) {},
              ),
            ),
          ),
        );
        if (scenario.width case final width?) {
          await until(
            tester,
            () => tester
                .widgetList<RawImage>(find.byType(RawImage))
                .any((image) => image.image?.width == width),
          );
          expect(find.byType(ShellGeneratedCover), findsNothing);
        } else {
          await until(tester, () => mirrorFinished);
          expect(find.byType(ShellGeneratedCover), findsOneWidget);
          expect(
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .where((image) => image.image != null),
            isEmpty,
          );
        }
        await tester.pumpWidget(const SizedBox());
        id++;
      }
    } finally {
      debugNetworkImageHttpClientProvider = null;
      client.close(force: true);
      await tester.runAsync(() => server.close(force: true));
    }
  });

  testWidgets(
    'featured artwork keeps catalog identity and full accessible names',
    (tester) async {
      const HarnessView(size: Size(360, 932)).apply(tester);
      final semantics = tester.ensureSemantics();
      BrowseMessage? intent;
      await tester.pumpWidget(
        productionShell(
          home: Scaffold(
            body: ShellBrowsePage(
              layout: ShellLayout.phone,
              model: const BrowseModel(
                categories: [
                  (id: 'other', label: 'Another category', books: 9),
                  (
                    id: 'gutenberg:Crime, Thrillers and Mystery',
                    label: 'Crime, Thrillers and Mystery',
                    books: 23,
                  ),
                ],
              ),
              local: const ShellSearchModel(),
              dispatch: (message) => intent = message,
              onChosen: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Crime, Thrillers and Mystery, 23 books'),
        findsOneWidget,
      );
      expect(find.text('Classics of\nLiterature'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Crime &\nMystery')).dx,
        lessThan(tester.getTopLeft(find.text('Another category')).dx),
      );
      await tester.tap(find.text('Crime &\nMystery'));
      expect(
        (intent as BrowseChanged).criteria.category,
        'gutenberg:Crime, Thrillers and Mystery',
      );
      semantics.dispose();
    },
  );

  testWidgets('category cards stay equal-sized and remain actionable', (
    tester,
  ) async {
    const label = 'Research Methods/Statistics/Information Sys';
    final semantics = tester.ensureSemantics();
    for (final width in [360.0, 1280.0]) {
      for (final scale in [.85, 1.0, 2.0]) {
        HarnessView(size: Size(width, 900), textScale: scale).apply(tester);
        BrowseMessage? intent;
        await tester.pumpWidget(
          productionShell(
            home: Scaffold(
              body: ShellBrowsePage(
                layout: ShellLayout.forWidth(width),
                model: const BrowseModel(
                  categories: [
                    (id: 'research', label: label, books: 1),
                    (id: 'gutenberg:Poetry', label: 'Poetry', books: 1234),
                    (id: 'science', label: 'Science fiction', books: 19),
                    (id: 'history', label: 'History', books: 8),
                    (
                      id: 'gutenberg:Science-Fiction & Fantasy',
                      label: 'Science-Fiction & Fantasy',
                      books: 2419,
                    ),
                  ],
                ),
                local: const ShellSearchModel(),
                dispatch: (message) => intent = message,
                onChosen: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChoiceChip), findsNothing);
        final first = tester.getRect(
          find.byKey(
            const ValueKey(
              'catalog-category-gutenberg:Science-Fiction & Fantasy',
            ),
          ),
        );
        final second = tester.getRect(
          find.byKey(const ValueKey('catalog-category-gutenberg:Poetry')),
        );
        for (final id in [
          'research',
          'science',
          'history',
          'gutenberg:Science-Fiction & Fantasy',
        ]) {
          final size = tester.getSize(
            find.byKey(ValueKey('catalog-category-$id')),
          );
          expect(size.width, closeTo(first.width, .001));
          expect(size.height, closeTo(first.height, .001));
        }
        expect(first.height, greaterThanOrEqualTo(width == 360 ? 112 : 128));
        if (scale <= 1 || width == 1280) {
          expect(first.top, second.top);
          expect(first.right, lessThan(second.left));
        } else {
          expect(first.left, second.left);
          expect(first.bottom, lessThan(second.top));
        }
        expect(find.bySemanticsLabel('$label, 1 book'), findsOneWidget);
        expect(find.text('1,234 books'), findsOneWidget);
        await tester.ensureVisible(find.text(label));
        await capture(tester, 'catalog-long-category-$width-$scale');
        await tester.tap(find.text(label));
        expect((intent as BrowseChanged).criteria.category, 'research');
      }
    }
    semantics.dispose();
  });

  testWidgets('a colliding category name never borrows bundled artwork', (
    tester,
  ) async {
    const HarnessView(size: Size(360, 740)).apply(tester);
    await tester.pumpWidget(
      productionShell(
        home: Scaffold(
          body: ShellBrowsePage(
            layout: ShellLayout.phone,
            model: const BrowseModel(
              categories: [
                (
                  id: 'gutenberg:Science Fiction & Fantasy',
                  label: 'New category',
                  books: 1,
                ),
              ],
            ),
            local: const ShellSearchModel(),
            dispatch: (_) {},
            onChosen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(
      const ValueKey('catalog-category-gutenberg:Science Fiction & Fantasy'),
    );
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(Image)),
      findsNothing,
    );
    await capture(tester, 'catalog-unregistered-collision');
  });

  test(
    'early submissions merge persisted history and serialize saves',
    () async {
      final bridge = _DelayedHistoryBridge(catalog)
        ..recentSearches = ['Earlier', 'Oldest'];
      final controller = BrowseController(
        bridge: bridge,
        openLink: (_) async {},
      );
      controller.dispatch(const BrowseOpened());
      void submit(String query) {
        controller.dispatch(
          BrowseChanged((
            query: query,
            filter: BrowseFilter.all,
            category: null,
            language: null,
            source: null,
            author: null,
          )),
        );
        controller.dispatch(const BrowseSearchSubmitted());
      }

      submit('New');
      await Future<void>.delayed(Duration.zero);
      expect(bridge.recentSearches, ['Earlier', 'Oldest']);
      bridge.initialRead.complete(['Earlier', 'Oldest']);
      await bridge.writeStarted.future;
      expect(controller.model.recentSearches, ['New', 'Earlier', 'Oldest']);
      submit('Newest');
      await Future<void>.delayed(Duration.zero);
      // The second save must not overtake the held first save.
      expect(bridge.recentSearches, ['Earlier', 'Oldest']);
      bridge.firstWrite.complete();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.recentSearches, ['Newest', 'New', 'Earlier', 'Oldest']);
      final restarted = BrowseController(
        bridge: bridge,
        openLink: (_) async {},
      );
      restarted.dispatch(const BrowseOpened());
      await Future<void>.delayed(Duration.zero);
      expect(restarted.model.recentSearches, [
        'Newest',
        'New',
        'Earlier',
        'Oldest',
      ]);
      controller.dispose();
      restarted.dispose();
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'committed recent searches replay, deduplicate and survive a controller restart (dark: $dark)',
      (tester) async {
        const HarnessView(size: Size(430, 932)).apply(tester);
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final bridge = CatalogHarnessBridge(catalog);
        var controller = BrowseController(
          bridge: bridge,
          openLink: (_) async {},
        );
        Future<void> mount() async {
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
          await until(
            tester,
            () => !controller.model.busy && !controller.model.refreshing,
          );
        }

        await mount();
        expect(find.text('Recent searches'), findsNothing);
        expect(controller.model.categoryBooks['fiction']!.map((b) => b.id), [
          '0',
          '1',
        ]);
        final input = find.descendant(
          of: find.byKey(const ValueKey('browse-search-field')),
          matching: find.byType(EditableText),
        );
        await tester.enterText(input, 'Pride');
        await until(tester, () => !controller.model.busy);
        expect(find.byType(ChoiceChip), findsNWidgets(5));
        expect(
          controller.model.recentSearches,
          isEmpty,
          reason: 'Typing alone must not save unfinished queries',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(bridge.recentSearches, ['Pride']);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        controller = BrowseController(bridge: bridge, openLink: (_) async {});
        addTearDown(controller.dispose);
        await mount();
        expect(find.text('Recent searches'), findsOneWidget);
        await capture(tester, 'catalog-phone-${dark ? 'dark-' : ''}recents');
        await tester.tap(find.widgetWithText(ActionChip, 'Pride'));
        await until(tester, () => !controller.model.busy);
        expect(controller.model.criteria.query, 'Pride');
        expect(controller.model.books.single.title, 'Pride and Prejudice');
        await tester.tap(find.text('Pride and Prejudice').first);
        await until(tester, () => controller.model.details != null);
        expect(controller.model.recentSearches, ['Pride']);
        expect(bridge.recentSearches, ['Pride']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final (dark, layout, width, scale) in [
    for (final dark in [false, true]) ...[
      (dark, ShellLayout.phone, 390.0, 1.0),
      (dark, ShellLayout.tablet, 800.0, 1.0),
      (dark, ShellLayout.desktop, 1280.0, 1.0),
      (dark, ShellLayout.desktop, 1280.0, 2.0),
    ],
  ]) {
    testWidgets(
      'Add stays in details; only Read opens an identical existing book (dark: $dark, layout: $layout, scale: $scale)',
      (tester) async {
        HarnessView(size: Size(width, 900), textScale: scale).apply(tester);
        final name =
            '${layout.name}-${dark ? 'dark' : 'light'}${scale == 1 ? '' : '-large'}';
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
                  layout: layout,
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
        final cover = find.byType(ShellGeneratedCover).first;
        final picker = find.byKey(const ValueKey('catalog-edition-picker'));
        void expectCoverWidth(String label) {
          if (layout == ShellLayout.phone) return;
          final button = tester.getRect(find.widgetWithText(ShadButton, label));
          final coverRect = tester.getRect(cover);
          expect(button.left, closeTo(coverRect.left, 0.1));
          expect(button.width, closeTo(coverRect.width, 0.1));
        }

        final saveTo = tester.getRect(find.text('Save to'));
        if (layout == ShellLayout.phone) {
          expect(saveTo.top, greaterThan(tester.getRect(picker).bottom));
        } else {
          expect(saveTo.top, greaterThan(tester.getRect(cover).bottom));
          expect(saveTo.left, closeTo(tester.getRect(cover).left, 0.1));
          expect(
            tester.getRect(find.text('View at source')).left,
            greaterThan(tester.getRect(cover).right),
          );
        }
        await tester.ensureVisible(find.text('Add to library'));
        await tester.pumpAndSettle();
        expectCoverWidth('Add to library');
        await capture(tester, 'catalog-acquire-$name-ready');
        await tester.tap(find.text('Add to library'));
        await until(tester, () => controller.model.acquisition.busy);
        await tester.ensureVisible(picker);
        await tester.pumpAndSettle();
        expect(tester.getSemantics(picker).flagsCollection.isButton, true);
        expect(
          tester.getSemantics(picker).flagsCollection.isEnabled,
          Tristate.isFalse,
        );
        await tester.tap(picker);
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<int>), findsNothing);
        expect(controller.model.edition, 0);
        await capture(tester, 'catalog-acquire-$name-edition-disabled');
        await tester.ensureVisible(find.text('Cancel'));
        await tester.pump();
        expectCoverWidth('Cancel');
        await capture(tester, 'catalog-acquire-$name-progress');
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
        expectCoverWidth('Read');
        await capture(tester, 'catalog-acquire-$name-existing');
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
        expectCoverWidth('Add to library');
        await capture(tester, 'catalog-acquire-$name-failed');
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

  for (final dark in [false, true]) {
    for (final (width, scale) in [(600.0, 1.0), (800.0, 2.0), (1280.0, 1.0)]) {
      testWidgets(
        'source actions reflow within the frame (dark: $dark, width: $width, scale: $scale)',
        (tester) async {
          HarnessView(size: Size(width, 1000), textScale: scale).apply(tester);
          tester.platformDispatcher.platformBrightnessTestValue = dark
              ? Brightness.dark
              : Brightness.light;
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          final details = await tester.runAsync(() => catalog.book('0'));
          final messages = <BrowseMessage>[];
          final layout = ShellLayout.forWidth(width);
          await tester.pumpWidget(
            productionShell(
              home: Scaffold(
                body: ShellFrame(
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
                    model: BrowseModel(details: details),
                    local: const ShellSearchModel(),
                    dispatch: messages.add,
                    onChosen: (_) {},
                  ),
                ),
              ),
            ),
          );
          final picker = find.byKey(const ValueKey('catalog-edition-picker'));
          final page = tester.getRect(find.byType(ShellBrowsePage));
          final pickerBounds = tester.getRect(picker);
          expect(pickerBounds.right, closeTo(page.right - 32, 0.1));
          if (width == 600) {
            expect(pickerBounds.width, closeTo(page.width - 64, 0.1));
          }
          if (width == 1280) {
            final source = tester.getRect(
              find.widgetWithText(ShadButton, 'View at source'),
            );
            final support = tester.getRect(
              find.widgetWithText(ShadButton, 'Support Project Gutenberg'),
            );
            expect(support.top, closeTo(source.top, 0.1));
            expect(support.left, greaterThan(source.right));
          }
          for (final (name, label, url) in [
            ('source', 'View at source', details!.editions.first.sourceUrl),
            (
              'support',
              'Support Project Gutenberg',
              details.editions.first.supportUrl,
            ),
          ]) {
            final button = find.widgetWithText(ShadButton, label);
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            await capture(
              tester,
              'catalog-framed-${width.toInt()}-${dark ? 'dark' : 'light'}-$name',
            );
            final bounds = tester.getRect(button);
            expect(bounds.height, greaterThanOrEqualTo(44));
            expect(bounds.right, lessThanOrEqualTo(width));
            await tester.tap(button);
            expect((messages.last as BrowseLinkRequested).url, url);
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('sources without a donation URL have no support action', (
    tester,
  ) async {
    const HarnessView(size: Size(1280, 900)).apply(tester);
    final noDonations = createCatalogFixture(
      Directory('${root.path}/no-donations'),
      supportUrl: null,
    );
    addTearDown(noDonations.close);
    final details = await tester.runAsync(() => noDonations.book('0'));
    final messages = <BrowseMessage>[];
    await tester.pumpWidget(
      productionShell(
        home: Scaffold(
          body: ShellBrowsePage(
            layout: ShellLayout.desktop,
            model: BrowseModel(details: details),
            local: const ShellSearchModel(),
            dispatch: messages.add,
            onChosen: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('Support Project Gutenberg'), findsNothing);
    expect(find.text('Support this source'), findsNothing);
    await tester.tap(find.text('View at source'));
    expect(
      (messages.single as BrowseLinkRequested).url,
      details!.editions.first.sourceUrl,
    );
    await capture(tester, 'catalog-source-no-donations');
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    testWidgets(
      'catalog failures are announced in danger, not neutral statuses (dark: $dark)',
      (tester) async {
        const HarnessView(size: Size(800, 900)).apply(tester);
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final semantics = tester.ensureSemantics();
        final details = await tester.runAsync(() => catalog.book('0'));
        final options = await CatalogHarnessBridge(
          catalog,
        ).catalogSaveOptions();
        final book = BrowseModel(details: details, saveOptions: options);
        for (final (name, model, message, error) in [
          (
            'catalog',
            const BrowseModel(failed: true),
            'The catalog could not be read. Leave Search and try again.',
            true,
          ),
          (
            'details',
            const BrowseModel(detailFailed: true),
            'The catalog could not be read. Leave Search and try again.',
            true,
          ),
          (
            'link',
            book.copyWith(linkFailed: true),
            'The source could not be opened. Try again.',
            true,
          ),
          (
            'locations',
            book.copyWith(saveOptions: () => null),
            'Save locations could not be loaded.',
            true,
          ),
          (
            'changed',
            book.copyWith(
              acquisition: const BrowseAcquisition(
                failed: true,
                locationChanged: true,
              ),
            ),
            'The save location changed. Choose a save location again before adding.',
            true,
          ),
          (
            'add',
            book.copyWith(acquisition: const BrowseAcquisition(failed: true)),
            'The book could not be added. Check your connection and save location, then try again.',
            true,
          ),
          (
            'cancelled',
            book.copyWith(
              acquisition: const BrowseAcquisition(cancelled: true),
            ),
            'Download cancelled.',
            false,
          ),
          (
            'loading',
            book.copyWith(saveOptions: () => null, optionsBusy: true),
            'Loading save locations…',
            false,
          ),
          (
            'progress',
            book.copyWith(
              acquisition: const BrowseAcquisition(
                busy: true,
                received: 4096,
                total: 8192,
              ),
            ),
            'Downloading and adding…',
            false,
          ),
        ]) {
          await tester.pumpWidget(
            productionShell(
              home: Scaffold(
                body: ShellBrowsePage(
                  layout: ShellLayout.tablet,
                  model: model,
                  local: const ShellSearchModel(),
                  dispatch: (_) {},
                  onChosen: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final text = find.text(message);
          expect(text, findsOneWidget, reason: name);
          await tester.ensureVisible(text);
          await tester.pumpAndSettle();
          final danger = ShadTheme.of(
            tester.element(text),
          ).colorScheme.destructive;
          final style = DefaultTextStyle.of(
            tester.element(text),
          ).style.merge(tester.widget<Text>(text).style);
          expect(style.color, error ? danger : isNot(danger), reason: name);
          if (error) {
            expect(
              tester.getSemantics(text).flagsCollection.isLiveRegion,
              isTrue,
              reason: name,
            );
          }
          await capture(
            tester,
            'catalog-error-${dark ? 'dark' : 'light'}-$name',
          );
          await tester.pumpWidget(const SizedBox());
        }
        semantics.dispose();
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
        find.byKey(const ValueKey('catalog-edition-picker')),
      );
      await tester.tap(find.byKey(const ValueKey('catalog-edition-picker')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<int>,
          'Project Gutenberg · Without images',
        ),
      );
      await tester.pumpAndSettle();
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
      expect(find.text('Browse free books'), findsOneWidget);
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
      await until(tester, () => find.text('Edition').evaluate().isNotEmpty);
      expect(
        find.text('Public domain in the USA. Check the law where you live.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('catalog-edition-picker')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<int>,
          'Project Gutenberg · Without images',
        ),
      );
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
      expect(find.text('Edition'), findsNothing);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.tap(find.text('Pride and Prejudice').first);
      await until(tester, () => find.text('Edition').evaluate().isNotEmpty);
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

  for (final size in [const Size(1280, 900), const Size(360, 740)]) {
    testWidgets('edition picker dismisses before acting behind it at $size', (
      tester,
    ) async {
      HarnessView(size: size).apply(tester);
      final semantics = tester.ensureSemantics();
      final controller = BrowseController(
        bridge: CatalogHarnessBridge(catalog),
        openLink: (_) async {},
      );
      addTearDown(controller.dispose);
      var additions = 0;
      await tester.pumpWidget(
        productionShell(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => ShellFrame(
                layout: ShellLayout.forWidth(size.width),
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
                  layout: ShellLayout.forWidth(size.width),
                  model: controller.model,
                  local: controller.local.model,
                  dispatch: (message) {
                    if (message is BrowseAddRequested) additions++;
                    controller.dispatch(message);
                  },
                  onChosen: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      controller.dispatch(const BrowseBookRequested('0'));
      await until(tester, () => controller.model.saveOptions != null);
      final picker = find.byKey(const ValueKey('catalog-edition-picker'));
      await tester.ensureVisible(find.text('Add to library'));
      // The author shelf below lets Add scroll to the top; bring the picker
      // back so the menu opens over Add.
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      final option = find.widgetWithText(
        PopupMenuItem<int>,
        'Project Gutenberg · Without images',
      );
      expect(option, findsOneWidget);
      expect(find.semantics.byLabel('Add to library'), findsNothing);
      expect(find.semantics.byLabel('Library'), findsNothing);
      expect(
        tester.semantics
            .simulatedAccessibilityTraversal()
            .where(
              (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
            )
            .map((node) => node.label),
        unorderedEquals([
          'Project Gutenberg · With images\nEPUB · en · 123,456 bytes',
          'Project Gutenberg · Without images\nEPUB · en',
          'Dismiss menu',
        ]),
      );
      // Tap the lower edge of Add, outside the popup even when it overlaps
      // the top of the button. Dismissing must not start acquisition.
      final add = tester.getRect(
        find
            .ancestor(
              of: find.text('Add to library'),
              matching: find.byType(ShadButton),
            )
            .first,
      );
      final outside = Offset(add.center.dx, add.bottom - 1);
      final menu = tester.getRect(
        find
            .ancestor(of: option, matching: find.byType(SingleChildScrollView))
            .first,
      );
      expect(menu.contains(outside), false);
      await tester.tapAt(outside);
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(additions, 0);
      expect(controller.model.edition, 0);
      expect(controller.model.details, isNotNull);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(controller.model.details, isNotNull);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      final alternate = find.semantics.byLabel(RegExp('Without images'));
      tester.semantics.tap(alternate);
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(controller.model.edition, 1);
      expect(additions, 0);
      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        contains(isSemantics(label: 'Add to library')),
      );
      expect(find.semantics.byLabel('Library'), findsOne);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      tester.semantics.performAction(
        find.semantics.byLabel('Dismiss menu'),
        SemanticsAction.dismiss,
      );
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(controller.model.edition, 1);
      expect(controller.model.details, isNotNull);
      tester.semantics.tap(find.semantics.byLabel('Add to library'));
      await tester.pumpAndSettle();
      expect(additions, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(controller.model.details, isNull);
      semantics.dispose();
    });
  }

  for (final count in [1, 24]) {
    testWidgets(
      'edition dropdown supports $count choices without expanding details',
      (tester) async {
        HarnessView(
          size: count == 24 ? const Size(360, 740) : const Size(390, 844),
          textScale: count == 24 ? 2 : 1,
        ).apply(tester);
        final variants = createCatalogFixture(
          Directory('${root.path}/variants'),
          editionCount: count,
        );
        final controller = BrowseController(
          bridge: CatalogHarnessBridge(variants),
          openLink: (_) async {},
        );
        addTearDown(() async {
          controller.dispose();
          await variants.close();
        });
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
        await until(tester, () => controller.model.details != null);
        final picker = find.byKey(const ValueKey('catalog-edition-picker'));
        await tester.ensureVisible(picker);
        await tester.pumpAndSettle();
        final lastLabel = count == 1
            ? 'Project Gutenberg · With images'
            : 'Project Gutenberg · Additional variant $count';
        if (count > 1) expect(find.text(lastLabel), findsNothing);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(lastLabel).last,
          250,
          scrollable: find
              .descendant(
                of: find.byType(SingleChildScrollView),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        await tester.pumpAndSettle();
        await capture(tester, 'catalog-phone-$count-edition-menu');
        await tester.tap(find.widgetWithText(PopupMenuItem<int>, lastLabel));
        await tester.pumpAndSettle();
        expect(controller.model.edition, count - 1);
        expect(find.text(lastLabel), findsOneWidget);
        expect(
          find.text(
            count == 1
                ? 'Public domain in the USA. Check the law where you live.'
                : 'Alternate edition rights — check the source.',
          ),
          findsOneWidget,
        );
        if (count == 24) {
          await tester.tap(picker);
          await tester.pumpAndSettle();
          final selected = find.widgetWithText(PopupMenuItem<int>, lastLabel);
          final selectedRect = tester.getRect(selected);
          final menuRect = tester.getRect(
            find
                .ancestor(
                  of: selected,
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          );
          expect(selectedRect.top, greaterThanOrEqualTo(menuRect.top));
          expect(selectedRect.bottom, lessThanOrEqualTo(menuRect.bottom));
          expect(selected.hitTestable(), findsOneWidget);
          await capture(tester, 'catalog-phone-24-reopened-edition-menu');
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(controller.model.edition, 22);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final (name, size, dark, scale, locale) in [
    ('desktop', const Size(1280, 900), false, 1.0, const Locale('en')),
    ('desktop-dark', const Size(1280, 900), true, 1.0, const Locale('en')),
    ('desktop-large', const Size(1280, 900), false, 2.0, const Locale('en')),
    ('tablet', const Size(834, 1112), false, 1.0, const Locale('en')),
    ('tablet-wide', const Size(1180, 834), false, 1.0, const Locale('en')),
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
      // Two England headings collapse to one tag; the full heading is kept
      // for screen readers.
      expect(find.text('England'), findsOneWidget);
      expect(find.text('England -- Fiction'), findsNothing);
      expect(find.text('Love stories'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'England -- Fiction',
        ),
        findsOneWidget,
      );
      expect(find.text('Project Gutenberg · Without images'), findsNothing);
      final picker = find.byKey(const ValueKey('catalog-edition-picker'));
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      if (name == 'desktop') {
        for (var i = 0; i < 30; i++) {
          if (tester.getSemantics(picker).flagsCollection.isFocused ==
              Tristate.isTrue) {
            break;
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
        }
        expect(
          tester.getSemantics(picker).flagsCollection.isFocused,
          Tristate.isTrue,
        );
        await capture(tester, 'catalog-$name-edition-focus');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(picker);
      }
      await tester.pumpAndSettle();
      await capture(tester, 'catalog-$name-edition-menu');
      if (name.startsWith('desktop')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await capture(tester, 'catalog-$name-edition-option-focus');
        await tester.sendKeyEvent(
          name == 'desktop'
              ? LogicalKeyboardKey.space
              : LogicalKeyboardKey.enter,
        );
      } else {
        await tester.tap(
          find.widgetWithText(
            PopupMenuItem<int>,
            'Project Gutenberg · Without images',
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(controller.model.edition, 1);
      await capture(tester, 'catalog-$name-edition');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}

class _DelayedHistoryBridge extends CatalogHarnessBridge {
  _DelayedHistoryBridge(super.catalog);
  final initialRead = Completer<List<String>>();
  final firstWrite = Completer<void>();
  final writeStarted = Completer<void>();
  bool _read = false;
  @override
  Future<List<String>> recentCatalogSearches() {
    if (_read) return super.recentCatalogSearches();
    _read = true;
    return initialRead.future;
  }

  @override
  Future<void> saveRecentCatalogSearches(List<String> queries) async {
    if (!writeStarted.isCompleted) {
      writeStarted.complete();
      await firstWrite.future;
    }
    await super.saveRecentCatalogSearches(queries);
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

class _RealCoverHttp extends HttpOverrides {}

class _CoverHttpClient implements HttpClient {
  _CoverHttpClient(this.port);
  final int port;
  final HttpClient client = _RealCoverHttp().createHttpClient(null)
    ..autoUncompress = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) => client.getUrl(
    Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/${url.host}${url.path}',
    ),
  );

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
