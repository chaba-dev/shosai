import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/production_shell_harness.dart';

/// Package 4C reader-panel renders.
///
/// Every state renders the production shell through the shared harness, runs
/// the geometry detectors and captures an artifact for inspection. These are
/// **candidate** renders for owner approval: the file deliberately does not
/// compare them with a committed baseline, because accepting a reader baseline
/// is the owner's decision, not 4C's.
///
/// The Contents entries and progress ordinals are fixture-injected
/// presentation data (contract §2.2); the saved places, export, search and
/// open-book paths run through the real controller and the harness bridge.
class _PanelRenderBridge extends HarnessBridge {
  _PanelRenderBridge({super.books, super.unitCount, this.bookmarks = const []});

  final List<FlutterBookmark> bookmarks;
  List<FlutterAnnotation> annotations = const [];

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => annotations;

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) async => bookmarks;

  @override
  Future<String> exportBookmarks({required int bookId}) async =>
      '# Bookmarks\n\n- Pg 1\n';

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  }) async => [
    FlutterSearchMatch(
      unit: BigInt.zero,
      offset: BigInt.from(4),
      length: BigInt.from(5),
      context: 'the survey began',
    ),
    FlutterSearchMatch(
      unit: BigInt.one,
      offset: BigInt.from(8),
      length: BigInt.from(5),
      context: 'the tide turned',
    ),
  ];
}

const _settings = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
  zonesHintDismissed: true,
);

List<ReaderContentsEntry> _contentsEntries() => const [
  ReaderContentsEntry(depth: 0, title: 'Headwaters', unit: 0),
  ReaderContentsEntry(depth: 1, title: 'The Long Meander', unit: 1),
  ReaderContentsEntry(depth: 1, title: 'Floodplains', unit: 2),
  ReaderContentsEntry(depth: 2, title: 'The estuary at first light', unit: 3),
  ReaderContentsEntry(
    depth: 0,
    title: 'A deliberately long chapter title',
    unit: 4,
  ),
];

/// The reference's chapter-fallback and truncation fixture in Japanese.
List<ReaderContentsEntry> _contentsEntriesJa() => const [
  ReaderContentsEntry(depth: 0, title: '一 湖の記録', unit: 0),
  ReaderContentsEntry(depth: 1, title: '二 砂の記録', unit: 1),
  ReaderContentsEntry(depth: 0, title: '三 乾いた手紙', unit: 2),
  ReaderContentsEntry(depth: 0, unit: 3),
];

Widget _reader({
  required HarnessBridge bridge,
  Locale? locale,
  String? initialPath = '/books/quiet-cartographer.epub',
  int? initialBookId,
  ReaderContentsLoader? contentsLoader,
  ReaderProgressSource? progressSource,
}) => productionShell(
  locale: locale,
  home: ReaderScreen(
    bridge: bridge,
    initialPath: initialPath,
    initialBookId: initialBookId,
    initialSettings: _settings,
    contentsLoader: contentsLoader,
    progressSource: progressSource,
  ),
);

bool _chromeReady(WidgetTester tester) {
  if (!harnessReaderPageReady(tester)) return false;
  final contents = find.byKey(const ValueKey('reader-header-contents'));
  if (contents.evaluate().isEmpty) return false;
  return tester
      .widget<ShadButton>(
        find.descendant(of: contents, matching: find.byType(ShadButton)),
      )
      .enabled;
}

Future<void> _openPanel(WidgetTester tester, String name) async {
  await revealReaderChrome(tester);
  await tester.tap(find.byKey(ValueKey('reader-header-$name')));
  await pumpHarnessFrames(tester, frames: 4);
}

void main() {
  setUpAll(loadHarnessFonts);

  Future<void> render(
    WidgetTester tester,
    String name,
    HarnessView view,
    Widget widget, {
    required bool Function() ready,
    Map<String, Object?> metadata = const {},
  }) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    view.apply(tester);
    await renderHarnessState(tester, widget, ready: ready);
    await revealReaderChrome(tester);
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      name,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        ...metadata,
        ...harnessPlatformMetrics(),
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expect(
      recorder.overflowErrors,
      isEmpty,
      reason: 'Flutter reported a layout overflow in $name',
    );
    expect(tester.takeException(), isNull);
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  }

  testWidgets('contents panel with saved places (EN, wide)', (tester) async {
    final bridge = _PanelRenderBridge(
      books: harnessLibraryBooks(),
      unitCount: 5,
      bookmarks: [
        FlutterBookmark(
          id: 1,
          bookId: 1,
          unit: BigInt.zero,
          color: 'yellow',
          createdAt: '2026-09-20T00:00:00Z',
        ),
        FlutterBookmark(
          id: 2,
          bookId: 1,
          unit: BigInt.from(2),
          color: 'yellow',
          createdAt: '2026-09-20T00:00:00Z',
        ),
      ],
    );
    await render(
      tester,
      'reader-contents-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: bridge,
        locale: const Locale('en'),
        initialBookId: 1,
        contentsLoader: (_) async => _contentsEntries(),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready'},
    );
    await _openPanel(tester, 'contents');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-contents-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'entries': 'fixture: 5 entries (5E owns the real TOC)',
        'savedPlaces': 'fixture: 2 saved places (persistence is live)',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('contents panel (JA, compact)', (tester) async {
    final bridge = _PanelRenderBridge(
      books: harnessLibraryBooks(),
      unitCount: 4,
      bookmarks: [
        FlutterBookmark(
          id: 1,
          bookId: 1,
          unit: BigInt.zero,
          color: 'yellow',
          createdAt: '2026-09-20T00:00:00Z',
        ),
      ],
    );
    await render(
      tester,
      'reader-contents-390-ja',
      const HarnessView(size: Size(390, 844)),
      _reader(
        bridge: bridge,
        locale: const Locale('ja'),
        initialBookId: 1,
        contentsLoader: (_) async => _contentsEntriesJa(),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready', 'chrome': 'compact'},
    );
    await _openPanel(tester, 'contents');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-contents-open-390-ja',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'chrome': 'compact',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('contents panel (JA, compact, 200% text)', (tester) async {
    final bridge = _PanelRenderBridge(
      books: harnessLibraryBooks(),
      unitCount: 4,
      bookmarks: [
        FlutterBookmark(
          id: 1,
          bookId: 1,
          unit: BigInt.zero,
          color: 'yellow',
          createdAt: '2026-09-20T00:00:00Z',
        ),
      ],
    );
    await render(
      tester,
      'reader-contents-390-ja-t200',
      const HarnessView(size: Size(390, 844), textScale: 2),
      _reader(
        bridge: bridge,
        locale: const Locale('ja'),
        initialBookId: 1,
        contentsLoader: (_) async => _contentsEntriesJa(),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready', 'textScale': 2},
    );
    await _openPanel(tester, 'contents');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-contents-open-390-ja-t200',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'textScale': 2,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('contents empty state (EN, wide)', (tester) async {
    // A document whose Contents loader returns no entries (no chapters and no
    // saved places); the production fallback derives one entry per logical
    // unit, so this state is reached through the fixture loader (5E owns the
    // real TOC).
    final bridge = _PanelRenderBridge(
      books: harnessLibraryBooks(),
      unitCount: 3,
    );
    await render(
      tester,
      'reader-contents-empty-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: bridge,
        locale: const Locale('en'),
        initialBookId: 1,
        contentsLoader: (_) async => const [],
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'empty'},
    );
    await _openPanel(tester, 'contents');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-contents-empty-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'empty': 'no chapters and no saved places',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('contents loading state (EN, wide)', (tester) async {
    final bridge = _PanelRenderBridge(
      books: harnessLibraryBooks(),
      unitCount: 3,
    );
    final pending = Completer<List<ReaderContentsEntry>>();
    await render(
      tester,
      'reader-contents-loading-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: bridge,
        locale: const Locale('en'),
        initialBookId: 1,
        contentsLoader: (_) => pending.future,
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'loading'},
    );
    await _openPanel(tester, 'contents');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-contents-loading-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'loading': 'the fixture loader is still pending',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    pending.complete(const []);
    await pumpHarnessFrames(tester, frames: 2);
  });

  testWidgets('contents failure state (EN, wide)', (tester) async {
    final bridge = _PanelRenderBridge(
      books: harnessLibraryBooks(),
      unitCount: 3,
    );
    await render(
      tester,
      'reader-contents-failed-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: bridge,
        locale: const Locale('en'),
        initialBookId: 1,
        contentsLoader: (_) async =>
            throw StateError('chapter index unavailable'),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'failed'},
    );
    await _openPanel(tester, 'contents');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-contents-failed-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'contents',
        'failure': 'fixture loader error: chapter index unavailable',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('typography panel for EPUB (EN, wide)', (tester) async {
    await render(
      tester,
      'reader-typography-epub-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _PanelRenderBridge(books: harnessLibraryBooks(), unitCount: 3),
        locale: const Locale('en'),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready'},
    );
    await _openPanel(tester, 'typography');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-typography-epub-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'typography',
        'mode': 'EPUB (font size, line spacing, theme)',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('typography panel for PDF (EN, wide)', (tester) async {
    await render(
      tester,
      'reader-typography-pdf-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _PanelRenderBridge(books: harnessLibraryBooks(), unitCount: 3),
        locale: const Locale('en'),
        initialPath: '/books/atlas.pdf',
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready'},
    );
    await _openPanel(tester, 'typography');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-typography-pdf-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'typography',
        'mode': 'PDF (zoom, fit width/page)',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('typography panel (JA, compact, 200% text)', (tester) async {
    await render(
      tester,
      'reader-typography-390-ja-t200',
      const HarnessView(size: Size(390, 844), textScale: 2),
      _reader(
        bridge: _PanelRenderBridge(books: harnessLibraryBooks(), unitCount: 3),
        locale: const Locale('ja'),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready', 'textScale': 2},
    );
    await _openPanel(tester, 'typography');
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-typography-open-390-ja-t200',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'typography',
        'textScale': 2,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('notes panel (EN, wide and compact)', (tester) async {
    await render(
      tester,
      'reader-notes-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _withNotes(
          _PanelRenderBridge(books: harnessLibraryBooks(), unitCount: 4),
          ja: false,
        ),
        locale: const Locale('en'),
        initialBookId: 1,
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready'},
    );
    await _openPanel(tester, 'notes');
    var defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-notes-open-1280-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'notes',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

    // On a phone the docked panel becomes a bottom sheet.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await pumpHarnessFrames(tester, frames: 2);
    defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-notes-open-390-en',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'notes',
        'chrome': 'compact',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('notes panel and search bar (JA, compact, 200% text)', (
    tester,
  ) async {
    await render(
      tester,
      'reader-notes-390-ja-t200',
      const HarnessView(size: Size(390, 844), textScale: 2),
      _reader(
        bridge: _withNotes(
          _PanelRenderBridge(books: harnessLibraryBooks(), unitCount: 4),
          ja: true,
        ),
        locale: const Locale('ja'),
        initialBookId: 1,
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready', 'textScale': 2},
    );
    await _openPanel(tester, 'notes');
    var defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-notes-open-390-ja-t200',
      metadata: <String, Object?>{
        'state': 'panel-open',
        'panel': 'notes',
        'textScale': 2,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

    // Close the sheet, then search from the toolbar.
    await _openPanel(tester, 'notes');
    await tester.tap(find.byKey(const ValueKey('reader-header-search')));
    await pumpHarnessFrames(tester, frames: 2);
    await tester.enterText(
      find.byKey(const ValueKey('reader-search-input')),
      'の',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpHarnessFrames(tester, frames: 4);
    defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-search-results-390-ja-t200',
      metadata: <String, Object?>{
        'state': 'results',
        'textScale': 2,
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('search bar with results (EN, wide and compact)', (tester) async {
    await render(
      tester,
      'reader-search-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _PanelRenderBridge(books: harnessLibraryBooks(), unitCount: 4),
        locale: const Locale('en'),
        initialBookId: 1,
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'ready'},
    );
    await tester.tap(find.byKey(const ValueKey('reader-header-search')));
    await pumpHarnessFrames(tester, frames: 2);
    await tester.enterText(
      find.byKey(const ValueKey('reader-search-input')),
      'the',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpHarnessFrames(tester, frames: 4);
    var defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-search-results-1280-en',
      metadata: <String, Object?>{
        'state': 'results',
        'count': '2 fixture matches (5G owns live highlights)',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await pumpHarnessFrames(tester, frames: 2);
    defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-search-results-390-en',
      metadata: <String, Object?>{
        'state': 'results',
        'chrome': 'compact',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });
}

/// [bridge] with a book note, a page note and a highlight with its note, so
/// the Notes panel renders each kind of card.
_PanelRenderBridge _withNotes(_PanelRenderBridge bridge, {required bool ja}) {
  FlutterNote note(String id, BigInt? unit, String body) => FlutterNote(
    id: id,
    kind: unit == null ? FlutterNoteKind.book : FlutterNoteKind.page,
    unit: unit,
    resolution: FlutterAnnotationResolution.exact,
    body: body,
    modifiedAt: '2026-09-20T00:00:00Z',
  );
  bridge.placeNotes.addAll([
    note(
      'book',
      null,
      ja
          ? '読書会の課題。第三章と第四章から読む。'
          : 'Reading group pick. Chapters III and IV first.',
    ),
    note(
      'page',
      BigInt.one,
      ja
          ? '図1はこの後のすべての節が参照するモデル。'
          : 'Fig. 1 is the model every later section refers back to.',
    ),
  ]);
  bridge.annotations = [
    FlutterAnnotation(
      id: 'highlight',
      unit: BigInt.two,
      resolution: FlutterAnnotationResolution.exact,
      textRange: FlutterAnnotationTextRange(
        start: BigInt.zero,
        end: BigInt.from(40),
      ),
      quote: ja
          ? '海辺の図書館には、古い地図と潮の記録が並んでいた。'
          : 'The library by the sea kept old maps beside the records of the '
                'tides.',
      color: FlutterHighlightColor.yellow,
      body: ja ? '地図の章へのつながり。' : 'The link to the chapter on maps.',
    ),
  ];
  return bridge;
}
