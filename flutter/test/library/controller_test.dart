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
  var _nextCancellation = BigInt.one;

  @override
  bool get isDisposed => disposeCount != 0;

  @override
  void dispose() => disposeCount += 1;

  @override
  BigInt createCancellation() {
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
