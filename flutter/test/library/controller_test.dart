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
  final offsets = <int>[];
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
    offsets.add(offset);
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

  test('a paging request while a page is in flight is refused', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();

    // Page one is still in flight: the scroll trigger cannot open a second
    // request for the same page.
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.pages, hasLength(1));
    expect(bridge.offsets, [0]);

    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();

    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(
      bridge.offsets,
      [0, 1],
      reason: 'an appended page asks for the offset after the loaded books',
    );

    // The append is in flight now. The trigger can fire again before the model
    // it was built with is replaced; the controller refuses those requests, so
    // one page is fetched per completed page rather than two for one trigger.
    controller.dispatch(const LibraryMoreRequested());
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.offsets, [0, 1]);

    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Another Book')], hasMore: false),
    );
    await _settle();
    expect(controller.model.books.map((book) => book.bookId), [1, 2]);
    expect(controller.model.loadingMore, isFalse);

    // Exhaustion: the completed page said there is no next page, so the trigger
    // cannot ask again.
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.offsets, [0, 1]);

    controller.dispose();
    await _settle();
  });

  test('a failed appended page keeps the next page advertised', () async {
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
    bridge.pages.last.completeError(StateError('the next page failed'));
    await _settle();

    // A failed append keeps the loaded page and its own recovery, and it does
    // not claim the collection is exhausted: the alert's Retry recovers, and
    // the next page stays advertised until then.
    expect(controller.model.books.map((book) => book.bookId), [1]);
    expect(controller.model.loadError, isNotNull);
    expect(controller.model.pagingFailed, isTrue);
    expect(controller.model.hasMore, isTrue);
    expect(controller.model.loading, isFalse);
    expect(controller.model.loadingMore, isFalse);

    // A late trigger cannot retry the failed page by itself: the alert's Retry
    // is the explicit recovery.
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.offsets, [0, 1]);

    // That recovery retries the page that failed, in place, rather than
    // reloading the collection.
    controller.dispatch(const LibraryMoreRetryRequested());
    await _settle();
    expect(bridge.offsets, [0, 1, 1]);
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Another Book')], hasMore: false),
    );
    await _settle();
    expect(controller.model.books.map((book) => book.bookId), [1, 2]);
    expect(controller.model.loadError, isNull);
    expect(controller.model.pagingFailed, isFalse);

    controller.dispose();
    await _settle();
  });

  test('the paging retry cannot run an unrelated mutation recovery', () async {
    final bridge = _PartialImportBridge();
    var pickerCalls = 0;
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async {
        pickerCalls += 1;
        return const LibraryImportSelection(
          paths: ['/books/a.pdf'],
          managed: false,
        );
      },
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      editSettings: (_) async => null,
    );

    // A partial import leaves its own persistent failure on the alert above the
    // grid.
    controller.dispatch(const LibraryImportRequested());
    await _settle();
    await _settle();
    await _settle();
    expect(controller.model.failure, LibraryFailure.import);
    expect(pickerCalls, 1);
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(9, 'Imported')], hasMore: false),
    );
    await _settle();

    controller.dispatch(const LibraryRefreshed());
    await _settle();
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();

    // The append fails while the import failure is still on screen.
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    bridge.pages.last.completeError(StateError('the next page failed'));
    await _settle();
    expect(controller.model.pagingFailed, isTrue);
    expect(controller.model.failure, LibraryFailure.import);

    // The paging row's Retry retries the page. It must not run the mutation's
    // recovery: the two failures share a screen but not a surface.
    controller.dispatch(const LibraryMoreRetryRequested());
    await _settle();
    // The partial import reloaded the collection and the refresh reloaded it
    // again before the append; the retry is the second request at the failed
    // offset and nothing else.
    expect(bridge.offsets, [0, 0, 1, 1]);
    expect(
      pickerCalls,
      1,
      reason: 'the paging Retry cannot open the import picker',
    );

    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Another Book')], hasMore: false),
    );
    await _settle();
    expect(controller.model.pagingFailed, isFalse);

    // The alert above the grid still recovers its own failure.
    controller.dispatch(const LibraryRetryRequested());
    await _settle();
    expect(pickerCalls, 2, reason: 'the mutation recovery is unchanged');
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(9, 'Imported')], hasMore: false),
    );
    await _settle();

    controller.dispose();
    await _settle();
  });

  test('the paging retry obeys the paging admission', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    Future<void> failAnAppend() async {
      controller.dispatch(const LibraryMoreRequested());
      await _settle();
      bridge.pages.last.completeError(StateError('the next page failed'));
      await _settle();
      expect(controller.model.pagingFailed, isTrue);
    }

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();
    await failAnAppend();

    // A retry while one is already in flight is refused: it is a recovery, not
    // a new trigger.
    controller.dispatch(const LibraryMoreRetryRequested());
    await _settle();
    expect(bridge.offsets, [0, 1, 1]);
    controller.dispatch(const LibraryMoreRetryRequested());
    controller.dispatch(const LibraryMoreRetryRequested());
    await _settle();
    expect(bridge.offsets, [0, 1, 1]);
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Another Book')], hasMore: true),
    );
    await _settle();
    await failAnAppend();

    // A filter change owns the collection: the retained failure is stale, so
    // its retry cannot ask for the new filter at the old collection's offset.
    controller.dispatch(const LibraryFormatChanged(FlutterBookFormat.epub));
    await _settle();
    final afterFormatChange = List<int>.of(bridge.offsets);
    controller.dispatch(const LibraryMoreRetryRequested());
    await _settle();
    expect(
      bridge.offsets,
      afterFormatChange,
      reason: 'a stale paging retry is refused',
    );
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();
    expect(controller.model.pagingFailed, isFalse);
    await failAnAppend();

    // The same holds inside the search debounce window, before the replacement
    // load has started.
    controller.dispatch(const LibraryQueryChanged('new'));
    await _settle();
    final afterQueryChange = List<int>.of(bridge.offsets);
    controller.dispatch(const LibraryMoreRetryRequested());
    await _settle();
    expect(bridge.offsets, afterQueryChange);

    controller.dispose();
    await _settle();
  });

  test('an append completing inside the debounce is not adopted', () async {
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

    // The query change invalidates the load revision at once, before its
    // debounce starts the replacement: the page that lands inside that window
    // belongs to the collection the user left.
    controller.dispatch(const LibraryQueryChanged('new'));
    await _settle();
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Stale')], hasMore: false),
    );
    await _settle();
    expect(controller.model.books.map((book) => book.bookId), [1]);
    expect(controller.model.hasMore, isFalse);

    controller.dispose();
    await _settle();
  });

  test('a failure inside the debounce is not adopted', () async {
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

    controller.dispatch(const LibraryQueryChanged('new'));
    await _settle();
    bridge.pages.last.completeError(StateError('stale failure'));
    await _settle();
    expect(controller.model.loadError, isNull);
    expect(controller.model.pagingFailed, isFalse);

    controller.dispose();
    await _settle();
  });

  test('an append that adds no books is not asked for again', () async {
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
    expect(bridge.offsets, [0, 1]);
    // The page claims another page but adds nothing, so asking for that offset
    // again would return the same empty page: the trigger is refused until the
    // collection changes.
    bridge.pages.last.complete(
      const FlutterLibraryPage(books: [], hasMore: true),
    );
    await _settle();
    expect(controller.model.hasMore, isTrue);

    controller.dispatch(const LibraryMoreRequested());
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.offsets, [0, 1]);

    // A replacement load is a new collection, and its pages are asked for
    // normally.
    controller.dispatch(const LibraryRefreshed());
    await _settle();
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();
    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.offsets, [0, 1, 0, 1]);

    controller.dispose();
    await _settle();
  });

  test('a completion after disposal cannot write the model', () async {
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
    expect(bridge.offsets, [0, 1]);

    controller.dispose();
    await _settle();

    // The disposed controller drains its effect but owns no model state: the
    // page that lands afterwards cannot append itself.
    bridge.pages.last.complete(
      FlutterLibraryPage(books: [_book(2, 'Late')], hasMore: false),
    );
    await _settle();
    expect(controller.model.books.map((book) => book.bookId), [1]);
    expect(controller.model.loadError, isNull);
    expect(bridge.disposeCount, 1);
  });

  test('a failure after disposal cannot write the model', () async {
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
    controller.dispose();
    await _settle();

    bridge.pages.last.completeError(StateError('too late'));
    await _settle();
    expect(controller.model.loadError, isNull);
    expect(controller.model.books.map((book) => book.bookId), [1]);
    expect(bridge.disposeCount, 1);
  });

  test('an append that cannot start keeps the next page advertised', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();

    // The append cannot even create its cancellation: the loaded page and the
    // next page it was advertising survive, with the failure's own recovery.
    bridge.failCancellationCreation = true;
    controller.dispatch(const LibraryMoreRequested());
    await _settle();

    expect(controller.model.books.map((book) => book.bookId), [1]);
    expect(controller.model.loadError, isNotNull);
    expect(controller.model.pagingFailed, isTrue);
    expect(controller.model.hasMore, isTrue);

    controller.dispose();
    await _settle();
  });

  test('a failed replacement page does not advertise another page', () async {
    final bridge = _StubLibraryBridge();
    final controller = _controller(bridge);

    controller.dispatch(const LibraryStarted());
    await _settle();
    bridge.pages.single.complete(
      FlutterLibraryPage(books: [_book(1, 'A Book')], hasMore: true),
    );
    await _settle();
    expect(controller.model.hasMore, isTrue);

    // A refresh that fails replaces page one, so the collection's length is
    // unknown again: unlike a failed append, there is no next page to advertise
    // until the load is retried, and the trigger cannot ask for one.
    controller.dispatch(const LibraryRefreshed());
    await _settle();
    bridge.pages.last.completeError(StateError('refresh failed'));
    await _settle();

    expect(controller.model.loadError, isNotNull);
    expect(controller.model.pagingFailed, isFalse);
    expect(controller.model.hasMore, isFalse);

    controller.dispatch(const LibraryMoreRequested());
    await _settle();
    expect(bridge.offsets, [0, 0]);

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
