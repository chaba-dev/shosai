import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';

/// Package 4C reader panels: Contents/saved places, typography, more and
/// search (rows RD-07…RD-11).
///
/// Interactions are driven through the rendered surface; the Contents entries,
/// the progress ordinals and the tab list are fixture-injected presentation
/// data because the bridge exposes no TOC/session/pagination DTO (contract
/// §2.2). The saved places, note editing, delete, Markdown export, search and
/// open-book paths run through the real controller and the harness bridge.
class _PanelBridge extends HarnessBridge {
  _PanelBridge({
    super.books,
    super.unitCount,
    this.bookmarks = const [],
    this.failExport = false,
  });

  List<FlutterBookmark> bookmarks;
  final bool failExport;

  /// Every `toggleBookmark` call as (unit, offset).
  final List<(int, int?)> toggles = [];

  /// Every `updateBookmarkNote` call as (id, note).
  final List<(int, String?)> noteUpdates = [];

  /// Every `deleteBookmark` call.
  final List<int> deletes = [];

  /// Export calls and the Markdown handed to the sink.
  int exportCalls = 0;
  final List<String> sinkTexts = [];

  /// When set, `exportBookmarks` waits for the test to release it.
  bool holdExport = false;
  final List<Completer<String>> heldExports = [];

  /// Search completions the test controls.
  final List<Completer<List<FlutterSearchMatch>>> searchCompletions = [];

  /// When set, `renderPage` waits for the test to release it, so a relayout can
  /// be observed in flight.
  bool holdRender = false;
  final List<Completer<void>> heldRenders = [];

  @override
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  }) async {
    if (holdRender) {
      final completer = Completer<void>();
      heldRenders.add(completer);
      await completer.future;
    }
    return super.renderPage(
      document: document,
      page: page,
      scale: scale,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) async => bookmarks;

  @override
  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
    String? note,
  }) async {
    toggles.add((unit.toInt(), offset?.toInt()));
    final existing = bookmarks
        .where((bookmark) => bookmark.unit == unit && bookmark.offset == offset)
        .firstOrNull;
    if (existing != null) {
      bookmarks = [
        for (final bookmark in bookmarks)
          if (bookmark.id != existing.id) bookmark,
      ];
      return null;
    }
    final created = FlutterBookmark(
      id: 100 + toggles.length,
      bookId: bookId,
      unit: unit,
      offset: offset,
      note: note,
      color: 'yellow',
      createdAt: '2026-09-20T00:00:00Z',
    );
    bookmarks = [...bookmarks, created];
    return created;
  }

  @override
  Future<void> updateBookmarkNote({required int id, String? note}) async {
    noteUpdates.add((id, note));
    bookmarks = [
      for (final bookmark in bookmarks)
        if (bookmark.id == id)
          FlutterBookmark(
            id: bookmark.id,
            bookId: bookmark.bookId,
            unit: bookmark.unit,
            offset: bookmark.offset,
            title: bookmark.title,
            note: note,
            color: bookmark.color,
            createdAt: bookmark.createdAt,
          )
        else
          bookmark,
    ];
  }

  @override
  Future<void> deleteBookmark({required int id}) async {
    deletes.add(id);
    bookmarks = [
      for (final bookmark in bookmarks)
        if (bookmark.id != id) bookmark,
    ];
  }

  @override
  Future<String> exportBookmarks({required int bookId}) {
    exportCalls += 1;
    if (holdExport) {
      final completer = Completer<String>();
      heldExports.add(completer);
      return completer.future;
    }
    if (failExport) {
      return Future<String>.error(
        const FlutterBridgeError(
          kind: FlutterBridgeErrorKind.inaccessible,
          message: 'export target is unavailable',
        ),
      );
    }
    return Future<String>.value('# Bookmarks');
  }

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  }) {
    final completer = Completer<List<FlutterSearchMatch>>();
    searchCompletions.add(completer);
    return completer.future;
  }
}

const _epubSettings = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
);

int _readerKeyCounter = 0;

Widget _reader({
  required HarnessBridge bridge,
  String? initialPath = '/books/slow-rivers.epub',
  int? initialBookId,
  FlutterReaderSettings? settings = _epubSettings,
  ReaderContentsLoader? contentsLoader,
  ReaderDocumentPickerAdapter? documentPicker,
  ReaderExportSink? exportSink,
  ReaderNoticeReporter? noticeReporter,
  Locale? locale,
}) => productionShell(
  locale: locale,
  home: ReaderScreen(
    key: ValueKey('panel-reader-${_readerKeyCounter++}'),
    bridge: bridge,
    decoder: (pixels, {required width, required height}) => _testImage(),
    initialPath: initialPath,
    initialBookId: initialBookId,
    initialSettings: settings,
    contentsLoader: contentsLoader,
    documentPicker: documentPicker,
    exportSink: exportSink,
    noticeReporter: noticeReporter,
  ),
);

Future<void> _open(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump(const Duration(milliseconds: 32));
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps a fixed number of frames after an interaction.
Future<void> _settle(WidgetTester tester, {int frames = 4}) async {
  for (var index = 0; index < frames; index += 1) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Future<ui.Image> _testImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(1, 1);
  } finally {
    picture.dispose();
  }
}

FlutterBookmark _bookmark({int id = 1, BigInt? unit, String? note}) =>
    FlutterBookmark(
      id: id,
      bookId: 1,
      unit: unit ?? BigInt.zero,
      note: note,
      color: 'yellow',
      createdAt: '2026-09-20T00:00:00Z',
    );

List<ReaderContentsEntry> _fixtureEntries() => const [
  ReaderContentsEntry(depth: 0, title: 'Headwaters', unit: 0),
  ReaderContentsEntry(depth: 1, title: 'The Long Meander', unit: 1),
  ReaderContentsEntry(
    depth: 0,
    title:
        'A deliberately long chapter title that must be truncated at the '
        'pinned 38 characters',
    unit: 2,
  ),
];

Future<void> _openContents(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
  await tester.pump();
  await _settle(tester);
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-header-more')));
  await tester.pump();
  await _settle(tester);
}

Future<void> _openTypography(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
  await tester.pump();
  await _settle(tester);
}

void main() {
  setUpAll(loadHarnessFonts);

  group('contents panel', () {
    testWidgets('renders fixture entries with the chapter fallback and '
        'navigates through rendered controls', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 4);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          contentsLoader: (_) async => [
            ..._fixtureEntries(),
            const ReaderContentsEntry(depth: 0, unit: 3),
          ],
        ),
      );

      await _openContents(tester);
      expect(
        find.byKey(const ValueKey('reader-panel-contents')),
        findsOneWidget,
      );
      expect(find.text('Headwaters'), findsOneWidget);
      expect(find.text('The Long Meander'), findsOneWidget);
      // The untitled entry renders the localized chapter fallback, not an
      // invented title (contract §4.6).
      expect(find.text('Chapter 4'), findsOneWidget);
      // The 38-character truncation is applied to the long fixture title.
      expect(
        find.textContaining('A deliberately long chapter title tha…'),
        findsOneWidget,
      );
      // The current entry (unit 0) is selected and reachable.
      final current = tester.getSemantics(
        find.byKey(const ValueKey('reader-contents-entry-0')),
      );
      expect(
        current.getSemanticsData().flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('reader-contents-entry-1')));
      await tester.pump();
      await _settle(tester);
      // The status wording follows the navigated unit.
      expect(find.text('Chapter 2 · 50%'), findsOneWidget);
    });

    testWidgets('shows loading, empty, failed and retry states', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final completers = <Completer<List<ReaderContentsEntry>>>[];
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          contentsLoader: (_) {
            final completer = Completer<List<ReaderContentsEntry>>();
            completers.add(completer);
            return completer.future;
          },
        ),
      );

      // Loading: the panel is open while the loader is still pending.
      await _openContents(tester);
      expect(find.text('Loading contents…'), findsOneWidget);

      // Failure carries the error payload and a retry.
      completers.single.completeError(StateError('toc unavailable'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('reader-contents-error')),
        findsOneWidget,
      );
      expect(find.textContaining('toc unavailable'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-contents-retry')),
        findsOneWidget,
      );

      // Retry starts a fresh guarded load.
      await tester.tap(find.byKey(const ValueKey('reader-contents-retry')));
      await tester.pump();
      expect(find.text('Loading contents…'), findsOneWidget);
      expect(completers, hasLength(2));
      completers.last.complete(const []);
      await _settle(tester);
      expect(find.text('No chapters in this document'), findsOneWidget);
    });

    testWidgets('a stale load cannot publish entries for a newer document', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final completers = <Completer<List<ReaderContentsEntry>>>[];
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          documentPicker: () async =>
              const ReaderPickedDocument('/books/replacement.pdf'),
          contentsLoader: (document) {
            final completer = Completer<List<ReaderContentsEntry>>();
            completers.add(completer);
            return completer.future;
          },
        ),
      );

      await _openContents(tester);
      expect(completers, hasLength(1));

      // A new open through the rendered more panel replaces the document
      // generation while the first load is still pending.
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await tester.pump();
      await _settle(tester, frames: 6);

      // The stale completion must not publish entries for the new document.
      completers.first.complete(_fixtureEntries());
      await _settle(tester);

      await _openContents(tester);
      expect(completers, hasLength(2));
      completers.last.complete(const [
        ReaderContentsEntry(depth: 0, title: 'Replacement chapter', unit: 0),
      ]);
      await _settle(tester);
      expect(find.text('Replacement chapter'), findsOneWidget);
      expect(find.text('Headwaters'), findsNothing);
    });

    testWidgets('saved places list empty state, delete and busy gating', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(
        unitCount: 3,
        bookmarks: [_bookmark(id: 7, note: 'A short note')],
      );
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialBookId: 1,
          contentsLoader: (_) async => const [],
        ),
      );
      await _openContents(tester);

      expect(find.text('Bookmarks · 1'), findsOneWidget);
      expect(find.text('A short note'), findsOneWidget);
      expect(find.text('Edit note'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader-saved-place-delete-7')),
      );
      await tester.pump();
      await _settle(tester);
      expect(bridge.deletes, [7]);
      expect(find.text('No bookmarks yet'), findsOneWidget);
      expect(find.text('Bookmarks · 0'), findsOneWidget);
    });

    testWidgets('the note editor runs through the controller-owned dialog', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3, bookmarks: [_bookmark(id: 7)]);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialBookId: 1,
          contentsLoader: (_) async => const [],
        ),
      );
      await _openContents(tester);

      await tester.tap(find.byKey(const ValueKey('reader-saved-place-note-7')));
      await tester.pumpAndSettle();
      // The controller-owned modal is open while the editor runs.
      expect(find.byType(ShadDialog), findsOneWidget);
      expect(find.text('Bookmark note'), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byType(ShadDialog),
          matching: find.byType(ShadInput),
        ),
        'Edited note',
      );
      await tester.tap(find.widgetWithText(ShadButton, 'Save'));
      await tester.pumpAndSettle();
      expect(bridge.noteUpdates, [(7, 'Edited note')]);
      expect(find.byType(ShadDialog), findsNothing);
    });

    testWidgets('Markdown export copies through the sink and reports success', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3, bookmarks: [_bookmark(id: 7)]);
      final notices = <NoticeRequest>[];
      final sinkTexts = <String>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialBookId: 1,
          contentsLoader: (_) async => const [],
          exportSink: (markdown) async => sinkTexts.add(markdown),
          noticeReporter: notices.add,
        ),
      );
      await _openContents(tester);

      await tester.tap(find.byKey(const ValueKey('reader-bookmark-export')));
      await tester.pump();
      await _settle(tester);
      expect(bridge.exportCalls, 1);
      expect(sinkTexts, ['# Bookmarks']);
      expect(notices, hasLength(1));
      expect(notices.single.lifetime, NoticeLifetime.brief);
      expect(
        notices.single.text.resolve(
          AppLocalizations.of(
            tester.element(find.byKey(const ValueKey('reader-panel-contents'))),
          ),
        ),
        'Bookmarks copied as Markdown',
      );
      expect(
        find.byKey(const ValueKey('reader-bookmark-export-error')),
        findsNothing,
      );
    });

    testWidgets('a failed export stays visible in the panel and as a notice', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(
        unitCount: 3,
        bookmarks: [_bookmark(id: 7)],
        failExport: true,
      );
      final notices = <NoticeRequest>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialBookId: 1,
          contentsLoader: (_) async => const [],
          noticeReporter: notices.add,
        ),
      );
      await _openContents(tester);

      await tester.tap(find.byKey(const ValueKey('reader-bookmark-export')));
      await tester.pump();
      await _settle(tester);
      final error = find.byKey(const ValueKey('reader-bookmark-export-error'));
      expect(error, findsOneWidget);
      expect(
        tester
            .getSemantics(error)
            .getSemanticsData()
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      expect(notices, hasLength(1));
      expect(notices.single.lifetime, NoticeLifetime.persistent);
      expect(notices.single.dedupeKey, NoticePolicy.readerExportKey);
    });
  });

  group('effect invalidation', () {
    testWidgets('a suspended picker releases its modal slot and stays stale', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      final pickers = <Completer<ReaderPickedDocument?>>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialBookId: 1,
          documentPicker: () {
            final completer = Completer<ReaderPickedDocument?>();
            pickers.add(completer);
            return completer.future;
          },
        ),
      );
      ShadButton openBook() => tester.widget<ShadButton>(
        find.descendant(
          of: find.byKey(const ValueKey('reader-more-open-book')),
          matching: find.byType(ShadButton),
        ),
      );

      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await tester.pump();
      expect(pickers, hasLength(1));
      expect(openBook().enabled, isFalse, reason: 'the picker owns the modal');

      // Suspension invalidates the picker: the slot is released by the
      // transition, not by a completion that would be rejected as stale.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await _settle(tester, frames: 6);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _settle(tester, frames: 6);

      await _openMore(tester);
      expect(openBook().enabled, isTrue, reason: 'the modal slot was retired');
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await tester.pump();
      expect(pickers, hasLength(2));

      // The old completion is rejected and must not clear the newer slot or
      // open its document.
      pickers.first.complete(
        const ReaderPickedDocument('/books/stale.epub', bookId: 9),
      );
      await tester.pump();
      await _settle(tester, frames: 6);
      expect(find.text('stale.epub'), findsNothing);
      expect(
        openBook().enabled,
        isFalse,
        reason: 'the new picker still owns it',
      );

      pickers.last.complete(null);
      await tester.pump();
      await _settle(tester);
      expect(openBook().enabled, isTrue);
    });

    testWidgets('a stale export never reaches the sink', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(
        unitCount: 3,
        books: harnessLibraryBooks(),
        bookmarks: [_bookmark(id: 7)],
      )..holdExport = true;
      final sinkTexts = <String>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialBookId: 1,
          // The replacement is another library book, so the export path keeps
          // a book id to export for.
          documentPicker: () async =>
              const ReaderPickedDocument('/books/umibe.epub', bookId: 2),
          contentsLoader: (_) async => const [],
          exportSink: (markdown) async => sinkTexts.add(markdown),
        ),
      );
      await _openContents(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmark-export')));
      await tester.pump();
      expect(bridge.heldExports, hasLength(1));

      // Replace the document while the export is pending.
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await tester.pump();
      await _settle(tester, frames: 6);
      expect(find.text('umibe.epub'), findsOneWidget);

      bridge.heldExports.first.complete('# stale book');
      await tester.pump();
      await _settle(tester);
      expect(sinkTexts, isEmpty);

      // The replacement's own export still works.
      await _openContents(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmark-export')));
      await tester.pump();
      expect(bridge.heldExports, hasLength(2));
      bridge.heldExports.last.complete('# fresh book');
      await tester.pump();
      await _settle(tester);
      expect(sinkTexts, ['# fresh book']);
    });

    testWidgets('the current contents entry is revealed after an async load', (
      tester,
    ) async {
      _setView(tester, const Size(390, 844));
      final bridge = _PanelBridge(unitCount: 30);
      final completers = <Completer<List<ReaderContentsEntry>>>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          contentsLoader: (_) {
            final completer = Completer<List<ReaderContentsEntry>>();
            completers.add(completer);
            return completer.future;
          },
        ),
      );

      // Move to a late unit through the rendered page input, then open the
      // Contents panel while the load is still pending.
      await _openMore(tester);
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '25',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await _settle(tester, frames: 6);
      await _openContents(tester);
      expect(completers, hasLength(1));

      completers.single.complete([
        for (var unit = 0; unit < 30; unit += 1)
          ReaderContentsEntry(
            depth: 0,
            title: 'Chapter entry $unit',
            unit: unit,
          ),
      ]);
      await tester.pump();
      await _settle(tester, frames: 4);

      // The current entry (unit 24) is far below the fold and is revealed
      // without another interaction.
      final viewport = tester.getRect(
        find.byKey(const ValueKey('reader-contents-scroll')),
      );
      final current = tester.getRect(
        find.byKey(const ValueKey('reader-contents-entry-24')),
      );
      expect(current.top, greaterThanOrEqualTo(viewport.top - 0.5));
      expect(current.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
    });
  });

  group('typography panel', () {
    testWidgets('EPUB shows font size, line spacing and theme with clamps', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          settings: const FlutterReaderSettings(
            continuous: false,
            theme: 'light',
            epubFontSize: 46,
            epubLineSpacing: 1.6,
            pdfZoom: 0,
          ),
        ),
      );
      await _openTypography(tester);

      expect(find.text('46px'), findsOneWidget);
      expect(find.text('1.6×'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-typography-fit-page')),
        findsNothing,
        reason: 'an EPUB has no raster fit controls',
      );

      await tester.tap(
        find.byKey(const ValueKey('reader-typography-font-increase')),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.text('48px'), findsOneWidget);

      // The clamp is 8–48 (the pinned step ±2.0): another step stays at 48.
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-font-increase')),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.text('48px'), findsOneWidget);

      // Line spacing cycles through the pinned settings values.
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-line-spacing')),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.text('1.8×'), findsOneWidget);

      // The theme cycle is light → dark → sepia → light.
      await tester.tap(find.byKey(const ValueKey('reader-typography-theme')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('Dark'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-typography-theme')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('Sepia'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-typography-theme')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('Light'), findsOneWidget);
    });

    testWidgets('a raster document shows zoom and fit controls only', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
      );
      await _openTypography(tester);

      expect(find.text('Fit page'), findsWidgets);
      expect(
        find.byKey(const ValueKey('reader-typography-font-increase')),
        findsNothing,
        reason: 'a raster document has no EPUB font-size control',
      );
      expect(
        find.byKey(const ValueKey('reader-typography-theme')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('reader-typography-zoom-in')));
      await tester.pump();
      await _settle(tester);
      // The manual zoom label is the percentage and the fit selection is
      // cleared.
      expect(find.text('125%'), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('reader-typography-fit-page')),
            )
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey('reader-typography-fit-width')),
      );
      await tester.pump();
      await _settle(tester);
      expect(
        tester
            .getSemantics(
              find.byKey(const ValueKey('reader-typography-fit-width')),
            )
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );
      expect(find.text('Fit width'), findsWidgets);
    });

    testWidgets('controls are disabled while a relayout is in flight', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
      );
      await _openTypography(tester);
      final zoomIn = find.byKey(const ValueKey('reader-typography-zoom-in'));
      ShadButton button() => tester.widget<ShadButton>(
        find.descendant(of: zoomIn, matching: find.byType(ShadButton)),
      );
      expect(button().enabled, isTrue);

      bridge.holdRender = true;
      await tester.tap(zoomIn);
      await tester.pump();
      // The relayout is in flight; the control gates on `relayoutBusy`.
      expect(button().enabled, isFalse);

      bridge.heldRenders.single.complete();
      await tester.pump();
      await _settle(tester);
      expect(button().enabled, isTrue);
    });
  });

  group('more panel', () {
    testWidgets('page input validates and converts the 1-based ordinal', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _openMore(tester);

      expect(find.text('of 3'), findsOneWidget);
      // The open's relayout has settled, so the input is enabled: a pending
      // relayout would silently drop the submission.
      expect(
        tester
            .widget<ShadInput>(find.byKey(const ValueKey('reader-page-input')))
            .enabled,
        isTrue,
      );
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '2',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await _settle(tester);
      expect(find.text('Chapter 2 · 67%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-page-input-error')),
        findsNothing,
      );

      // An out-of-range submission stays inline and does not navigate.
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '9',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('reader-page-input-error')),
        findsOneWidget,
      );
      expect(find.text('Enter a page between 1 and 3.'), findsOneWidget);
      expect(find.text('Chapter 2 · 67%'), findsOneWidget);

      // A non-numeric draft is rejected the same way.
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        'two',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await _settle(tester);
      expect(find.text('Enter a page between 1 and 3.'), findsOneWidget);
    });

    testWidgets('bookmark toggle runs through the rendered control', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge, initialBookId: 1));
      await _openMore(tester);

      expect(find.text('☆ Bookmark'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-more-bookmark')));
      await tester.pump();
      await _settle(tester);
      expect(bridge.toggles, [(0, null)]);
      // The bookmarks reloaded with the created entry, so the toggle now
      // reports the saved state.
      expect(find.text('★ Saved'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('reader-more-bookmark')))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue,
      );
    });

    testWidgets('open book uses the injected picker and opens the document', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      final picked = <int>[];
      await _open(
        tester,
        _reader(
          bridge: bridge,
          documentPicker: () async {
            picked.add(1);
            return const ReaderPickedDocument('/books/other.epub');
          },
        ),
      );
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await tester.pump();
      await _settle(tester, frames: 6);

      expect(picked, [1]);
      // The picked document opened through the normal open path: the reader
      // title is the picked file's name.
      expect(find.text('other.epub'), findsOneWidget);
    });

    testWidgets('a cancelled picker is neutral', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      var calls = 0;
      await _open(
        tester,
        _reader(
          bridge: bridge,
          documentPicker: () async {
            calls += 1;
            return null;
          },
        ),
      );
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-open-book')));
      await tester.pump();
      await _settle(tester);
      expect(calls, 1);
      // The original document stays open and no error is reported.
      expect(find.text('slow-rivers.epub'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-tool-error')), findsNothing);
      expect(
        tester
            .widget<ShadButton>(
              find.descendant(
                of: find.byKey(const ValueKey('reader-more-open-book')),
                matching: find.byType(ShadButton),
              ),
            )
            .enabled,
        isTrue,
        reason: 'the picker modal slot is cleared on cancellation',
      );
    });
  });

  group('search bar', () {
    testWidgets('submit searches, reports the count and steps with wrap', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-search')));
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('reader-search-input')), findsOneWidget);
      expect(
        tester
            .widget<ShadInput>(
              find.byKey(const ValueKey('reader-search-input')),
            )
            .enabled,
        isTrue,
      );

      await tester.enterText(
        find.byKey(const ValueKey('reader-search-input')),
        'river',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(bridge.searchCompletions, hasLength(1));

      bridge.searchCompletions.single.complete([
        FlutterSearchMatch(
          unit: BigInt.one,
          offset: BigInt.from(4),
          length: BigInt.from(5),
          context: 'river bank',
        ),
        FlutterSearchMatch(
          unit: BigInt.from(2),
          offset: BigInt.from(8),
          length: BigInt.from(5),
          context: 'river mouth',
        ),
      ]);
      await tester.pump();
      await _settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      // The pinned reference navigates to the first result on completion.
      expect(find.text('Chapter 2 · 67%'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-search-next')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('Chapter 3 · 100%'), findsOneWidget);

      // Stepping wraps.
      await tester.tap(find.byKey(const ValueKey('reader-search-next')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-search-previous')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('no matches is distinct from idle and close cancels', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-search')));
      await tester.pump();
      await _settle(tester);

      await tester.enterText(
        find.byKey(const ValueKey('reader-search-input')),
        'nothing',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      bridge.searchCompletions.single.complete(const []);
      await tester.pump();
      await _settle(tester);
      expect(find.text('No results'), findsOneWidget);

      // A second query in flight, then close: the close stays enabled and
      // cancels the search.
      await tester.enterText(
        find.byKey(const ValueKey('reader-search-input')),
        'still nothing',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(bridge.searchCompletions, hasLength(2));
      await tester.tap(find.byKey(const ValueKey('reader-search-close')));
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('reader-search-input')), findsNothing);
      expect(bridge.events, contains('cancel'));

      // The stale completion cannot publish results into the closed bar.
      bridge.searchCompletions.last.complete([
        FlutterSearchMatch(
          unit: BigInt.zero,
          offset: BigInt.zero,
          length: BigInt.one,
          context: 'stale',
        ),
      ]);
      await _settle(tester);
      expect(find.text('1 / 1'), findsNothing);
    });

    testWidgets('a failed search reports through the guarded error path', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _openMore(tester);
      await tester.tap(find.byKey(const ValueKey('reader-more-search')));
      await tester.pump();
      await _settle(tester);

      await tester.enterText(
        find.byKey(const ValueKey('reader-search-input')),
        'boom',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      bridge.searchCompletions.single.completeError(
        StateError('search backend failed'),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.textContaining('search backend failed'), findsOneWidget);
      expect(find.text('No results'), findsNothing);
    });
  });
}
