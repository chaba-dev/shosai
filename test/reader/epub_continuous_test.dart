import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/continuous.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/notices/notice.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';

/// Continuous EPUB reading on the Dart engine: a chapter is one page as tall
/// as the chapter, which the reader scrolls; PageDown and PageUp move between
/// chapters, and a location inside the chapter is scrolled into view.
///
/// The fixture archive is parsed by the real engine and read by the
/// production `ReaderScreen` over the deterministic harness bridge.
class _ContinuousBridge extends HarnessBridge {
  _ContinuousBridge({
    required super.books,
    required super.unitCount,
    this.readingState,
  });

  final FlutterReadingState? readingState;
  List<FlutterAnnotation> annotations = const [];
  List<FlutterBookmark> bookmarks = const [];
  List<FlutterSearchMatch> matches = const [];

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async => readingState;

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
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  }) async => matches;
}

/// A layout clock that never advances: the reader's layout time budgets are
/// never spent, so each layout step is bounded by its node counts alone and
/// the tests below do the same work in the same frames on any machine.
int _stillClock() => 0;

/// The rules between the paragraphs of the backward-search fixture: sized so
/// a search back across them reaches its window limit a few nodes after the
/// paragraph nearest them, where restarting further back would skip it.
const _backwardGap = 4971;

const _continuous = FlutterReaderSettings(
  continuous: true,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.5,
  pdfZoom: 0,
);

/// The Contents panel's own text: the toolbar and status line also name the
/// current section.
Finder inContents(String text) => find.descendant(
  of: find.byKey(const ValueKey('reader-panel-contents')),
  matching: find.text(text),
);

void main() {
  final bytes = navigationEpub();
  final book = openEpubBytes(bytes);

  _ContinuousBridge bridge({
    FlutterReadingState? readingState,
    Uint8List? epub,
    int? unitCount,
  }) {
    final harness = _ContinuousBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Reader Navigation',
          format: FlutterBookFormat.epub,
          pathKey: '/books/navigation.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-01',
        ),
      ],
      unitCount: unitCount ?? book.chapters.length,
      readingState: readingState,
    );
    harness.epubBytes = epub ?? bytes;
    return harness;
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    void Function(NoticeRequest)? noticeReporter,
    void Function(ChapterLayoutSession)? sessionObserver,
    void Function(({int micros, int measured}) step)? stepObserver,
  }) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/navigation.epub',
          initialBookId: 1,
          initialSettings: _continuous,
          epubImageDecoder: (bytes) async => null,
          noticeReporter: noticeReporter,
          debugEpubSessionObserver: sessionObserver,
          debugContinuousStepObserver: stepObserver,
          debugLayoutClock: _stillClock,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
  }

  ReaderEpubPage? dartPage(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter is ReaderEpubPageContentPainter) return painter.page;
    }
    return null;
  }

  /// Pumps frames until the window steps and selection geometry a change
  /// scheduled have run.
  ///
  /// Only frames: once [openReader] has waited for the book's parse isolate,
  /// the reader's continuous work runs on frame callbacks and microtasks in
  /// the test zone. A real-time wait here would cost wall time on every
  /// scroll and key press without letting anything else complete.
  Future<void> settle(WidgetTester tester) =>
      pumpHarnessFrames(tester, frames: 28);

  /// Pumps frames one at a time, at least one and then until [done] (for at
  /// most as many frames as 30 [settle]s), and shows [painted] the window of
  /// every frame: a window a later step releases is still seen at its widest.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() done,
    void Function(ReaderEpubWindow window) painted,
  ) async {
    var frame = 0;
    do {
      await tester.pump(const Duration(milliseconds: 16));
      painted(dartPage(tester)!.window!);
      frame += 1;
    } while (frame < 30 * 28 && !done());
  }

  /// The position of the chapter's scroll view.
  ScrollPosition chapterScroll(WidgetTester tester) {
    final view = find.descendant(
      of: find.byKey(const ValueKey('reader-continuous-presentation')),
      matching: find.byType(Scrollable),
    );
    expect(view, findsOneWidget, reason: 'the chapter scrolls');
    return tester.state<ScrollableState>(view).position;
  }

  Future<void> closeReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  testWidgets('a chapter is one page that scrolls', (tester) async {
    await openReader(tester, bridge());
    await settle(tester);

    final page = dartPage(tester)!;
    expect(page.unit, 0);
    expect(page.continuous, isTrue);
    expect(page.pageCount, 1);
    expect(page.canonicalStart, 0);
    expect(
      page.window!.nodeTops,
      hasLength(book.chapters.first.blocks.length + 1),
      reason: 'the one page is the whole chapter column',
    );
    final position = chapterScroll(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, 0);
    expect(
      find.byKey(const ValueKey('reader-edge-next')),
      findsNothing,
      reason: 'continuous reading has no page-turn edges',
    );

    await closeReader(tester);
  });

  testWidgets('PageDown and PageUp move between chapters', (tester) async {
    await openReader(tester, bridge());
    await settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settle(tester);
    expect(dartPage(tester)!.unit, 1);
    expect(dartPage(tester)!.pageCount, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await settle(tester);
    final previous = dartPage(tester)!;
    expect(previous.unit, 0);
    expect(previous.continuous, isTrue);
    expect(previous.canonicalStart, 0);

    await closeReader(tester);
  });

  testWidgets('Space and the arrows do not leave a chapter that scrolls', (
    tester,
  ) async {
    await openReader(tester, bridge());
    await settle(tester);

    for (final key in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
    ]) {
      await tester.sendKeyEvent(key);
      await settle(tester);
      expect(dartPage(tester)!.unit, 0, reason: '$key');
    }

    await closeReader(tester);
  });

  testWidgets('a restored location inside the chapter is scrolled into view', (
    tester,
  ) async {
    final chapter = book.chapters.first;
    final target = chapter.scalarCount - 4;
    await openReader(
      tester,
      bridge(
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(target),
          zoom: 1,
        ),
      ),
    );
    await settle(tester);

    final page = dartPage(tester)!;
    expect(page.targetScalar, target);
    final position = chapterScroll(tester);
    expect(position.pixels, greaterThan(0));
    final line = page.surface.endpoints
        .where((endpoint) => endpoint.offset >= BigInt.from(target))
        .map((endpoint) => endpoint.rect)
        .first;
    expect(
      line.top >= position.pixels &&
          line.bottom <= position.pixels + position.viewportDimension,
      isTrue,
      reason: 'the restored line is inside the viewport',
    );

    await closeReader(tester);
  });

  testWidgets('a location in the open chapter scrolls to its line', (
    tester,
  ) async {
    // A desktop window, where Contents opens as a popover over the page.
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openReader(tester, bridge());
    await settle(tester);
    expect(chapterScroll(tester).pixels, 0);

    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settle(tester);
    await tester.tap(inContents('Chapter one deep'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reader-reference-go-to')));
    await settle(tester);

    final page = dartPage(tester)!;
    final anchor = book.chapters.first.anchors['one-deep']!;
    expect(page.unit, 0);
    expect(page.targetScalar, anchor);
    final line = page.surface.endpoints
        .where((endpoint) => endpoint.offset >= BigInt.from(anchor))
        .map((endpoint) => endpoint.rect)
        .first;
    expect(
      chapterScroll(tester).pixels,
      closeTo(line.top - kEpubPageMargin, 1),
      reason: 'the anchor line is scrolled to the top of the view',
    );

    await closeReader(tester);
  });

  /// The canonical top of the line holding [scalar] on [page].
  double lineTop(ReaderEpubPage page, int scalar) => page.surface.endpoints
      .where((endpoint) => endpoint.offset >= BigInt.from(scalar))
      .map((endpoint) => endpoint.rect.top)
      .first;

  /// Opens Contents and chooses [title]; choosing closes the panel.
  Future<void> openContentsEntry(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settle(tester);
    await tester.tap(inContents(title));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reader-reference-go-to')));
    await settle(tester);
  }

  testWidgets("choosing the open chapter's start in Contents scrolls back to "
      'the top', (tester) async {
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openReader(tester, bridge());
    await settle(tester);

    await openContentsEntry(tester, 'Chapter one deep');
    expect(chapterScroll(tester).pixels, greaterThan(0));

    // The chapter start is a location like any other: the target is 0, and
    // the view must not stay where the deep anchor left it.
    await openContentsEntry(tester, 'Chapter one');
    final page = dartPage(tester)!;
    expect(page.unit, 0);
    expect(page.targetScalar, 0);
    expect(chapterScroll(tester).pixels, 0);

    await closeReader(tester);
  });

  testWidgets('the same location again scrolls back after a manual scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openReader(tester, bridge());
    await settle(tester);

    await openContentsEntry(tester, 'Chapter one deep');
    final anchor = book.chapters.first.anchors['one-deep']!;
    final revealed = chapterScroll(tester).pixels;
    expect(
      revealed,
      closeTo(lineTop(dartPage(tester)!, anchor) - kEpubPageMargin, 1),
    );

    // The reader scrolls back to the top by hand.
    await tester.drag(
      find.byKey(const ValueKey('reader-continuous-presentation')),
      const Offset(0, 4000),
    );
    await settle(tester);
    expect(chapterScroll(tester).pixels, 0);

    // The same entry is a new request even though its target is unchanged.
    await openContentsEntry(tester, 'Chapter one deep');
    expect(dartPage(tester)!.targetScalar, anchor);
    expect(chapterScroll(tester).pixels, closeTo(revealed, 1));

    await closeReader(tester);
  });

  // --- Long chapters: a window of the chapter is laid out at a time. ---

  final longEpub = longChapterEpub();
  final longBook = openEpubBytes(longEpub);
  final longChapter = longBook.chapters.first;
  final deepAnchor = longChapter.anchors['long-deep']!;

  _ContinuousBridge longBridge({FlutterReadingState? readingState}) =>
      bridge(epub: longEpub, unitCount: 2, readingState: readingState);

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// The column region the chapter's view shows, in content coordinates.
  ({double top, double bottom}) shown(WidgetTester tester) {
    final position = chapterScroll(tester);
    return (
      top: position.pixels - kEpubPageMargin,
      bottom: position.pixels + position.viewportDimension - kEpubPageMargin,
    );
  }

  /// Asserts the laid-out window covers what the view shows.
  void expectWindowCoversView(WidgetTester tester) {
    final page = dartPage(tester)!;
    final window = page.window!;
    final view = shown(tester);
    expect(
      window.nodeTops[window.firstNode],
      lessThanOrEqualTo(math.max(0, view.top) + 0.5),
      reason: 'the window starts above the viewport',
    );
    expect(
      window.nodeTops[window.endNode],
      greaterThanOrEqualTo(math.min(window.nodeTops.last, view.bottom) - 0.5),
      reason: 'the window ends below the viewport',
    );
  }

  /// Asserts [scalar]'s line was revealed at the top of the view.
  void expectRevealed(WidgetTester tester, int scalar) {
    final page = dartPage(tester)!;
    expect(page.targetScalar, scalar);
    final position = chapterScroll(tester);
    if (scalar == 0) {
      expect(position.pixels, 0);
      return;
    }
    expect(
      position.pixels,
      closeTo(lineTop(page, scalar) - kEpubPageMargin, 1),
      reason: 'the target line is at the top of the view',
    );
  }

  /// Scrolls the chapter by [dy] with a mouse wheel over the view's corner.
  Future<void> scrollBy(WidgetTester tester, double dy) async {
    final view = find.byKey(const ValueKey('reader-continuous-presentation'));
    final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
    final at = tester.getBottomLeft(view) + const Offset(30, -30);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await settle(tester);
  }

  testWidgets('a 250K-scalar chapter reads continuously from a window', (
    tester,
  ) async {
    expect(longChapter.scalarCount, greaterThan(250000));
    await openReader(tester, longBridge());
    await settle(tester);

    final page = dartPage(tester)!;
    expect(page.unit, 0);
    expect(page.continuous, isTrue);
    expect(
      find.byKey(const ValueKey('reader-continuous-presentation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-paginated-presentation')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('reader-edge-next')), findsNothing);
    final window = page.window!;
    expect(window.firstNode, 0);
    expect(
      window.endNode,
      lessThan(longChapter.blocks.length ~/ 20),
      reason: 'only the nodes near the viewport are laid out',
    );
    expect(
      page.canonicalEnd - page.canonicalStart,
      lessThan(longChapter.scalarCount ~/ 20),
      reason: 'the selection surface covers the window, not the chapter',
    );
    final position = chapterScroll(tester);
    expect(
      position.maxScrollExtent,
      greaterThan(position.viewportDimension * 100),
      reason: 'the scroll extent covers the whole chapter',
    );
    expect(window.nodeTops, hasLength(longChapter.blocks.length + 1));
    expectWindowCoversView(tester);

    await closeReader(tester);
  });

  testWidgets('scrolling moves the window in bounded steps and releases what '
      'it leaves', (tester) async {
    final sessions = <ChapterLayoutSession>[];
    final steps = <({int micros, int measured})>[];
    final harness = longBridge();
    await openReader(
      tester,
      harness,
      sessionObserver: (session) {
        session.debugObservePainters = true;
        sessions.add(session);
      },
      stepObserver: steps.add,
    );
    await settle(tester);
    final session = sessions.last;

    var maxLaidOut = 0;
    var maxLive = 0;
    var maxSurface = 0;
    var maxSteps = 0;
    for (var drag = 0; drag < 24; drag += 1) {
      final before = steps.length;
      await scrollBy(tester, 2400);
      expectWindowCoversView(tester);
      maxSteps = math.max(maxSteps, steps.length - before);
      final page = dartPage(tester)!;
      maxSurface = math.max(
        maxSurface,
        page.canonicalEnd - page.canonicalStart,
      );
      maxLaidOut = math.max(maxLaidOut, session.laidOutNodes);
      maxLive = math.max(
        maxLive,
        session.debugCreatedPainters
            .where((painter) => !painter.debugDisposed)
            .length,
      );
    }
    final window = dartPage(tester)!.window!;
    final saved = harness.savedReadingStates.last;
    expect(saved.unit, BigInt.zero);
    expect(saved.offset!.toInt(), greaterThan(0));
    expect(
      saved.progress,
      saved.offset!.toInt() /
          longBook.chapters.fold<int>(
            0,
            (sum, chapter) => sum + chapter.scalarCount,
          ),
      reason: 'scrolling saves the same canonical fraction as the location',
    );
    final percentage = (saved.progress! * 100).round().clamp(1, 99);
    expect(find.textContaining('$percentage% · page '), findsOneWidget);
    expect(window.firstNode, greaterThan(0), reason: 'the start was released');
    expect(
      session.debugCreatedPainters.where((painter) => painter.debugDisposed),
      isNotEmpty,
      reason: 'released nodes release their paragraphs',
    );
    // The window keeps a few viewports either side, whatever was scrolled.
    expect(maxLaidOut, lessThan(longChapter.blocks.length ~/ 10));
    expect(maxLive, lessThanOrEqualTo(maxLaidOut + 2 * kContinuousBatchNodes));
    expect(
      maxSurface,
      lessThan(longChapter.scalarCount ~/ 20),
      reason: 'selection geometry covers the window, not the chapter',
    );
    // One step is one bounded batch, and a drag takes only the batches that
    // fill the window around the view: then the steps stop.
    expect(steps, isNotEmpty);
    expect(
      steps.map((step) => step.measured).reduce(math.max),
      kContinuousBatchNodes,
    );
    expect(
      maxSteps,
      lessThanOrEqualTo(maxLaidOut ~/ kContinuousBatchNodes + 1),
      reason: 'each drag settles in a few steps',
    );

    await closeReader(tester);
  });

  testWidgets('measuring above the viewport does not move what it shows', (
    tester,
  ) async {
    // A restored location deep in the chapter is laid out first; the nodes
    // above it are measured afterwards, and their estimates are wrong.
    final target = longChapter.anchors['long-deep']!;
    await openReader(
      tester,
      longBridge(
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(target),
          zoom: 1,
        ),
      ),
    );
    await settle(tester);
    expectRevealed(tester, target);
    final window = dartPage(tester)!.window!;
    expect(
      window.firstNode,
      lessThan(longChapter.blocks.length * 3 ~/ 4),
      reason: 'the window grew above the restored location',
    );

    // Scrolling up measures more nodes above; the line stays under the
    // pointer that dragged it.
    final before =
        lineTop(dartPage(tester)!, target) - chapterScroll(tester).pixels;
    await scrollBy(tester, -500);
    expect(chapterScroll(tester).pixels, isNot(0));
    expectWindowCoversView(tester);
    expect(
      lineTop(dartPage(tester)!, target) - chapterScroll(tester).pixels,
      closeTo(before + 500, 1),
    );

    await closeReader(tester);
  });

  testWidgets('a restored location deep in a long chapter is revealed', (
    tester,
  ) async {
    final target = longChapter.scalarCount - 40;
    await openReader(
      tester,
      longBridge(
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(target),
          zoom: 1,
        ),
      ),
    );
    await settle(tester);
    final page = dartPage(tester)!;
    expect(page.targetScalar, target);
    final position = chapterScroll(tester);
    final line = lineTop(page, target);
    expect(
      line >= position.pixels &&
          line <= position.pixels + position.viewportDimension,
      isTrue,
      reason: 'the restored line, near the chapter end, is in view',
    );
    expectWindowCoversView(tester);

    await closeReader(tester);
  });

  testWidgets('Contents entries reveal their targets in a long chapter', (
    tester,
  ) async {
    wide(tester);
    await openReader(tester, longBridge());
    await settle(tester);

    await openContentsEntry(tester, 'Long deep');
    expectRevealed(tester, deepAnchor);
    expectWindowCoversView(tester);

    // The chapter start, from deep in the chapter.
    await openContentsEntry(tester, 'Long start');
    expectRevealed(tester, 0);
    expectWindowCoversView(tester);

    // The same deep entry again, after scrolling away by hand.
    await openContentsEntry(tester, 'Long deep');
    await scrollBy(tester, 3000);
    await openContentsEntry(tester, 'Long deep');
    expectRevealed(tester, deepAnchor);

    await closeReader(tester);
  });

  testWidgets('a link reveals its target in a long chapter', (tester) async {
    await openReader(tester, longBridge());
    await settle(tester);

    final page = dartPage(tester)!;
    final link = longChapter.canonicalText.indexOf('Jump to the deep');
    final rect = page.surface.endpoints
        .firstWhere((endpoint) => endpoint.offset == BigInt.from(link + 2))
        .rect;
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('reader-selection-surface')),
    );
    await tester.tapAt(
      origin +
          Offset((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reader-reference-go-to')));
    await settle(tester);
    expectRevealed(tester, deepAnchor);
    expectWindowCoversView(tester);

    await closeReader(tester);
  });

  testWidgets('a search hit reveals its target in a long chapter', (
    tester,
  ) async {
    wide(tester);
    final harness = longBridge();
    final hit = longChapter.canonicalText.indexOf('Paragraph 2001 ');
    harness.matches = [
      FlutterSearchMatch(
        unit: BigInt.zero,
        offset: BigInt.from(hit),
        length: BigInt.from(14),
        context: 'Paragraph 2001',
      ),
    ];
    await openReader(tester, harness);
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('reader-header-search')));
    await tester.pump();
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('reader-search-input')),
      'Paragraph 2001',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expectRevealed(tester, hit);
    expectWindowCoversView(tester);

    await closeReader(tester);
  });

  testWidgets('a bookmark reveals its target in a long chapter', (
    tester,
  ) async {
    wide(tester);
    final harness = longBridge();
    final mark = longChapter.canonicalText.indexOf('Paragraph 1501 ');
    harness.bookmarks = [
      FlutterBookmark(
        id: 7,
        bookId: 1,
        unit: BigInt.zero,
        offset: BigInt.from(mark),
        title: 'Deep mark',
        color: 'yellow',
        createdAt: '2026-10-21',
      ),
    ];
    await openReader(tester, harness);
    await settle(tester);

    // Saved places are listed in the Contents panel.
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settle(tester);
    final open = find.byKey(const ValueKey('reader-saved-place-open-7'));
    await tester.ensureVisible(open);
    await tester.pump();
    await tester.tap(open);
    await settle(tester);
    expectRevealed(tester, mark);
    expectWindowCoversView(tester);

    await closeReader(tester);
  });

  Set<TextPainter> collectedSlices(ReaderEpubPage page) {
    final painters = <TextPainter>{};
    collectPainters([
      for (final slice in page.page.slices) slice.block,
    ], painters);
    return painters;
  }

  PagePainter highlightPainter(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<PagePainter>()
      .single;

  /// The selection endpoints of the window inside [start]..[end] that the view
  /// shows.
  Iterable<FlutterSelectionEndpoint> shownInRange(
    WidgetTester tester,
    int start,
    int end,
  ) {
    final view = shown(tester);
    return dartPage(tester)!.surface.endpoints.where(
      (endpoint) =>
          endpoint.rangeStart.toInt() < end &&
          start < endpoint.rangeEnd.toInt() &&
          endpoint.rect.bottom > view.top + kEpubPageMargin &&
          endpoint.rect.top < view.bottom + kEpubPageMargin,
    );
  }

  testWidgets('a highlight longer than any window paints in every window', (
    tester,
  ) async {
    final harness = longBridge();
    final start = longChapter.canonicalText.indexOf('Paragraph 100 ');
    final end = longChapter.canonicalText.indexOf('Paragraph 900 ');
    harness.annotations = [
      FlutterAnnotation(
        id: 'long',
        unit: BigInt.zero,
        resolution: FlutterAnnotationResolution.exact,
        textRange: FlutterAnnotationTextRange(
          start: BigInt.from(start),
          end: BigInt.from(end),
        ),
        color: FlutterHighlightColor.green,
      ),
    ];
    await openReader(tester, harness);
    await settle(tester);

    // Scroll to the highlight's first node, which is not laid out yet.
    final node = longChapter.blocks.lastIndexWhere(
      (block) => (block.canonical?.start ?? 0) <= start,
    );
    await scrollBy(tester, dartPage(tester)!.window!.nodeTops[node]);
    var windows = <int>{};
    for (var drag = 0; drag < 12; drag += 1) {
      expect(
        highlightPainter(tester).savedSelections.map((saved) => saved.start),
        [start],
      );
      expect(
        shownInRange(tester, start, end),
        isNotEmpty,
        reason: 'the highlight paints the text the view shows',
      );
      windows.add(dartPage(tester)!.window!.firstNode);
      await scrollBy(tester, 3000);
    }
    expect(windows.length, greaterThan(1), reason: 'across window boundaries');

    await closeReader(tester);
  });

  testWidgets('a selection survives its window being released and laid out '
      'again', (tester) async {
    await openReader(tester, longBridge());
    await settle(tester);

    final page = dartPage(tester)!;
    final from = longChapter.canonicalText.indexOf('Paragraph 3 ');
    final to = longChapter.canonicalText.indexOf('Paragraph 9 ');
    FlutterSelectionRect rectOf(ReaderEpubPage page, int offset) => page
        .surface
        .endpoints
        .firstWhere((endpoint) => endpoint.offset == BigInt.from(offset))
        .rect;
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('reader-selection-surface')),
    );
    final a = rectOf(page, from);
    final b = rectOf(page, to);
    final gesture = await tester.startGesture(
      origin + Offset(a.left + 1, (a.top + a.bottom) / 2),
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.moveTo(origin + Offset(b.left + 1, (b.top + b.bottom) / 2));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    final selected = highlightPainter(tester);
    expect((selected.anchor, selected.focus), (from, to));
    final painted = shownInRange(tester, from, to).map((e) => e.rect).toList();
    expect(painted, isNotEmpty);

    // Far enough that the selected nodes are released, then back.
    for (var drag = 0; drag < 12; drag += 1) {
      await scrollBy(tester, 3000);
    }
    expect(dartPage(tester)!.window!.firstNode, greaterThan(9));
    expect(
      (highlightPainter(tester).anchor, highlightPainter(tester).focus),
      (from, to),
      reason: 'the selection outlives the window that showed it',
    );
    for (var drag = 0; drag < 13; drag += 1) {
      await scrollBy(tester, -3000);
    }
    expect(chapterScroll(tester).pixels, 0);
    expect(
      (highlightPainter(tester).anchor, highlightPainter(tester).focus),
      (from, to),
    );
    expect(
      shownInRange(tester, from, to).map((e) => e.rect).toList(),
      painted,
      reason: 'the text laid out again is selected at the same place',
    );

    await closeReader(tester);
  });
  testWidgets('keyboard selection moves from a focus outside the window and '
      'across its edges', (tester) async {
    await openReader(tester, longBridge());
    await settle(tester);

    final page = dartPage(tester)!;
    final text = longChapter.canonicalText;
    final from = text.indexOf('Paragraph 3 ');
    final to = text.indexOf('Paragraph 9 ');
    FlutterSelectionRect rectOf(ReaderEpubPage page, int offset) => page
        .surface
        .endpoints
        .firstWhere((endpoint) => endpoint.offset == BigInt.from(offset))
        .rect;
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('reader-selection-surface')),
    );
    final a = rectOf(page, from);
    final b = rectOf(page, to);
    final gesture = await tester.startGesture(
      origin + Offset(a.left + 1, (a.top + a.bottom) / 2),
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.moveTo(origin + Offset(b.left + 1, (b.top + b.bottom) / 2));
    await tester.pump();
    await gesture.up();
    await settle(tester);
    int? focus() => highlightPainter(tester).focus;
    expect(focus(), to);

    // Scroll far enough that the selected nodes are released.
    for (var drag = 0; drag < 12; drag += 1) {
      await scrollBy(tester, 3000);
    }
    expect(dartPage(tester)!.window!.firstNode, greaterThan(9));

    Future<void> press(LogicalKeyboardKey key, {bool alt = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
    }

    // A word movement reads the chapter's own boundaries around the focus:
    // the next word boundary, not the window's first one.
    await press(LogicalKeyboardKey.arrowRight, alt: true);
    expect(focus(), to + 'Paragraph'.length);
    expect(highlightPainter(tester).anchor, from);

    // A visual movement lays the focus out again, reveals it, and moves.
    await press(LogicalKeyboardKey.arrowRight);
    expect(focus(), to + 'Paragraph'.length + 1);
    final position = chapterScroll(tester);
    final caret = rectOf(dartPage(tester)!, focus()!);
    expect(
      caret.top >= position.pixels &&
          caret.bottom <= position.pixels + position.viewportDimension,
      isTrue,
      reason: 'the focus is revealed',
    );

    // Line by line, past the edge of the restarted window: every press moves.
    var previous = focus()!;
    for (var line = 0; line < 30; line += 1) {
      await press(LogicalKeyboardKey.arrowDown);
      expect(focus(), greaterThan(previous), reason: 'line $line moves');
      previous = focus()!;
    }
    for (var line = 0; line < 40; line += 1) {
      await press(LogicalKeyboardKey.arrowUp);
      expect(focus(), lessThan(previous), reason: 'line $line moves back');
      previous = focus()!;
    }
    expect(highlightPainter(tester).anchor, from);

    await closeReader(tester);
  });

  testWidgets('Select All selects and copies the whole chapter', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    MethodCall? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard = call;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openReader(tester, longBridge());
    await settle(tester);

    // The document's own screen-reader action selects everything.
    final node = tester.getSemantics(
      find.byKey(const ValueKey('reader-content-semantics')),
    );
    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        type: ui.SemanticsAction.tap,
        viewId: tester.view.viewId,
        nodeId: node.id,
      ),
    );
    await settle(tester);
    expect(
      (highlightPainter(tester).anchor, highlightPainter(tester).focus),
      (0, longChapter.scalarCount),
    );
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect((clipboard?.arguments as Map?)?['text'], longChapter.canonicalText);

    await closeReader(tester);
    semantics.dispose();
  });

  testWidgets('a jump into unmeasured atomic nodes lays out where the view '
      'is, without chasing it', (tester) async {
    // A text-only first window, then a long run of rules (no text, so their
    // extent is the atomic estimate until measured), then text again.
    final epub = buildTestEpub(
      chapters: {
        'OPS/Text/chapter-1.xhtml':
            '${'<p>A paragraph before the rules, long enough to wrap onto a '
                    'second line at this width, so the first window is text.</p>' * 80}'
            '${'<hr/>' * 600}'
            '${'<p>A paragraph after the rules.</p>' * 300}',
        'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
      },
      nav: '<ol></ol>',
    );
    final steps = <({int micros, int measured})>[];
    await openReader(
      tester,
      bridge(epub: epub, unitCount: 2),
      stepObserver: steps.add,
    );
    await settle(tester);
    final tops = dartPage(tester)!.window!.nodeTops;
    expect(dartPage(tester)!.window!.endNode, lessThan(80));

    // Into the rule run, beyond the window.
    final target = tops[120] + 100;
    await scrollBy(
      tester,
      target + kEpubPageMargin - chapterScroll(tester).pixels,
    );
    // A rule is about a pixel tall in the column, so filling the view takes
    // hundreds of them however the window starts: settle until it stops.
    for (var round = 0, count = -1; round < 8 && count != steps.length;) {
      count = steps.length;
      round += 1;
      await settle(tester);
    }
    expectWindowCoversView(tester);
    expect(
      dartPage(tester)!.window!.firstNode,
      greaterThan(40),
      reason: 'the window restarted at the view instead of walking to it',
    );
    // Measuring the rules above the view moves the column; the view keeps the
    // node it jumped to on screen instead of being carried past the run.
    final window = dartPage(tester)!.window!;
    final atTop = continuousNodeAt(
      Float64List.fromList(window.nodeTops),
      chapterScroll(tester).pixels - kEpubPageMargin,
    );
    expect(atTop, inInclusiveRange(110, 130));

    await closeReader(tester);
  });

  testWidgets('a failed window step keeps the blocks its page paints, and '
      'releases them once', (tester) async {
    final sessions = <ChapterLayoutSession>[];
    await openReader(
      tester,
      longBridge(),
      sessionObserver: (session) {
        session.debugObservePainters = true;
        sessions.add(session);
      },
    );
    await settle(tester);
    final session = sessions.last;
    final painted = <TextPainter>{};
    collectPainters([
      for (final slice in dartPage(tester)!.page.slices) slice.block,
    ], painted);
    expect(painted, isNotEmpty);

    // A jump restarts the window; its first painter fails.
    session.debugFailTextBlockAt = session.debugCreatedPainters.length + 1;
    await scrollBy(tester, 60000);
    expect(
      painted.where((painter) => painter.debugDisposed),
      isEmpty,
      reason: 'the page still installed paints them',
    );
    expect(
      collectedSlices(dartPage(tester)!).containsAll(painted),
      isTrue,
      reason: 'the failed step installed nothing',
    );

    // The next step succeeds and replaces the page: they are released.
    session.debugFailTextBlockAt = null;
    await scrollBy(tester, 400);
    expectWindowCoversView(tester);
    expect(painted.every((painter) => painter.debugDisposed), isTrue);

    await closeReader(tester);
  });

  testWidgets('measuring above a node taller than the view does not move '
      'what it shows', (tester) async {
    wide(tester);
    // Rules and short paragraphs whose estimates are far off, then one
    // paragraph taller than the view and its lead together, so the window
    // around its first lines is that paragraph alone.
    final epub = buildTestEpub(
      chapters: {
        'OPS/Text/chapter-1.xhtml':
            // The first window calibrates the estimate on long paragraphs.
            '${'<p>${'A paragraph of the chapter start, long enough to '
                        'wrap. ' * 6}</p>' * 40}'
            '${'<p>x</p><hr/>' * 300}'
            '<p>${'A sentence of a paragraph far taller than the view, '
                    'which the window around its first lines is. ' * 4}'
            '<span id="tall">A target a few lines into it.</span> '
            '${'A sentence of a paragraph far taller than the view, which '
                    'the window around its first lines is. ' * 200}'
            '</p>'
            '${'<p>After the tall paragraph.</p>' * 40}',
        'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
      },
      nav: '<ol><li><a href="../Text/chapter-1.xhtml#tall">Tall</a></li></ol>',
    );
    final target = openEpubBytes(epub).chapters.first.anchors['tall']!;
    await openReader(tester, bridge(epub: epub, unitCount: 2));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settle(tester);
    await tester.tap(inContents('Tall'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reader-reference-go-to')));
    // Frame by frame, while the nodes above are measured: the target line
    // stays where the reader sees it.
    final shownAt = <double>[];
    final firstNodes = <int>{};
    for (var frame = 0; frame < 120; frame += 1) {
      await pumpHarnessFrames(tester, frames: 1);
      if (frame.isEven) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      final page = dartPage(tester);
      final position = chapterScroll(tester);
      if (page == null || page.targetScalar != target || position.pixels <= 0) {
        continue;
      }
      shownAt.add(lineTop(page, target) - position.pixels);
      firstNodes.add(page.window!.firstNode);
    }
    await settle(tester);
    expect(
      firstNodes.length,
      greaterThan(2),
      reason: 'nodes above were measured while the view was watched',
    );
    expect(shownAt.first, closeTo(kEpubPageMargin, 1), reason: 'revealed');
    for (final at in shownAt) {
      expect(at, closeTo(shownAt.first, 1));
    }
    expect(
      lineTop(dartPage(tester)!, target) - chapterScroll(tester).pixels,
      closeTo(shownAt.first, 1),
    );

    await closeReader(tester);
  });

  /// A chapter whose middle is a long run of rules, one of them a Contents
  /// target: a window there has no text, so no line to reveal.
  final ruleEpub = buildTestEpub(
    chapters: {
      'OPS/Text/chapter-1.xhtml':
          '${'<p>A paragraph before the rules.</p>' * 80}'
          '${'<hr/>' * 800}<hr id="rule-target"/>${'<hr/>' * 800}'
          '${'<p>A paragraph after the rules.</p>' * 100}',
      'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
    },
    nav:
        '<ol>'
        '<li><a href="../Text/chapter-1.xhtml">Rule start</a></li>'
        '<li><a href="../Text/chapter-1.xhtml#rule-target">Rule target</a></li>'
        '</ol>',
  );
  final ruleChapter = openEpubBytes(ruleEpub).chapters.first;
  final ruleTarget = ruleChapter.anchors['rule-target']!;

  /// Asserts the rule target's node is laid out and in view.
  void expectRuleShown(WidgetTester tester) {
    final page = dartPage(tester)!;
    expect(page.targetScalar, ruleTarget);
    final window = page.window!;
    final node = window.targetNode!;
    expect(node, inInclusiveRange(window.firstNode, window.endNode - 1));
    final view = shown(tester);
    expect(
      window.nodeTops[node],
      inInclusiveRange(view.top - 0.5, view.bottom),
      reason: 'the target rule is in view, not the chapter start',
    );
  }

  testWidgets('a location on a node without text reveals the node', (
    tester,
  ) async {
    wide(tester);
    await openReader(
      tester,
      bridge(
        epub: ruleEpub,
        unitCount: 2,
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(ruleTarget),
          zoom: 1,
        ),
      ),
    );
    await settle(tester);
    await settle(tester);
    expectRuleShown(tester);

    // From the chapter start, by its Contents entry, and once more after
    // scrolling away by hand.
    await openContentsEntry(tester, 'Rule start');
    expect(chapterScroll(tester).pixels, 0);
    await openContentsEntry(tester, 'Rule target');
    await settle(tester);
    expectRuleShown(tester);
    await scrollBy(tester, 4000);
    await openContentsEntry(tester, 'Rule target');
    await settle(tester);
    expectRuleShown(tester);

    await closeReader(tester);
  });

  Future<void> pressShifted(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool settled = true,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (settled) await settle(tester);
  }

  /// Drags a selection on the page shown from [from] to [to].
  Future<void> dragSelect(WidgetTester tester, int from, int to) async {
    final page = dartPage(tester)!;
    FlutterSelectionRect rectOf(int offset) => page.surface.endpoints
        .firstWhere((endpoint) => endpoint.offset == BigInt.from(offset))
        .rect;
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('reader-selection-surface')),
    );
    final a = rectOf(from);
    final b = rectOf(to);
    final gesture = await tester.startGesture(
      origin + Offset(a.left + 1, (a.top + a.bottom) / 2),
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.moveTo(origin + Offset(b.left + 1, (b.top + b.bottom) / 2));
    await tester.pump();
    await gesture.up();
    await settle(tester);
  }

  testWidgets('a visual movement from the chapter end after Select All moves '
      'back', (tester) async {
    final semantics = tester.ensureSemantics();
    await openReader(tester, longBridge());
    await settle(tester);
    final node = tester.getSemantics(
      find.byKey(const ValueKey('reader-content-semantics')),
    );
    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        type: ui.SemanticsAction.tap,
        viewId: tester.view.viewId,
        nodeId: node.id,
      ),
    );
    await settle(tester);
    expect(highlightPainter(tester).focus, longChapter.scalarCount);
    // Select All shows the actions; the reader returns to the text.
    Focus.of(
      tester.element(find.byKey(const ValueKey('reader-content-semantics'))),
    ).requestFocus();
    await tester.pump();

    // The chapter's end is the separator after its last block: no caret is
    // there, so the movement lands on the last one before it.
    await pressShifted(tester, LogicalKeyboardKey.arrowLeft);
    final focus = highlightPainter(tester).focus!;
    expect(focus, lessThan(longChapter.scalarCount));
    expect(focus, greaterThan(longChapter.scalarCount - 20));
    expect(highlightPainter(tester).anchor, 0);
    await pressShifted(tester, LogicalKeyboardKey.arrowLeft);
    expect(highlightPainter(tester).focus, lessThan(focus));

    await closeReader(tester);
    semantics.dispose();
  });

  testWidgets('keyboard selection moves from text while the view shows only '
      'rules, and across the rules', (tester) async {
    final text = ruleChapter.canonicalText;
    final from = text.indexOf('A paragraph before');
    final to = from + 'A paragraph'.length;
    await openReader(tester, bridge(epub: ruleEpub, unitCount: 2));
    await settle(tester);
    await dragSelect(tester, from, to);
    expect(highlightPainter(tester).focus, to);

    // Into the run of rules, until the window there paints no text.
    for (
      var jump = 0;
      jump < 6 && dartPage(tester)!.window!.firstNode <= 80;
      jump += 1
    ) {
      final tops = dartPage(tester)!.window!.nodeTops;
      await scrollBy(
        tester,
        tops[80 + 800] + kEpubPageMargin - chapterScroll(tester).pixels,
      );
      await settle(tester);
    }
    expect(dartPage(tester)!.window!.firstNode, greaterThan(80));
    expect(dartPage(tester)!.surface.visualLines, isEmpty);

    // The focus is laid out again and moves.
    await pressShifted(tester, LogicalKeyboardKey.arrowRight);
    expect(highlightPainter(tester).focus, to + 1);
    expect(highlightPainter(tester).anchor, from);

    await closeReader(tester);
  });

  testWidgets('a line movement crosses a run of rules it lays out over '
      'several frames', (tester) async {
    final text = ruleChapter.canonicalText;
    final last = text.lastIndexOf('A paragraph before');
    await openReader(
      tester,
      bridge(
        epub: ruleEpub,
        unitCount: 2,
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(last),
          zoom: 1,
        ),
      ),
    );
    await settle(tester);
    await dragSelect(tester, last, last + 'A paragraph'.length);
    // Back to the start, so the rules and the text after them are released.
    await scrollBy(tester, -chapterScroll(tester).pixels);
    await settle(tester);
    expect(dartPage(tester)!.window!.endNode, lessThan(80));

    // The focus's window is laid out again a batch at a time; the movement
    // waits for the line after the rules instead of being dropped.
    await pressShifted(tester, LogicalKeyboardKey.arrowDown);
    for (var round = 0; round < 12; round += 1) {
      await settle(tester);
    }
    final after = text.indexOf('A paragraph after');
    expect(
      highlightPainter(tester).focus,
      inInclusiveRange(after, after + 'A paragraph after the rules.'.length),
      reason: 'the line after the rules',
    );
    expect(highlightPainter(tester).anchor, last);

    await closeReader(tester);
  });

  testWidgets('a line movement crosses a gap taller than the window keeps, '
      'both ways, and the window stays bounded', (tester) async {
    final epub = buildTestEpub(
      chapters: {
        'OPS/Text/chapter-1.xhtml':
            '${'<p>A paragraph before the rules.</p>' * 80}'
            '${'<hr/>' * 6000}'
            '${'<p>A paragraph after the rules.</p>' * 100}',
        'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
      },
      nav: '<ol></ol>',
    );
    final chapter = openEpubBytes(epub).chapters.first;
    final text = chapter.canonicalText;
    final last = text.lastIndexOf('A paragraph before');
    final after = text.indexOf('A paragraph after');
    final steps = <({int micros, int measured})>[];
    await openReader(
      tester,
      bridge(
        epub: epub,
        unitCount: 2,
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(last),
          zoom: 1,
        ),
      ),
      stepObserver: steps.add,
    );
    await settle(tester);
    await dragSelect(tester, last, last + 'A paragraph'.length);

    final position = chapterScroll(tester);
    final gap =
        dartPage(tester)!.window!.nodeTops[80 + 6000] -
        dartPage(tester)!.window!.nodeTops[80];
    expect(gap, greaterThan(4 * position.viewportDimension));

    var widest = 0;
    Future<void> settleUntil(bool Function() done) async {
      await pumpUntil(tester, done, (window) {
        widest = math.max(widest, window.endNode - window.firstNode);
      });
    }

    bool inAfter(int? focus) =>
        focus != null &&
        focus >= after &&
        focus <= after + 'A paragraph after the rules.'.length;
    await pressShifted(tester, LogicalKeyboardKey.arrowDown, settled: false);
    await settleUntil(() => inAfter(highlightPainter(tester).focus));
    expect(
      inAfter(highlightPainter(tester).focus),
      isTrue,
      reason: 'the line after the gap',
    );
    expect(highlightPainter(tester).anchor, last);
    expect(
      widest,
      lessThan(3000),
      reason: 'the window never holds the whole gap',
    );

    // Back up across it.
    bool inLast(int? focus) =>
        focus != null &&
        focus >= last &&
        focus <= last + 'A paragraph before the rules.'.length;
    await pressShifted(tester, LogicalKeyboardKey.arrowUp, settled: false);
    await settleUntil(() => inLast(highlightPainter(tester).focus));
    expect(inLast(highlightPainter(tester).focus), isTrue);
    expect(widest, lessThan(3000));

    // Then the window follows the view again (a few hundred rules at a
    // batch a frame), and its steps stop.
    var count = -1;
    for (var round = 0; round < 30 && count != steps.length; round += 1) {
      count = steps.length;
      await settle(tester);
    }
    expect(steps.length, count, reason: 'no step is scheduled once settled');
    expectWindowCoversView(tester);

    await closeReader(tester);
  });

  testWidgets('a backward line movement across a gap lands on the nearest '
      'paragraph before it, past a tall one', (tester) async {
    // Tall paragraphs, then the paragraph nearest the gap: a search that
    // restarts further back and lays out forward would stop after a tall
    // paragraph and never examine the nearer one.
    final epub = buildTestEpub(
      chapters: {
        'OPS/Text/chapter-1.xhtml':
            '${'<p>${'A sentence of a paragraph taller than several views. ' * 160}</p>' * 10}'
            '<p>The paragraph nearest the gap.</p>'
            '${'<hr/>' * _backwardGap}'
            '${'<p>A paragraph after the rules.</p>' * 40}',
        'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
      },
      nav: '<ol></ol>',
    );
    final text = openEpubBytes(epub).chapters.first.canonicalText;
    final near = text.indexOf('The paragraph nearest the gap.');
    final after = text.indexOf('A paragraph after');
    final steps = <({int micros, int measured})>[];
    await openReader(
      tester,
      bridge(
        epub: epub,
        unitCount: 2,
        readingState: FlutterReadingState(
          unit: BigInt.zero,
          offset: BigInt.from(after),
          zoom: 1,
        ),
      ),
      stepObserver: steps.add,
    );
    await settle(tester);
    // The window fills the view's lead with rules a batch a frame.
    for (var round = 0, count = -1; round < 30 && count != steps.length;) {
      count = steps.length;
      round += 1;
      await settle(tester);
    }
    await dragSelect(tester, after, after + 'A paragraph'.length);

    await pressShifted(tester, LogicalKeyboardKey.arrowUp, settled: false);
    bool landed() => (highlightPainter(tester).focus ?? after) < after;
    var widest = 0;
    await pumpUntil(tester, landed, (window) {
      widest = math.max(widest, window.endNode - window.firstNode);
    });
    expect(
      highlightPainter(tester).focus,
      near + 'A paragraph'.length,
      reason:
          'the paragraph nearest the gap, not a tall one before it, in the '
          "focus's column",
    );
    expect(
      widest,
      lessThan(3000),
      reason: 'the search never holds the whole gap',
    );
    expect(highlightPainter(tester).anchor, after);

    await closeReader(tester);
  });

  test('selection geometry is built as one run of nodes, toward the '
      'priority point', () {
    final session = ChapterLayoutSession(
      chapter: longChapter,
      spec: const ChapterLayoutSpec(
        width: 632,
        height: 552,
        typography: ReaderEpubTypography(
          fontFamily: 'Inter',
          fontFamilyFallback: ['Noto Sans JP'],
          fontSize: 18,
          lineHeight: 1.5,
          palette: ReaderEpubPalette(
            background: ui.Color(0xFFFFFFFF),
            foreground: ui.Color(0xFF1A1A1A),
            link: ui.Color(0xFF174EA6),
            tableHeaderBackground: ui.Color(0xFFE8EEF8),
            tableHeaderBorder: ui.Color(0xFF596B89),
          ),
        ),
      ),
      images: const {},
    )..layoutWindowAt(0, maxNodes: 40, viewports: 100);
    final extents = ContinuousExtents(longChapter);
    final cache = ContinuousGeometryCache(longChapter);
    ReaderEpubPage window(double priorityTop) => continuousWindowFor(
      session: session,
      extents: extents,
      cache: cache,
      scalar: 0,
      unit: 0,
      chapterCount: 2,
      windowSize: const ui.Size(680, 600),
      priorityTop: priorityTop,
      selectionBudgetMicros: 0,
    );
    Set<int> built(ReaderEpubPage page) => {
      for (final line in page.surface.visualLines)
        for (final caret in line.carets)
          session.nodeIndexForScalar(caret.offset.toInt()),
    };
    // Near the top first, then near the window's bottom: the second step
    // builds the node next to the first run, not the one at the bottom.
    final first = window(0);
    final top = built(first);
    expect(top, isNotEmpty);
    final bottom = first.window!.nodeTops[39];
    var page = first;
    for (var step = 0; step < 4; step += 1) {
      page = window(bottom);
      final nodes = built(page).toList()..sort();
      expect(
        nodes.last - nodes.first + 1,
        nodes.length,
        reason: 'no node is pending between two built ones',
      );
    }
    expect(built(page).reduce(math.max), greaterThan(top.reduce(math.max)));
    expect(cache.selectionPending, isTrue);
    session.dispose();
  });

  test('a report against an older window is corrected as the view is', () {
    const before = ReaderEpubWindow(
      firstNode: 2,
      endNode: 3,
      nodeTops: [0, 1000, 2000, 2100],
    );
    // Measuring above the laid-out node moves it up by 900: the view keeps
    // it in place, so a view top 200 above it is 200 above its new top.
    expect(
      continuousCorrectedTop(
        before,
        const ReaderEpubWindow(
          firstNode: 1,
          endNode: 3,
          nodeTops: [0, 1000, 1100, 1200],
        ),
        1800,
      ),
      900,
    );
    // A restarted window keeps the view's place in the node under it.
    expect(
      continuousCorrectedTop(
        before,
        const ReaderEpubWindow(
          firstNode: 1,
          endNode: 2,
          nodeTops: [0, 1000, 1100, 1200],
          restartedAt: 1,
        ),
        1800,
      ),
      1100,
    );
  });

  test('a window step measures one batch and keeps released nodes in '
      'place', () {
    final session = ChapterLayoutSession(
      chapter: longChapter,
      spec: const ChapterLayoutSpec(
        width: 632,
        height: 552,
        typography: ReaderEpubTypography(
          fontFamily: 'Inter',
          fontFamilyFallback: ['Noto Sans JP'],
          fontSize: 18,
          lineHeight: 1.5,
          palette: ReaderEpubPalette(
            background: ui.Color(0xFFFFFFFF),
            foreground: ui.Color(0xFF1A1A1A),
            link: ui.Color(0xFF174EA6),
            tableHeaderBackground: ui.Color(0xFFE8EEF8),
            tableHeaderBorder: ui.Color(0xFF596B89),
          ),
        ),
      ),
      images: const {},
      clock: _stillClock,
    )..layoutWindowAt(0);
    final extents = ContinuousExtents(longChapter);
    final cache = ContinuousGeometryCache(longChapter);
    ReaderEpubPage window() => continuousWindowFor(
      session: session,
      extents: extents,
      cache: cache,
      scalar: 0,
      unit: 0,
      chapterCount: 2,
      windowSize: const ui.Size(680, 600),
    );
    final first = window();
    final probe = longChapter.canonicalText.indexOf('Paragraph 5 ');
    double topOf(ReaderEpubPage page) => page.surface.endpoints
        .firstWhere((endpoint) => endpoint.offset == BigInt.from(probe))
        .rect
        .top;
    final probeTop = topOf(first);

    // Down the chapter, one step at a time.
    var top = 0.0;
    var steps = 0;
    final released = <FlowBlock>[];
    while (steps < 400) {
      final before = session.laidOutNodes;
      final beforeEnd = session.lastNodeIndex;
      final step = advanceContinuousWindow(
        session: session,
        extents: extents,
        viewportTop: top,
        viewportBottom: top + 600,
        released: released,
      );
      expect(
        session.lastNodeIndex - beforeEnd,
        lessThanOrEqualTo(kContinuousBatchNodes),
      );
      expect(session.laidOutNodes, lessThanOrEqualTo(before + 8));
      final page = window();
      top += step.changed ? 0 : 1200;
      steps += 1;
      if (page.window!.firstNode > 200) break;
    }
    expect(session.firstNodeIndex, greaterThan(200));
    expect(released, isNotEmpty);
    disposeFlowBlocks(released);

    // Back to the start: the probe is laid out again, at the same top. The
    // window can reach the first node before it covers the probe; step until
    // it covers the viewport.
    for (var step = 0; step < 400; step += 1) {
      final detached = <FlowBlock>[];
      final result = advanceContinuousWindow(
        session: session,
        extents: extents,
        viewportTop: 0,
        viewportBottom: 600,
        released: detached,
      );
      window();
      disposeFlowBlocks(detached);
      if (session.firstNodeIndex == 0 && !result.pending) break;
    }
    expect(session.firstNodeIndex, 0);
    expect(topOf(window()), probeTop);
    session.dispose();
  });
}
