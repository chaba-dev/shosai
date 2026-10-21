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

  _ContinuousBridge bridge({FlutterReadingState? readingState}) {
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
      unitCount: book.chapters.length,
      readingState: readingState,
    );
    harness.epubBytes = bytes;
    return harness;
  }

  Future<void> openReader(WidgetTester tester, HarnessBridge harness) async {
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/navigation.epub',
          initialBookId: 1,
          initialSettings: _continuous,
          epubImageDecoder: (bytes) async => null,
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
