import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    await Future.wait([inter.load(), noto.load(), materialIcons.load()]);
  });

  testWidgets('expanded library golden', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bridge = _LibraryBridge();
    await tester.pumpWidget(
      MaterialApp(
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

  testWidgets('library renders content, progress, filters, and opens a book', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    FlutterLibraryBook? opened;
    await tester.pumpWidget(
      MaterialApp(
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
    final bridge = _LibraryBridge(
      books: [
        _book(
          7,
          'Recently Read',
          cover: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
          lastRead: '2026-09-10T12:00:00Z',
        ),
        ...List.generate(60, (index) => _book(index + 8, 'Book $index')),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
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
  });

  testWidgets('library refresh waits for popped reader route disposal', (
    tester,
  ) async {
    final bridge = _LibraryBridge();
    final disposed = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
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
      MaterialApp(
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
      MaterialApp(
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
      MaterialApp(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, _, _, _, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('library is empty'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'missing');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No books match these filters.'), findsOneWidget);
  });

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
    controller.dispose();
    await bridge.disposed.future;
  });

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
      final controller = _libraryController(bridge);
      controller.dispatch(const LibraryImportRequested());
      await _waitUntil(() => bridge.importCalls == 1);

      controller.dispose();
      expect(bridge.isDisposed, isFalse);
      expect(bridge.cancelled, [BigInt.one]);
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

    expect(controller.model.error, 'This file type is not supported.');
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
      MaterialApp(
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
        child: MaterialApp(
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
            child: MaterialApp(
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
  });

  final List<FlutterLibraryBook> books;
  FlutterBookFormat? lastFormat;
  bool disposed = false;
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
  }) async => const FlutterReaderSettings(
    continuous: false,
    epubFontSize: 18,
    epubLineSpacing: 1.6,
    pdfZoom: 0,
  );

  @override
  Future<bool> removeLibraryBook({required int bookId}) async {
    removeCalls += 1;
    return true;
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
  _ControlledLibraryBridge({this.books = const []});

  final List<FlutterLibraryBook> books;
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
  Future<List<FlutterImportItem>> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) {
    importCalls += 1;
    importedPaths = pathKeys;
    importedManaged = managed;
    return importCompleter?.future ?? Future.value(const []);
  }

  @override
  Future<List<FlutterImportItem>> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  }) {
    importCalls += 1;
    importedDirectory = pathKey;
    importedManaged = managed;
    return importCompleter?.future ?? Future.value(const []);
  }

  @override
  Future<bool> removeLibraryBook({required int bookId}) async {
    removeCalls += 1;
    return true;
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
