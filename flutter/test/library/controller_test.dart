import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

FlutterLibraryBook _book(int id, String title) => FlutterLibraryBook(
  bookId: id,
  title: title,
  format: FlutterBookFormat.pdf,
  pathKey: '/books/$id.pdf',
  managed: false,
  progress: 0,
  dateAdded: '2026-09-10',
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _StubLibraryBridge implements FlutterBridge {
  final pages = <Completer<FlutterLibraryPage>>[];
  final queries = <String?>[];
  final formats = <FlutterBookFormat?>[];
  var disposeCount = 0;
  var removeCalls = 0;
  bool failCancellationCreation = false;
  var _nextCancellation = BigInt.one;

  @override
  bool get isDisposed => disposeCount != 0;

  @override
  void dispose() => disposeCount += 1;

  @override
  BigInt createCancellation() {
    if (failCancellationCreation) {
      throw StateError('the bridge cannot create a cancellation');
    }
    _nextCancellation += BigInt.one;
    return _nextCancellation;
  }

  @override
  bool cancel({required BigInt id}) => true;

  @override
  bool releaseCancellation({required BigInt id}) => true;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) {
    queries.add(query);
    formats.add(format);
    final completer = Completer<FlutterLibraryPage>();
    pages.add(completer);
    return completer.future;
  }

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) async {
    removeCalls += 1;
    return const FlutterLibraryRemoveOutcome(
      removed: true,
      managedFileDeletionPending: false,
    );
  }

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => const FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.5,
    pdfZoom: 0,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LibraryController _controller(_StubLibraryBridge bridge) => LibraryController(
  bridge: bridge,
  confirmRemoval: (_) async => true,
  pickImport: () async => null,
  openBook: (_) async {},
  drainReaderSaves: (_) async {},
  editSettings: (_) async => null,
);

/// A controller that records whether a model notification arrived while a
/// dispatch was running.
///
/// Package 3B requires asynchronous results to report back as typed messages
/// and the message handler to own the transition, so the removal-pending state
/// must be published from inside `dispatch`.
class _ObservingController extends LibraryController {
  _ObservingController({
    required super.bridge,
    required super.confirmRemoval,
    required super.pickImport,
    required super.openBook,
    required super.drainReaderSaves,
    required super.editSettings,
  });

  bool inDispatch = false;
  final List<int?> removingBookIds = <int?>[];

  @override
  void dispatch(LibraryMessage message) {
    inDispatch = true;
    try {
      super.dispatch(message);
    } finally {
      inDispatch = false;
    }
  }
}

void main() {
  test('a completed page publishes books and reader settings', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();
    expect(bridge.pages, hasLength(1));
    expect(controller.model.busy, isTrue);

    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();

    expect(controller.model.loaded, isTrue);
    expect(controller.model.books.single.title, 'A Book');
    expect(controller.model.hasMore, isTrue);
    expect(controller.model.settings, isNotNull);
    expect(controller.model.busy, isFalse);

    controller.dispose();
    await _settle();
  });

  test('a stale page cannot replace a newer query result', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();

    controller.dispatch(const LibraryQueryChanged('new'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _settle();
    expect(bridge.pages, hasLength(2));

    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'New')], hasMore: false),
    );
    await _settle();
    bridge.pages.first.complete(
      FlutterLibraryPage(books: [_book(1, 'Old')], hasMore: false),
    );
    await _settle();

    expect(controller.model.books.single.title, 'New');
    expect(controller.model.query, 'new');

    controller.dispose();
    await _settle();
  });

  test('changing the format filter reloads with that format', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: false),
    );
    await _settle();

    controller.dispatch(const LibraryFormatChanged(FlutterBookFormat.epub));
    await _settle();

    expect(bridge.formats.last, FlutterBookFormat.epub);
    expect(controller.model.format, FlutterBookFormat.epub);

    controller.dispose();
    await _settle();
  });

  test('the removal-pending transition is published from dispatch', () async {
    final bridge = _HeldRemovalBridge();
    final controller = _ObservingController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
    );
    controller.addListener(() {
      if (controller.inDispatch) {
        controller.removingBookIds.add(controller.model.removingBookId);
      }
    });

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(3, 'A Book')], hasMore: false),
    );
    await _settle();

    controller.dispatch(LibraryBookRemovalRequested(_book(3, 'A Book')));
    await _settle();
    await _settle();

    expect(
      controller.removingBookIds,
      contains(3),
      reason:
          'the confirmed removal reports back as a typed message and the '
          'handler publishes the pending book, so no continuation writes model '
          'state',
    );
    expect(controller.model.removingBookId, 3);

    // The held removal keeps the pending state until it completes.
    expect(bridge.removeCalls, 1);
    controller.dispose();
    await _settle();
  });

  test('a first-page load publishes the collection loading state', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();

    // The skeleton owns page one: the model says so before the page lands, and
    // the collection can pick its shape from the immutable state.
    expect(controller.model.loading, isTrue);
    expect(controller.model.loadingMore, isFalse);
    expect(controller.model.collectionState, LibraryCollectionState.loading);

    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();

    expect(controller.model.loading, isFalse);
    expect(controller.model.loadingMore, isFalse);
    expect(controller.model.collectionState, LibraryCollectionState.ready);

    controller.dispose();
    await _settle();
  });

  test('an appended page keeps the grid instead of the skeleton', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();

    controller.dispatch(const LibraryMoreRequested());
    await _settle();

    expect(controller.model.loading, isTrue);
    expect(controller.model.loadingMore, isTrue);
    expect(
      controller.model.collectionState,
      LibraryCollectionState.ready,
      reason: 'a later page keeps the loaded grid, as the reference does',
    );

    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Another Book')], hasMore: false),
    );
    await _settle();

    expect(controller.model.loading, isFalse);
    expect(controller.model.loadingMore, isFalse);
    expect(controller.model.books.map((book) => book.bookId), [1, 2]);

    controller.dispose();
    await _settle();
  });

  test('a load that cannot start still ends the skeleton', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();
    expect(bridge.pages, hasLength(1));
    expect(controller.model.loading, isTrue);

    // The replacement load cannot even create its cancellation, so nothing is
    // left in flight to end the skeleton it replaced.
    bridge.failCancellationCreation = true;
    controller.dispatch(const LibraryFormatChanged(FlutterBookFormat.epub));
    await _settle();

    expect(controller.model.loading, isFalse);
    expect(controller.model.loadingMore, isFalse);
    expect(controller.model.loadError, isNotNull);

    // The superseded page is stale: it cannot replace the collection or revive
    // the skeleton.
    bridge.pages.first.complete(
      FlutterLibraryPage(books: [_book(1, 'Stale')], hasMore: false),
    );
    await _settle();
    expect(controller.model.books, isEmpty);
    expect(controller.model.loading, isFalse);

    controller.dispose();
    await _settle();
  });

  test('a stale completion cannot end a newer load skeleton', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();

    // A format change starts a newer load; the older page's completion must not
    // clear the loading state the newer load owns.
    controller.dispatch(const LibraryFormatChanged(FlutterBookFormat.epub));
    await _settle();
    expect(bridge.pages, hasLength(2));

    bridge.pages.first.complete(
      FlutterLibraryPage(books: [_book(1, 'Stale')], hasMore: false),
    );
    await _settle();

    expect(controller.model.loading, isTrue);
    expect(controller.model.books, isEmpty);

    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Current')], hasMore: false),
    );
    await _settle();

    expect(controller.model.loading, isFalse);
    expect(controller.model.books.single.title, 'Current');

    controller.dispose();
    await _settle();
  });

  test('a cancelled import is neutral, not an error surface', () async {
    final bridge = _CancelledImportBridge();
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async =>
          const LibraryImportSelection(paths: ['/books/a.pdf'], managed: false),
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
    );

    controller.dispatch(const LibraryImportRequested());
    await _settle();
    await _settle();
    await _settle();

    // Plan decision 13: cancellation is neutral. The books it did land are
    // reloaded into the grid instead of being reported as a failure.
    expect(controller.model.error, isNull);
    expect(controller.model.failure, LibraryFailure.none);
    expect(bridge.importCalls, 1);
    expect(bridge.pages, hasLength(1));

    controller.dispose();
    await _settle();
  });

  test(
    'a cancelled partial import keeps its failure summary visible',
    () async {
      final bridge = _PartialImportBridge();
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => const LibraryImportSelection(
          paths: ['/books/a.pdf'],
          managed: false,
        ),
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
        editSettings: (_) async => null,
      );

      controller.dispatch(const LibraryImportRequested());
      await _settle();
      await _settle();
      await _settle();

      expect(controller.model.failure, LibraryFailure.import);
      expect(controller.model.error, contains('Imported 2 books.'));
      expect(controller.model.error, contains('1 failed.'));
      expect(
        controller.model.error,
        isNot(contains('cancelled')),
        reason: 'cancellation is not the failure being reported',
      );

      controller.dispose();
      await _settle();
    },
  );

  test('an open effect keeps the book it was dispatched with', () async {
    final bridge = _StubLibraryBridge();
    final opened = <FlutterLibraryBook>[];
    final drained = <int>[];
    final openGate = Completer<void>();
    final drainGate = Completer<void>();
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (book) async {
        opened.add(book);
        await openGate.future;
      },
      drainReaderSaves: (bookId) async {
        drained.add(bookId);
        await drainGate.future;
      },
      editSettings: (_) async => null,
    );

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.single.complete(
      FlutterLibraryPage(
        books: [
          FlutterLibraryBook(
            bookId: 1,
            title: 'Resumable',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/1.pdf',
            managed: true,
            progress: 0.42,
            dateAdded: '2026-09-10',
            lastRead: '2026-09-19T08:12:00Z',
          ),
          FlutterLibraryBook(
            bookId: 2,
            title: 'Second resumable',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/2.pdf',
            managed: true,
            progress: 0.07,
            dateAdded: '2026-09-10',
            lastRead: '2026-09-18T08:12:00Z',
          ),
        ],
        hasMore: false,
      ),
    );
    await _settle();
    expect(controller.model.continueBook?.bookId, 1);

    controller.dispatch(LibraryBookOpened(controller.model.continueBook!));
    await _settle();

    // The open effect is in flight while a reload changes what the section
    // would select.
    controller.dispatch(const LibraryRefreshed());
    await _settle();
    bridge.pages.last.complete(
      FlutterLibraryPage(
        books: [
          FlutterLibraryBook(
            bookId: 2,
            title: 'Second resumable',
            format: FlutterBookFormat.pdf,
            pathKey: '/books/2.pdf',
            managed: true,
            progress: 0.07,
            dateAdded: '2026-09-10',
            lastRead: '2026-09-18T08:12:00Z',
          ),
        ],
        hasMore: false,
      ),
    );
    await _settle();
    expect(controller.model.continueBook?.bookId, 2);

    openGate.complete();
    await _settle();
    await _settle();

    expect(
      opened.map((book) => book.bookId),
      [1],
      reason:
          'the open effect carries the book the card dispatched, so a reload '
          'cannot change which book and durable position open',
    );

    // The drain that follows the reader is the dispatched book's too, and the
    // reader close only reports back once it has finished.
    expect(drained, [1]);
    expect(
      bridge.pages,
      hasLength(2),
      reason: 'no reader-close reload runs while the drain is still in flight',
    );

    drainGate.complete();
    await _settle();
    await _settle();
    expect(
      bridge.pages,
      hasLength(3),
      reason: 'the reader close reports back after the drain and reloads',
    );

    controller.dispose();
    await _settle();
  });
}

/// A stub bridge whose removal stays in flight.
class _HeldRemovalBridge extends _StubLibraryBridge {
  final removal = Completer<FlutterLibraryRemoveOutcome>();

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({required int bookId}) {
    removeCalls += 1;
    return removal.future;
  }
}

/// A stub bridge whose import is cancelled after landing two books.
class _CancelledImportBridge extends _StubLibraryBridge {
  int importCalls = 0;

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) async {
    importCalls += 1;
    return FlutterImportReport(
      imported: BigInt.from(2),
      failed: BigInt.zero,
      cancelled: true,
      items: const [],
    );
  }
}

/// A stub bridge whose import lands two books and fails one.
class _PartialImportBridge extends _StubLibraryBridge {
  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) async => FlutterImportReport(
    imported: BigInt.from(2),
    failed: BigInt.one,
    cancelled: true,
    items: const [
      FlutterImportItem(
        pathKey: '/books/broken.pdf',
        error: 'provider_error:readFailed',
      ),
    ],
  );
}
