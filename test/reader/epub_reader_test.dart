import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderPlace;
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/theme_tokens.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// The production reader lays every EPUB chapter out with the Dart engine.
///
/// The bytes are real fixture archives, parsed by the real engine; the bridge
/// is the deterministic harness, so the page windows, their ownership and the
/// durable offsets are what these tests isolate.
/// Alternates frame pumps with real-event-loop windows so native completions
/// (open, engine parse, layout, annotation reads) can arrive and settle.
Future<void> settleNative(WidgetTester tester, {int rounds = 4}) async {
  for (var round = 0; round < rounds; round += 1) {
    await pumpHarnessFrames(tester, frames: 4);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
  }
  await pumpHarnessFrames(tester, frames: 4);
}

void main() {
  final conformance = _fixture('epub-conformance/conformance.epub');
  final book = openEpubBytes(conformance);

  HarnessBridge bridge({
    Uint8List? bytes,
    int unitCount = 8,
    List<FlutterLibraryBook>? books,
  }) {
    final harness = HarnessBridge(books: books, unitCount: unitCount);
    harness.epubBytes = bytes ?? conformance;
    return harness;
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    bool failing = false,
    FlutterReaderSettings? settings,
    ReaderPlace? place,
    int? bookId,
  }) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          initialBookId: bookId,
          initialPlace: place,
          initialSettings: (settings ?? harnessReaderSettings).copyWith(
            zonesHintDismissed: true,
          ),
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: failing
          ? () => find
                .byKey(const ValueKey('reader-content-error'))
                .evaluate()
                .isNotEmpty
          : () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await revealReaderChrome(tester);
  }

  ReaderEpubPageContentPainter? dartPage(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is ReaderEpubPageContentPainter) return painter;
    }
    return null;
  }

  /// The saved highlights the page paints, as canonical ranges.
  List<(int, int)> painted(WidgetTester tester) => [
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    ))
      if (paint.painter case final PagePainter painter)
        for (final saved in painter.savedSelections) (saved.start, saved.end),
  ];

  /// Pumps until the installed Dart page stops changing size.
  ///
  /// Opening a document reports its content box twice (the opening body, then
  /// the document body), so the first page is followed by a corrected layout;
  /// a test that taps chrome in between would tap a disabled control.
  Future<void> settleEpubPage(WidgetTester tester) async {
    Size? previous;
    for (var round = 0; round < 16; round += 1) {
      await settleNative(tester, rounds: 1);
      final page = dartPage(tester);
      if (page == null) return;
      final size = page.page.box.size;
      if (size == previous) return;
      previous = size;
    }
  }

  testWidgets('a chapter renders the Dart page window', (tester) async {
    final harness = bridge();
    await openReader(tester, harness);

    final page = dartPage(tester);
    expect(page, isNotNull, reason: 'the chapter is laid out by the engine');
    // The surface carries the chapter's canonical stream, so copy, highlights
    // and durable offsets stay in the stream the store already uses.
    expect(page!.page.surface.text, book.chapters[0].canonicalText);
    expect(page.page.surface.copyEligible, isTrue);
    expect(page.page.unit, 0);
    expect(page.page.canGoForward, isTrue);
    expect(page.page.canGoBackward, isFalse);
    // The page is the whole window: the surface is not scaled by the fit.
    expect(page.page.box.size.width, greaterThan(0));
    expect(page.page.box.size.height, greaterThan(0));
    expect(harness.epubSourceCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a book past the cell-walk admission ceiling fails to lay out', (
    tester,
  ) async {
    // The shallow control lays out; the over-deep book, identical but for the
    // span depth, is refused at admission, and the reader reports the failure
    // instead of painting a page.
    final control = bridge(bytes: admissionEpub(spanNesting: 2), unitCount: 1);
    await openReader(tester, control);
    expect(
      dartPage(tester),
      isNotNull,
      reason: 'the identical book inside the ceiling lays out',
    );
    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);

    expect(
      () => openEpubBytes(admissionEpub(spanNesting: 65)),
      throwsA(isA<EpubLimitError>()),
    );
    final refused = bridge(bytes: admissionEpub(spanNesting: 65), unitCount: 1);
    await openReader(tester, refused, failing: true);
    expect(dartPage(tester), isNull);
    expect(
      find.byKey(const ValueKey('reader-content-error')),
      findsOneWidget,
      reason: 'a refused archive is an open failure',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets(
    'a chapter with one enormous paragraph is refused before layout',
    (tester) async {
      // The windowed session measures in bounded batches between top-level
      // blocks, but one paragraph is measured by a single `TextPainter.layout`:
      // a paragraph over the ceiling is refused with a typed error naming the
      // chapter instead of blocking the UI thread on one unbounded call.
      final huge = _repoFile('fixtures/epub-layout/huge-paragraph.epub');
      final hugeBook = openEpubBytes(huge);
      expect(
        hugeBook.chapters.first.scalarCount,
        greaterThan(kEpubIndivisibleScalarLimit),
      );
      final harness = bridge(bytes: huge, unitCount: hugeBook.chapters.length);
      await openReader(tester, harness, failing: true);
      await settleNative(tester);

      expect(dartPage(tester), isNull, reason: 'nothing was laid out');
      final error = tester.widget<Text>(
        find.byKey(const ValueKey('reader-content-error')),
      );
      expect(
        error.data,
        'Chapter 1 is too large to display: one of its paragraphs is longer '
        'than $kEpubIndivisibleScalarLimit characters. Choose another chapter '
        'from Contents.',
      );

      await tester.pumpWidget(const SizedBox());
      await _drainHarness(tester);
    },
  );

  testWidgets('a container over the node ceiling is refused and the reader '
      'can move on', (tester) async {
    // Wide enough that the contents panel sits beside the chapter.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bytes = buildTestEpub(
      chapters: {
        'OPS/Text/chapter-1.xhtml': '<p>Opening chapter.</p>',
        // One list is laid out by one call: every item counts.
        'OPS/Text/chapter-2.xhtml':
            '<ul>${'<li>Item.</li>' * (kEpubIndivisibleNodeLimit + 8)}</ul>',
        'OPS/Text/chapter-3.xhtml': '<p>Closing chapter.</p>',
      },
      nav:
          '<ol>'
          '<li><a href="../Text/chapter-1.xhtml">Opening</a></li>'
          '<li><a href="../Text/chapter-2.xhtml">Listing</a></li>'
          '<li><a href="../Text/chapter-3.xhtml">Closing</a></li>'
          '</ol>',
    );
    final harness = bridge(
      bytes: bytes,
      unitCount: 3,
      books: harnessLibraryBooks(),
    );
    await openReader(tester, harness, bookId: 1);
    await settleEpubPage(tester);
    expect(dartPage(tester)!.page.unit, 0);

    expect(harness.savedReadingStates, isNotEmpty);
    final saved = harness.savedReadingStates.last;
    await tester.fling(
      find.byKey(const ValueKey('reader-selection-surface')),
      const Offset(-200, 0),
      1000,
    );
    await settleNative(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-page-curl')), findsNothing);
    expect(
      (
        harness.savedReadingStates.last.unit,
        harness.savedReadingStates.last.offset,
      ),
      (saved.unit, saved.offset),
    );

    // The refusal is reported over the page the reader still shows.
    expect(dartPage(tester)!.page.unit, 0);
    final error = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('reader-layout-refusal')),
        matching: find.byType(Text),
      ),
    );
    expect(
      error.data,
      'Chapter 2 is too large to display: one of its lists, tables or '
      'sections holds more than $kEpubIndivisibleNodeLimit parts. Choose '
      'another chapter from Contents.',
    );

    await revealReaderChrome(tester);
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settleNative(tester);
    await tester.tap(find.text('Closing'));
    await settleNative(tester);

    expect(dartPage(tester)!.page.unit, 2);
    expect(harness.savedReadingStates.last.unit.toInt(), 2);
    expect(find.byKey(const ValueKey('reader-layout-refusal')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a chapter outside the bundled faces still lays out', (
    tester,
  ) async {
    // bidi.epub's stream carries Hebrew, Arabic and an emoji, which neither
    // bundled face carries: the host's fallback faces draw them.
    final bidi = _fixture('epub-conformance/bidi.epub');
    final bidiBook = openEpubBytes(bidi);
    final harness = bridge(bytes: bidi, unitCount: bidiBook.chapters.length);
    await openReader(tester, harness);

    expect(dartPage(tester), isNotNull);
    expect(
      dartPage(tester)!.page.surface.text,
      bidiBook.chapters.first.canonicalText,
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('the first page paints before its highlights load', (
    tester,
  ) async {
    // RFD 16 keeps annotation loading off the open's critical path: the page
    // shows while the store is still resolving the book's highlights, and the
    // highlights paint on that same page when they arrive.
    final harness = bridge();
    final highlights = Completer<List<FlutterAnnotation>>();
    harness.annotationListCompleters.add(highlights);
    await openReader(tester, harness);
    await settleEpubPage(tester);

    final page = dartPage(tester)!.page;
    expect(
      harness.annotationListCompleters,
      isEmpty,
      reason: 'the open asked for the highlights',
    );
    expect(painted(tester), isEmpty, reason: 'none have arrived yet');

    final start = page.canonicalStart + 2;
    highlights.complete([
      FlutterAnnotation(
        id: 'saved',
        unit: BigInt.from(page.unit),
        resolution: FlutterAnnotationResolution.exact,
        textRange: FlutterAnnotationTextRange(
          start: BigInt.from(start),
          end: BigInt.from(start + 6),
        ),
        color: FlutterHighlightColor.green,
      ),
    ]);
    await settleNative(tester);

    expect(painted(tester), [(start, start + 6)]);
    expect(
      dartPage(tester)!.page.canonicalStart,
      page.canonicalStart,
      reason: 'the highlights paint on the page already shown',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('resizes while highlights load keep them and retire sessions', (
    tester,
  ) async {
    // The book's highlights load once, for the document: relayouts that
    // supersede one another while the list is pending (a resize and its undo)
    // neither cancel it nor drop its result, and each replaced page's session
    // is retired with it while the installed one stays live.
    final sessions = <ChapterLayoutSession>[];
    final harness = bridge();
    final held = Completer<List<FlutterAnnotation>>();
    harness.annotationListCompleters.add(held);
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/conformance.epub',
          initialSettings: harnessReaderSettings,
          epubImageDecoder: (bytes) async => null,
          debugEpubSessionObserver: sessions.add,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settleEpubPage(tester);
    expect(
      harness.annotationListCompleters,
      isEmpty,
      reason: 'the highlights are loading',
    );
    final page = dartPage(tester)!.page;
    final openSession = sessions.last;
    expect(openSession.isDisposed, isFalse);

    final original = tester.view.physicalSize;
    final ratio = tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = original + const Offset(150, 0);
    await pumpHarnessFrames(tester, frames: 2);
    tester.view.physicalSize = original;
    await pumpHarnessFrames(tester, frames: 8);
    await settleEpubPage(tester);
    expect(tester.takeException(), isNull);
    expect(sessions.length, greaterThan(1), reason: 'the resize relaid out');
    final installedSession = sessions.last;
    expect(installedSession.isDisposed, isFalse);
    expect(
      sessions.where((session) => !session.isDisposed),
      [installedSession],
      reason: 'every replaced session is retired',
    );

    final start = page.canonicalStart + 2;
    held.complete([
      FlutterAnnotation(
        id: 'saved',
        unit: BigInt.from(page.unit),
        resolution: FlutterAnnotationResolution.exact,
        textRange: FlutterAnnotationTextRange(
          start: BigInt.from(start),
          end: BigInt.from(start + 6),
        ),
        color: FlutterHighlightColor.green,
      ),
    ]);
    await settleNative(tester);
    expect(tester.takeException(), isNull);
    expect(
      painted(tester),
      [(start, start + 6)],
      reason: "the document's list survives the superseded relayouts",
    );
    expect(installedSession.isDisposed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('an unreadable archive fails the open with an error', (
    tester,
  ) async {
    final harness = bridge(bytes: Uint8List(0));
    await openReader(tester, harness, failing: true);

    expect(dartPage(tester), isNull);
    expect(find.byKey(const ValueKey('reader-content-error')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('the dark reader keeps a failed book message legible', (
    tester,
  ) async {
    await openReader(
      tester,
      bridge(bytes: Uint8List(0)),
      failing: true,
      settings: const FlutterReaderSettings(
        continuous: false,
        theme: 'dark',
        epubFontSize: 18,
        epubLineSpacing: 1.5,
        pdfZoom: 0,
      ),
    );

    // A failed book is still document-area copy: the message follows the
    // reader palette ink over the reader paper.
    final message = tester.widget<Text>(
      find.byKey(const ValueKey('reader-content-error')),
    );
    expect(message.style?.color, ShosaiTokens.readerDarkText);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a page turn invalidates the selection it replaces', (
    tester,
  ) async {
    // The page a selection addresses leaves the screen on a turn: the selection
    // phase is invalidated with it, so nothing can submit a range the page no
    // longer shows. (The visible surface and the derived description are
    // replaced with the page anyway, which is why this asserts the outcome
    // rather than only the phase.)
    final semantics = tester.ensureSemantics();
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);

    final page = dartPage(tester)!;
    final surface = page.page.surface;
    final painted = paintedReaderSurface(tester);
    Offset center(int index) {
      final endpoint = surface.endpoints[index];
      final rect = endpoint.rect;
      return readerSurfaceToGlobal(
        painted,
        Offset((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2),
      );
    }

    await dragReaderSelectionBetween(
      tester,
      center(0),
      center(surface.endpoints.length > 6 ? 6 : surface.endpoints.length - 1),
    );
    await settleReaderSelection(tester);
    expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    expect(
      find.byKey(const ValueKey('selection-actions')),
      findsNothing,
      reason: 'the selection does not outlive the page it addresses',
    );
    final status = tester
        .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
        .getSemanticsData()
        .label;
    expect(
      status,
      isNot(startsWith('Selected text:')),
      reason: 'the selection phase is idle, not selected over an empty range',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpHarnessFrames(tester, frames: 4);
    expect(
      harness.createdRanges,
      isEmpty,
      reason: 'Enter after the turn must not persist the replaced range',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
    semantics.dispose();
  });

  testWidgets('a touch selection end handle drags across the real page', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);

    final surface = dartPage(tester)!.page.surface;
    final painted = paintedReaderSurface(tester);
    Offset center(int index) {
      final rect = surface.endpoints[index].rect;
      return readerSurfaceToGlobal(
        painted,
        Offset((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2),
      );
    }

    final last = surface.endpoints.length > 24
        ? 24
        : surface.endpoints.length - 1;
    final finger = await tester.startGesture(
      center(0),
      kind: ui.PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await finger.moveTo(center(last ~/ 2));
    await tester.pump();
    await finger.up();
    await settleReaderSelection(tester);
    expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
    final end = find.byKey(const ValueKey('reader-selection-handle-end'));
    expect(end, findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-selection-handle-start')),
      findsOneWidget,
    );

    final handle = await tester.startGesture(
      tester.getCenter(end),
      kind: ui.PointerDeviceKind.touch,
    );
    await tester.pump();
    await handle.moveBy(center(last) - center(last ~/ 2));
    await tester.pump();
    await handle.up();
    await settleReaderSelection(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleNative(tester, rounds: 2);

    final (_, start, stop) = harness.createdRanges.single;
    expect(start.toInt(), surface.endpoints[0].rangeStart.toInt());
    expect(
      stop.toInt(),
      greaterThan(surface.endpoints[last ~/ 2].rangeEnd.toInt()),
      reason: 'the end handle carried the range past where the drag left it',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a range ending after a paragraph break shows its end handle', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);

    final surface = dartPage(tester)!.page.surface;
    final painted = paintedReaderSurface(tester);
    // A paragraph's first grapheme whose offset no visible grapheme ends at:
    // the separator before it has no box.
    final after = surface.endpoints.firstWhere(
      (candidate) =>
          candidate.offset > BigInt.zero &&
          candidate.offset == candidate.rangeStart &&
          !surface.endpoints.any((other) => other.rangeEnd == candidate.offset),
    );
    Offset center(FlutterSelectionEndpoint endpoint) {
      final rect = endpoint.rect;
      return readerSurfaceToGlobal(
        painted,
        Offset((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2),
      );
    }

    final finger = await tester.startGesture(
      center(surface.endpoints.first),
      kind: ui.PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await finger.moveTo(center(after));
    await tester.pump();
    await finger.up();
    await settleReaderSelection(tester);
    expect(
      find.byKey(const ValueKey('reader-selection-handle-end')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a page turn advances the durable offset inside the chapter', (
    tester,
  ) async {
    final long = _repoFile('fixtures/epub-layout/long-chapter.epub');
    final longBook = openEpubBytes(long);
    final harness = HarnessBridge(
      books: harnessLibraryBooks(),
      unitCount: longBook.chapters.length,
    );
    harness.epubBytes = long;
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/umibe.epub',
          initialBookId: 2,
          initialSettings: harnessReaderSettings,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );

    await settleEpubPage(tester);
    final first = dartPage(tester);
    expect(first, isNotNull);
    final start = first!.page.canonicalStart;
    expect(first.page.pageIndex, 0);
    expect(
      first.page.pageCount,
      greaterThan(1),
      reason: 'the fixture chapter spans several pages',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    final second = dartPage(tester);
    expect(second, isNotNull, reason: 'the chapter stays on the Dart renderer');
    expect(
      second!.page.canonicalStart,
      greaterThan(start),
      reason: 'the next page starts after the first',
    );
    expect(second.page.unit, 0, reason: 'the step stayed inside the chapter');
    expect(
      harness.savedReadingStates.map((state) => state.offset?.toInt()),
      contains(second.page.canonicalStart),
      reason: 'the page turn is the durable position it saved',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('a taller viewport re-paginates and keeps the position', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);
    final before = dartPage(tester);
    expect(before, isNotNull);
    final offset = before!.page.canonicalStart;

    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    final after = dartPage(tester);
    expect(after, isNotNull);
    expect(
      after!.page.box.size.height,
      isNot(before.page.box.size.height),
      reason: 'the page window follows the reported document box',
    );
    expect(
      after.page.canonicalStart,
      offset,
      reason: 'a resize keeps the reader on the same durable position',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('book-wide progress survives two layouts and a restore', (
    tester,
  ) async {
    final bytes = buildTestEpub(
      chapters: {
        'OPS/Text/one.xhtml':
            '<h1>Long opening</h1>${'<p>The river winds past the old library and into the hills.</p>' * 100}',
        'OPS/Text/two.xhtml': '<h1>Short ending</h1><p>Home again.</p>',
      },
      nav:
          '<ol><li><a href="../Text/one.xhtml">Long opening</a></li><li><a href="../Text/two.xhtml">Short ending</a></li></ol>',
    );
    final book = openEpubBytes(bytes);
    final total = book.chapters.fold<int>(
      0,
      (sum, chapter) => sum + chapter.canonicalText.runes.length,
    );
    const offset = 2300;
    final expectedPercent = (offset / total * 100).round();
    final pageIndexes = <int>[];
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(1280, 800), const Size(560, 600)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final harness = bridge(
        bytes: bytes,
        unitCount: 2,
        books: harnessLibraryBooks(),
      );
      await openReader(
        tester,
        harness,
        bookId: 1,
        place: const ReaderPlace(0, offset: offset),
        settings: const FlutterReaderSettings(
          continuous: false,
          theme: 'light',
          epubFontSize: 18,
          epubLineSpacing: 1.5,
          pdfZoom: 1,
          twoPages: false,
        ),
      );
      await settleEpubPage(tester);
      final page = dartPage(tester)!.page;
      pageIndexes.add(page.pageIndex);
      expect(
        page.pageIndex,
        greaterThan(0),
        reason: 'restoring deep in a chapter must not label its window page 1',
      );
      expect(
        find.text(
          size.width < 600
              ? '$expectedPercent%\npage ${page.pageIndex + 1}'
              : '$expectedPercent% · page ${page.pageIndex + 1}',
        ),
        findsOneWidget,
      );
      expect(harness.savedReadingStates.last.offset, BigInt.from(offset));
      expect(harness.savedReadingStates.last.progress, offset / total);
      // A passive height change preserves the exact canonical address and
      // percentage, but changes which visual page contains it.
      tester.view.physicalSize = Size(size.width, size.height + 260);
      await pumpHarnessFrames(tester, frames: 8);
      await settleEpubPage(tester);
      expect(harness.savedReadingStates.last.offset, BigInt.from(offset));
      expect(harness.savedReadingStates.last.progress, offset / total);
      expect(dartPage(tester)!.page.pageIndex, lessThan(page.pageIndex));
      await tester.pumpWidget(const SizedBox());
      await _drainHarness(tester);
    }
    expect(
      pageIndexes[1],
      greaterThan(pageIndexes[0]),
      reason: 'narrower, shorter pages paginate the same location differently',
    );
  });

  testWidgets('a font-size change re-paginates and keeps the position', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    await settleEpubPage(tester);
    final before = dartPage(tester);
    expect(before, isNotNull);

    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await pumpHarnessFrames(tester, frames: 4);
    final increase = find.byKey(
      const ValueKey('reader-typography-font-increase'),
    );
    for (var round = 0; round < 8 && increase.evaluate().isEmpty; round += 1) {
      await settleNative(tester, rounds: 1);
    }
    await tester.tap(increase);
    await pumpHarnessFrames(tester, frames: 8);
    await settleNative(tester);

    final after = dartPage(tester);
    expect(after, isNotNull);
    expect(
      after!.page.canonicalStart,
      before!.page.canonicalStart,
      reason: 'a typography change keeps the durable position',
    );

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
  });

  testWidgets('selection and copy read the canonical stream of the page', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    MethodCall? clipboardCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboardCall = call;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final harness = bridge();
    await openReader(tester, harness);

    await settleEpubPage(tester);
    final page = dartPage(tester)!;
    final surface = page.page.surface;
    expect(surface.endpoints, isNotEmpty);
    final from = surface.endpoints.first;
    final to = surface.endpoints.last;
    final painted = paintedReaderSurface(tester);
    await dragReaderSelectionBetween(
      tester,
      readerSurfaceToGlobal(
        painted,
        Offset(
          (from.rect.left + from.rect.right) / 2,
          (from.rect.top + from.rect.bottom) / 2,
        ),
      ),
      readerSurfaceToGlobal(
        painted,
        Offset(
          (to.rect.left + to.rect.right) / 2,
          (to.rect.top + to.rect.bottom) / 2,
        ),
      ),
    );
    await settleReaderSelection(tester);

    final label = tester
        .getSemantics(find.byKey(const ValueKey('reader-selection-status')))
        .getSemanticsData()
        .label;
    expect(label, startsWith('Selected text:'));
    final selected = label.substring('Selected text:'.length).trim();
    expect(selected, isNotEmpty);
    // The selected text is a slice of the chapter's canonical stream: the
    // offsets the store will persist address that stream.
    expect(
      book.chapters[0].canonicalText,
      contains(selected),
      reason: 'the copied text is the canonical text the offsets address',
    );

    // Copy end to end: the action surface writes the same slice to the
    // platform clipboard, so a highlight's offsets and the copied text cannot
    // drift apart.
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboardCall?.arguments, {'text': selected});

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);
    semantics.dispose();
  });

  testWidgets('disposal releases the Dart page without a stale install', (
    tester,
  ) async {
    final harness = bridge();
    await openReader(tester, harness);
    expect(dartPage(tester), isNotNull);

    await tester.pumpWidget(const SizedBox());
    await _drainHarness(tester);

    expect(tester.takeException(), isNull);
    expect(harness.isDisposed, isTrue);
  });
}

/// Pumps a frame after tearing the reader down, so the harness's disposal
/// completes inside a real-async window.
Future<void> _drainHarness(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
}

/// The bytes of one repository fixture under the core crate.
Uint8List _fixture(String name) => _repoFile('fixtures/$name');

/// The bytes of one repository file.
Uint8List _repoFile(String path) =>
    Uint8List.fromList(File(path).readAsBytesSync());
