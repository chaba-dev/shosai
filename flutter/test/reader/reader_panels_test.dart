import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/notices/notices.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/bridge_pdf_engine.dart';
import '../support/production_shell_harness.dart';

/// The reader panels: Contents with its page field, Display settings, Notes
/// with the saved places, the toolbar's bookmark and search, and the open-book
/// shortcut (rows RD-07…RD-11).
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

  /// The book's highlights, as the Notes panel lists them.
  List<FlutterAnnotation> annotations = const [];

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => annotations;

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

/// [text] inside the open Contents panel; the toolbar and the status line
/// also name the current section.
Finder _inContents(String text) => find.descendant(
  of: find.byKey(const ValueKey('reader-panel-contents')),
  matching: find.text(text),
);

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

Future<void> _openNotes(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-header-notes')));
  await tester.pump();
  await _settle(tester);
}

/// Ctrl+O, the open-book shortcut that replaced the more panel's action.
Future<void> _pressOpenBook(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Whether the chrome takes new actions; an open modal (a picker or a note
/// editor) gates it.
bool _chromeEnabled(WidgetTester tester) => tester
    .widget<ShadButton>(
      find.descendant(
        of: find.byKey(const ValueKey('reader-header-contents')),
        matching: find.byType(ShadButton),
      ),
    )
    .enabled;

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
      expect(_inContents('Headwaters'), findsOneWidget);
      expect(_inContents('The Long Meander'), findsOneWidget);
      // The untitled entry renders the localized chapter fallback, not an
      // invented title (contract §4.6).
      expect(find.text('Chapter 4'), findsOneWidget);
      // A long title wraps to a second line and ellipsizes there.
      final long = tester.widget<Text>(
        find.textContaining('A deliberately long chapter title'),
      );
      expect(long.maxLines, 2);
      expect(long.overflow, TextOverflow.ellipsis);
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
      expect(find.text('50% · chapter 2 of 4'), findsOneWidget);
    });

    testWidgets('a short window at 200% text scrolls the whole panel and '
        'keeps the page field and close reachable', (tester) async {
      _setView(tester, const Size(1280, 480));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final bridge = _PanelBridge(unitCount: 12);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          contentsLoader: (_) async => [
            for (var unit = 0; unit < 12; unit += 1)
              ReaderContentsEntry(depth: 0, title: 'Chapter $unit', unit: unit),
          ],
        ),
      );
      await _openContents(tester);
      expect(tester.takeException(), isNull);

      // An invalid page adds the error under the field.
      final input = find.byKey(const ValueKey('reader-page-input'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '99');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final error = find.byKey(const ValueKey('reader-page-input-error'));
      await tester.ensureVisible(error);
      await tester.pump();
      expect(tester.getRect(error).bottom, lessThanOrEqualTo(480));

      // The keyboard takes a third of the window.
      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(input);
      await tester.pump();
      expect(tester.getRect(input).bottom, lessThanOrEqualTo(480 - 160));

      final close = find.byKey(const ValueKey('reader-contents-close'));
      await tester.ensureVisible(close);
      await tester.pump();
      await tester.tap(close);
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('reader-panel-contents')), findsNothing);
      expect(tester.takeException(), isNull);
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
      await _openContents(tester);

      // A new open through the shortcut replaces the document generation
      // while the first load is still pending; the new document starts its own
      // load.
      await _pressOpenBook(tester);
      await _settle(tester, frames: 6);
      expect(completers, hasLength(2));

      // The stale completion must not publish entries for the new document.
      completers.first.complete(_fixtureEntries());
      await _settle(tester);

      await _openContents(tester);
      completers.last.complete(const [
        ReaderContentsEntry(depth: 0, title: 'Replacement chapter', unit: 0),
      ]);
      await _settle(tester);
      expect(_inContents('Replacement chapter'), findsOneWidget);
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
      await _openNotes(tester);

      expect(find.text('BOOKMARKS · 1'), findsOneWidget);
      expect(find.text('A short note'), findsOneWidget);
      expect(find.text('Edit note'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reader-saved-place-delete-7')),
      );
      await tester.pump();
      await _settle(tester);
      expect(bridge.deletes, [7]);
      expect(find.text('No bookmarks yet'), findsOneWidget);
      expect(find.text('BOOKMARKS · 0'), findsOneWidget);
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
      await _openNotes(tester);

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
      await _openNotes(tester);

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
            tester.element(find.byKey(const ValueKey('reader-panel-notes'))),
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
      await _openNotes(tester);

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
      await _pressOpenBook(tester);
      expect(pickers, hasLength(1));
      expect(
        _chromeEnabled(tester),
        isFalse,
        reason: 'the picker owns the modal',
      );

      // Suspension invalidates the picker: the slot is released by the
      // transition, not by a completion that would be rejected as stale.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await _settle(tester, frames: 6);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _settle(tester, frames: 6);

      expect(
        _chromeEnabled(tester),
        isTrue,
        reason: 'the modal slot was retired',
      );
      await _pressOpenBook(tester);
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
        _chromeEnabled(tester),
        isFalse,
        reason: 'the new picker still owns it',
      );

      pickers.last.complete(null);
      await tester.pump();
      await _settle(tester);
      expect(_chromeEnabled(tester), isTrue);
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
      await _openNotes(tester);
      await tester.tap(find.byKey(const ValueKey('reader-bookmark-export')));
      await tester.pump();
      expect(bridge.heldExports, hasLength(1));

      // Replace the document while the export is pending.
      await _pressOpenBook(tester);
      await _settle(tester, frames: 6);
      expect(find.text('umibe.epub'), findsOneWidget);

      bridge.heldExports.first.complete('# stale book');
      await tester.pump();
      await _settle(tester);
      expect(sinkTexts, isEmpty);

      // The replacement's own export still works.
      if (find.byKey(const ValueKey('reader-panel-notes')).evaluate().isEmpty) {
        await _openNotes(tester);
      }
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

      // Move to a late unit through the Contents page field while the load is
      // still pending.
      await _openContents(tester);
      await tester.enterText(
        find.byKey(const ValueKey('reader-page-input')),
        '25',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump();
      await _settle(tester, frames: 6);
      expect(completers, hasLength(1));
      // Choosing a page closed Contents; opening it again reuses the pending
      // load.
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
    testWidgets('EPUB shows text size, line spacing and page theme with '
        'clamps', (tester) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(
          bridge: bridge,
          settings: const FlutterReaderSettings(
            continuous: false,
            theme: 'light',
            epubFontSize: 27,
            epubLineSpacing: 1.6,
            pdfZoom: 0,
          ),
        ),
      );
      await _openTypography(tester);

      // Text size is a share of the 18 px default.
      expect(find.text('150%'), findsOneWidget);
      expect(find.text('1.6×'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-typography-fit-page')),
        findsNothing,
        reason: 'an EPUB has no raster fit controls',
      );
      ShadButton button(String key) => tester.widget<ShadButton>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(ShadButton),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('reader-typography-font-increase')),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.text('160%'), findsOneWidget);

      // 160 % is the largest size: the step is disabled there.
      expect(button('reader-typography-font-increase').enabled, isFalse);
      expect(button('reader-typography-font-decrease').enabled, isTrue);

      // Line spacing steps through the pinned settings values.
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-line-spacing-increase')),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.text('1.8×'), findsOneWidget);

      // The page theme is one of three tiles; the chosen one is selected.
      bool selected(String theme) =>
          tester
              .getSemantics(
                find.byKey(ValueKey('reader-typography-theme-$theme')),
              )
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue;
      expect(selected('light'), isTrue);
      expect(find.text('Paper'), findsOneWidget);
      expect(find.text('Sepia'), findsOneWidget);
      expect(find.text('Night'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('reader-typography-theme-dark')),
      );
      await tester.pump();
      await _settle(tester);
      expect(selected('dark'), isTrue);
      expect(selected('light'), isFalse);
    });

    testWidgets('the page themes and the progress track work from the '
        'keyboard and assistive technology', (tester) async {
      _setView(tester, const Size(1280, 800));
      final semantics = tester.ensureSemantics();
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _openTypography(tester);

      // A theme tile takes focus and activates on Enter and Space.
      FocusNode focusOf(Finder finder) => Focus.of(
        tester.element(
          find.descendant(of: finder, matching: find.byType(GestureDetector)),
        ),
      );
      bool selected(String theme) =>
          tester
              .getSemantics(
                find.byKey(ValueKey('reader-typography-theme-$theme')),
              )
              .getSemanticsData()
              .flagsCollection
              .isSelected ==
          ui.Tristate.isTrue;
      final night = focusOf(
        find.byKey(const ValueKey('reader-typography-theme-dark')),
      );
      expect(night.canRequestFocus, isTrue);
      night.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await _settle(tester);
      expect(selected('dark'), isTrue);
      // The focus ring is 2 px of accent, 2 px outside the tile.
      final ring = find.byKey(const ValueKey('reader-focus-ring'));
      expect(ring, findsOneWidget);
      expect(
        tester.getRect(ring),
        tester
            .getRect(find.byKey(const ValueKey('reader-typography-theme-dark')))
            .inflate(4),
      );
      final border =
          (tester.widget<DecoratedBox>(ring).decoration as BoxDecoration)
                  .border!
              as Border;
      expect(border.top.width, 2);
      focusOf(
        find.byKey(const ValueKey('reader-typography-theme-sepia')),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await _settle(tester);
      expect(selected('sepia'), isTrue);
      await _openTypography(tester);

      // The progress track is a slider: its value is the place, the arrow
      // keys step one unit, and so do the semantic actions.
      final trackFinder = find.byKey(const ValueKey('reader-progress-track'));
      String value() => tester.getSemantics(trackFinder).value;
      final opening = value();
      expect(tester.getSemantics(trackFinder).label, 'Reading progress');
      // The track spans the status line between the section and the place.
      expect(tester.getSize(trackFinder).width, greaterThan(200));
      expect(opening, contains('of 3'));
      Focus.of(tester.element(trackFinder)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await _settle(tester);
      expect(
        tester.getRect(find.byKey(const ValueKey('reader-focus-ring'))),
        tester.getRect(trackFinder).inflate(4),
      );
      final stepped = value();
      expect(stepped, isNot(opening));
      tester.binding.performSemanticsAction(
        ui.SemanticsActionEvent(
          type: ui.SemanticsAction.decrease,
          viewId: tester.view.viewId,
          nodeId: tester.getSemantics(trackFinder).id,
        ),
      );
      await tester.pump();
      await _settle(tester);
      expect(value(), opening);
      semantics.dispose();
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

      // A spread renders both of its pages.
      for (final render in bridge.heldRenders) {
        render.complete();
      }
      await tester.pump();
      await _settle(tester);
      expect(button().enabled, isTrue);
    });
  });

  group('notes panel', () {
    testWidgets('highlight cards keep their size at 200% text and wrap '
        'their actions inside the panel', (tester) async {
      _setView(tester, const Size(1024, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final bridge = _PanelBridge(unitCount: 3)
        ..annotations = [
          for (final (id, resolution) in [
            ('exact', FlutterAnnotationResolution.exact),
            ('orphaned', FlutterAnnotationResolution.orphaned),
          ])
            FlutterAnnotation(
              id: id,
              unit: BigInt.one,
              resolution: resolution,
              color: FlutterHighlightColor.yellow,
            ),
        ];
      await _open(tester, _reader(bridge: bridge));
      await _openNotes(tester);

      final panel = tester.getRect(
        find.byKey(const ValueKey('reader-panel-notes')),
      );
      for (final id in ['exact', 'orphaned']) {
        final card = find.byKey(ValueKey('reader-annotation-$id'));
        expect(card, findsOneWidget);
        final cardRect = tester.getRect(card);
        expect(cardRect.left, greaterThanOrEqualTo(panel.left));
        expect(cardRect.right, lessThanOrEqualTo(panel.right));
        // Painted at its laid-out size: nothing scales the card down.
        for (final action in ['navigate', 'color', 'note', 'delete']) {
          final finder = find.byKey(ValueKey('reader-annotation-$action-$id'));
          expect(
            tester.getRect(finder).size,
            tester.getSize(finder),
            reason: '$action of $id is drawn at its own size',
          );
        }
      }
      // The scaled label pushes the actions under it.
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey('reader-annotation-delete-orphaned')),
            )
            .top,
        greaterThanOrEqualTo(
          tester
              .getRect(
                find.byKey(
                  const ValueKey('reader-annotation-navigate-orphaned'),
                ),
              )
              .bottom,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('panel modality', () {
    bool focusInStage(WidgetTester tester) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return false;
      final stage = tester.element(find.byKey(const ValueKey('reader-stage')));
      var inside = identical(context, stage);
      context.visitAncestorElements((ancestor) {
        if (identical(ancestor, stage)) inside = true;
        return !inside;
      });
      return inside;
    }

    /// Whether the live semantics tree exposes the page's text.
    bool documentText(WidgetTester tester) {
      var found = false;
      bool visit(SemanticsNode node) {
        if (node.label.startsWith('Document text')) found = true;
        if (!found) node.visitChildren(visit);
        return !found;
      }

      visit(
        tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!,
      );
      return found;
    }

    for (final (name, size, open) in [
      ('a tablet Notes slide-over', const Size(1024, 800), _openNotes),
      ('a desktop Contents popover', const Size(1280, 800), _openContents),
      ('a phone Notes sheet', const Size(390, 800), _openNotes),
    ]) {
      testWidgets('$name takes the page out of focus and semantics', (
        tester,
      ) async {
        _setView(tester, size);
        final semantics = tester.ensureSemantics();
        final bridge = _PanelBridge(unitCount: 3);
        await _open(
          tester,
          _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
        );
        expect(documentText(tester), isTrue);
        await open(tester);

        expect(documentText(tester), isFalse);
        for (var press = 0; press < 30; press += 1) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(focusInStage(tester), isFalse, reason: 'Tab press $press');
        }
        semantics.dispose();
      });
    }

    testWidgets('a note chosen in the slide-over keeps focus in the panel, '
        'and Escape closes it', (tester) async {
      _setView(tester, const Size(1024, 800));
      final bridge = _PanelBridge(
        unitCount: 3,
        bookmarks: [_bookmark(id: 7, unit: BigInt.two)],
      );
      await _open(
        tester,
        _reader(
          bridge: bridge,
          initialPath: '/books/atlas.pdf',
          initialBookId: 1,
        ),
      );
      await _openNotes(tester);
      await tester.tap(find.byKey(const ValueKey('reader-saved-place-open-7')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('100% · page 3 of 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-panel-notes')), findsOneWidget);
      expect(focusInStage(tester), isFalse);
      expect(FocusManager.instance.primaryFocus, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await _settle(tester);
      expect(find.byKey(const ValueKey('reader-panel-notes')), findsNothing);
    });

    testWidgets('the docked desktop Notes panel leaves the page reachable', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final semantics = tester.ensureSemantics();
      final bridge = _PanelBridge(unitCount: 3);
      await _open(
        tester,
        _reader(bridge: bridge, initialPath: '/books/atlas.pdf'),
      );
      await _openNotes(tester);
      expect(documentText(tester), isTrue);
      var reached = false;
      for (var press = 0; press < 40 && !reached; press += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        reached = focusInStage(tester);
      }
      expect(reached, isTrue);
      semantics.dispose();
    });
  });

  group('page field, bookmark and open book', () {
    testWidgets('the page field validates and converts the 1-based ordinal', (
      tester,
    ) async {
      _setView(tester, const Size(1280, 800));
      final bridge = _PanelBridge(unitCount: 3);
      await _open(tester, _reader(bridge: bridge));
      await _openContents(tester);

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
      expect(find.text('67% · chapter 2 of 3'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-page-input-error')),
        findsNothing,
      );
      // Choosing a page closes Contents.
      expect(find.byKey(const ValueKey('reader-panel-contents')), findsNothing);
      await _openContents(tester);

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
      expect(find.text('67% · chapter 2 of 3'), findsOneWidget);

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
      SemanticsData bookmark() => tester
          .getSemantics(find.byKey(const ValueKey('reader-header-bookmark')))
          .getSemanticsData();

      expect(bookmark().label, 'Bookmark this page');
      await tester.tap(find.byKey(const ValueKey('reader-header-bookmark')));
      await tester.pump();
      await _settle(tester);
      expect(bridge.toggles, [(0, null)]);
      // The bookmarks reloaded with the created entry, so the toggle now
      // reports the saved state.
      expect(bookmark().label, 'Remove bookmark');
      expect(bookmark().flagsCollection.isSelected, ui.Tristate.isTrue);
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
      await _pressOpenBook(tester);
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
      await _pressOpenBook(tester);
      await _settle(tester);
      expect(calls, 1);
      // The original document stays open and no error is reported.
      expect(find.text('slow-rivers.epub'), findsOneWidget);
      expect(find.byKey(const ValueKey('reader-tool-error')), findsNothing);
      expect(
        _chromeEnabled(tester),
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
      await tester.tap(find.byKey(const ValueKey('reader-header-search')));
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
      expect(find.text('67% · chapter 2 of 3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reader-search-next')));
      await tester.pump();
      await _settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('100% · chapter 3 of 3'), findsOneWidget);

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
      await tester.tap(find.byKey(const ValueKey('reader-header-search')));
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
      await tester.tap(find.byKey(const ValueKey('reader-header-search')));
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
