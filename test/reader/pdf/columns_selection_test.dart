import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../../support/production_shell_harness.dart' show loadHarnessFonts;

PagePainter? painting(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<PagePainter>()
    .firstOrNull;

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(ready(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadHarnessFonts);

  testWidgets(
    'touch selects the painted rows before and after Columns reopen',
    (tester) async {
      tester.view.physicalSize = const Size(880, 1800);
      tester.view.devicePixelRatio = 2;
      tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
      addTearDown(tester.view.reset);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('columns-selection-'),
      ))!;
      Future<void> close() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        var closed = false;
        unawaited(closeApplicationCores().then((_) => closed = true));
        await until(tester, () => closed);
      }

      addTearDown(() async {
        await close();
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      final path = '${directory.path}/Thrift.pdf';
      await tester.runAsync(
        () => File('fixtures/pdf-columns/thrift.pdf').copy(path),
      );
      var bridge = (await tester.runAsync(
        () => createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        ),
      ))!;
      final cancellation = bridge.createCancellation();
      await tester.runAsync(
        () => bridge.importPaths(
          pathKeys: [path],
          managed: false,
          cancellationId: cancellation,
        ),
      );
      final book = (await tester.runAsync(
        () => bridge.libraryPage(
          limit: 10,
          offset: 0,
          cancellationId: cancellation,
        ),
      ))!.books.single;
      bridge.releaseCancellation(id: cancellation);
      final geometry = (await tester.runAsync(() async {
        final pdf = await PdfrxPdfEngine().open(path);
        try {
          return await pdf.pageGeometry(0);
        } finally {
          await pdf.dispose();
        }
      }))!;
      // Enter the right column well below its top, then reopen from the
      // persisted page point rather than injecting a second destination.
      final destination = geometry.lines.firstWhere(
        (l) => l.bounds.left > 316 && l.bounds.top >= 342,
      );
      final captureKey = GlobalKey();
      Future<void> capture(String name) async {
        final output = Platform.environment['SHOSAI_COLUMNS_ARTIFACTS'];
        if (output == null) return;
        final boundary =
            captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await Directory(output).create(recursive: true);
        await File(
          '$output/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      }

      Future<void> open({bool jump = false}) async {
        await tester.pumpWidget(
          ShosaiShell(
            locale: const Locale('ja'),
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                key: UniqueKey(),
                bridge: bridge,
                initialPath: path,
                initialBookId: book.bookId,
                initialPlace: jump
                    ? ReaderPlace(0, offset: destination.start)
                    : null,
                initialSettings: const FlutterReaderSettings(
                  continuous: false,
                  theme: 'light',
                  epubFontSize: 18,
                  epubLineSpacing: 1.6,
                  pdfZoom: 0,
                  pdfFit: FlutterPdfFit.columns,
                  twoPages: false,
                  zonesHintDismissed: true,
                ),
              ),
            ),
          ),
        );
        await until(tester, () => painting(tester)?.columns != null);
      }

      await open(jump: true);
      String? expectedQuote;
      double? savedTop;
      for (final restored in [false, true]) {
        if (restored) {
          await close();
          bridge = (await tester.runAsync(
            () => createApplicationBridge(
              applicationSupportDirectory: () async => directory,
            ),
          ))!;
          await open();
        }
        final paint = painting(tester)!;
        final piece = paint.columns!.pieces.first;
        if (restored) {
          expect(piece.source.top, closeTo(savedTop!, 1));
        } else {
          savedTop = piece.source.top;
        }
        if (restored) {
          final restoredScreen = paint.columns!;
          await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
          await until(
            tester,
            () => painting(tester)!.columns != restoredScreen,
          );
          final previous = painting(tester)!.columns!;
          expect(previous.next.page, restoredScreen.start.page);
          expect(previous.next.region, restoredScreen.start.region);
          expect(previous.next.y, restoredScreen.start.y);
          expect(
            previous.pieces.last.source.bottom,
            piece.source.top,
            reason: 'the previous crop ends exactly at the restored crop',
          );
          final regionRows = geometry.lines.where(
            (row) =>
                row.bounds.left >= piece.source.left &&
                row.bounds.right <= piece.source.right &&
                row.bounds.top >= previous.pieces.last.source.top &&
                row.bounds.bottom <= piece.source.bottom,
          );
          expect(regionRows.length, greaterThan(10));
          for (final row in regionRows) {
            expect(
              [
                ...previous.pieces,
                ...restoredScreen.pieces,
              ].where((p) => p.source.contains(row.bounds)),
              hasLength(1),
              reason:
                  'each original physical row occurs exactly once: ${row.text}',
            );
          }
          // Traverse farther back and then forward twice: the arbitrary
          // restored boundary must survive history, not only the first turn.
          await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
          await until(tester, () => painting(tester)!.columns != previous);
          final earlier = painting(tester)!.columns;
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
          await until(tester, () => painting(tester)!.columns != earlier);
          expect(painting(tester)!.columns!.next.y, restoredScreen.start.y);
          final returnedPrevious = painting(tester)!.columns;
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
          await until(
            tester,
            () => painting(tester)!.columns != returnedPrevious,
          );
          final returned = painting(tester)!.columns!;
          expect(returned.start.page, restoredScreen.start.page);
          expect(returned.start.region, restoredScreen.start.region);
          expect(returned.start.y, restoredScreen.start.y);
          expect(returned.pieces.first.source.top, piece.source.top);
          expect(returned.pieces.first.source.bottom, piece.source.bottom);
        }
        final rows =
            geometry.lines
                .where(
                  (l) =>
                      l.bounds.left >= piece.source.left &&
                      l.bounds.right <= piece.source.right &&
                      l.bounds.top > piece.source.top + 100 &&
                      l.bounds.bottom < piece.source.bottom,
                )
                .toList()
              ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
        final first = rows[0];
        final second = rows[1];
        expectedQuote = '${first.text}\r\n${second.text}';
        final box = tester.getRect(
          find.byKey(const ValueKey('reader-selection-surface')),
        );
        // Follow raster placement independently of the selection mapper: a
        // translation bug in fromPage must not move the test's finger too.
        Offset point(double x, double y) =>
            box.topLeft +
            Offset(
              piece.left + (x - piece.source.left) * piece.scale,
              piece.top + (y - piece.source.top) * piece.scale,
            );

        final finger = await tester.startGesture(
          point(
            first.bounds.left + 1,
            (first.bounds.top + first.bounds.bottom) / 2,
          ),
          kind: ui.PointerDeviceKind.touch,
        );
        // No selection messages are dispatched by the test: the real gesture
        // must win the arena before a drag can extend it to the following row.
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          painting(tester)!.anchor,
          inInclusiveRange(first.start, first.end),
          reason: 'long press hits the painted row; restored=$restored',
        );
        await finger.moveTo(
          point(
            second.bounds.right - 1,
            (second.bounds.top + second.bounds.bottom) / 2,
          ),
        );
        await finger.up();
        await tester.pumpAndSettle();
        expect(
          painting(tester)!.focus,
          inInclusiveRange(second.start, second.end),
        );
        final selected = painting(tester)!;
        expect(selected.anchor, lessThan(second.start));
        expect(selected.focus, greaterThan(second.start));
        if (!restored) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
      }
      await tester.runAsync(() => capture('restored-selection'));
      await tester.tap(find.byKey(const ValueKey('selection-swatch-yellow')));
      await until(tester, () => painting(tester)!.annotations.isNotEmpty);
      expect(painting(tester)!.annotations.single.quote, expectedQuote);
      final notes = find.byKey(const ValueKey('reader-header-notes'));
      if (notes.hitTestable().evaluate().isEmpty) {
        await tester.tapAt(const Offset(220, 120));
        await until(tester, () => notes.hitTestable().evaluate().isNotEmpty);
      }
      expect(notes.hitTestable(), findsOneWidget);
      await tester.tap(notes);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-notes-heading')),
        findsOneWidget,
      );
      final quote = find.text(expectedQuote!);
      expect(quote, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(quote);
      expect(paragraph.didExceedMaxLines, isFalse);
      await tester.ensureVisible(quote);
      await tester.pumpAndSettle();
      await tester.runAsync(() => capture('notes-quote'));
      await close();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
