import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/controller.dart'
    show ReaderPlace, ReaderPlaceRequests;
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/view.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// The book's direction in the production reader: a right-to-left book (the
/// spine's `page-progression-direction`) reads its spread's right page first
/// and turns leftward; an undeclared book reads left to right; a vertical
/// book reads down its columns, right to left.
void main() {
  HarnessBridge bridge(String? pageProgression, {Uint8List? epub}) {
    final harness = HarnessBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Long chapter',
          format: FlutterBookFormat.epub,
          pathKey: '/books/long.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-22',
        ),
      ],
      unitCount: 2,
    );
    harness.epubBytes =
        epub ??
        longChapterEpub(paragraphs: 80, pageProgression: pageProgression);
    return harness;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 6; round += 1) {
      await pumpHarnessFrames(tester, frames: 4);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
  }

  Future<void> openReader(
    WidgetTester tester,
    HarnessBridge harness, {
    FlutterReaderSettings? settings,
    ReaderPlaceRequests? placeRequests,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/long.epub',
          initialBookId: 1,
          initialSettings: (settings ?? harnessReaderSettings).copyWith(
            zonesHintDismissed: true,
          ),
          placeRequests: placeRequests,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settle(tester);
    await revealReaderChrome(tester);
  }

  Future<void> closeReader(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  ReaderEpubPage page(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      if (paint.painter case final ReaderEpubPageContentPainter painter) {
        return painter.page;
      }
    }
    fail('no EPUB page was painted');
  }

  double centreOf(WidgetTester tester, String key) =>
      tester.getCenter(find.byKey(ValueKey(key))).dx;

  for (final direction in ['ltr', 'rtl', 'vertical']) {
    testWidgets('swipes on EPUB furniture and margins turn $direction pages', (
      tester,
    ) async {
      for (final size in [const Size(390, 844), const Size(900, 1000)]) {
        await openReader(
          tester,
          bridge(
            direction == 'rtl' ? 'rtl' : null,
            epub: direction == 'vertical'
                ? verticalJapaneseEpub(paragraphs: 120, pageProgression: null)
                : null,
          ),
          size: size,
          settings: harnessReaderSettings.copyWith(twoPages: false),
        );
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('reader-stage'))),
        );
        await tester.pumpAndSettle();
        final movement = Offset(direction == 'ltr' ? -150 : 150, 0);
        for (final key in ['reader-folio', 'reader-running-head']) {
          final before = page(tester);
          await tester.drag(find.byKey(ValueKey(key)), movement);
          await settle(tester);
          expect(
            page(tester).canonicalStart,
            // A vertical paragraph boundary may skip its newline separator.
            inInclusiveRange(before.canonicalEnd, before.canonicalEnd + 1),
            reason: key,
          );
        }
        if (size.width > 600) {
          final rect = tester.getRect(
            find.byKey(const ValueKey('reader-page')),
          );
          final before = page(tester);
          await tester.dragFrom(Offset(rect.center.dx, rect.top + 8), movement);
          await settle(tester);
          expect(
            page(tester).canonicalStart,
            inInclusiveRange(before.canonicalEnd, before.canonicalEnd + 1),
            reason: 'paper margin',
          );
        }
        await closeReader(tester);
      }
    });
  }

  testWidgets('a right-to-left book reads right to left and turns leftward', (
    tester,
  ) async {
    await openReader(tester, bridge('rtl'));

    final first = page(tester);
    expect(first.rightToLeft, isTrue);
    expect(first.spread, isTrue);
    expect(
      first.box.origin.dx,
      greaterThan(first.facingBox!.origin.dx),
      reason: 'the first page is on the right',
    );
    expect(
      centreOf(tester, 'reader-edge-next'),
      lessThan(centreOf(tester, 'reader-edge-previous')),
      reason: 'the next page is behind the left margin',
    );

    await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
    await settle(tester);
    expect(
      page(tester).canonicalStart,
      first.facing!.canonicalEnd,
      reason: 'the left margin turns to the page after the spread',
    );

    await revealReaderChrome(tester);
    await tester.tap(find.byKey(const ValueKey('reader-edge-previous')));
    await settle(tester);
    expect(
      page(tester).canonicalStart,
      first.canonicalStart,
      reason: 'the right margin turns back to the first spread',
    );

    await closeReader(tester);
  });

  testWidgets('in right-to-left and vertical books Left turns forward and '
      'Right back, as their margins do', (tester) async {
    for (final epub in [
      longChapterEpub(paragraphs: 80, pageProgression: 'rtl'),
      verticalJapaneseEpub(paragraphs: 30, pageProgression: null),
    ]) {
      await openReader(tester, bridge(null, epub: epub));
      final first = page(tester);
      expect(first.spread, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(page(tester).pageIndex, first.pageIndex + 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(page(tester).pageIndex, first.pageIndex);

      await closeReader(tester);
    }
  });

  testWidgets('a right-to-left book\'s progress track starts at its right '
      'end', (tester) async {
    await openReader(tester, bridge('rtl'));
    final track = find.byKey(const ValueKey('reader-progress-track'));

    // The left end of the track is the end of the book. The place beside the
    // track changes its width, so each tap measures it again.
    var rect = tester.getRect(track);
    await tester.tapAt(Offset(rect.left, rect.center.dy));
    await settle(tester);
    expect(page(tester).unit, 1);
    rect = tester.getRect(track);
    await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
    await settle(tester);
    expect(page(tester).unit, 0);

    // The left arrow steps toward the end, the right arrow back.
    Focus.of(tester.element(track)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(page(tester).unit, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(page(tester).unit, 0);

    await closeReader(tester);
  });

  testWidgets('a right-to-left book read continuously keeps its direction', (
    tester,
  ) async {
    await openReader(
      tester,
      bridge('rtl'),
      settings: const FlutterReaderSettings(
        continuous: true,
        theme: 'light',
        epubFontSize: 18,
        epubLineSpacing: 1.6,
        pdfZoom: 0,
      ),
    );
    final continuous = page(tester);
    expect(continuous.continuous, isTrue);
    expect(continuous.rightToLeft, isTrue);
    await closeReader(tester);
  });

  testWidgets('an undeclared book reads left to right', (tester) async {
    await openReader(tester, bridge(null));

    final first = page(tester);
    expect(first.rightToLeft, isFalse);
    expect(first.box.origin.dx, lessThan(first.facingBox!.origin.dx));
    expect(
      centreOf(tester, 'reader-edge-next'),
      greaterThan(centreOf(tester, 'reader-edge-previous')),
    );

    await closeReader(tester);
  });

  testWidgets('a vertical book reads right to left even when its spine does '
      'not say', (tester) async {
    await openReader(
      tester,
      bridge(
        null,
        epub: verticalJapaneseEpub(paragraphs: 30, pageProgression: null),
      ),
    );

    final first = page(tester);
    expect(first.box.vertical, isTrue);
    expect(first.rightToLeft, isTrue);
    expect(first.box.origin.dx, greaterThan(first.facingBox!.origin.dx));
    expect(
      centreOf(tester, 'reader-edge-next'),
      lessThan(centreOf(tester, 'reader-edge-previous')),
    );

    await tester.tap(find.byKey(const ValueKey('reader-edge-next')));
    await settle(tester);
    expect(
      page(tester).pageIndex,
      first.pageIndex + 2,
      reason: 'the left margin turns to the next spread',
    );

    await closeReader(tester);
  });

  testWidgets('chapter-edge back keeps final spreads in RTL and vertical '
      'books and counts as one Back-pill turn', (tester) async {
    final cases = <({Uint8List bytes, bool vertical})>[
      (
        bytes: longChapterEpub(paragraphs: 80, pageProgression: 'rtl'),
        vertical: false,
      ),
      (
        bytes: verticalJapaneseEpub(paragraphs: 30, pageProgression: null),
        vertical: true,
      ),
    ];
    for (final testCase in cases) {
      final requests = ReaderPlaceRequests();
      final harness = bridge(null, epub: testCase.bytes);
      final parsed = openEpubBytes(testCase.bytes);
      await openReader(tester, harness, placeRequests: requests);
      requests.go(const ReaderPlace(1, offset: 0));
      await settle(tester);
      expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await settle(tester);
      final last = page(tester);
      expect(last.unit, parsed.chapters.first.spine);
      expect(last.spread, isTrue);
      expect(last.pageIndex.isEven, isTrue);
      expect(last.targetScalar, parsed.chapters.first.scalarCount);
      expect(
        last.canonicalEnd,
        greaterThanOrEqualTo(parsed.chapters.first.scalarCount - 1),
      );
      expect(last.rightToLeft, isTrue);
      expect(last.box.vertical, testCase.vertical);
      expect(last.box.origin.dx, greaterThan(last.facingBox?.origin.dx ?? -1));
      expect(
        find.byKey(const ValueKey('reader-back-pill')),
        findsOneWidget,
        reason: 'one accepted chapter-edge turn keeps Back available',
      );

      if (!testCase.vertical) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await settle(tester);
        expect(find.byKey(const ValueKey('reader-back-pill')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await settle(tester);
        expect(
          find.byKey(const ValueKey('reader-back-pill')),
          findsNothing,
          reason: 'the chapter-edge turn counts once toward the three turns',
        );
      }
      await closeReader(tester);
    }
  });

  testWidgets('a drag down a column selects and copies its text', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openReader(
      tester,
      bridge('rtl', epub: verticalJapaneseEpub(paragraphs: 30)),
    );

    const phrase = '名前はまだ無い';
    final text = paintedReaderSurface(tester).surface.text;
    final start = text.runes.toList().indexOf('名'.runes.single);
    final end = start + phrase.runes.length;
    final from = renderedEndpointCenter(tester, start);
    final to = renderedEndpointCenter(tester, end);
    expect(to.dy, greaterThan(from.dy), reason: 'the phrase runs down');
    expect((to.dx - from.dx).abs(), lessThan(1), reason: 'in one column');

    await dragReaderSelectionBetween(tester, from, to);
    await settleReaderSelection(tester);
    await tester.tap(find.text('Copy'));
    await settleReaderSelection(tester);
    expect(copied, [phrase]);

    await closeReader(tester);
  });

  testWidgets('the arrows extend a selection along a column and across '
      'columns', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await openReader(
      tester,
      bridge('rtl', epub: verticalJapaneseEpub(paragraphs: 30)),
    );

    const phrase = '名前はまだ無い';
    final surface = paintedReaderSurface(tester).surface;
    final runes = surface.text.runes.toList();
    final start = runes.indexOf('名'.runes.single);
    final end = start + phrase.runes.length;
    await dragReaderSelectionBetween(
      tester,
      renderedEndpointCenter(tester, start),
      renderedEndpointCenter(tester, end),
    );
    await settleReaderSelection(tester);

    Future<void> shift(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settleReaderSelection(tester);
    }

    Future<String> copy() async {
      await tester.tap(find.text('Copy'));
      await settleReaderSelection(tester);
      return copied.last;
    }

    // Down moves one character down the column.
    await shift(LogicalKeyboardKey.arrowDown);
    expect(await copy(), phrase + String.fromCharCode(runes[end]));
    await shift(LogicalKeyboardKey.arrowUp);
    expect(await copy(), phrase);

    // Left moves into the next column, to the left: the selection now runs
    // through the end of this column and into that one.
    final column = surface.visualLines.indexWhere(
      (line) => line.carets.any((caret) => caret.offset.toInt() == end),
    );
    final columnEnd = surface.visualLines[column].carets.last.offset.toInt();
    await shift(LogicalKeyboardKey.arrowLeft);
    final across = await copy();
    expect(across.runes.length, greaterThan(columnEnd - start));
    expect(across, startsWith(phrase));
    await shift(LogicalKeyboardKey.arrowRight);
    expect(await copy(), phrase);

    await closeReader(tester);
  });
}
