import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/pdf/column_strip.dart';
import 'package:shosai_flutter/shell/view.dart';

/// Real PDFium, records and reader gestures on a packaged host. An absolute
/// fixture path also lets the iOS simulator read the host's test corpus.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixtureRoot = String.fromEnvironment(
    'SHOSAI_FIXTURES',
    defaultValue: 'fixtures',
  );
  const captureDirectory = String.fromEnvironment('SHOSAI_COLUMNS_CAPTURE');
  const demo = bool.fromEnvironment('SHOSAI_COLUMNS_DEMO');

  Future<void> pinch(
    WidgetTester tester,
    Offset center,
    double from,
    double to,
  ) async {
    final left = await tester.startGesture(
      center - Offset(from, 0),
      pointer: 11,
    );
    final right = await tester.startGesture(
      center + Offset(from, 0),
      pointer: 12,
    );
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      final span = from + (to - from) * i / 8;
      await left.moveTo(center - Offset(span, 0));
      await right.moveTo(center + Offset(span, 0));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await left.up();
    await right.up();
  }

  Future<void> captureView(GlobalKey key, String name) async {
    if (captureDirectory.isEmpty) return;
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(captureDirectory).create(recursive: true);
    await File(
      '$captureDirectory/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
  }

  testWidgets(
    'Continuous Columns scrolls, names pages and keeps place when switched',
    (tester) async {
      // Keep the engine's real physical size so simulator recordings receive
      // frames too; only the logical test viewport is fixed.
      await binding.setSurfaceSize(const Size(440, 900));
      addTearDown(() => binding.setSurfaceSize(null));
      tester.view.viewPadding = FakeViewPadding(
        top: 59 * tester.view.devicePixelRatio,
        bottom: 34 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.reset);
      final directory = await Directory.systemTemp.createTemp(
        'shosai-continuous-columns-',
      );
      final path = '${directory.path}/Thrift.pdf';
      await File('$fixtureRoot/pdf-columns/thrift.pdf').copy(path);
      var bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      final cancellation = bridge.createCancellation();
      await bridge.importPaths(
        pathKeys: [path],
        managed: false,
        cancellationId: cancellation,
      );
      final book = (await bridge.libraryPage(
        limit: 10,
        offset: 0,
        cancellationId: cancellation,
      )).books.single;
      bridge.releaseCancellation(id: cancellation);
      final continuous = ValueNotifier(false);
      final captureKey = GlobalKey();
      final raster = find.byKey(const ValueKey('reader-columns-raster'));
      final area = find.byKey(const ValueKey('reader-page-tap-area'));
      PagePainter? painting() {
        for (final custom in tester.widgetList<CustomPaint>(
          find.byType(CustomPaint),
        )) {
          if (custom.painter case final PagePainter p) return p;
        }
        return null;
      }

      PdfStripScreen? screen() => painting()?.columns;
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 400 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(ready(), isTrue);
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        await captureView(captureKey, name);
        if (demo) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 2)),
          );
        }
      }

      Future<FlutterReadingState> saved() async {
        final cancellation = bridge.createCancellation();
        try {
          for (var i = 0; i < 100; i++) {
            final state = await bridge.loadReadingState(
              bookId: book.bookId,
              cancellationId: cancellation,
            );
            if (state?.pdfY != null) return state!;
            await tester.pump(const Duration(milliseconds: 30));
          }
          throw StateError('No saved PDF place');
        } finally {
          bridge.releaseCancellation(id: cancellation);
        }
      }

      final app = ShosaiShell(
        home: ValueListenableBuilder<bool>(
          valueListenable: continuous,
          builder: (context, enabled, _) => RepaintBoundary(
            key: captureKey,
            child: ReaderScreen(
              bridge: bridge,
              initialPath: path,
              initialBookId: book.bookId,
              initialSettings: FlutterReaderSettings(
                continuous: enabled,
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
      await tester.pumpWidget(app);
      await until(() => screen() != null);
      expect(screen()!.continuous, isFalse);
      await capture('screens-default');
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      final initial = screen();
      await until(() => screen() != initial);
      final before = await saved();
      continuous.value = true;
      await until(() => screen()?.continuous == true);
      final after = await saved();
      expect(after.unit, before.unit);
      expect(after.pdfY, closeTo(before.pdfY!, .01));
      expect(after.pdfX, closeTo(before.pdfX!, .01));
      await capture('continuous-entry');
      final rect = tester.getRect(area);
      final origin = tester.getTopLeft(raster);
      final previous = await saved();
      await tester.drag(area, const Offset(0, -160));
      await tester.pumpAndSettle();
      final moved = tester.getTopLeft(raster);
      expect(moved.dy, lessThan(origin.dy - 100));
      final scrolled = await saved();
      expect(scrolled.pdfY, isNot(previous.pdfY));
      expect(find.byKey(const ValueKey('reader-page-curl')), findsNothing);
      expect(find.byKey(const ValueKey('reader-columns-slide')), findsNothing);
      await capture('continuous-scrolled');
      final surface = painting()!.surface;
      final contentOrigin = tester.getTopLeft(
        find.byKey(const ValueKey('reader-selection-surface')),
      );
      Offset center(FlutterSelectionEndpoint e) =>
          contentOrigin +
          Offset(
            (e.rect.left + e.rect.right) / 2,
            (e.rect.top + e.rect.bottom) / 2,
          );
      final visible = surface.endpoints
          .where((e) => rect.deflate(140).contains(center(e)))
          .toList();
      final from = visible.first;
      final to = visible.firstWhere(
        (e) => e.offset > from.offset + BigInt.from(10),
      );
      final mouse = await tester.startGesture(
        center(from),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(center(to));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(painting()!.anchor, isNot(painting()!.focus));
      await tester.tap(find.byKey(const ValueKey('selection-swatch-yellow')));
      await until(() => painting()!.annotations.isNotEmpty);
      final mark = painting()!.annotations.single;
      expect(mark.unit, scrolled.unit);
      expect(mark.textRange!.end, greaterThan(mark.textRange!.start));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await capture('continuous-highlight');
      // Middle tap still reveals chrome without moving the strip.
      await tester.tapAt(rect.center);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-header-typography')).hitTestable(),
        findsOneWidget,
      );
      expect((await saved()).pdfY, closeTo(scrolled.pdfY!, .01));
      await capture('continuous-chrome');
      await tester.tapAt(rect.center);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      continuous.value = false;
      await until(() => screen()?.continuous == false);
      final restored = await saved();
      expect(restored.unit, scrolled.unit);
      expect(
        restored.pdfY,
        closeTo(scrolled.pdfY!, 15),
        reason: 'Screens may align to the start of the same physical row',
      );
      expect(restored.pdfX, closeTo(scrolled.pdfX!, .01));
      await capture('screens-restored-place');
      continuous.value = true;
      await until(() => screen()?.continuous == true);
      final named = <int>{};
      var sawRule = false;
      var sawPage = false;
      var checkedBoundary = false;
      for (var i = 0; i < 100; i++) {
        final top =
            rect.top + 59 + pdfStripHeaderHeight - tester.getTopLeft(raster).dy;
        final first = screen()!.pieces.firstWhere(
          (p) => p.top + p.height > top,
        );
        if (!checkedBoundary &&
            first.top <= top &&
            first.page !=
                screen()!.visiblePage(top, screen()!.viewportHeight!)) {
          // A later page dominates the viewport, but its preceding tail is
          // still the durable visual anchor, not the later page's beginning.
          final anchor = first.toPage(first.left, top);
          final place = await saved();
          expect(place.unit.toInt(), first.page);
          expect(place.pdfY, closeTo(anchor.y, .01));
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await closeApplicationCores();
          bridge = await createApplicationBridge(
            applicationSupportDirectory: () async => directory,
          );
          await tester.pumpWidget(app);
          await until(() => screen()?.continuous == true);
          double visibleHeight() {
            final piece = screen()!.pieces.firstWhere(
              (p) => p.page == first.page && p.region == first.region,
            );
            return tester.getTopLeft(raster).dy +
                piece.fromPage(anchor.x, anchor.y).y;
          }

          expect(
            visibleHeight(),
            closeTo(rect.top + 59 + pdfStripHeaderHeight, 1),
          );
          continuous.value = false;
          await until(() => screen()?.continuous == false);
          continuous.value = true;
          await until(() => screen()?.continuous == true);
          // Screens aligns the same physical row; it must not drop the tail.
          expect(
            visibleHeight(),
            closeTo(rect.top + 59 + pdfStripHeaderHeight, 30),
          );
          checkedBoundary = true;
        }
        final folio = find.descendant(
          of: find.byKey(const ValueKey('reader-columns-folio')),
          matching: find.byType(Text),
        );
        final text = tester.widget<Text>(folio).data!;
        final numbers = RegExp(
          r'\d+',
        ).allMatches(text).map((m) => int.parse(m.group(0)!)).toList();
        for (
          var page = numbers.first;
          page <= (numbers.length == 3 ? numbers[1] : numbers.first);
          page++
        ) {
          named.add(page);
        }
        sawRule |= screen()!.separators.any((s) => s.page == null);
        sawPage |= screen()!.separators.any((s) => s.page != null);
        if (named.contains(8)) break;
        await tester.drag(area, const Offset(0, -250));
        await tester.pumpAndSettle();
        if (i == 4 || i == 12) await capture('continuous-strip-$i');
      }
      expect(named, containsAll([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(sawRule && sawPage, isTrue);
      expect(checkedBoundary, isTrue);
      final lastPlace = await saved();
      expect(lastPlace.unit, greaterThan(BigInt.zero));
      await capture('continuous-last-page');
      // Scroll backward through another raster window, not just within one.
      for (var i = 0; i < 40; i++) {
        await tester.drag(area, const Offset(0, 250));
        await tester.pumpAndSettle();
        if ((await saved()).unit < lastPlace.unit) break;
      }
      final backPlace = await saved();
      expect(backPlace.unit, lessThan(lastPlace.unit));
      await capture('continuous-backward');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await tester.pumpWidget(app);
      await until(() => screen()?.continuous == true);
      final reopened = await saved();
      expect(reopened.unit, backPlace.unit);
      expect(reopened.pdfY, closeTo(backPlace.pdfY!, .01));
      expect(painting()!.annotations.single.id, mark.id);
      await capture('continuous-reopened');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      continuous.dispose();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['short', 'figure', 'refused']) {
    testWidgets(
      switch (mode) {
        'short' => 'PageDown is harmless on a short continuous PDF',
        'figure' =>
          'Continuous figure detail returns to its visible strip position',
        _ =>
          'Refused detail keeps the continuous strip and its visible position',
      },
      (tester) async {
        await binding.setSurfaceSize(const Size(440, 900));
        addTearDown(() => binding.setSurfaceSize(null));
        final directory = await Directory.systemTemp.createTemp(
          'columns-detail-',
        );
        final path = '${directory.path}/Control.pdf';
        final source = File(
          '$fixtureRoot/pdf-columns/${mode == 'figure' ? 'right-column-figure' : 'scanned'}.pdf',
        );
        if (mode == 'refused') {
          // Equal-length replacements preserve xref/stream lengths. This
          // tall fallback admits crisp viewport crops, but not whole detail.
          await File(path).writeAsBytes(
            latin1.encode(
              latin1
                  .decode(await source.readAsBytes())
                  .replaceFirst(
                    '/MediaBox [0 0 612 792]',
                    '/MediaBox [0 0 010 792]',
                  )
                  .replaceFirst('q 612 0 0 792', 'q 010 0 0 792'),
            ),
          );
        } else {
          await source.copy(path);
        }
        final bridge = await createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        );
        PdfStripScreen? screen() {
          for (final custom in tester.widgetList<CustomPaint>(
            find.byType(CustomPaint),
          )) {
            if (custom.painter case final PagePainter p) return p.columns;
          }
          return null;
        }

        Future<void> until(bool Function() ready) async {
          for (var i = 0; i < 400 && !ready(); i++) {
            await tester.pump(const Duration(milliseconds: 30));
          }
          expect(ready(), isTrue);
          await tester.pumpAndSettle();
        }

        final captureKey = GlobalKey();
        await tester.pumpWidget(
          ShosaiShell(
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                bridge: bridge,
                initialPath: path,
                initialSettings: const FlutterReaderSettings(
                  continuous: true,
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
        await until(() => screen()?.continuous == true);
        final raster = find.byKey(const ValueKey('reader-columns-raster'));
        if (mode == 'short') {
          final initial = screen();
          final last = initial!.pieces.last;
          expect(last.top + last.height, lessThan(initial.viewportHeight!));
          for (var i = 0; i < 4; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
            await tester.pumpAndSettle();
          }
          expect(screen(), same(initial));
        } else {
          final area = find.byKey(const ValueKey('reader-page-tap-area'));
          Rect visibleFigure() {
            final piece = screen()!.pieces.firstWhere((p) => p.zoomable);
            return (tester.getTopLeft(raster) + Offset(piece.left, piece.top) &
                    Size(piece.width, piece.height))
                .intersect(tester.getRect(area).deflate(100));
          }

          for (var i = 0; i < 30 && visibleFigure().height < 200; i++) {
            await tester.drag(area, const Offset(0, -200));
            await tester.pumpAndSettle();
          }
          expect(visibleFigure().height, greaterThanOrEqualTo(200));
          // Pan within the installed window, not just to its initial anchor.
          await tester.drag(area, const Offset(0, -80));
          await tester.pumpAndSettle();
          final before = screen()!;
          final origin = tester.getTopLeft(raster).dy;
          final piece = before.pieces.firstWhere((p) => p.zoomable);
          final y =
              tester.getTopLeft(raster).dy +
              piece.fromPage(piece.source.left, piece.source.top).y;
          await pinch(tester, visibleFigure().center, 30, 90);
          if (mode == 'refused') {
            await until(() => screen() != before);
            expect(screen()!.continuous, isTrue);
            expect(screen()!.strip, isNull);
          } else {
            await until(() => screen()?.strip != null);
            await pinch(tester, tester.getRect(area).center, 90, 25);
            await until(() => screen()?.continuous == true);
          }
          final restored = screen()!.pieces.firstWhere(
            (p) => p.page == piece.page && p.region == piece.region,
          );
          final restoredY =
              tester.getTopLeft(raster).dy +
              restored.fromPage(piece.source.left, piece.source.top).y;
          expect(
            restoredY,
            closeTo(y, 1),
            reason: 'detail must not return to overscan at $origin',
          );
          await captureView(captureKey, 'continuous-$mode-detail-return');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await closeApplicationCores();
        await directory.delete(recursive: true);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Settings changes keep the PDF Columns page and height', (
    tester,
  ) async {
    await binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => binding.setSurfaceSize(null));
    addTearDown(tester.view.reset);
    final directory = await Directory.systemTemp.createTemp(
      'columns-settings-',
    );
    final path = '${directory.path}/Thrift.pdf';
    await File('$fixtureRoot/pdf-columns/thrift.pdf').copy(path);
    final owner = await applicationCoreOwner(
      applicationSupportDirectory: () async => directory,
    );
    final bridge = owner.bridge();
    final cancellation = bridge.createCancellation();
    await bridge.importPaths(
      pathKeys: [path],
      managed: false,
      cancellationId: cancellation,
    );
    final book = (await bridge.libraryPage(
      limit: 10,
      offset: 0,
      cancellationId: cancellation,
    )).books.single;
    bridge.releaseCancellation(id: cancellation);
    await bridge.saveReaderSettings(
      value: const FlutterReaderSettings(
        continuous: false,
        theme: 'light',
        epubFontSize: 18,
        epubLineSpacing: 1.6,
        pdfZoom: 0,
        pdfFit: FlutterPdfFit.columns,
        twoPages: false,
        zonesHintDismissed: true,
      ),
    );
    PdfStripScreen? screen() {
      for (final custom in tester.widgetList<CustomPaint>(
        find.byType(CustomPaint),
      )) {
        if (custom.painter case final PagePainter p) return p.columns;
      }
      return null;
    }

    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 400 && !ready(); i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(ready(), isTrue);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(ShosaiApp(productBridgeFactory: owner.bridge));
    final card = find.byWidgetPredicate((widget) => widget is LibraryBookCard);
    await until(() => card.evaluate().isNotEmpty);
    await tester.tap(card.first);
    await until(() => screen() != null);
    for (var i = 0; i < 3; i++) {
      final previous = screen();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await until(() => screen() != previous);
    }
    for (final enabled in [true, false]) {
      await tester.tap(find.byTooltip('Settings'));
      await until(() => find.text('Continuous reading').evaluate().isNotEmpty);
      // Leaving the reader drains its save before Settings becomes interactive.
      final c = bridge.createCancellation();
      final before = (await bridge.loadReadingState(
        bookId: book.bookId,
        cancellationId: c,
      ))!;
      await tester.tap(find.text('Continuous reading'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ShellSidebar),
          matching: find.text(book.title),
        ),
      );
      await until(() => screen()?.continuous == enabled);
      await ReaderController.drainBookWrites(book.bookId.toInt());
      final after = (await bridge.loadReadingState(
        bookId: book.bookId,
        cancellationId: c,
      ))!;
      bridge.releaseCancellation(id: c);
      expect(after.unit, before.unit);
      expect(after.pdfY, closeTo(before.pdfY!, 15));
      expect(after.pdfX, closeTo(before.pdfX!, .01));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await closeApplicationCores();
    await directory.delete(recursive: true);
    expect(tester.takeException(), isNull);
  });
}
