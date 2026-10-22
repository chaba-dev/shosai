import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/view.dart';

import '../support/epub_navigation_fixture.dart';
import '../support/production_shell_harness.dart';

/// The book's direction in the production reader: a right-to-left book (the
/// spine's `page-progression-direction`) reads its spread's right page first
/// and turns leftward; an undeclared book reads left to right.
void main() {
  HarnessBridge bridge(String? pageProgression) {
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
    harness.epubBytes = longChapterEpub(
      paragraphs: 80,
      pageProgression: pageProgression,
    );
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
  }) async {
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await renderHarnessState(
      tester,
      productionShell(
        home: ReaderScreen(
          bridge: harness,
          initialPath: '/books/long.epub',
          initialBookId: 1,
          initialSettings: settings,
          epubImageDecoder: (bytes) async => null,
        ),
      ),
      ready: () => harnessReaderPageReady(tester),
      maxRounds: 16,
    );
    await settle(tester);
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

    await tester.tap(find.byKey(const ValueKey('reader-edge-previous')));
    await settle(tester);
    expect(
      page(tester).canonicalStart,
      first.canonicalStart,
      reason: 'the right margin turns back to the first spread',
    );

    await closeReader(tester);
  });

  testWidgets('a right-to-left book\'s progress track starts at its right '
      'end', (tester) async {
    await openReader(tester, bridge('rtl'));
    final track = find.byKey(const ValueKey('reader-progress-track'));

    // The left end of the track is the end of the book. The place beside the
    // track changes its width, so each tap measures it again.
    var rect = tester.getRect(track);
    await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
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
}
