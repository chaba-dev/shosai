import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

  Future<void> openReader(WidgetTester tester, HarnessBridge harness) async {
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
