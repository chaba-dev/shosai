import 'dart:math' as math;
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

/// A chapter of [paragraphs] numbered paragraphs (about 250K scalars at the
/// default), alternating short and long so a node's estimated extent is not
/// its measured one, with a link at the start to an anchor three quarters in.
Uint8List _longChapterEpub({int paragraphs = 2400}) {
  final deep = paragraphs * 3 ~/ 4;
  final body = StringBuffer(
    '<h1 id="long-start">Long chapter</h1>'
    '<p>Start of the chapter. <a href="#long-deep">Jump to the deep '
    'anchor</a>.</p>',
  );
  for (var index = 0; index < paragraphs; index += 1) {
    if (index == deep) {
      body.write('<h2 id="long-deep">Deep anchor</h2>');
    }
    body.write(
      index.isEven
          ? '<p>Paragraph $index is short.</p>'
          : '<p>Paragraph $index is a long paragraph of a very long chapter, '
                'which reads continuously however long it is, because only '
                'the part of it near the viewport is laid out, and the rest '
                'reserves its estimated height until it is measured.</p>',
    );
  }
  return buildTestEpub(
    chapters: {
      'OPS/Text/chapter-1.xhtml': body.toString(),
      'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
    },
    nav:
        '<ol>'
        '<li><a href="../Text/chapter-1.xhtml">Long start</a></li>'
        '<li><a href="../Text/chapter-1.xhtml#long-deep">Long deep</a></li>'
        '<li><a href="../Text/chapter-2.xhtml">Short chapter</a></li>'
        '</ol>',
  );
}

const _continuous = FlutterReaderSettings(
  continuous: true,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.5,
  pdfZoom: 0,
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
    void Function(int micros)? stepObserver,
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

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round += 1) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    await pumpHarnessFrames(tester, frames: 4);
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
    expect(dartPage(tester)!.unit, 0);

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
    // Wide enough that the contents panel sits beside the chapter.
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openReader(tester, bridge());
    await settle(tester);
    expect(chapterScroll(tester).pixels, 0);

    await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
    await tester.pump();
    await settle(tester);
    await tester.tap(find.text('Chapter one deep'));
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

  Future<void> openContentsEntry(WidgetTester tester, String title) async {
    if (find.text(title).evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('reader-header-contents')));
      await tester.pump();
      await settle(tester);
    }
    await tester.tap(find.text(title));
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

  final longEpub = _longChapterEpub();
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
    final steps = <int>[];
    await openReader(
      tester,
      longBridge(),
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
    for (var drag = 0; drag < 24; drag += 1) {
      await scrollBy(tester, 2400);
      expectWindowCoversView(tester);
      maxLaidOut = math.max(maxLaidOut, session.laidOutNodes);
      maxLive = math.max(
        maxLive,
        session.debugCreatedPainters
            .where((painter) => !painter.debugDisposed)
            .length,
      );
    }
    final window = dartPage(tester)!.window!;
    expect(window.firstNode, greaterThan(0), reason: 'the start was released');
    expect(
      session.debugCreatedPainters.where((painter) => painter.debugDisposed),
      isNotEmpty,
      reason: 'released nodes release their paragraphs',
    );
    // The window keeps a few viewports either side, whatever was scrolled.
    expect(maxLaidOut, lessThan(longChapter.blocks.length ~/ 10));
    expect(maxLive, lessThanOrEqualTo(maxLaidOut + 2 * kContinuousBatchNodes));
    // One step is one bounded batch: far below building the whole chapter
    // (about a second for this chapter on a desktop host).
    expect(steps, isNotEmpty);
    expect(steps.reduce(math.max), lessThan(100000));

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

    await tester.tap(find.byKey(const ValueKey('reader-header-more')));
    await tester.pump();
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reader-more-search')));
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
      );
      released.addAll(step.released);
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

    // Back to the start: the probe is laid out again, at the same top.
    for (var step = 0; step < 400 && session.firstNodeIndex > 0; step += 1) {
      advanceContinuousWindow(
        session: session,
        extents: extents,
        viewportTop: 0,
        viewportBottom: 600,
      ).released.forEach((block) => disposeFlowBlocks([block]));
      window();
    }
    expect(session.firstNodeIndex, 0);
    expect(topOf(window()), probeTop);
    session.dispose();
  });
}
