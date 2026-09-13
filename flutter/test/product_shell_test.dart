import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/android_document_import_adapter.dart';
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/product_shell.dart';
import 'package:shosai_flutter/src/rust/api.dart';

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')
      ..addFont(rootBundle.load('../assets/fonts/InterVariable.ttf'));
    final noto = FontLoader('Noto Sans JP')
      ..addFont(rootBundle.load('../assets/fonts/NotoSansJP-Variable.ttf'));
    final materialIcons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    final lucide = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(
        rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
      );
    await Future.wait([
      inter.load(),
      noto.load(),
      materialIcons.load(),
      lucide.load(),
    ]);
  });

  testWidgets('expanded library golden', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      _libraryApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff745b3e)),
          useMaterial3: true,
          fontFamily: 'Inter',
        ),
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(ProductShell),
      matchesGoldenFile('goldens/library-expanded.png'),
    );
    // Goldens are recorded on Linux; text rasterization differs on other
    // desktop platforms, so only assert pixels there.
  }, skip: !Platform.isLinux);

  testWidgets('deferred provider cleanup has a dedicated retry banner', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _LibraryBridge();
    final channel = _CleanupChannel([1, 0]);
    await tester.pumpWidget(
      _libraryApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff745b3e)),
          useMaterial3: true,
          fontFamily: 'Inter',
        ),
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          androidImport: AndroidDocumentImportAdapter(channel: channel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Temporary import data could not be removed yet.'),
      findsOneWidget,
    );
    expect(find.text('Retry cleanup'), findsOneWidget);
    if (Platform.isLinux) {
      await expectLater(
        find.byType(ProductShell),
        matchesGoldenFile('goldens/library-cleanup-pending.png'),
      );
    }

    await tester.tap(find.text('Retry cleanup'));
    await tester.pumpAndSettle();
    expect(find.text('Retry cleanup'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  test('stale cleanup results cannot overwrite a newer retry', () async {
    final bridge = _ControlledLibraryBridge();
    final cleanups = <Completer<bool>>[];
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
      retryProviderCleanup: () {
        final cleanup = Completer<bool>();
        cleanups.add(cleanup);
        return cleanup.future;
      },
    );
    controller.dispatch(const LibraryStarted());
    await _waitUntil(() => cleanups.length == 1);
    controller.dispatch(const LibraryCleanupRetryRequested());
    await _waitUntil(() => cleanups.length == 2);

    cleanups[1].complete(false);
    await Future<void>.delayed(Duration.zero);
    cleanups[0].complete(true);
    await Future<void>.delayed(Duration.zero);

    expect(controller.model.providerCleanupPending, isFalse);
    controller.dispose();
    await bridge.disposed.future;
  });

  test('library transitions preserve pending provider cleanup', () async {
    final bridge = _ControlledLibraryBridge(books: [_book(1, 'Initial book')]);
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
      retryProviderCleanup: () async => true,
    );
    controller.dispatch(const LibraryStarted());
    await _waitUntil(
      () => controller.model.loaded && controller.model.providerCleanupPending,
    );

    final refreshed = Completer<FlutterLibraryPage>();
    bridge.pages.add(refreshed);
    controller.dispatch(const LibraryQueryChanged('new query'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _waitUntil(() => bridge.queries.last == 'new query');
    refreshed.complete(
      FlutterLibraryPage(books: [_book(2, 'New result')], hasMore: false),
    );
    await _waitUntil(() => !controller.model.busy);

    expect(controller.model.providerCleanupPending, isTrue);
    expect(controller.model.books.single.title, 'New result');
    controller.dispose();
    await bridge.disposed.future;
  });

  test('successful mutations preserve managed deletion notice', () async {
    final bridge = _ControlledLibraryBridge(
      books: [_book(1, 'Book')],
      removalOutcome: const FlutterLibraryRemoveOutcome(
        removed: true,
        managedFileDeletionPending: true,
      ),
    );
    bridge.importReport = FlutterImportReport(
      imported: BigInt.one,
      failed: BigInt.zero,
      cancelled: false,
      items: const [],
    );
    final controller = _libraryController(bridge);
    controller.dispatch(const LibraryStarted());
    await _waitUntil(() => controller.model.loaded && !controller.model.busy);

    controller.dispatch(LibraryBookRemovalRequested(_book(1, 'Book')));
    await _waitUntil(() => bridge.removeCalls == 1 && !controller.model.busy);
    expect(controller.model.managedFileDeletionPending, isTrue);

    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => bridge.importCalls == 1 && !controller.model.busy);
    expect(controller.model.managedFileDeletionPending, isTrue);

    controller.dispose();
    await bridge.disposed.future;
  });

  testWidgets('library renders content, progress, filters, and opens a book', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    FlutterLibraryBook? opened;
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, book, _, _, _, _) {
            opened = book;
            return Scaffold(body: Text('Reading ${book.title}'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A Book'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('42% read'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);

    await tester.tap(find.text('PDF'));
    await tester.pumpAndSettle();
    expect(bridge.lastFormat, FlutterBookFormat.pdf);

    await tester.tap(find.text('A Book'));
    await tester.pumpAndSettle();
    expect(opened?.bookId, 7);
    expect(find.text('Reading A Book'), findsOneWidget);
  });

  testWidgets('library lazily renders bounded covers and recent activity', (
    tester,
  ) async {
    final cover = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final bridge = _LibraryBridge(
      covers: {7: cover},
      books: [
        _book(7, 'Recently Read', lastRead: '2026-09-10T12:00:00Z'),
        ...List.generate(60, (index) => _book(index + 8, 'Book $index')),
      ],
    );
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Continue reading'), findsOneWidget);
    expect(find.bySemanticsLabel('Cover of Recently Read'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Book 59'), findsNothing);
    expect(bridge.coverRequests, contains(7));

    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Cover of Recently Read'), findsOneWidget);
    expect(bridge.coverRequests.where((bookId) => bookId == 7), hasLength(1));
  });

  testWidgets('disposing library evicts its memory image keys', (tester) async {
    final cover = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final bridge = _LibraryBridge(
      covers: {7: cover},
      books: [_book(7, 'Covered')],
    );
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    final key = await image.image.obtainKey(ImageConfiguration.empty);
    final loaded = imageCache.statusForKey(key);
    expect(loaded.live || loaded.keepAlive, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    final status = imageCache.statusForKey(key);
    expect(status.pending, isFalse);
    expect(status.live, isFalse);
    expect(status.keepAlive, isFalse);
  });

  testWidgets('library retries failed covers only after explicit refresh', (
    tester,
  ) async {
    final bridge = _LibraryBridge(
      books: List.generate(10, (index) => _book(index, 'Book $index')),
    );
    final first = Completer<Uint8List?>();
    final covers = [first, ...List.generate(9, (_) => Completer<Uint8List?>())];
    bridge.coverCompleters.addAll(covers);
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(bridge.coverRequests.length, lessThanOrEqualTo(4));
    first.completeError(StateError('temporary failure'));
    await tester.pump();
    await tester.pump();
    expect(bridge.coverRequests.where((bookId) => bookId == 0), hasLength(1));
    for (final pending in covers) {
      if (!pending.isCompleted) pending.complete(null);
    }
    await tester.pumpAndSettle();

    expect(bridge.coverRequests.where((bookId) => bookId == 0), hasLength(1));
    await tester.tap(find.byTooltip('Refresh library'));
    await tester.pumpAndSettle();
    expect(bridge.coverRequests.where((bookId) => bookId == 0), hasLength(2));
  });

  test('library model retains only bounded cover bytes', () async {
    final evicted = <Uint8List>[];
    final bridge = _LibraryBridge(
      books: List.generate(20, (index) => _book(index, 'Book $index')),
      covers: {
        for (var index = 0; index < 20; index += 1)
          index: Uint8List(1024 * 1024),
      },
    );
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
      evictCover: evicted.add,
    );
    controller.dispatch(const LibraryStarted());
    await _waitUntil(() => controller.model.loaded);

    for (var index = 0; index < 20; index += 1) {
      controller.dispatch(LibraryCoverRequested(index));
      await _waitUntil(() => bridge.coverRequests.length == index + 1);
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      controller.model.covers.values.fold<int>(
        0,
        (total, bytes) => total + bytes.length,
      ),
      lessThanOrEqualTo(16 * 1024 * 1024),
    );
    expect(
      controller.model.books,
      everyElement(predicate<FlutterLibraryBook>((book) => book.cover == null)),
    );
    expect(evicted, hasLength(4));
    controller.dispose();
    expect(evicted, hasLength(20));
    expect(controller.model.covers, isEmpty);
  });

  testWidgets('mounted covers stop requesting after bounded eviction', (
    tester,
  ) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final covers = {
      for (var index = 0; index < 40; index += 1)
        index: Uint8List.fromList([
          ...png,
          ...List<int>.filled(512 * 1024 - png.length - 1, 0),
          index,
        ]),
    };
    final bridge = _LibraryBridge(
      books: List.generate(40, (index) => _book(index, 'Book $index')),
      covers: covers,
    );
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final completedDemand = bridge.coverRequests.length;
    expect(completedDemand, 40);

    for (var frame = 0; frame < 10; frame += 1) {
      await tester.pump();
    }
    expect(bridge.coverRequests, hasLength(completedDemand));
    final residentBytes = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<MemoryImage>()
        .map((image) => image.bytes)
        .toSet();
    final evicted = covers.values
        .where((bytes) => !residentBytes.contains(bytes))
        .toList();
    expect(evicted, hasLength(8));
    for (final bytes in evicted) {
      final key = await MemoryImage(bytes).obtainKey(ImageConfiguration.empty);
      final status = imageCache.statusForKey(key);
      expect(status.pending, isFalse);
      expect(status.live, isFalse);
      expect(status.keepAlive, isFalse);
    }
  });

  testWidgets('an evicted cover reloads after leaving and re-entering view', (
    tester,
  ) async {
    final png = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    final bridge = _LibraryBridge(
      books: List.generate(80, (index) => _book(index, 'Book $index')),
      covers: {for (var index = 0; index < 80; index += 1) index: png},
    );
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.coverRequests.where((bookId) => bookId == 0), hasLength(1));

    final grid = find.descendant(
      of: find.byType(GridView),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Book 79'),
      600,
      scrollable: grid,
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Book 0'),
      -600,
      scrollable: grid,
    );
    await tester.pumpAndSettle();

    expect(bridge.coverRequests.where((bookId) => bookId == 0), hasLength(2));
  });

  testWidgets('library refresh waits for popped reader route disposal', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    final disposed = Completer<void>();
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => _DisposeSignal(
            disposed: disposed,
            child: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Back'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A Book'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(disposed.isCompleted, isFalse);
    expect(bridge.pageCalls, 1);

    await tester.pumpAndSettle();
    expect(disposed.isCompleted, isTrue);
    expect(bridge.pageCalls, 2);
  });

  testWidgets('disposing navigator with an open reader drains library effect', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) =>
              const Scaffold(body: Text('Open reader')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A Book'));
    await tester.pumpAndSettle();
    expect(find.text('Open reader'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(bridge.disposed, isTrue);
  });

  testWidgets('restoration reopens the replacement reader locator', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      _libraryApp(
        restorationScopeId: 'app',
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, path, bookId, locatorChanged) => Scaffold(
            body: Column(
              children: [
                Text('locator:$path:$bookId'),
                TextButton(
                  onPressed: () => locatorChanged('/replacement.epub', null),
                  child: const Text('Replace'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A Book'));
    await tester.pumpAndSettle();
    expect(find.text('locator:/books/a.pdf:7'), findsOneWidget);

    await tester.tap(find.text('Replace'));
    await tester.pump();
    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.text('locator:/replacement.epub:null'), findsOneWidget);
  });

  testWidgets('library distinguishes empty and no-result states', (
    tester,
  ) async {
    final bridge = _LibraryBridge(books: const []);
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('library is empty'), findsOneWidget);

    await tester.enterText(find.byType(ShadInput), 'missing');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No books match these filters.'), findsOneWidget);
  });

  testWidgets('reader settings expose and persist complete product controls', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Reader settings'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Reader theme'), findsOneWidget);
    expect(find.text('Continuous reading'), findsOneWidget);
    expect(find.text('EPUB text size'), findsOneWidget);
    expect(find.text('EPUB line spacing'), findsOneWidget);
    expect(find.text('PDF zoom'), findsOneWidget);

    Future<void> settlePopover() async {
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.tap(find.text('Light'));
    await settlePopover();
    await tester.tap(find.text('Dark').last);
    await settlePopover();
    await tester.tap(find.text('Continuous reading'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await settlePopover();

    expect(bridge.savedSettings?.theme, 'dark');
    expect(bridge.savedSettings?.continuous, isTrue);
  });

  testWidgets('reader settings accept a persisted custom PDF zoom', (
    tester,
  ) async {
    final bridge = _LibraryBridge(
      settings: const FlutterReaderSettings(
        continuous: false,
        theme: 'light',
        epubFontSize: 18,
        epubLineSpacing: 1.6,
        pdfZoom: 2.75,
      ),
    );
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Reader settings'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('275% (custom)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader settings remain scrollable on a compact scaled viewport',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bridge = _LibraryBridge();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _libraryApp(
            home: ProductShell(
              bridgeFactory: () => bridge,
              readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reader settings'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  test('stale library loads cannot publish under a newer query', () async {
    final bridge = _ControlledLibraryBridge();
    final first = Completer<FlutterLibraryPage>();
    final second = Completer<FlutterLibraryPage>();
    bridge.pages.addAll([first, second]);
    final controller = _libraryController(bridge);
    controller.dispatch(const LibraryStarted());
    controller.dispatch(const LibraryQueryChanged('new'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    second.complete(
      FlutterLibraryPage(books: [_book(2, 'New')], hasMore: false),
    );
    await _waitUntil(() => controller.model.books.isNotEmpty);
    first.complete(
      FlutterLibraryPage(books: [_book(1, 'Old')], hasMore: false),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.model.books.single.title, 'New');
    controller.dispose();
    await bridge.disposed.future;
  });

  test('mutation completion refreshes the current query', () async {
    final bridge = _ControlledLibraryBridge();
    final importing = Completer<List<FlutterImportItem>>();
    bridge.importCompleter = importing;
    final controller = _libraryController(bridge);
    controller.dispatch(const LibraryStarted());
    await _waitUntil(() => !controller.model.busy);

    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => bridge.importCalls == 1);
    controller.dispatch(const LibraryQueryChanged('current'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    importing.complete(const [FlutterImportItem(pathKey: '/tmp/book.pdf')]);
    await _waitUntil(() => bridge.queries.length >= 3);

    expect(bridge.queries.sublist(1), everyElement('current'));
    expect(controller.canCancel, isFalse);
    controller.dispose();
    await bridge.disposed.future;
  });

  test(
    'partial import refreshes committed books while reporting failure',
    () async {
      final bridge = _ControlledLibraryBridge();
      final importing = Completer<List<FlutterImportItem>>();
      bridge.importCompleter = importing;
      final controller = _libraryController(bridge);
      controller.dispatch(const LibraryStarted());
      await _waitUntil(() => !controller.model.busy);

      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => bridge.importCalls == 1);
      importing.complete([
        FlutterImportItem(pathKey: '/tmp/good.pdf', book: _book(1, 'Good')),
        const FlutterImportItem(pathKey: '/tmp/bad.pdf', error: 'unsupported'),
      ]);
      await _waitUntil(() => bridge.queries.length == 2);

      expect(
        controller.model.error,
        'Imported 1 book. 1 failed. This file type is not supported.',
      );
      expect(controller.model.failure, LibraryFailure.import);
      controller.dispose();
      await bridge.disposed.future;
    },
  );

  test('import summary distinguishes metadata warning from failure', () async {
    final bridge = _ControlledLibraryBridge()
      ..importReport = FlutterImportReport(
        imported: BigInt.one,
        failed: BigInt.one,
        cancelled: false,
        items: const [
          FlutterImportItem(
            pathKey: '/tmp/imported.pdf',
            warning: 'metadata readback failed',
          ),
          FlutterImportItem(pathKey: '/tmp/bad.bin', error: 'unsupported'),
        ],
      );
    final controller = _libraryController(bridge);

    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => controller.model.error != null);

    expect(
      controller.model.error,
      'Imported 1 book. 1 failed. This file type is not supported. '
      'Some imported book details could not be loaded.',
    );
    controller.dispose();
    await bridge.disposed.future;
  });

  test('import summary preserves allowlisted provider errors', () async {
    final bridge = _ControlledLibraryBridge()
      ..importReport = FlutterImportReport(
        imported: BigInt.zero,
        failed: BigInt.one,
        cancelled: false,
        items: const [
          FlutterImportItem(
            pathKey: 'Document 1',
            error: 'provider_error:permissionDenied',
          ),
        ],
      );
    final controller = _libraryController(bridge);

    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => controller.model.error != null);

    expect(
      controller.model.error,
      '1 failed. Permission to read the selected document was denied.',
    );
    controller.dispose();
    await bridge.disposed.future;
  });

  test(
    'cancelling a pending picker invalidates its eventual selection',
    () async {
      final bridge = _ControlledLibraryBridge();
      final selection = Completer<LibraryImportSelection?>();
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () => selection.future,
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
      );
      controller.dispatch(const LibraryImportRequested());
      expect(controller.canCancel, isTrue);

      controller.dispatch(const LibraryOperationCancelled());
      selection.complete(
        const LibraryImportSelection(paths: ['/tmp/late.pdf'], managed: true),
      );
      await _waitUntil(() => !controller.model.busy);

      expect(bridge.importCalls, 0);
      expect(controller.canCancel, isFalse);
      controller.dispose();
      await bridge.disposed.future;
    },
  );

  test(
    'reviewed multi-file import preserves selection and storage choice',
    () async {
      final bridge = _ControlledLibraryBridge();
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => const LibraryImportSelection(
          paths: ['/books/one.pdf', '/books/two.epub'],
          managed: false,
        ),
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
      );
      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => !controller.model.busy);

      expect(bridge.importedPaths, ['/books/one.pdf', '/books/two.epub']);
      expect(bridge.importedManaged, isFalse);
      expect(bridge.importedDirectory, isNull);
      controller.dispose();
      await bridge.disposed.future;
    },
  );

  test('reviewed folder import uses recursive bridge operation', () async {
    final bridge = _ControlledLibraryBridge();
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => const LibraryImportSelection(
        paths: ['/books/folder'],
        managed: true,
        directory: true,
      ),
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
    );
    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => !controller.model.busy);

    expect(bridge.importedDirectory, '/books/folder');
    expect(bridge.importedManaged, isTrue);
    expect(bridge.importedPaths, isNull);
    controller.dispose();
    await bridge.disposed.future;
  });

  test(
    'cancelled folder import reports and refreshes committed books',
    () async {
      final bridge = _ControlledLibraryBridge();
      bridge.directoryImportCompleter = Completer<FlutterImportReport>();
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => const LibraryImportSelection(
          paths: ['/books/folder'],
          managed: true,
          directory: true,
        ),
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
      );
      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => bridge.importCalls == 1);

      bridge.directoryImportCompleter!.complete(
        FlutterImportReport(
          imported: BigInt.from(2),
          failed: BigInt.zero,
          cancelled: true,
          items: const [],
        ),
      );
      await _waitUntil(() => bridge.queries.isNotEmpty);

      expect(controller.model.error, 'Import cancelled. Imported 2 books.');
      expect(controller.model.failure, LibraryFailure.import);
      controller.dispose();
      await bridge.disposed.future;
    },
  );

  test('custom import runner preserves partial cancellation outcome', () async {
    final bridge = _ControlledLibraryBridge();
    var runnerCalls = 0;
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => LibraryImportSelection(
        paths: const ['First.pdf', 'Second.pdf'],
        managed: true,
        runner: (runnerBridge, cancellation) async {
          runnerCalls += 1;
          expect(runnerBridge, same(bridge));
          return FlutterImportReport(
            imported: BigInt.one,
            failed: BigInt.zero,
            cancelled: true,
            items: [
              FlutterImportItem(pathKey: 'First.pdf', book: _book(1, 'First')),
            ],
          );
        },
      ),
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
    );

    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => bridge.queries.isNotEmpty);

    expect(runnerCalls, 1);
    expect(bridge.importCalls, 0);
    expect(controller.model.error, 'Import cancelled. Imported 1 book.');
    controller.dispose();
    await bridge.disposed.future;
  });

  test(
    'selected-file import reports committed work before cancellation',
    () async {
      final bridge = _ControlledLibraryBridge()
        ..importReport = FlutterImportReport(
          imported: BigInt.one,
          failed: BigInt.one,
          cancelled: true,
          items: [
            FlutterImportItem(pathKey: '/first.pdf', book: _book(1, 'First')),
            const FlutterImportItem(
              pathKey: '/second.pdf',
              error: 'unsupported',
            ),
          ],
        );
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => const LibraryImportSelection(
          paths: ['/first.pdf', '/second.pdf'],
          managed: true,
        ),
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
      );

      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => bridge.queries.isNotEmpty);

      expect(
        controller.model.error,
        'Import cancelled. Imported 1 book. 1 failed. '
        'This file type is not supported.',
      );
      expect(bridge.importedPaths, ['/first.pdf', '/second.pdf']);
      controller.dispose();
      await bridge.disposed.future;
    },
  );

  test('active import can be cancelled from product progress', () async {
    final bridge = _ControlledLibraryBridge();
    bridge.importCompleter = Completer<List<FlutterImportItem>>();
    final controller = _libraryController(bridge);
    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => bridge.importCalls == 1);

    controller.dispatch(const LibraryOperationCancelled());

    expect(bridge.cancelled, [BigInt.one]);
    bridge.importCompleter!.completeError(
      const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.cancelled,
        message: 'cancelled',
      ),
    );
    await _waitUntil(() => !controller.model.busy);
    controller.dispose();
    await bridge.disposed.future;
  });

  test('reader close drains its book save queue before refreshing', () async {
    final books = [_book(7, 'A Book')];
    final bridge = _ControlledLibraryBridge(books: books);
    final saveDrain = Completer<void>();
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) => saveDrain.future,
      editSettings: (_) async => null,
    );
    controller.dispatch(const LibraryStarted());
    await _waitUntil(() => !controller.model.busy);

    controller.dispatch(LibraryBookOpened(books.single));
    await Future<void>.delayed(Duration.zero);
    books[0] = FlutterLibraryBook(
      bookId: 7,
      title: 'A Book',
      format: FlutterBookFormat.pdf,
      pathKey: '/books/7.pdf',
      managed: true,
      progress: 0.9,
      dateAdded: '2026-09-10',
    );
    expect(bridge.queries, hasLength(1));
    expect(controller.model.busy, isTrue);

    saveDrain.complete();
    await _waitUntil(
      () => bridge.queries.length == 2 && !controller.model.busy,
    );
    expect(controller.model.books.single.progress, 0.9);
    controller.dispose();
    await bridge.disposed.future;
  });

  test(
    'disposing during import cancels and drains before bridge disposal',
    () async {
      final bridge = _ControlledLibraryBridge();
      final importing = Completer<List<FlutterImportItem>>();
      bridge.importCompleter = importing;
      var adapterCancellations = 0;
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => const LibraryImportSelection(
          paths: ['/tmp/book.pdf'],
          managed: true,
        ),
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
        cancelImportAdapter: () => adapterCancellations += 1,
      );
      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => bridge.importCalls == 1);

      controller.dispose();
      expect(bridge.isDisposed, isFalse);
      expect(bridge.cancelled, [BigInt.one]);
      expect(adapterCancellations, 1);
      importing.completeError(StateError('cancelled'));
      await bridge.disposed.future;

      expect(bridge.released, [BigInt.one]);
      expect(bridge.events, ['cancel', 'release', 'dispose']);
    },
  );

  test('library paging appends instead of silently truncating', () async {
    final bridge = _ControlledLibraryBridge(
      books: List.generate(75, (index) => _book(index, 'Book $index')),
    );
    final controller = _libraryController(bridge);
    controller.dispatch(const LibraryStarted());
    await _waitUntil(() => !controller.model.busy);
    expect(controller.model.books, hasLength(50));
    expect(controller.model.hasMore, isTrue);

    controller.dispatch(const LibraryMoreRequested());
    await _waitUntil(() => !controller.model.busy);
    expect(controller.model.books, hasLength(75));
    expect(controller.model.hasMore, isFalse);
    expect(bridge.offsets, [0, 50]);
    controller.dispose();
    await bridge.disposed.future;
  });

  test(
    'failed replacement query cannot append the displayed collection',
    () async {
      final bridge = _ControlledLibraryBridge(
        books: List.generate(75, (index) => _book(index, 'Book $index')),
      );
      final controller = _libraryController(bridge);
      controller.dispatch(const LibraryStarted());
      await _waitUntil(() => !controller.model.busy);
      final failedQuery = Completer<FlutterLibraryPage>();
      bridge.pages.add(failedQuery);

      controller.dispatch(const LibraryQueryChanged('different'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      failedQuery.completeError(StateError('query failed'));
      await _waitUntil(() => !controller.model.busy);
      controller.dispatch(const LibraryMoreRequested());
      await Future<void>.delayed(Duration.zero);

      expect(bridge.queries, ['', 'different']);
      expect(bridge.offsets, [0, 0]);
      expect(controller.model.books, hasLength(50));
      controller.dispose();
      await bridge.disposed.future;
    },
  );

  test('successful background load does not clear a mutation error', () async {
    final bridge = _ControlledLibraryBridge();
    bridge.importCompleter = Completer<List<FlutterImportItem>>()
      ..complete(const [
        FlutterImportItem(pathKey: '/bad.pdf', error: 'unsupported'),
      ]);
    final controller = _libraryController(bridge);
    controller.dispatch(const LibraryImportRequested());
    await _waitUntil(() => !controller.model.busy);
    expect(controller.model.error, isNotNull);

    controller.dispatch(const LibraryRefreshed());
    await _waitUntil(() => !controller.model.busy);

    expect(
      controller.model.error,
      '1 failed. This file type is not supported.',
    );
    expect(controller.model.failure, LibraryFailure.import);
    controller.dispose();
    await bridge.disposed.future;
  });

  for (final adapter in ['picker', 'removal', 'settings']) {
    test(
      '$adapter affirmative completion after dispose makes no bridge writes',
      () async {
        final bridge = _ControlledLibraryBridge();
        final picker = Completer<LibraryImportSelection?>();
        final removal = Completer<bool>();
        final settings = Completer<FlutterReaderSettings?>();
        final controller = LibraryController(
          bridge: bridge,
          confirmRemoval: (_) => removal.future,
          pickImport: () => picker.future,
          openBook: (_) async {},
          drainReaderSaves: (_) async {},
          editSettings: (_) => settings.future,
        );
        controller.dispatch(const LibraryStarted());
        await _waitUntil(() => !controller.model.busy);
        switch (adapter) {
          case 'picker':
            controller.dispatch(const LibraryImportRequested());
          case 'removal':
            controller.dispatch(LibraryBookRemovalRequested(_book(1, 'Book')));
          case 'settings':
            controller.dispatch(const LibrarySettingsRequested());
        }
        await Future<void>.delayed(Duration.zero);
        controller.dispose();
        switch (adapter) {
          case 'picker':
            picker.complete(
              const LibraryImportSelection(paths: ['/book.pdf'], managed: true),
            );
          case 'removal':
            removal.complete(true);
          case 'settings':
            settings.complete(
              const FlutterReaderSettings(
                continuous: false,
                theme: 'light',
                epubFontSize: 20,
                epubLineSpacing: 1.6,
                pdfZoom: 0,
              ),
            );
        }
        await bridge.disposed.future;
        expect(bridge.importCalls, 0);
        expect(bridge.removeCalls, 0);
        expect(bridge.settingsWrites, 0);
      },
    );
  }

  testWidgets('managed removal requires confirmation', (tester) async {
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      _libraryApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove and delete copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete managed copy?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(bridge.removeCalls, 0);
  });

  testWidgets('managed deletion debt is disclosed without a retry action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _LibraryBridge(
      removalOutcome: const FlutterLibraryRemoveOutcome(
        removed: true,
        managedFileDeletionPending: true,
      ),
    );
    await tester.pumpWidget(
      _libraryApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff745b3e)),
          useMaterial3: true,
          fontFamily: 'Inter',
        ),
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Book actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove and delete copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Remove and delete'));
    await _waitUntil(() => bridge.removeCalls == 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Book removed. Its private copy will be deleted later.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
    expect(bridge.removeCalls, 1);
    if (Platform.isLinux) {
      await expectLater(
        find.byType(ProductShell),
        matchesGoldenFile('goldens/library-managed-deletion-pending.png'),
      );
    }

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(
      find.text('Book removed. Its private copy will be deleted later.'),
      findsNothing,
    );
    expect(bridge.removeCalls, 1);
  });

  testWidgets('compact Japanese library supports 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _LibraryBridge(books: [_book(7, '詳しい本', author: '紫式部')]);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: _libraryApp(
          theme: ThemeData(
            fontFamily: 'Inter',
            fontFamilyFallback: const ['Noto Sans JP'],
          ),
          home: ProductShell(
            bridgeFactory: () => bridge,
            readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('詳しい本'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(ProductShell),
      matchesGoldenFile('goldens/library-compact-large-text.png'),
    );
    // Goldens are recorded on Linux; text rasterization differs on other
    // desktop platforms, so only assert pixels there.
  }, skip: !Platform.isLinux);

  for (final width in [360.0, 800.0, 1280.0]) {
    testWidgets(
      'long multilingual metadata fits at 200 percent and $width px',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final bridge = _LibraryBridge(
          books: [
            _book(
              7,
              '非常に長い書名 — An exceptionally long title that needs two full lines',
              author: '紫式部 and an unusually long translated author attribution',
            ),
          ],
        );
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _libraryApp(
              home: ProductShell(
                bridgeFactory: () => bridge,
                readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

final class _CleanupChannel implements AndroidDocumentImportChannel {
  _CleanupChannel(Iterable<int> pending) : _pending = Queue.of(pending);

  final Queue<int> _pending;

  @override
  Future<Object?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (method == 'retryCleanup') {
      return <String, Object?>{'pending': _pending.removeFirst()};
    }
    return null;
  }
}

FlutterLibraryBook _book(
  int id,
  String title, {
  String? author,
  Uint8List? cover,
  String? lastRead,
}) => FlutterLibraryBook(
  bookId: id,
  title: title,
  author: author,
  format: FlutterBookFormat.pdf,
  pathKey: '/books/$id.pdf',
  managed: true,
  cover: cover,
  progress: 0.5,
  dateAdded: '2026-09-10',
  lastRead: lastRead,
);

LibraryController _libraryController(_ControlledLibraryBridge bridge) =>
    LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async =>
          const LibraryImportSelection(paths: ['/tmp/book.pdf'], managed: true),
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
    );

Future<void> _waitUntil(bool Function() predicate) async {
  while (!predicate()) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _LibraryBridge implements FlutterBridge {
  _LibraryBridge({
    this.books = const [
      FlutterLibraryBook(
        bookId: 7,
        title: 'A Book',
        author: 'Ada',
        format: FlutterBookFormat.pdf,
        pathKey: '/books/a.pdf',
        managed: true,
        progress: 0.42,
        dateAdded: '2026-09-10',
      ),
    ],
    this.settings = const FlutterReaderSettings(
      continuous: false,
      theme: 'light',
      epubFontSize: 18,
      epubLineSpacing: 1.6,
      pdfZoom: 0,
    ),
    this.covers = const {},
    this.removalOutcome = const FlutterLibraryRemoveOutcome(
      removed: true,
      managedFileDeletionPending: false,
    ),
  });

  final List<FlutterLibraryBook> books;
  final FlutterReaderSettings settings;
  final Map<int, Uint8List> covers;
  final FlutterLibraryRemoveOutcome removalOutcome;
  final List<int> coverRequests = [];
  final Queue<Completer<Uint8List?>> coverCompleters = Queue();
  FlutterBookFormat? lastFormat;
  bool disposed = false;
  FlutterReaderSettings? savedSettings;
  int removeCalls = 0;
  int pageCalls = 0;
  BigInt _nextCancellation = BigInt.one;

  @override
  bool get isDisposed => disposed;

  @override
  BigInt createCancellation() {
    final value = _nextCancellation;
    _nextCancellation += BigInt.one;
    return value;
  }

  @override
  bool releaseCancellation({required BigInt id}) => true;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async {
    pageCalls += 1;
    lastFormat = format;
    return FlutterLibraryPage(
      books: books
          .where(
            (book) =>
                (format == null || book.format == format) &&
                (query == null ||
                    query.isEmpty ||
                    book.title.toLowerCase().contains(query.toLowerCase())),
          )
          .toList(),
      hasMore: false,
    );
  }

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => settings;

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    coverRequests.add(bookId);
    if (coverCompleters.isNotEmpty) {
      return coverCompleters.removeFirst().future;
    }
    return covers[bookId];
  }

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) async {
    removeCalls += 1;
    return removalOutcome;
  }

  @override
  Future<void> saveReaderSettings({
    required FlutterReaderSettings value,
  }) async {
    savedSettings = value;
  }

  @override
  void dispose() => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DisposeSignal extends StatefulWidget {
  const _DisposeSignal({required this.disposed, required this.child});

  final Completer<void> disposed;
  final Widget child;

  @override
  State<_DisposeSignal> createState() => _DisposeSignalState();
}

class _DisposeSignalState extends State<_DisposeSignal> {
  @override
  void dispose() {
    widget.disposed.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ControlledLibraryBridge implements FlutterBridge {
  _ControlledLibraryBridge({
    this.books = const [],
    this.removalOutcome = const FlutterLibraryRemoveOutcome(
      removed: true,
      managedFileDeletionPending: false,
    ),
  });

  final List<FlutterLibraryBook> books;
  final FlutterLibraryRemoveOutcome removalOutcome;
  final Queue<Completer<FlutterLibraryPage>> pages = Queue();
  final List<String> queries = [];
  final List<int> offsets = [];
  final List<BigInt> cancelled = [];
  final List<BigInt> released = [];
  final List<String> events = [];
  List<String>? importedPaths;
  bool? importedManaged;
  String? importedDirectory;
  final Completer<void> disposed = Completer<void>();
  Completer<List<FlutterImportItem>>? importCompleter;
  FlutterImportReport? importReport;
  Completer<FlutterImportReport>? directoryImportCompleter;
  int importCalls = 0;
  int removeCalls = 0;
  int settingsWrites = 0;
  bool _disposed = false;
  BigInt _nextCancellation = BigInt.one;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async {
    queries.add(query ?? '');
    offsets.add(offset);
    if (pages.isNotEmpty) return pages.removeFirst().future;
    final filtered = books
        .where(
          (book) =>
              (query == null || query.isEmpty || book.title.contains(query)) &&
              (format == null || book.format == format),
        )
        .toList();
    final end = (offset + limit).clamp(0, filtered.length);
    return FlutterLibraryPage(
      books: filtered.sublist(offset.clamp(0, end), end),
      hasMore: end < filtered.length,
    );
  }

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => const FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.6,
    pdfZoom: 0,
  );

  @override
  BigInt createCancellation() {
    final value = _nextCancellation;
    _nextCancellation += BigInt.one;
    return value;
  }

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) async {
    importCalls += 1;
    importedPaths = pathKeys;
    importedManaged = managed;
    if (importReport case final report?) return report;
    final items =
        await (importCompleter?.future ??
            Future.value(const <FlutterImportItem>[]));
    return FlutterImportReport(
      imported: BigInt.from(items.where((item) => item.book != null).length),
      failed: BigInt.from(items.where((item) => item.error != null).length),
      cancelled: false,
      items: items,
    );
  }

  @override
  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  }) {
    importCalls += 1;
    importedDirectory = pathKey;
    importedManaged = managed;
    return directoryImportCompleter?.future ??
        Future.value(
          FlutterImportReport(
            imported: BigInt.zero,
            failed: BigInt.zero,
            cancelled: false,
            items: const [],
          ),
        );
  }

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) async {
    removeCalls += 1;
    return removalOutcome;
  }

  @override
  Future<bool> saveReaderSettings({
    required FlutterReaderSettings value,
  }) async {
    settingsWrites += 1;
    return true;
  }

  @override
  bool cancel({required BigInt id}) {
    cancelled.add(id);
    events.add('cancel');
    return true;
  }

  @override
  bool releaseCancellation({required BigInt id}) {
    released.add(id);
    events.add('release');
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    events.add('dispose');
    disposed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _libraryApp({
  ThemeData? theme,
  String? restorationScopeId,
  required Widget home,
}) => ShadTheme(
  data: shosaiShadTheme(Brightness.light),
  child: MaterialApp(
    theme: theme,
    restorationScopeId: restorationScopeId,
    home: home,
  ),
);
