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

import '../test/support/reference_documents.dart';

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

  for (final rtl in [false, true]) {
    testWidgets('Continuous edge taps keep one line overlap (RTL $rtl)', (
      tester,
    ) async {
      await binding.setSurfaceSize(const Size(440, 900));
      addTearDown(() => binding.setSurfaceSize(null));
      final directory = await Directory.systemTemp.createTemp('columns-taps-');
      final path = '${directory.path}/Steps.pdf';
      await File(
        path,
      ).writeAsBytes(columnsAfterFrontMatterPdf(rightToLeft: rtl));
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
      final raster = find.byKey(const ValueKey('reader-columns-raster'));
      final area = find.byKey(const ValueKey('reader-page-tap-area'));
      PagePainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<PagePainter>()
          .single;
      PdfStripScreen screen() => painter().columns!;
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 400 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(ready(), isTrue);
        await tester.pumpAndSettle();
      }

      // A passive overscan refill legitimately replaces the screen object with
      // equivalent content while it serves scrolling. Identity-based assertions
      // must run against a strip whose pending loads have landed.
      Future<void> settle() async {
        for (var i = 0, stable = 0; i < 250 && stable < 8; i++) {
          final previous = screen();
          await tester.pump(const Duration(milliseconds: 60));
          stable = identical(screen(), previous) ? stable + 1 : 0;
        }
        await tester.pumpAndSettle();
      }

      Future<void> singleTap(Offset point) async {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
      }

      final captureKey = GlobalKey();
      Widget app() => ShosaiShell(
        home: RepaintBoundary(
          key: captureKey,
          child: ReaderScreen(
            bridge: bridge,
            initialPath: path,
            initialBookId: book.bookId,
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
      );
      await tester.pumpWidget(app());
      await until(() => raster.evaluate().isNotEmpty);
      await settle();
      final initial = screen();
      final first = initial.pieces.first;
      final rect = tester.getRect(area);
      final forward = Offset(
        rect.left + rect.width * (rtl ? .125 : .875),
        rect.center.dy,
      );
      final backward = Offset(
        rect.left + rect.width * (rtl ? .875 : .125),
        rect.center.dy,
      );
      double anchorY() {
        final piece = screen().pieces.firstWhere(
          (p) => p.page == first.page && p.region == first.region,
        );
        return tester.getTopLeft(raster).dy +
            piece.fromPage(first.source.left, first.source.top).y;
      }

      final origin = anchorY();
      await singleTap(backward);
      await tester.pumpAndSettle();
      expect(screen(), same(initial));
      await singleTap(forward);
      await until(() => screen() != initial);
      await settle();
      // The authored PDF advances every row by exactly 14 original points.
      final stride = initial.viewportHeight! - 14 * first.scale;
      expect(origin - anchorY(), closeTo(stride, 1));
      await captureView(captureKey, 'continuous-edge-forward-$rtl');
      await settle();
      final advanced = screen();
      await singleTap(backward);
      await until(() => screen() != advanced);
      await settle();
      expect(anchorY(), closeTo(origin, 1));

      // A turn-zone tap dismisses an active selection, without scrolling it.
      final surfaceOrigin = tester.getTopLeft(
        find.byKey(const ValueKey('reader-selection-surface')),
      );
      Offset center(FlutterSelectionEndpoint e) =>
          surfaceOrigin +
          Offset(
            (e.rect.left + e.rect.right) / 2,
            (e.rect.top + e.rect.bottom) / 2,
          );
      final visible = painter().surface.endpoints
          .where((e) => rect.deflate(100).contains(center(e)))
          .toList();
      final from = visible.first;
      final to = visible.firstWhere(
        (e) => e.offset > from.offset + BigInt.from(10),
      );
      final mouse = await tester.startGesture(
        center(from),
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.moveTo(center(to));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(painter().anchor, isNot(painter().focus));
      await settle();
      final selected = screen();
      await singleTap(forward);
      await tester.pumpAndSettle();
      expect(screen(), same(selected));
      expect(painter().anchor, painter().focus);
      await singleTap(forward);
      await until(() => screen() != selected);
      await settle();

      // Save and reopen after a tap, not only after a drag.
      await ReaderController.drainBookWrites(book.bookId.toInt());
      final c = bridge.createCancellation();
      final saved = (await bridge.loadReadingState(
        bookId: book.bookId,
        cancellationId: c,
      ))!;
      bridge.releaseCancellation(id: c);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await tester.pumpWidget(app());
      await until(() => raster.evaluate().isNotEmpty);
      final piece = screen().pieces.firstWhere(
        (p) =>
            p.page == saved.unit.toInt() &&
            p.source.top <= saved.pdfY! &&
            p.source.bottom >= saved.pdfY!,
      );
      final restoredY =
          tester.getTopLeft(raster).dy +
          piece.fromPage(saved.pdfX!, saved.pdfY!).y;
      expect(restoredY, closeTo(origin, 1));

      bool atEnd() =>
          screen().next.page == 5 &&
          screen().viewportTop + screen().viewportHeight! >=
              screen().height - .01;
      final testedSeparators = <bool>{};
      for (var i = 0; i < 30 && !atEnd(); i++) {
        for (final separator in screen().separators) {
          final pageBand = separator.page != null;
          if (testedSeparators.contains(pageBand)) continue;
          final scrollable = tester
              .stateList<ScrollableState>(
                find.descendant(of: area, matching: find.byType(Scrollable)),
              )
              .singleWhere((s) => s.position.axis == Axis.vertical);
          final target = separator.top + (pageBand ? 14 : 8);
          if (target < 0 || target > scrollable.position.maxScrollExtent) {
            continue;
          }
          // Set up an exact origin halfway through the unpainted separator;
          // the actions under test remain real outer-quarter single taps.
          scrollable.position.jumpTo(target);
          await tester.pumpAndSettle();
          final viewport = tester.getRect(
            find
                .ancestor(
                  of: raster,
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          );
          final reference = screen().pieces.firstWhere(
            (p) =>
                tester.getTopLeft(raster).dy + p.top + p.height > viewport.top,
          );
          double referenceY() =>
              tester.getTopLeft(raster).dy +
              screen().pieces
                  .firstWhere(
                    (p) =>
                        p.page == reference.page &&
                        p.region == reference.region,
                  )
                  .fromPage(reference.source.left, reference.source.top)
                  .y;
          final gap =
              tester.getTopLeft(raster).dy + reference.top - viewport.top;
          expect(gap, closeTo(pageBand ? 14 : 8, 1));
          final beforeY = referenceY();
          final distance = screen().viewportHeight! - 14 * reference.scale;
          await settle();
          final before = screen();
          await singleTap(forward);
          await until(() => screen() != before);
          await settle();
          expect(
            beforeY - referenceY(),
            closeTo(distance, 1),
            reason:
                'band=$pageBand page=${reference.page} region=${reference.region} '
                'target=$target max=${scrollable.position.maxScrollExtent} '
                'before=${before.viewportTop}/${before.height} next=${before.next.page}',
          );
          final after = screen();
          await singleTap(backward);
          await until(() => screen() != after);
          await settle();
          expect(referenceY(), closeTo(beforeY, 1));
          final returned = screen();
          await singleTap(backward);
          await until(() => screen() != returned);
          await settle();
          expect(referenceY() - beforeY, closeTo(distance, 1));
          testedSeparators.add(pageBand);
          break;
        }
        final previous = screen();
        await singleTap(forward);
        await until(() => screen() != previous);
        await settle();
      }
      expect(testedSeparators, {false, true});
      expect(atEnd(), isTrue);
      await settle();
      final last = screen();
      for (var i = 0; i < 3; i++) {
        await singleTap(forward);
        await tester.pumpAndSettle();
        expect(screen(), same(last));
      }
      await captureView(captureKey, 'continuous-edge-end-$rtl');
      for (var i = 0; i < 30; i++) {
        if (screen().start.page == 0 && screen().viewportTop <= .01) break;
        final previous = screen();
        await singleTap(backward);
        await until(() => screen() != previous);
        await settle();
      }
      expect(anchorY(), closeTo(origin, 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    });
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
        // The persisted place is written asynchronously; flush the queue so a
        // read observes the place the strip shows now.
        await ReaderController.drainBookWrites(book.bookId.toInt());
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
      // The strip's canvas coordinate at the viewport's top edge is the
      // vertical scroll view's top on screen minus the raster widget's top:
      // the window canvas begins at the raster widget's top edge.
      final verticalScroll = find
          .ancestor(
            of: raster,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is SingleChildScrollView &&
                  w.scrollDirection == Axis.vertical,
            ),
          )
          .first;
      double viewportCanvasTop() =>
          tester.getTopLeft(verticalScroll).dy - tester.getTopLeft(raster).dy;
      // The strip window slides about a viewport of content per overscan
      // refill, so crossing the whole document takes many drags.
      for (var i = 0; i < 400; i++) {
        final top = viewportCanvasTop();
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
            closeTo(tester.getTopLeft(verticalScroll).dy, 1),
          );
          continuous.value = false;
          await until(() => screen()?.continuous == false);
          continuous.value = true;
          await until(() => screen()?.continuous == true);
          // Screens aligns the same physical row; it must not drop the tail.
          expect(
            visibleHeight(),
            closeTo(tester.getTopLeft(verticalScroll).dy, 30),
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

  for (final mode in ['short', 'figure', 'refused', 'tall', 'shorts']) {
    testWidgets(
      switch (mode) {
        'short' => 'PageDown is harmless on a short continuous PDF',
        'figure' =>
          'Continuous figure detail returns to its visible strip position',
        'tall' => 'Tall figure interior keeps nearby body line overlap',
        'shorts' => 'Continuous taps span many short landscape pages',
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
        if (mode == 'shorts') {
          // Thirty original, textless landscape pages, each 100/400 as tall
          // as its fitted width. Several pages fit within one scroll stride.
          final objects = [
            '<< /Type /Catalog /Pages 2 0 R >>',
            '<< /Type /Pages /Kids [${[for (var p = 3; p < 33; p++) '$p 0 R'].join(' ')}] /Count 30 >>',
            for (var p = 0; p < 30; p++)
              '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 100] >>',
          ];
          final pdf = StringBuffer('%PDF-1.7\n');
          final offsets = <int>[];
          for (var i = 0; i < objects.length; i++) {
            offsets.add(pdf.length);
            pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
          }
          final xref = pdf.length;
          pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
          for (final offset in offsets) {
            pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
          }
          pdf.write(
            'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
          );
          await File(path).writeAsString(pdf.toString());
        } else if (mode == 'tall') {
          await File(
            path,
          ).writeAsBytes(columnsAfterFrontMatterPdf(tallFigure: true));
        } else if (mode == 'refused') {
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

        // A passive overscan refill legitimately replaces the screen object
        // with equivalent content while it serves scrolling. Identity-based
        // assertions must run against a strip whose pending loads have landed.
        Future<void> settle() async {
          for (var i = 0, stable = 0; i < 250 && stable < 8; i++) {
            final previous = screen();
            await tester.pump(const Duration(milliseconds: 60));
            stable = identical(screen(), previous) ? stable + 1 : 0;
          }
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
                initialPlace: switch (mode) {
                  'tall' => const ReaderPlace(3),
                  'shorts' => const ReaderPlace(20),
                  _ => null,
                },
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
        if (mode == 'shorts') {
          final area = find.byKey(const ValueKey('reader-page-tap-area'));
          final rect = tester.getRect(area);
          double origin() {
            final first = screen()!.pieces.first;
            return first.page * (screen()!.width / 4 + 28) +
                first.source.top * screen()!.width / 400 -
                first.top +
                screen()!.viewportTop;
          }

          final initial = origin();
          final stride = screen()!.viewportHeight! - 16;
          var expected = initial;
          for (final forward in [false, false, true, true]) {
            final previous = screen();
            await tester.pump(const Duration(milliseconds: 350));
            await tester.tapAt(
              Offset(
                rect.left + rect.width * (forward ? .875 : .125),
                rect.center.dy,
              ),
            );
            await tester.pump(const Duration(milliseconds: 350));
            await until(() => screen() != previous);
            await settle();
            expected += forward ? stride : -stride;
            expect(origin(), closeTo(expected, 1));
            expect(
              screen()!.height,
              lessThanOrEqualTo(3 * screen()!.viewportHeight!),
            );
          }
          expect(origin(), closeTo(initial, 1));
        } else if (mode == 'tall') {
          final body = screen()!.pieces.firstWhere(
            (p) => p.page == 3 && !p.zoomable,
          );
          final stride = screen()!.viewportHeight! - 14 * body.scale;
          for (
            var i = 0;
            i < 20 && !screen()!.pieces.every((p) => p.zoomable);
            i++
          ) {
            final previous = screen();
            await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
            await until(() => screen() != previous);
            await settle();
          }
          expect(
            screen()!.pieces.every((p) => p.zoomable),
            isTrue,
            reason: 'No body crop remains anywhere in the overscan window',
          );
          final figure = screen()!.pieces.single;
          double pointY() =>
              tester.getTopLeft(raster).dy +
              screen()!.pieces
                  .firstWhere(
                    (p) => p.page == figure.page && p.region == figure.region,
                  )
                  .fromPage(figure.source.left, figure.source.top)
                  .y;
          final area = find.byKey(const ValueKey('reader-page-tap-area'));
          final rect = tester.getRect(area);
          final origin = pointY();
          for (final fraction in [.875, .125]) {
            final previous = screen();
            await tester.pump(const Duration(milliseconds: 350));
            await tester.tapAt(
              Offset(rect.left + rect.width * fraction, rect.center.dy),
            );
            await tester.pump(const Duration(milliseconds: 350));
            await until(() => screen() != previous);
            await settle();
            expect(
              pointY(),
              closeTo(fraction > .5 ? origin - stride : origin, 1),
            );
          }
          await captureView(captureKey, 'continuous-tall-figure-overlap');
        } else if (mode == 'short') {
          await settle();
          final initial = screen();
          final last = initial!.pieces.last;
          expect(last.top + last.height, lessThan(initial.viewportHeight!));
          final rect = tester.getRect(
            find.byKey(const ValueKey('reader-page-tap-area')),
          );
          for (var i = 0; i < 4; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
            await tester.pump(const Duration(milliseconds: 350));
            await tester.tapAt(
              Offset(
                rect.left + rect.width * (i.isEven ? .125 : .875),
                rect.center.dy,
              ),
            );
            await tester.pump(const Duration(milliseconds: 350));
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
          if (mode == 'figure') {
            final viewport = tester.getRect(
              find
                  .ancestor(
                    of: raster,
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is SingleChildScrollView &&
                          w.scrollDirection == Axis.vertical,
                    ),
                  )
                  .first,
            );
            Future<void> alignFigure() async {
              final figure = screen()!.pieces.firstWhere((p) => p.zoomable);
              final top = tester.getTopLeft(raster).dy + figure.top;
              await tester.drag(area, Offset(0, viewport.top - top));
              await tester.pumpAndSettle();
            }

            Future<void> single(Offset point) async {
              await tester.pump(const Duration(milliseconds: 350));
              await tester.tapAt(point);
              await tester.pump(const Duration(milliseconds: 350));
              await tester.pumpAndSettle();
            }

            await alignFigure();
            expect(visibleFigure().height, greaterThan(500));
            await settle();
            final fitted = screen();
            await single(viewport.center);
            expect(screen(), same(fitted));
            expect(
              find
                  .byKey(const ValueKey('reader-header-typography'))
                  .hitTestable(),
              findsOneWidget,
            );
            await captureView(captureKey, 'continuous-figure-middle-chrome');
            await single(viewport.center);
            final figure = screen()!.pieces.firstWhere((p) => p.zoomable);
            double pointY() =>
                tester.getTopLeft(raster).dy +
                screen()!.pieces
                    .firstWhere(
                      (p) => p.page == figure.page && p.region == figure.region,
                    )
                    .fromPage(figure.source.left, figure.source.top)
                    .y;
            final startY = pointY();
            final rect = tester.getRect(area);
            await single(
              Offset(rect.left + rect.width * .875, viewport.center.dy),
            );
            await until(() => screen() != fitted);
            await settle();
            expect(screen()!.continuous, isTrue);
            expect(screen()!.strip, isNull);
            final forwardY = pointY();
            expect(forwardY, lessThan(startY - 50));
            await captureView(captureKey, 'continuous-figure-edge-forward');
            await settle();
            final advanced = screen();
            await single(
              Offset(rect.left + rect.width * .125, viewport.center.dy),
            );
            await until(() => screen() != advanced);
            await settle();
            expect(screen()!.continuous, isTrue);
            expect(pointY(), greaterThan(forwardY + 50));
            await alignFigure();
          }
          await settle();
          final before = screen()!;
          final origin = tester.getTopLeft(raster).dy;
          final piece = before.pieces.firstWhere((p) => p.zoomable);
          final y =
              tester.getTopLeft(raster).dy +
              piece.fromPage(piece.source.left, piece.source.top).y;
          await pinch(tester, visibleFigure().center, 30, 90);
          if (mode == 'refused') {
            await until(() => screen() != before);
            await settle();
            expect(screen()!.continuous, isTrue);
            expect(screen()!.strip, isNull);
          } else {
            await until(() => screen()?.strip != null);
            await settle();
            await pinch(tester, tester.getRect(area).center, 90, 25);
            await until(() => screen()?.continuous == true);
            await settle();
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
          if (mode == 'figure') {
            // Exercise #299's revised zoom contract on the continuous stack,
            // not only its Screens tests or this scenario's pinch path.
            final middle = visibleFigure().center;
            await tester.tapAt(middle);
            await tester.pump(const Duration(milliseconds: 100));
            await tester.tapAt(middle);
            await until(() => screen()?.strip != null);
            final close = find.byKey(
              const ValueKey('reader-columns-detail-close'),
            );
            expect(close.hitTestable(), findsOneWidget);
            await captureView(
              captureKey,
              'continuous-figure-double-tap-detail',
            );
            if (demo) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(seconds: 2)),
              );
            }
            await tester.tap(close);
            await until(() => screen()?.continuous == true);
            final returned = screen()!.pieces.firstWhere(
              (p) => p.page == piece.page && p.region == piece.region,
            );
            expect(
              tester.getTopLeft(raster).dy +
                  returned.fromPage(piece.source.left, piece.source.top).y,
              closeTo(y, 1),
            );
            await captureView(captureKey, 'continuous-figure-close-return');
          }
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
