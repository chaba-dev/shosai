import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/notices/library_notice_text.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/src/rust/api.dart';

FlutterLibraryBook _book(int id, String title) => FlutterLibraryBook(
  bookId: id,
  title: title,
  format: FlutterBookFormat.epub,
  pathKey: '/books/$id.epub',
  managed: false,
  progress: 0,
  dateAdded: '2026-09-10',
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// The bridge surface the import/settings notice integration needs.
class _StubBridge implements FlutterBridge {
  _StubBridge();

  Completer<FlutterImportReport>? importCompleter;
  FlutterImportReport? importReport;
  Completer<void>? saveCompleter;
  bool saveSettingsFails = false;
  int importCalls = 0;
  int saveCalls = 0;
  var _nextCancellation = BigInt.one;

  @override
  bool get isDisposed => false;

  @override
  void dispose() {}

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
  }) async => FlutterLibraryPage(books: [_book(1, 'First')], hasMore: false);

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => const FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.4,
    pdfZoom: 1,
  );

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) {
    importCalls += 1;
    if (importCompleter case final completer?) return completer.future;
    return Future<FlutterImportReport>.value(importReport!);
  }

  @override
  Future<void> saveReaderSettings({required FlutterReaderSettings value}) {
    saveCalls += 1;
    if (saveSettingsFails) return Future<void>.error(Exception('save failed'));
    if (saveCompleter case final completer?) return completer.future;
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LibraryController _controller(
  _StubBridge bridge, {
  NoticeReporter? noticeReporter,
  Future<LibraryImportSelection?> Function()? pickImport,
  Future<FlutterReaderSettings?> Function(FlutterReaderSettings)? editSettings,
}) => LibraryController(
  bridge: bridge,
  confirmRemoval: (_) async => true,
  pickImport:
      pickImport ??
      () async =>
          const LibraryImportSelection(paths: ['/tmp/a.epub'], managed: false),
  openBook: (_) async {},
  drainReaderSaves: (_) async {},
  editSettings: editSettings ?? (initial) async => initial,
  noticeReporter: noticeReporter ?? ignoreNotice,
);

FlutterImportReport _report({
  int imported = 0,
  int failed = 0,
  bool cancelled = false,
  List<FlutterImportItem> items = const [],
}) => FlutterImportReport(
  imported: BigInt.from(imported),
  failed: BigInt.from(failed),
  cancelled: cancelled,
  items: items,
);

/// Starts the controller and waits for its first library page.
Future<void> _start(LibraryController controller) async {
  controller.dispatch(const LibraryStarted());
  await _settle();
}

void main() {
  test('a clean import reports one brief success notice', () async {
    final bridge = _StubBridge()..importReport = _report(imported: 2);
    final notices = <NoticeRequest>[];
    final controller = _controller(bridge, noticeReporter: notices.add);
    addTearDown(controller.dispose);

    await _start(controller);
    controller.dispatch(const LibraryImportRequested());
    await _settle();

    expect(notices, hasLength(1));
    final text = notices.single.text;
    expect(text, isA<LibraryImportSucceededNotice>());
    expect((text as LibraryImportSucceededNotice).count, 2);
    expect(notices.single.kind, NoticeKind.success);
    expect(notices.single.lifetime, NoticeLifetime.brief);
    expect(controller.model.error, isNull);

    // A later refresh or reload does not report the same success again.
    controller.dispatch(const LibraryRefreshed());
    await _settle();

    expect(notices, hasLength(1));
  });

  test(
    'a partial import stays inline, reports no notice, and a new operation succeeds',
    () async {
      final bridge = _StubBridge()
        ..importReport = _report(
          imported: 1,
          failed: 1,
          items: [
            FlutterImportItem(pathKey: '/tmp/a.epub', book: _book(2, 'Landed')),
            FlutterImportItem(
              pathKey: '/tmp/b.epub',
              error: 'unsupported format',
            ),
          ],
        );
      final notices = <NoticeRequest>[];
      final controller = _controller(bridge, noticeReporter: notices.add);
      addTearDown(controller.dispose);

      await _start(controller);
      controller.dispatch(const LibraryImportRequested());
      await _settle();

      expect(notices, isEmpty);
      expect(controller.model.error, isNotNull);
      expect(controller.model.error, contains('failed'));

      // The inline surface's retry is a new operation: a clean result reports
      // exactly one success and clears the failure state.
      bridge.importReport = _report(imported: 3);
      controller.dispatch(const LibraryRetryRequested());
      await _settle();

      expect(notices, hasLength(1));
      expect((notices.single.text as LibraryImportSucceededNotice).count, 3);
      expect(controller.model.error, isNull);
      expect(controller.model.failure, LibraryFailure.none);
    },
  );

  test('a warning-only import stays inline and reports no notice', () async {
    final bridge = _StubBridge()
      ..importReport = _report(
        imported: 1,
        items: [
          FlutterImportItem(
            pathKey: '/tmp/a.epub',
            book: _book(2, 'Landed'),
            warning: 'missing cover',
          ),
        ],
      );
    final notices = <NoticeRequest>[];
    final controller = _controller(bridge, noticeReporter: notices.add);
    addTearDown(controller.dispose);

    await _start(controller);
    controller.dispatch(const LibraryImportRequested());
    await _settle();

    expect(notices, isEmpty);
    expect(controller.model.error, isNotNull);
  });

  test('cancellation is neutral: no notice and no error surface', () async {
    final bridge = _StubBridge()..importReport = _report(cancelled: true);
    final notices = <NoticeRequest>[];
    final controller = _controller(bridge, noticeReporter: notices.add);
    addTearDown(controller.dispose);

    await _start(controller);
    controller.dispatch(const LibraryImportRequested());
    await _settle();

    expect(notices, isEmpty);
    expect(controller.model.error, isNull);
    expect(controller.model.failure, LibraryFailure.none);
  });

  test(
    'a cancelled import that landed books reports no success notice',
    () async {
      final bridge = _StubBridge()
        ..importReport = _report(
          imported: 2,
          cancelled: true,
          items: [
            FlutterImportItem(pathKey: '/tmp/a.epub', book: _book(2, 'Landed')),
            FlutterImportItem(pathKey: '/tmp/b.epub', book: _book(3, 'Also')),
          ],
        );
      final notices = <NoticeRequest>[];
      final controller = _controller(bridge, noticeReporter: notices.add);
      addTearDown(controller.dispose);

      await _start(controller);
      controller.dispatch(const LibraryImportRequested());
      await _settle();

      expect(notices, isEmpty);
      expect(controller.model.error, isNull);
      expect(controller.model.failure, LibraryFailure.none);
    },
  );

  test(
    'a cancelled import that also failed keeps its inline summary',
    () async {
      final bridge = _StubBridge()
        ..importReport = _report(
          failed: 1,
          cancelled: true,
          items: [
            FlutterImportItem(
              pathKey: '/tmp/b.epub',
              error: 'unsupported format',
            ),
          ],
        );
      final notices = <NoticeRequest>[];
      final controller = _controller(bridge, noticeReporter: notices.add);
      addTearDown(controller.dispose);

      await _start(controller);
      controller.dispatch(const LibraryImportRequested());
      await _settle();

      expect(notices, isEmpty);
      expect(controller.model.error, isNotNull);
      expect(controller.model.error, isNot(contains('cancelled')));
    },
  );

  test(
    'cancelling before the picker returns runs no import and reports nothing',
    () async {
      final bridge = _StubBridge();
      final notices = <NoticeRequest>[];
      final picker = Completer<LibraryImportSelection?>();
      final controller = _controller(
        bridge,
        noticeReporter: notices.add,
        pickImport: () => picker.future,
      );
      addTearDown(controller.dispose);

      await _start(controller);
      controller.dispatch(const LibraryImportRequested());
      await _settle();
      controller.dispatch(const LibraryOperationCancelled());
      await _settle();
      picker.complete(
        const LibraryImportSelection(paths: ['/tmp/a.epub'], managed: false),
      );
      await _settle();

      expect(bridge.importCalls, 0);
      expect(notices, isEmpty);
      expect(controller.model.error, isNull);
    },
  );

  test('a saved settings change reports one brief success notice', () async {
    final bridge = _StubBridge();
    final notices = <NoticeRequest>[];
    final controller = _controller(bridge, noticeReporter: notices.add);
    addTearDown(controller.dispose);

    await _start(controller);
    controller.dispatch(const LibrarySettingsRequested());
    await _settle();

    expect(notices, hasLength(1));
    expect(notices.single.text, isA<LibrarySettingsSavedNotice>());
    expect(notices.single.kind, NoticeKind.success);
  });

  test('a failed settings save stays inline and reports no notice', () async {
    final bridge = _StubBridge()..saveSettingsFails = true;
    final notices = <NoticeRequest>[];
    final controller = _controller(bridge, noticeReporter: notices.add);
    addTearDown(controller.dispose);

    await _start(controller);
    controller.dispatch(const LibrarySettingsRequested());
    await _settle();

    expect(notices, isEmpty);
    expect(controller.model.error, isNotNull);
  });

  test(
    'a settings save keeps its success feedback when a concurrent load is cancelled',
    () async {
      final bridge = _StubBridge()..saveCompleter = Completer<void>();
      final notices = <NoticeRequest>[];
      final controller = _controller(
        bridge,
        noticeReporter: notices.add,
        editSettings: (initial) async => FlutterReaderSettings(
          continuous: initial.continuous,
          theme: initial.theme,
          epubFontSize: 20,
          epubLineSpacing: initial.epubLineSpacing,
          pdfZoom: initial.pdfZoom,
        ),
      );
      addTearDown(controller.dispose);

      await _start(controller);
      controller.dispatch(const LibrarySettingsRequested());
      await _settle();
      expect(bridge.saveCalls, 1);

      // A concurrent load starts and its cancel action invalidates the shared
      // adapter revision; the settings write is already persisted, so its
      // feedback must survive.
      controller.dispatch(const LibraryFormatChanged(null));
      await _settle();
      controller.dispatch(const LibraryOperationCancelled());
      await _settle();
      bridge.saveCompleter!.complete();
      await _settle();

      expect(controller.model.settings?.epubFontSize, 20);
      expect(notices, hasLength(1));
      expect(notices.single.text, isA<LibrarySettingsSavedNotice>());
    },
  );

  test('a late import completion after disposal reports no notice', () async {
    final bridge = _StubBridge()
      ..importCompleter = Completer<FlutterImportReport>();
    final notices = <NoticeRequest>[];
    final controller = _controller(bridge, noticeReporter: notices.add);

    await _start(controller);
    controller.dispatch(const LibraryImportRequested());
    await _settle();

    // The import really started before disposal: the empty result below is not
    // a vacuous pass.
    expect(bridge.importCalls, 1);

    controller.dispose();
    bridge.importCompleter!.complete(_report(imported: 3));
    await _settle();

    expect(notices, isEmpty);
  });
}
