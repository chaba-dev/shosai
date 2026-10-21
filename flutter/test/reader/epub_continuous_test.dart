import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/epub/text_style.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/notices/notice.dart';
import 'package:shosai_flutter/notices/reader_notice_text.dart';

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

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async => readingState;
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
    expect(page.pageCount, 1);
    expect(page.layoutComplete, isTrue);
    expect(page.canonicalStart, 0);
    expect(
      page.canonicalEnd,
      greaterThanOrEqualTo(book.chapters.first.scalarCount - 1),
      reason: 'the one page holds the whole chapter',
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

  testWidgets('a chapter over the continuous ceiling is shown as pages', (
    tester,
  ) async {
    // Every paragraph is small, so no single block is refused, but the
    // chapter's text is over the continuous ceiling: a single continuous page
    // would build a selection surface for the whole chapter at once.
    const paragraph =
        '<p>A paragraph of ordinary length in a very long chapter, read '
        'one page at a time.</p>';
    final paragraphs = kEpubContinuousScalarLimit ~/ 80 + 16;
    final epub = buildTestEpub(
      chapters: {
        'OPS/Text/chapter-1.xhtml': paragraph * paragraphs,
        'OPS/Text/chapter-2.xhtml': '<p>A short chapter.</p>',
      },
      nav: '<ol></ol>',
    );
    final longBook = openEpubBytes(epub);
    expect(
      longBook.chapters.first.scalarCount,
      greaterThan(kEpubContinuousScalarLimit),
    );
    final notices = <NoticeRequest>[];
    await openReader(
      tester,
      bridge(epub: epub, unitCount: 2),
      noticeReporter: notices.add,
    );
    await settle(tester);

    final page = dartPage(tester)!;
    expect(page.unit, 0);
    expect(page.continuous, isFalse);
    expect(page.pageCount, greaterThan(1));
    expect(
      page.canonicalEnd - page.canonicalStart,
      lessThan(kEpubContinuousScalarLimit),
      reason: 'the surface covers one page, not the whole chapter',
    );
    expect(
      find.byKey(const ValueKey('reader-paginated-presentation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-continuous-presentation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('reader-edge-next')),
      findsOneWidget,
      reason: 'a paginated chapter turns pages',
    );
    expect(
      notices.where((notice) => notice.text is ReaderChapterPaginatedNotice),
      hasLength(1),
    );

    // PageDown turns a page inside the chapter instead of leaving it.
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await settle(tester);
    expect(dartPage(tester)!.unit, 0);
    expect(dartPage(tester)!.canonicalStart, greaterThan(0));

    await closeReader(tester);
  });

  test('a continuous window is the whole chapter in one page box', () {
    final chapter = book.chapters.first;
    final session = ChapterLayoutSession(
      chapter: chapter,
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
    while (!session.complete) {
      if (session.layoutForward() == 0) break;
    }
    final window = pageWindowFor(
      session: session,
      scalar: 40,
      unit: 0,
      chapterCount: book.chapters.length,
      windowSize: const ui.Size(680, 600),
      continuous: true,
    );
    expect(window.pageCount, 1);
    expect(window.targetScalar, 40);
    expect(window.box.size.width, 680);
    expect(window.box.size.height, window.page.height + 2 * kEpubPageMargin);
    expect(window.box.size.height, greaterThan(600));
    expect(window.canGoBackward, isFalse);
    expect(window.canGoForward, isTrue, reason: 'the next chapter');
    session.dispose();
  });
}
