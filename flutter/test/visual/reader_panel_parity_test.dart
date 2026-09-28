import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

import '../support/production_shell_harness.dart';

/// Package 4C **matched-state parity evidence** (RD-07…RD-11).
///
/// Each capture reproduces a committed 1C reference state with the same fixture
/// bytes, locale, viewport, DPR, panel, location and bookmark state, renders it
/// through the production shell **and the real Rust bridge**, and compares
/// measurable panel geometry with the reference image using the same ink-profile
/// algorithm on both sides. The reference ids, fixture paths and their SHA-256
/// are recorded per capture in the artifact metadata; the fixture bytes are the
/// committed 1C evidence files, opened by reference (never copied or modified).
///
/// Known, disclosed capability gaps (not hidden by the comparison):
/// - the Flutter reader renders the real Rust chapter surface, but it has no
///   paginated page box, spread, page footer or page number yet: those are
///   Stage 5 (5A/5B/5G/5H) capabilities, so the document area is not compared
///   with the reference's page composition;
/// - a document that declares no font faces gets only the rasterizer's math
///   fallback: Latin text paints legibly, Japanese text paints missing-glyph
///   boxes. The missing capability is document fallback-font coverage for CJK
///   (typography.md keeps the book-content role separate from interface fonts),
///   owned by 5C; the captures keep the truthful output;
/// - Contents entries, the tab list and the progress ordinals are
///   fixture-injected presentation data in Stage 4 (no TOC/session/pagination
///   DTO): 5E/5F/5G own the real sources. The fixtures reproduce the reference
///   document's own chapter titles and the reference manifest's page facts so
///   the chrome comparison is like-for-like;
/// - the note editor is a controller-injected dialog in Flutter (contract §4.7)
///   where Iced edits the note inline in the panel.
void main() {
  final supported = Platform.isLinux || Platform.isMacOS;

  setUpAll(() async {
    if (!supported) return;
    await loadHarnessFonts();
    final library = Platform.isMacOS
        ? '../target/debug/libshosai_flutter_bridge.dylib'
        : '../target/debug/libshosai_flutter_bridge.so';
    await RustLib.init(externalLibrary: ExternalLibrary.open(library));
    parityDataDirectory = await Directory.systemTemp.createTemp(
      'shosai-4c-parity-',
    );
    parityDatabasePath = '${parityDataDirectory.path}/library.sqlite';
    final bridge = FlutterBridge.withDatabasePath(
      databasePath: parityDatabasePath,
    );
    final cancellation = bridge.createCancellation();
    try {
      final report = await bridge.importPaths(
        pathKeys: [
          for (final name in _fixtureNames)
            File('$_fixtureRoot/$name').absolute.path,
        ],
        managed: false,
        cancellationId: cancellation,
      );
      expect(report.imported, BigInt.from(_fixtureNames.length));
      final page = await bridge.libraryPage(
        limit: 50,
        offset: 0,
        cancellationId: cancellation,
      );
      for (final book in page.books) {
        bookIdsForTest[book.pathKey.split('/').last] = book.bookId;
        bookPathsForTest[book.pathKey.split('/').last] = book.pathKey;
      }
    } finally {
      bridge.releaseCancellation(id: cancellation);
      bridge.dispose();
    }
  });

  tearDownAll(() async {
    if (!supported) return;
    RustLib.dispose();
    await parityDataDirectory.delete(recursive: true);
  });

  testWidgets('the document ink check rejects a blank raster', (tester) async {
    // Negative controls for the assertion above, through the same measurement
    // path: opaque paper, a fully transparent raster (what an uninitialised
    // Rust page buffer looks like) and a transparent raster with one opaque
    // mark. Only the marked raster may measure ink.
    Future<int> inkOf(ui.Image image) async {
      final data = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      return _inkPixels(data.buffer.asUint8List());
    }

    final opaquePaper = (await tester.runAsync(
      () => _solidImage(const Color(0xFFFFFFFF)),
    ))!;
    expect(await inkOf(opaquePaper), 0, reason: 'opaque paper is not ink');
    opaquePaper.dispose();

    final transparent = (await tester.runAsync(
      () => _solidImage(const Color(0x00000000)),
    ))!;
    expect(
      await inkOf(transparent),
      0,
      reason: 'a fully transparent raster paints nothing',
    );
    transparent.dispose();

    final marked = (await tester.runAsync(_transparentImageWithMark))!;
    expect(
      await inkOf(marked),
      greaterThan(0),
      reason: 'a transparent raster with a mark paints ink',
    );
    marked.dispose();
  });

  for (final capture in _captures) {
    testWidgets('matched ${capture.id}', (tester) async {
      // Native bridge calls and image decoding only complete on the real event
      // loop, so every one of them runs inside a bounded `runAsync` window.
      final reference = (await tester.runAsync(
        () => _referenceCapture(capture.referenceId),
      ))!;
      // The reference identity: the manifest's own byte length and pixel size.
      // The SHA-256 stays the authoritative hash (verified by 1C and recorded
      // per capture below); this pins that this run read the same file.
      expect(
        reference.bytes,
        _manifestCaptureBytes(capture.referenceId),
        reason: 'the committed 1C capture ${capture.referenceId} is unmodified',
      );
      expect(reference.image.width, capture.size.width.round());
      expect(reference.image.height, capture.size.height.round());
      await tester.runAsync(() => _seedReaderState(capture));
      expect(
        File('$_fixtureRoot/${capture.fixture}').lengthSync(),
        _manifestFixtureBytes(capture.fixture),
        reason: 'the committed 1C fixture ${capture.fixture} is unmodified',
      );
      final view = HarnessView(size: capture.size);
      view.apply(tester);
      final recorder = RenderErrorRecorder.install();
      addTearDown(recorder.dispose);

      final bridge = FlutterBridge.withDatabasePath(
        databasePath: parityDatabasePath,
      );
      // The reader disposes this bridge when it is torn down, so it is only
      // released here if the reader never got that far.
      addTearDown(() {
        if (!bridge.isDisposed) bridge.dispose();
      });
      await renderHarnessState(
        tester,
        _reader(capture, bridge),
        ready: () => _ready(tester, capture),
        // These captures open real documents through the bridge, which is
        // heavier than the chrome renders the shared harness default was sized
        // for; the wait stays bounded and still fails rather than capturing a
        // half-loaded state.
        maxRounds: 16,
      );
      await _openPanel(tester, capture);
      await pumpHarnessFrames(tester, frames: 6);

      final defects = await findRenderDefects(tester);
      final geometry = _flutterGeometry(tester, capture);
      final spacing = _spacingComparison(capture, geometry);
      // The document check reads the Rust chapter raster itself, so chrome,
      // edge-navigation glyphs, the search bar or the note dialog's scrim can
      // never be mistaken for document content.
      final documentInk = await _documentBandInk(tester);
      Map<String, Object?>? deleteInk;
      // The note-editor capture shows the modal dialog over the panel, so its
      // crop would measure the scrim rather than the control.
      if (capture.bookmarkAt != null && !capture.noteEditor) {
        final cropPng = await _cropWidgetPng(
          tester,
          _savedPlaceControl('delete'),
        );
        deleteInk = _inkBox(
          (await tester.runAsync(() => decodeHarnessImage(cropPng)))!,
        );
        writeHarnessArtifact(
          '${capture.id}-delete-crop',
          cropPng,
          metadata: <String, Object?>{
            'purpose':
                'ink review of the saved-place delete control at 4x: the glyph '
                'must paint a legible mark, not a corrupted fragment',
            'widget': 'saved-place delete control',
            'inkBox': deleteInk,
            'accessibleLabel': 'Delete <saved-place title>',
          },
        );
      }
      await captureHarnessArtifact(
        tester,
        capture.id,
        metadata: <String, Object?>{
          ...view.toMetadata(),
          ...harnessPlatformMetrics(),
          'reference': capture.referenceId,
          'referenceSha256': capture.referenceSha256,
          'fixture': capture.fixture,
          'fixtureSha256': capture.fixtureSha256,
          'state': capture.stateDerivation,
          'fixturePresentation': capture.fixturePresentation,
          'documentCapability':
              'the document area is painted by the reader document renderer '
              '(the Dart EPUB page window for a routed chapter, the retained '
              'Rust chapter surface otherwise); no page box/spread/footer '
              '(5A/5B/5G/5H). The retained rasterizer\'s disclosed CJK '
              'fallback gap (5C/FM-22) is what the Dart renderer closes for a '
              'routed chapter: it lays text out with the bundled document '
              'family, so Japanese text paints real glyphs instead of '
              'missing-glyph boxes',
          'referenceRow': capture.referenceRow,
          'flutterGeometry': geometry,
          'spacingComparison': spacing,
          'documentInkPixels': documentInk,
          'deleteInkBox': deleteInk,
          'defects': defects.map((defect) => defect.toMetadata()).toList(),
        },
      );
      expect(
        recorder.overflowErrors,
        isEmpty,
        reason: 'Flutter reported a layout overflow in ${capture.id}',
      );
      expect(tester.takeException(), isNull);
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);

      // Every capture in this suite is a loaded-document reference state, so
      // the document surface has to paint real Rust ink: a placeholder-only
      // capture cannot pass as parity evidence. (States that legitimately have
      // no document — welcome, opening, open failure — would be compared as
      // what they are instead.)
      expect(
        documentInk,
        greaterThan(0),
        reason: '${capture.id}: the document area rendered no ink',
      );

      // The panel composition against the pinned reference's own values, so a
      // re-inflated row or a changed gap fails here rather than being absorbed
      // by a rasterization tolerance.
      _expectSpacing(capture, spacing);

      if (deleteInk != null) {
        // Ink review, not just "no detector defect": the delete control has to
        // paint a legible mark and keep its accessible name.
        expect(
          deleteInk['width'],
          greaterThanOrEqualTo(20),
          reason: 'delete glyph ink width at 4x: ${deleteInk['width']}',
        );
        expect(
          deleteInk['height'],
          greaterThanOrEqualTo(20),
          reason: 'delete glyph ink height at 4x: ${deleteInk['height']}',
        );
        expect(
          deleteInk['inkPixels'],
          greaterThan(150),
          reason: 'delete glyph ink pixels: ${deleteInk['inkPixels']}',
        );
        expect(
          tester
              .widgetList<Semantics>(
                find.descendant(
                  of: _savedPlaceControl('delete'),
                  matching: find.byType(Semantics),
                ),
              )
              .map((semantics) => semantics.properties.label),
          contains('Delete Pg 2'),
          reason: 'the delete control keeps its accessible name',
        );
      }
      if (capture.noteEditor) {
        // The note editor is the controller-injected dialog (contract §4.7);
        // Iced edits the note inline in the panel, which the reference capture
        // shows and the metadata records as the deviation.
        expect(
          find.byKey(const ValueKey('reader-note-editor-field')),
          findsOneWidget,
          reason: 'the note editor opens as the controller-injected dialog',
        );
      }

      // Tear the reader down while the test still owns the real event loop, so
      // it releases its document handle (and any search work still finishing)
      // before the next capture opens one.
      await tester.pumpWidget(const SizedBox());
      await _settleNative(tester, rounds: 2);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Reference states
// ---------------------------------------------------------------------------

const _fixtureRoot =
    '../rfd/0004/evidence/reference-shots-1c/fixtures/library/featured';

const _fixtureNames = [
  'mizu-no-kioku.epub',
  'slow-rivers.epub',
  'small-atlas.pdf',
];

/// The reference documents' own chapter titles, reproduced as fixture entries
/// because Stage 4 has no TOC DTO (contract §4.6; 5E owns the real TOC).
const _mizuChapters = ['一 湖の記録', '二 砂の記録', '三 乾いた手紙'];
const _slowRiversChapters = [
  'Headwaters',
  'Meanders',
  'Floodplains',
  'Estuary',
];

final class _Capture {
  const _Capture({
    required this.id,
    required this.referenceId,
    required this.referenceSha256,
    required this.fixture,
    required this.fixtureSha256,
    required this.locale,
    required this.size,
    required this.panel,
    required this.stateDerivation,
    required this.fixturePresentation,
    required this.referenceRow,
    this.referenceRowHeight,
    this.unit = 0,
    this.bookmarkAt,
    this.searchQuery,
    this.progress,
    this.chapters = const [],
    this.noteEditor = false,
    this.compact = false,
    this.searchResultLabel,
    this.noteDraft,
  });

  final String id;
  final String referenceId;
  final String referenceSha256;
  final String fixture;
  final String fixtureSha256;
  final String locale;
  final Size size;
  final ReaderPanel panel;
  final String stateDerivation;
  final String fixturePresentation;

  /// The reference capture's own row/panel geometry, measured on the committed
  /// 1C PNG and cross-checked against the Iced source constants.
  final String referenceRow;

  /// The reference's rendered row height for the full-width rows
  /// (`reader_more_height` / `reader_search_height` / the settings row's
  /// content height); null for the side panel.
  final int? referenceRowHeight;
  final int unit;
  final int? bookmarkAt;
  final String? searchQuery;
  final ReaderProgressPresentation? progress;
  final List<String> chapters;
  final bool noteEditor;
  final bool compact;

  /// The settled result label the reference manifest records for a search
  /// capture (`1 / 16`); null when the capture has no search.
  final String? searchResultLabel;

  /// The draft text the pinned note-editor setup enters before capturing.
  final String? noteDraft;

  /// The left edge of the compared panel region; the document area is excluded.
  double get panelRegionLeft => panel == ReaderPanel.contents ? 900 : 0;
}

const _contentsJaSha =
    '4d60dd6408fe6258da18d4692550da3759b786345595b556b3ff8984e468a0ff';
const _savedPlaceSha =
    'dcb0d4185cbfc16d6c7ed141aee0549ea0f1d6e8bb991665a60cd752eebb3a53';
const _savedEmptySha =
    'f81362bca9c727cee45d17f32577c5c552ed28a4cf78dd379de95884db4f9be7';
const _noteEditorSha =
    '0bcae12cc5399ec4c2051930a6a61a3ceaa381895192a926d42095c31b5c2019';
const _typographyEpubSha =
    '872e21da864b4431a4462e38c86ce70bff2ca9e4ea8b8fb2f9fec9af67c17086';
const _typographyPdfSha =
    'a137cf9fde1d4f238df53a14a989abfc5f2a1cf143b59de4893c4f2800397ab9';
const _moreWideSha =
    'bc490a16562d94302659a3241ba761e33e2f00d84a14aca96d944dbb7e756095';
const _moreCompactSha =
    '367ff21d74a0eb19651cf7f6037518f1d40edc4bf652c4171981b1e9eb640d2a';
const _searchWideSha =
    'b94700059fa34d2ee5934ef3130197bec9043b0e364e580f170c19cc46c6994d';
const _searchCompactSha =
    'b02f79e5096a7c6a5bdd6cf3da64edeb55d0dcb2cc81c58ec5ddf1429b889ce1';

const _mizuSha =
    '6bb45dc565816a5af1323c77eb22e1a063dc503018d2ddfaa350705c3cf6f045';
const _slowRiversSha =
    'bee90fdac975f9be395dbcb86550d9494865c748d3ad99979712c72cc8fa2b12';
const _atlasSha =
    '77dae76187fb4e22fa7e11a1515001b4bc606e9097ded4f9357e6c761f20b734';

ReaderProgressPresentation _pages(int first, int last, int percentage) =>
    ReaderProgressPresentation(
      kind: last == first
          ? ReaderProgressKind.single
          : ReaderProgressKind.range,
      hasDocument: true,
      displayUnit: ReaderDisplayUnit.page,
      firstOrdinal: first,
      lastOrdinal: last == first ? null : last,
      percentage: percentage,
    );

final _captures = <_Capture>[
  _Capture(
    referenceRow:
        'Contents panel: left edge 981, top 91, heading ink 108, chapter pitch 37, no saved places',
    id: 'parity-contents-w1280-ja',
    referenceId: 'rd-panel-contents-w1280-ja',
    referenceSha256: _contentsJaSha,
    fixture: 'mizu-no-kioku.epub',
    fixtureSha256: _mizuSha,
    locale: 'ja',
    size: const Size(1280, 800),
    panel: ReaderPanel.contents,
    stateDerivation:
        'OpenLibraryBook(mizu-no-kioku.epub) at unit 0, contents open',
    fixturePresentation:
        '3 chapter entries (the reference document\'s own titles; 5E owns the TOC DTO), '
        'progress pages 1-2 / 33% (5G owns live ranges)',
    chapters: _mizuChapters,
    progress: _pages(1, 2, 33),
  ),
  _Capture(
    referenceRow:
        'Contents panel: left edge 981, top 91, chapter pitch 37, one saved-place entry 65 px tall',
    id: 'parity-saved-place-w1280-en',
    referenceId: 'rd-panel-saved-place-w1280-en',
    referenceSha256: _savedPlaceSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.contents,
    unit: 1,
    bookmarkAt: 1,
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at location 2 with one bookmark, contents open',
    fixturePresentation:
        '4 chapter entries, one saved place at unit 1 (persistence is live), '
        'progress pages 1-2 / 50%',
    chapters: _slowRiversChapters,
    progress: _pages(1, 2, 50),
  ),
  _Capture(
    referenceRow:
        'Contents panel: left edge 981, top 91, chapter pitch 37, empty state at 356 (18 px inset)',
    id: 'parity-saved-places-empty-w1280-en',
    referenceId: 'rd-panel-saved-places-empty-w1280-en',
    referenceSha256: _savedEmptySha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.contents,
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at location 1 with no bookmark, contents open',
    fixturePresentation:
        '4 chapter entries, no saved places, progress pages 1-2 / 25%',
    chapters: _slowRiversChapters,
    progress: _pages(1, 2, 25),
  ),
  _Capture(
    referenceRow:
        'Contents panel with the Iced inline note editor; Flutter opens the contract dialog instead',
    id: 'parity-note-editor-w1280-en',
    referenceId: 'rd-panel-note-editor-w1280-en',
    referenceSha256: _noteEditorSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.contents,
    unit: 1,
    bookmarkAt: 1,
    noteEditor: true,
    noteDraft: 'check the survey notes',
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at location 2 with one bookmark, note editor open with the reference draft text',
    fixturePresentation:
        '4 chapter entries, one saved place, the note editor (Flutter uses the '
        'controller-injected dialog where Iced edits inline), progress pages 1-2 / 50%',
    chapters: _slowRiversChapters,
    progress: _pages(1, 2, 50),
  ),
  _Capture(
    referenceRowHeight: 52,
    referenceRow:
        'typography row 89-142 (52 px rendered; the Iced page-box math reserves 62, app.rs:4390)',
    id: 'parity-typography-epub-w1280-en',
    referenceId: 'rd-panel-typography-epub-w1280-en',
    referenceSha256: _typographyEpubSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.typography,
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at unit 0, typography open',
    fixturePresentation: 'progress pages 1-2 / 25% (5G owns live ranges)',
    progress: _pages(1, 2, 25),
  ),
  _Capture(
    referenceRowHeight: 52,
    referenceRow:
        'typography row 89-142 (52 px rendered, raster zoom/fit controls)',
    id: 'parity-typography-pdf-w1280-en',
    referenceId: 'rd-panel-typography-pdf-w1280-en',
    referenceSha256: _typographyPdfSha,
    fixture: 'small-atlas.pdf',
    fixtureSha256: _atlasSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.typography,
    stateDerivation:
        'OpenLibraryBook(small-atlas.pdf) at unit 0, typography open',
    fixturePresentation: 'progress page 1 / 25% (5G owns live ranges)',
    progress: _pages(1, 1, 25),
  ),
  _Capture(
    referenceRowHeight: 58,
    referenceRow: 'more row 89-147 (58 px, reader_more_height wide)',
    id: 'parity-more-w1280-en',
    referenceId: 'rd-panel-more-w1280-en',
    referenceSha256: _moreWideSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.more,
    stateDerivation: 'OpenLibraryBook(slow-rivers.epub) at unit 0, more open',
    fixturePresentation: 'progress pages 1-2 / 25%',
    progress: _pages(1, 2, 25),
  ),
  _Capture(
    referenceRowHeight: 84,
    referenceRow: 'more row 93-175 (84 px, reader_more_height compact)',
    id: 'parity-more-c390-en',
    referenceId: 'rd-panel-more-c390-en',
    referenceSha256: _moreCompactSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(390, 844),
    panel: ReaderPanel.more,
    compact: true,
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at unit 0, more open, compact',
    fixturePresentation: 'progress page 1 / 25%',
    progress: _pages(1, 1, 25),
  ),
  _Capture(
    referenceRowHeight: 58,
    referenceRow:
        'more row 89-147 (58 px) plus the search bar 148-199 (52 px, reader_search_height wide)',
    id: 'parity-search-w1280-en',
    referenceId: 'rd-panel-search-w1280-en',
    referenceSha256: _searchWideSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(1280, 800),
    panel: ReaderPanel.more,
    searchQuery: 'the',
    searchResultLabel: '1 / 16',
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at unit 0, search open with the query `the` settled at 1 / 16',
    fixturePresentation:
        'the query runs through the real bridge search; progress pages 1-2 / 25%',
    progress: _pages(1, 2, 25),
  ),
  _Capture(
    referenceRowHeight: 84,
    referenceRow:
        'more row 93-175 (84 px) plus the search bar 176-263 (88 px, reader_search_height compact)',
    id: 'parity-search-c390-en',
    referenceId: 'rd-panel-search-c390-en',
    referenceSha256: _searchCompactSha,
    fixture: 'slow-rivers.epub',
    fixtureSha256: _slowRiversSha,
    locale: 'en',
    size: const Size(390, 844),
    panel: ReaderPanel.more,
    searchQuery: 'the',
    searchResultLabel: '1 / 16',
    compact: true,
    stateDerivation:
        'OpenLibraryBook(slow-rivers.epub) at unit 0, search open with the query `the` settled at 1 / 16, compact',
    fixturePresentation:
        'the query runs through the real bridge search; progress page 1 / 25%',
    progress: _pages(1, 1, 25),
  ),
];

// ---------------------------------------------------------------------------
// Seeding, rendering and panel opening
// ---------------------------------------------------------------------------

Future<void> _seedReaderState(_Capture capture) async {
  final bookId = bookIdsForTest[capture.fixture];
  expect(bookId, isNotNull, reason: 'the fixture was seeded');
  final bridge = FlutterBridge.withDatabasePath(
    databasePath: parityDatabasePath,
  );
  final cancellation = bridge.createCancellation();
  try {
    final summary = await bridge.openLibraryBook(
      bookId: bookId!,
      cancellationId: cancellation,
    );
    try {
      await bridge.saveReadingState(
        bookId: bookId,
        value: FlutterReadingState(unit: BigInt.from(capture.unit), zoom: 1),
        unitCount: summary.logicalUnitCount,
      );
      final existing = await bridge.listBookmarks(
        bookId: bookId,
        cancellationId: cancellation,
      );
      for (final bookmark in existing) {
        await bridge.deleteBookmark(id: bookmark.id);
      }
      if (capture.bookmarkAt case final unit?) {
        await bridge.toggleBookmark(
          bookId: bookId,
          unit: BigInt.from(unit),
          offset: null,
        );
      }
    } finally {
      bridge.releaseDocument(handle: summary.handle);
    }
  } finally {
    bridge.releaseCancellation(id: cancellation);
    bridge.dispose();
  }
}

Widget _reader(_Capture capture, FlutterBridge bridge) => productionShell(
  locale: Locale(capture.locale),
  home: ReaderScreen(
    bridge: bridge,
    initialPath: bookPathsForTest[capture.fixture],
    initialBookId: bookIdsForTest[capture.fixture],
    initialSettings: const FlutterReaderSettings(
      continuous: false,
      theme: 'light',
      epubFontSize: 16,
      epubLineSpacing: 1.6,
      pdfZoom: 0,
    ),
    initialTabs: const [
      ReaderTabPresentation(id: 'tab-0', title: '', selected: true),
    ],
    progressSource: capture.progress == null ? null : (_) => capture.progress!,
    contentsLoader: capture.chapters.isEmpty
        ? (_) async => const []
        : (_) async => [
            for (var index = 0; index < capture.chapters.length; index += 1)
              ReaderContentsEntry(title: capture.chapters[index], unit: index),
          ],
  ),
);

bool _ready(WidgetTester tester, _Capture capture) {
  if (!harnessReaderPageReady(tester)) return false;
  final action = find.byKey(ValueKey('reader-header-${capture.panel.name}'));
  if (action.evaluate().isEmpty) return false;
  return tester
      .widget<ShadButton>(
        find.descendant(of: action, matching: find.byType(ShadButton)),
      )
      .enabled;
}

/// Whether the control at [finder] is enabled.
bool _controlEnabled(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  final button = find.descendant(of: finder, matching: find.byType(ShadButton));
  if (button.evaluate().isEmpty) return false;
  return tester.widget<ShadButton>(button).enabled;
}

Future<void> _openPanel(WidgetTester tester, _Capture capture) async {
  await tester.tap(find.byKey(ValueKey('reader-header-${capture.panel.name}')));
  await pumpHarnessFrames(tester, frames: 4);
  if (capture.searchQuery case final query?) {
    // Opening the panel changes the document box, so the reader re-lays the
    // chapter out and disables its controls until the new page lands. Wait
    // (bounded) for the control to be enabled before tapping it: the same
    // settle the other captures use for their own delayed state.
    final search = find.byKey(const ValueKey('reader-more-search'));
    for (var round = 0; round < 8; round += 1) {
      if (_controlEnabled(tester, search)) break;
      await _settleNative(tester, rounds: 1);
    }
    await tester.tap(search);
    await pumpHarnessFrames(tester, frames: 2);
    await tester.enterText(
      find.byKey(const ValueKey('reader-search-input')),
      query,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // The pinned search captures settle with the reference manifest's match
    // count (`1 / 16`); a still-running or empty search is not that state.
    final settled = find.text(capture.searchResultLabel!);
    for (var round = 0; round < 12 && settled.evaluate().isEmpty; round += 1) {
      await _settleNative(tester, rounds: 1);
    }
    expect(
      settled,
      findsOneWidget,
      reason:
          'the search settled with ${capture.searchResultLabel} '
          '(reference manifest search_matches)',
    );
    final next = find.byKey(const ValueKey('reader-search-next'));
    expect(
      tester
          .widget<ShadButton>(
            find.descendant(of: next, matching: find.byType(ShadButton)),
          )
          .enabled,
      isTrue,
      reason: 'the settled search enables the next-result control',
    );
  }
  if (capture.noteEditor) {
    // The saved-place list arrives from the controller's own bookmark read, so
    // wait (bounded) for the row before tapping its note control.
    final note = _savedPlaceControl('note');
    for (var round = 0; round < 8 && note.evaluate().isEmpty; round += 1) {
      await _settleNative(tester, rounds: 1);
    }
    expect(
      note,
      findsOneWidget,
      reason: 'the saved-place row rendered before its note control',
    );
    await tester.tap(note);
    await _settleNative(tester, rounds: 2);
    // The pinned setup opens the editor with the draft `check the survey notes`
    // (`reference_shots/reader.rs`), so the capture reproduces that state.
    final field = find.byKey(const ValueKey('reader-note-editor-field'));
    expect(field, findsOneWidget);
    await tester.enterText(field, capture.noteDraft!);
    await pumpHarnessFrames(tester, frames: 2);
    expect(
      tester.widget<ShadInput>(field).controller!.text,
      capture.noteDraft,
      reason: 'the note editor holds the reference draft text',
    );
  }
}

/// Alternates frame pumps with real-event-loop windows so native completions
/// (open, layout, search, bookmark writes) can arrive and settle.
Future<void> _settleNative(WidgetTester tester, {int rounds = 4}) async {
  for (var round = 0; round < rounds; round += 1) {
    await pumpHarnessFrames(tester, frames: 4);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
  }
  await pumpHarnessFrames(tester, frames: 4);
}

// ---------------------------------------------------------------------------
// Rendered widget geometry
// ---------------------------------------------------------------------------

/// The saved-place row, found by key shape rather than by bookmark id.
///
/// The bookmark id comes from the shared store's auto-increment, so the parity
/// test must not pin the numeric id; the functional tests own deterministic
/// fixture ids.
Finder _savedPlaceRow() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      RegExp(
        r'^reader-saved-place-\d+$',
      ).hasMatch((widget.key! as ValueKey<String>).value),
  description: 'saved-place row',
);

/// One control inside the saved-place row (`open`, `delete`, `note`).
Finder _savedPlaceControl(String name) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(
        'reader-saved-place-$name-',
      ),
  description: 'saved-place $name control',
);

/// The rendered rects the composition assertions are computed from.
///
/// These are the existing panel layout coordinates; the comparison against the
/// reference's own values happens in [_spacingComparison].
Map<String, Object?> _flutterGeometry(WidgetTester tester, _Capture capture) {
  final geometry = <String, Object?>{};
  void recordRect(String name, Finder finder) {
    if (finder.evaluate().isEmpty) return;
    final rect = tester.getRect(finder);
    geometry[name] = <String, Object?>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
  }

  recordRect(
    'panel',
    find.byKey(ValueKey('reader-panel-${capture.panel.name}')),
  );
  recordRect('header', find.byKey(const ValueKey('reader-header')));
  if (capture.panel == ReaderPanel.contents) {
    recordRect(
      'contentsScroll',
      find.byKey(const ValueKey('reader-contents-scroll')),
    );
    recordRect(
      'heading',
      find.byKey(const ValueKey('reader-contents-heading')),
    );
    recordRect(
      'subheading',
      find.byKey(const ValueKey('reader-contents-subheading')),
    );
    recordRect(
      'chaptersLabel',
      find.byKey(const ValueKey('reader-contents-chapters-label')),
    );
    recordRect(
      'bookmarksCount',
      find.byKey(const ValueKey('reader-contents-bookmarks-count')),
    );
    recordRect(
      'emptyState',
      find.byKey(const ValueKey('reader-contents-empty')),
    );
    if (capture.chapters.isNotEmpty) {
      recordRect(
        'firstChapterRow',
        find.byKey(const ValueKey('reader-contents-entry-0')),
      );
    }
    if (capture.chapters.length > 1) {
      recordRect(
        'secondChapterRow',
        find.byKey(const ValueKey('reader-contents-entry-1')),
      );
      recordRect(
        'lastChapterRow',
        find.byKey(
          ValueKey('reader-contents-entry-${capture.chapters.length - 1}'),
        ),
      );
    }
    if (capture.bookmarkAt != null) {
      recordRect('savedPlaceRow', _savedPlaceRow());
      recordRect('deleteControl', _savedPlaceControl('delete'));
      recordRect('noteLink', _savedPlaceControl('note'));
      recordRect(
        'exportAction',
        find.byKey(const ValueKey('reader-bookmark-export')),
      );
    }
  } else {
    recordRect(
      'panelRow',
      find.byKey(ValueKey('reader-panel-${capture.panel.name}')),
    );
    if (capture.panel == ReaderPanel.more) {
      recordRect('pageInput', find.byKey(const ValueKey('reader-page-input')));
      recordRect(
        'bookmarkControl',
        find.byKey(const ValueKey('reader-more-bookmark')),
      );
      recordRect(
        'openBookControl',
        find.byKey(const ValueKey('reader-more-open-book')),
      );
      recordRect(
        'searchControl',
        find.byKey(const ValueKey('reader-more-search')),
      );
    }
    if (capture.searchQuery != null) {
      recordRect('searchBar', find.byKey(const ValueKey('reader-search-bar')));
      recordRect(
        'searchClose',
        find.byKey(const ValueKey('reader-search-close')),
      );
      recordRect(
        'searchInput',
        find.byKey(const ValueKey('reader-search-input')),
      );
      recordRect(
        'searchNext',
        find.byKey(const ValueKey('reader-search-next')),
      );
    }
  }
  return geometry;
}

// ---------------------------------------------------------------------------
// Measurement: the rendered panel composition and the reference's own values
// ---------------------------------------------------------------------------

/// True for text and icon ink; the same threshold the render detectors use.
bool _isInk(int r, int g, int b) =>
    (0.2126 * r + 0.7152 * g + 0.0722 * b) < 170;

/// Ink pixels in the rendered document area.
///
/// The document area is the reader's own page box, painted by whichever
/// document renderer is active (the Dart EPUB page window for a routed
/// chapter, the retained Rust chapter surface otherwise); measuring the
/// captured frame inside that box proves the document itself has content, so a
/// blank page fails while the surrounding chrome stays irrelevant.
/// The document area is the reader's own page box, painted by whichever
/// document renderer is active (the Dart EPUB page window for a routed
/// chapter, the retained Rust chapter surface otherwise).
///
/// The measurement reads the page box's own repaint boundary rather than the
/// composed frame: a selection overlay, a panel or a dialog that happens to sit
/// inside the same rectangle cannot supply ink for a blank document, so the
/// assertion is about the document's paint, not the screen's.
Future<int> _documentBandInk(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('reader-page-paint')),
  );
  final data = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
  });
  final rgba = data!.buffer.asUint8List();
  return regionInk(
    HarnessImage(
      width: boundary.size.width.round(),
      height: boundary.size.height.round(),
      rgba: rgba,
    ),
    rect: Rect.fromLTWH(0, 0, boundary.size.width, boundary.size.height),
  );
}

/// Ink pixels in raw RGBA bytes.
/// Ink pixels in raw (premultiplied) RGBA bytes.
///
/// Each pixel is composited onto the light document paper first, so a
/// transparent raster pixel counts as paper rather than ink: the Rust page
/// buffer can carry transparent pixels, and a fully transparent raster must
/// measure zero ink.
int _inkPixels(Uint8List rgba, {int paper = 255}) {
  var count = 0;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final alpha = rgba[i + 3];
    if (alpha == 0) continue;
    if (alpha == 255) {
      if (_isInk(rgba[i], rgba[i + 1], rgba[i + 2])) count += 1;
      continue;
    }
    final uncovered = paper * (255 - alpha) ~/ 255;
    if (_isInk(
      rgba[i] + uncovered,
      rgba[i + 1] + uncovered,
      rgba[i + 2] + uncovered,
    )) {
      count += 1;
    }
  }
  return count;
}

/// The ink bounding box and pixel count of a crop.
///
/// A legible glyph paints a mark with a real box; a corrupted fragment paints a
/// sliver. The crop is captured at 4x, so the box is in 4x pixels.
Map<String, Object?> _inkBox(HarnessImage image) {
  var minX = image.width;
  var minY = image.height;
  var maxX = -1;
  var maxY = -1;
  var count = 0;
  for (var y = 0; y < image.height; y += 1) {
    for (var x = 0; x < image.width; x += 1) {
      final i = (y * image.width + x) * 4;
      if (_isInk(image.rgba[i], image.rgba[i + 1], image.rgba[i + 2])) {
        count += 1;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  return <String, Object?>{
    'inkPixels': count,
    'width': maxX < 0 ? 0 : maxX - minX + 1,
    'height': maxY < 0 ? 0 : maxY - minY + 1,
  };
}

/// The panel composition measured from the rendered widget rects.
///
/// Every key is a gap or a row height the pinned reference fixes: the panel
/// padding 14, the heading spacing 2, the child spacing 10, the chapter row
/// height 27 (padding [6, 8] plus a 12 px line box, which is the reference's
/// 37 px pitch), the entry padding 10, the compact stack spacing 7 and the row
/// heights 58/84 (more) and 52/88 (search).
Map<String, Object?> _spacingComparison(
  _Capture capture,
  Map<String, Object?> geometry,
) {
  Map<String, Object?>? rect(String name) =>
      geometry[name] as Map<String, Object?>?;
  double? top(String name) => rect(name)?['top'] as double?;
  double? heightOf(String name) => rect(name)?['height'] as double?;
  double? bottom(String name) {
    final value = rect(name);
    if (value == null) return null;
    return (value['top'] as double) + (value['height'] as double);
  }

  double? gap(String from, String to) {
    final start = bottom(from);
    final end = top(to);
    if (start == null || end == null) return null;
    return end - start;
  }

  double? span(String from, String to) {
    final start = top(from);
    final end = top(to);
    if (start == null || end == null) return null;
    return end - start;
  }

  final result = <String, Object?>{};
  if (capture.panel == ReaderPanel.contents) {
    result['panelPadding'] = span('panel', 'heading');
    result['headingSpacing'] = gap('heading', 'subheading');
    result['subheadingToChapters'] = gap('subheading', 'chaptersLabel');
    result['chaptersToFirstEntry'] = gap('chaptersLabel', 'firstChapterRow');
    result['entryRowHeight'] = heightOf('firstChapterRow');
    result['entryPitch'] = span('firstChapterRow', 'secondChapterRow');
    result['lastEntryToBookmarks'] = gap('lastChapterRow', 'bookmarksCount');
    result['bookmarksToNext'] = gap(
      'bookmarksCount',
      capture.bookmarkAt != null ? 'savedPlaceRow' : 'emptyState',
    );
    result['savedPlaceHeight'] = heightOf('savedPlaceRow');
    final entry = rect('savedPlaceRow');
    final delete = rect('deleteControl');
    if (entry != null && delete != null) {
      result['deleteRightInset'] =
          (entry['left'] as double) +
          (entry['width'] as double) -
          ((delete['left'] as double) + (delete['width'] as double));
    }
    result['exportActionHeight'] = heightOf('exportAction');
    result['entryToExportGap'] = gap('savedPlaceRow', 'exportAction');
  } else {
    result['rowHeight'] = heightOf('panelRow');
    if (capture.searchQuery != null) {
      result['barHeight'] = heightOf('searchBar');
      final input = rect('searchInput');
      if (input != null) result['searchInputWidth'] = input['width'];
      final bar = rect('searchBar');
      final close = rect('searchClose');
      if (bar != null && close != null) {
        final barLeft = bar['left'] as double;
        final barRight = barLeft + (bar['width'] as double);
        final closeLeft = close['left'] as double;
        result['closeLeftInset'] = closeLeft - barLeft;
        result['closeRightInset'] =
            barRight - (closeLeft + (close['width'] as double));
      }
    }
    if (capture.compact) {
      result['stackSpacing'] = capture.searchQuery != null
          ? gap('searchInput', 'searchNext')
          : gap('pageInput', 'bookmarkControl');
    }
  }
  return result;
}

/// Asserts the measured composition against the pinned reference values.
///
/// The tolerances are the measured font-rasterization difference between the
/// two toolkits: the same 12 px label paints a line box one or two pixels apart
/// (Inter Variable under Iced versus Inter under Flutter), so a gap or a row
/// height may differ by that much. A larger difference is a spacing regression,
/// not rasterization, and fails.
void _expectSpacing(_Capture capture, Map<String, Object?> spacing) {
  void expectValue(String key, num expected, {num tolerance = 2}) {
    final value = spacing[key];
    expect(value, isNotNull, reason: '$key was not measured');
    expect(
      (value! as num) - expected,
      inInclusiveRange(-tolerance, tolerance),
      reason: '$key: measured $value against the reference $expected',
    );
  }

  if (capture.panel == ReaderPanel.contents) {
    expectValue('panelPadding', 14);
    expectValue('headingSpacing', 2);
    expectValue('subheadingToChapters', 10);
    expectValue('chaptersToFirstEntry', 10);
    expectValue('entryRowHeight', 27);
    expectValue('entryPitch', 37);
    expectValue('lastEntryToBookmarks', 10);
    expectValue('bookmarksToNext', 10);
    if (capture.bookmarkAt != null) {
      // The reference entry is 65 px (10 px padding, a 24 px header row, 4 px
      // spacing and a 20 px note link); Flutter's links are sized to content
      // too, but its line boxes are a little taller.
      expectValue('savedPlaceHeight', 65, tolerance: 8);
      // The pinned reference's header row is title | filler | page + delete, so
      // the delete control ends at the entry's right padding edge (10 px inset).
      expectValue('deleteRightInset', 10, tolerance: 2);
      // The reference's export action renders 37 px (its [9, 14] padding plus a
      // 14 px line box, measured 433-469 on the committed capture); the
      // component layer's minimum would render 42.
      expectValue('exportActionHeight', 37, tolerance: 3);
      // The pinned panel column spaces the entry and the export action by 10 px
      // (measured 424-432 on the committed capture).
      expectValue('entryToExportGap', 10, tolerance: 2);
    }
    return;
  }
  // The wide rows match the reference exactly. The compact rows are sized to
  // their content (36 px input + 7 px stack + 31 px control) rather than to
  // Iced's fixed 84/88, which centres 3-4 px of overflow; sizing to content
  // keeps every control unclipped, so the recorded difference is bounded at 4
  // px instead of reproducing the reference's overflow.
  expectValue(
    'rowHeight',
    capture.referenceRowHeight!,
    tolerance: capture.compact ? 4 : 3,
  );
  if (capture.searchQuery != null) {
    expectValue('barHeight', capture.compact ? 88 : 52, tolerance: 4);
    // The pinned wide bar right-aligns the count and the three controls at the
    // bar's [8, 12] padding edge (the close ink measures 1251-1256 on the
    // committed wide capture); the compact bar stacks them below the field,
    // left-aligned (the close ink measures 117-121 on the committed compact
    // capture). The wide field is capped at 420 px.
    if (capture.compact) {
      expectValue('closeLeftInset', 111, tolerance: 8);
    } else {
      expectValue('closeRightInset', 12, tolerance: 2);
      // The pinned wide field shares the free space with the filler and renders
      // 557 px wide (measured x 12-568 on the committed capture); the token's
      // 420 px cap is not what the pinned build painted. The share itself
      // follows the actions' intrinsic width, which differs by a few pixels
      // between the toolkits, so the field is allowed to differ by that much
      // while the close control's right inset above stays exact.
      expectValue('searchInputWidth', 557, tolerance: 10);
    }
  }
  if (capture.compact) {
    expectValue('stackSpacing', 7);
  }
}

/// A transparent image with one opaque dark mark, for the ink control.
Future<ui.Image> _transparentImageWithMark() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(8, 8, 16, 16),
    ui.Paint()..color = const Color(0xFF282724),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(32, 32);
  } finally {
    picture.dispose();
  }
}

/// A solid [color] image, for the document-ink negative control.
Future<ui.Image> _solidImage(Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 32, 32), ui.Paint()..color = color);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(32, 32);
  } finally {
    picture.dispose();
  }
}

// ---------------------------------------------------------------------------
// Reference images and artifacts
// ---------------------------------------------------------------------------

/// The committed 1C reference capture: decoded pixels plus its file length.
///
/// The manifest's SHA-256 is the authoritative identity (verified in 1C and
/// recorded per capture); the pinned file length and pixel size prove that this
/// run read the same committed file without adding a hashing dependency to the
/// Flutter package.
Future<({HarnessImage image, int bytes})> _referenceCapture(
  String referenceId,
) async {
  final bytes = await File(
    '../rfd/0004/evidence/reference-shots-1c/captures/$referenceId.png',
  ).readAsBytes();
  return (image: await decodeHarnessImage(bytes), bytes: bytes.length);
}

/// The committed 1C manifest, read once per suite.
Map<String, Object?> get _referenceManifest => _manifestCache ??=
    jsonDecode(
          File(
            '../rfd/0004/evidence/reference-shots-1c/manifest.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

Map<String, Object?>? _manifestCache;

/// The manifest's byte length for one capture.
int? _manifestCaptureBytes(String referenceId) {
  final captures = _referenceManifest['captures'] as List?;
  for (final capture in captures ?? const []) {
    final entry = capture as Map<String, Object?>;
    if (entry['id'] == referenceId) return entry['bytes'] as int?;
  }
  return null;
}

/// The manifest's byte length for one seeded fixture.
int? _manifestFixtureBytes(String fixture) {
  final fixtures = _referenceManifest['fixtures'] as Map<String, Object?>?;
  for (final entry in (fixtures?['files'] as List? ?? const [])) {
    final file = entry as Map<String, Object?>;
    if (file['relative_path'] == 'library/featured/$fixture') {
      return file['bytes'] as int?;
    }
  }
  return null;
}

/// Book ids and paths resolved by the suite setup (see `setUpAll`).
final bookIdsForTest = <String, int>{};
final bookPathsForTest = <String, String>{};

/// The disposable data root and database the suite seeds once.
late Directory parityDataDirectory;
late String parityDatabasePath;

/// Crop of one widget for ink inspection (the delete control and similar).
Future<Uint8List> _cropWidgetPng(
  WidgetTester tester,
  Finder finder, {
  double padding = 4,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(harnessBoundaryKey),
  );
  final rect = tester.getRect(finder).inflate(padding);
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 4);
    try {
      final cropped = ui.PictureRecorder();
      ui.Canvas(cropped).drawImageRect(
        image,
        Rect.fromLTWH(
          rect.left * 4,
          rect.top * 4,
          rect.width * 4,
          rect.height * 4,
        ),
        Rect.fromLTWH(0, 0, rect.width * 4, rect.height * 4),
        ui.Paint(),
      );
      final picture = cropped.endRecording();
      try {
        final croppedImage = await picture.toImage(
          (rect.width * 4).round(),
          (rect.height * 4).round(),
        );
        try {
          final data = await croppedImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          bytes = data!.buffer.asUint8List();
        } finally {
          croppedImage.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      image.dispose();
    }
  });
  return bytes;
}
