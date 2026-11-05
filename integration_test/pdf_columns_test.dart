import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/controller.dart'
    show ReaderDisplayChange, ReaderPlace;
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart'
    show pdfMaxBitmapDimension, pdfMaxBitmapPixels;
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

/// Production PDFium, controller, settings and gestures. Runs on Linux, not a
/// browser approximation of a native reader. Artifacts are opt-in.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  final raster = find.byKey(const ValueKey('reader-columns-raster'));
  final folio = find.byKey(const ValueKey('reader-columns-folio'));
  final folioText = find.descendant(
    of: folio,
    matching: find.byType(Text),
    matchRoot: true,
  );
  final artifacts = Platform.environment['SHOSAI_COLUMNS_ARTIFACTS'];

  Future<void> capture(String name) async {
    if (artifacts == null) return;
    final boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(artifacts).create(recursive: true);
    await File(
      '$artifacts/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() ready, {
    bool settle = true,
  }) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(ready(), isTrue);
    if (settle) await tester.pumpAndSettle();
  }

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

  testWidgets(
    'ResNet diagram keeps its three headers across the page boundary',
    (tester) async {
      tester.view.physicalSize = const Size(880, 1800);
      tester.view.devicePixelRatio = 2;
      tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
      addTearDown(tester.view.reset);
      final original = Platform.environment['RESNET_PDF']!;
      expect(
        sha256.convert(await File(original).readAsBytes()).toString(),
        '1e0651b6810ecba34a3dbc5b5b0209226f889004607c1f203540a48d64e5a93a',
      );
      final pdf = await PdfrxPdfEngine().open(original);
      final geometry = await pdf.pageGeometry(3);
      await pdf.dispose();
      final headers = geometry.lines
          .where((line) => {995, 1002, 1558}.contains(line.start))
          .toList();
      expect(headers, hasLength(3));
      final directory = await Directory.systemTemp.createTemp('resnet-strip-');
      final path = '${directory.path}/ResNet.pdf';
      await File(original).copy(path);
      final bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await tester.pumpWidget(
        ShosaiShell(
          home: RepaintBoundary(
            key: captureKey,
            child: ReaderScreen(
              bridge: bridge,
              initialPath: path,
              initialSettings: const FlutterReaderSettings(
                continuous: false,
                theme: 'light',
                epubFontSize: 18,
                epubLineSpacing: 1.6,
                pdfZoom: 0,
                pdfFit: FlutterPdfFit.columns,
                twoPages: false,
                zonesHintDismissed: true,
                animations: false,
              ),
            ),
          ),
        ),
      );
      await until(tester, () => raster.evaluate().isNotEmpty);
      var steps = 0;
      while (tester.widget<Text>(folioText).data != 'page 4 of 12' &&
          steps++ < 40) {
        await capture('resnet-before-diagram');
        final before = tester.widget<RawImage>(raster).image;
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await until(
          tester,
          () => tester.widget<RawImage>(raster).image != before,
        );
      }
      expect(tester.widget<Text>(folioText).data, 'page 4 of 12');
      await capture('resnet-diagram-with-headers');
      final image = tester.widget<RawImage>(raster).image!;
      final stripHeight = tester.getSize(raster).height;
      expect(stripHeight, closeTo(775, 1));
      expect([image.width, image.height], [824, (stripHeight * 2).ceil()]);
      expect(tester.getTopLeft(folio).dy, greaterThanOrEqualTo(59));
      expect(tester.getBottomRight(raster).dy, lessThanOrEqualTo(866));
      final object = analyzePdfColumns([geometry]).single.regions.singleWhere(
        (region) =>
            region.kind == PdfRegionKind.figure &&
            region.bounds.contains(
              const PdfRect(51.045, 92.112, 284.799, 618.042),
            ),
      );
      final bounds = object.bounds;
      expect(
        headers.every((label) => bounds.contains(label.bounds)),
        isTrue,
        reason: 'The figure crop must include its three network headers',
      );
      final scale = math.min(
        412 / bounds.width,
        (stripHeight - 28) / bounds.height,
      );
      final pixels = (await image.toByteData())!.buffer.asUint8List();
      int ink(PdfRect box) {
        final left = (412 - bounds.width * scale) / 2;
        final x0 = ((left + (box.left - bounds.left) * scale) * 2).floor();
        final x1 = ((left + (box.right - bounds.left) * scale) * 2).ceil();
        final y0 = ((28 + (box.top - bounds.top) * scale) * 2).floor();
        final y1 = ((28 + (box.bottom - bounds.top) * scale) * 2).ceil();
        var count = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            if (pixels[(y * image.width + x) * 4] < 128) count++;
          }
        }
        return count;
      }

      for (final label in headers) {
        expect(
          ink(label.bounds),
          greaterThan(20),
          reason: 'Every network header must be painted above its diagram',
        );
      }
      expect(
        ink(const PdfRect(51.045, 605, 284.799, 618.042)),
        greaterThan(50),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    },
    skip: Platform.environment['RESNET_PDF'] == null,
  );

  testWidgets('Columns reads the real Thrift paper across screens and pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(880, 1800);
    tester.view.devicePixelRatio = 2;
    tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewPadding);
    final directory = await Directory.systemTemp.createTemp('shosai-columns-');
    final path = '${directory.path}/Thrift.pdf';
    await File('fixtures/pdf-columns/thrift.pdf').copy(path);
    final bridge = await createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );
    final saved = <ReaderDisplayChange>[];
    await tester.pumpWidget(
      ShosaiShell(
        home: RepaintBoundary(
          key: captureKey,
          child: ReaderScreen(
            bridge: bridge,
            initialPath: path,
            onDisplayChanged: saved.add,
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
    ui.Image? image() => raster.evaluate().isEmpty
        ? null
        : tester.widget<RawImage>(raster).image;
    String place() => tester.widget<Text>(folioText).data!;
    await until(tester, () => image() != null);
    expect(place(), 'page 1 of 8');
    expect(tester.getTopLeft(folio).dy, greaterThanOrEqualTo(59));
    expect(tester.getBottomRight(raster).dy, lessThanOrEqualTo(900 - 34));
    expect(
      tester.getSize(find.byKey(const ValueKey('reader-columns-outline'))),
      const Size(12, 15),
    );
    await capture('columns-title');
    var before = image();
    final area = find.byKey(const ValueKey('reader-page-tap-area'));
    final rect = tester.getRect(area);
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    expect(find.text('100% · max'), findsOneWidget);
    before = image();
    await tester.tap(find.byKey(const ValueKey('reader-typography-zoom-in')));
    await tester.pumpAndSettle();
    expect(image(), same(before), reason: 'Size cannot exceed fitted width');
    await capture('columns-size-maximum');
    await tester.tap(find.byKey(const ValueKey('reader-typography-zoom-out')));
    await until(tester, () => image() != before);
    expect(find.text('75%'), findsOneWidget);
    before = image();
    await tester.tap(find.byKey(const ValueKey('reader-typography-zoom-in')));
    await until(tester, () => image() != before);
    expect(find.text('100% · max'), findsOneWidget);
    expect(tester.getSize(raster).width, rect.width - 28);
    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    before = image();
    // Touch in the outer quarter advances exactly one screen on the same page.
    await tester.tapAt(Offset(rect.left + rect.width * .9, rect.center.dy));
    await until(tester, () => image() != before, settle: false);
    await tester.pump();
    expect(place(), 'page 1 of 8');
    expect(find.byKey(const ValueKey('reader-page-curl')), findsNothing);
    expect(find.byKey(const ValueKey('reader-columns-slide')), findsOneWidget);
    await capture('columns-slide');
    await tester.pump(const Duration(milliseconds: 210));
    expect(find.byKey(const ValueKey('reader-columns-slide')), findsNothing);
    await tester.pumpAndSettle();
    await capture('columns-next');
    before = image();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await until(tester, () => image() != before);
    await capture('columns-return');
    before = image();
    await tester.fling(area, const Offset(-180, 0), 1000);
    await until(tester, () => image() != before);
    expect(place(), 'page 1 of 8');
    // Middle reveals Display without advancing.
    before = image();
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
    expect(image(), same(before));
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    expect(find.text('Columns'), findsOneWidget);
    await capture('columns-display');
    await tester.tap(find.byKey(const ValueKey('reader-typography-fit-width')));
    await until(tester, () => raster.evaluate().isEmpty);
    expect(saved.last.pdfFit, FlutterPdfFit.fitWidth);
    await tester.tap(find.byKey(const ValueKey('reader-typography-columns')));
    await until(tester, () => image() != null);
    expect(saved.last.pdfFit, FlutterPdfFit.columns);
    for (final progress in [
      FlutterReaderProgress.off,
      FlutterReaderProgress.percent,
      FlutterReaderProgress.page,
    ]) {
      before = image();
      await tester.tap(
        find.byKey(ValueKey('reader-progress-${progress.name}')),
      );
      await tester.pumpAndSettle();
      expect(saved.last.progress, progress);
      expect(image(), same(before), reason: 'Progress must not move the crop');
      final outline = find.byKey(const ValueKey('reader-columns-outline'));
      if (progress == FlutterReaderProgress.off) {
        expect(folio, findsNothing);
        expect(outline, findsNothing);
      } else {
        // The top visible original page is 1 of 8, even on later strip screens.
        expect(
          place(),
          progress == FlutterReaderProgress.page ? 'page 1 of 8' : '13%',
        );
        expect(
          outline,
          progress == FlutterReaderProgress.page
              ? findsOneWidget
              : findsNothing,
        );
      }
      await tester.tapAt(const Offset(10, 100));
      await tester.pumpAndSettle();
      await tester.tapAt(rect.center, kind: ui.PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await capture('columns-progress-${progress.name}');
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pumpAndSettle();
    }
    // Animation off changes at once; changing the platform's reduced-motion
    // request has the same effect even with Page animations on.
    await tester.tap(
      find.byKey(const ValueKey('reader-typography-animations')),
    );
    await tester.pumpAndSettle();
    expect(saved.last.animations, isFalse);
    // Close the sheet and traverse enough screens to cross a column/page band.
    await tester.tapAt(Offset(10, 100));
    await tester.pumpAndSettle();
    await tester.tapAt(rect.center, kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    before = image();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await until(tester, () => image() != before, settle: false);
    expect(find.byKey(const ValueKey('reader-columns-slide')), findsNothing);
    await tester.pumpAndSettle();
    final namedPages = <int>{};
    var sawRange = false;
    for (var i = 0; i < 40; i++) {
      final numbers = RegExp(
        r'\d+',
      ).allMatches(place()).map((m) => int.parse(m.group(0)!)).toList();
      final first = numbers.first;
      final last = numbers.length == 3 ? numbers[1] : first;
      sawRange |= last > first;
      for (var page = first; page <= last; page++) {
        namedPages.add(page);
      }
      if (last == 8) break;
      before = image();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await until(tester, () => image() != before);
      if (i < 7) await capture('columns-screen-$i');
      if (place().startsWith('pages ')) await capture('columns-page-range');
    }
    expect(
      namedPages,
      containsAll([2, 3, 4, 5, 6, 7, 8]),
      reason:
          'Every traversed PDF page must be named, even when it never starts a screen',
    );
    expect(sawRange, isTrue);
    expect(place(), isNot('page 1 of 8'));
    if (find
        .byKey(const ValueKey('reader-header-typography'))
        .hitTestable()
        .evaluate()
        .isEmpty) {
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('reader-typography-animations')),
    );
    await tester.pumpAndSettle();
    expect(saved.last.animations, isTrue);
    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    await tester.tapAt(rect.center, kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    before = image();
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await until(tester, () => image() != before, settle: false);
    expect(find.byKey(const ValueKey('reader-columns-slide')), findsNothing);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await closeApplicationCores();
    await directory.delete(recursive: true);
    expect(tester.takeException(), isNull);
  });

  for (final pageWidth in [612, 100, 50]) {
    testWidgets(
      'DPR 3 scan width $pageWidth caps detail and returns to its strip',
      (tester) async {
        tester.view.physicalSize = const Size(1320, 2700);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = await Directory.systemTemp.createTemp(
          'shosai-columns-scan-',
        );
        final path = '${directory.path}/Scan.pdf';
        // Equal-length substitutions keep the original xref and stream lengths.
        // Narrow pages are tall fallback controls without another binary fixture.
        final width = pageWidth.toString().padLeft(3, '0');
        final source = latin1.decode(
          await File('fixtures/pdf-columns/scanned.pdf').readAsBytes(),
        );
        await File(path).writeAsBytes(
          latin1.encode(
            source
                .replaceFirst(
                  '/MediaBox [0 0 612 792]',
                  '/MediaBox [0 0 $width 792]',
                )
                .replaceFirst('q 612 0 0 792', 'q $width 0 0 792'),
          ),
        );
        final bridge = await createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        );
        await tester.pumpWidget(
          ShosaiShell(
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                bridge: bridge,
                initialPath: path,
                initialSettings: const FlutterReaderSettings(
                  continuous: false,
                  theme: 'light',
                  epubFontSize: 18,
                  epubLineSpacing: 1.6,
                  pdfZoom: 0,
                  pdfFit: FlutterPdfFit.columns,
                  twoPages: true,
                  zonesHintDismissed: true,
                ),
              ),
            ),
          ),
        );
        await until(tester, () => raster.evaluate().isNotEmpty);
        expect(tester.widget<Text>(folioText).data, 'page 1 of 1');
        final box = tester.getSize(
          find.byKey(const ValueKey('reader-page-tap-area')),
        );
        expect(tester.getSize(raster).width, box.width - 28);
        final area = find.byKey(const ValueKey('reader-page-tap-area'));
        final rect = tester.getRect(area);
        if (pageWidth != 612) {
          final first = tester.widget<RawImage>(raster).image;
          await tester.tapAt(Offset(rect.right - 20, rect.center.dy));
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != first,
          );
        }
        Future<Digest> pixels(ui.Image image) async =>
            sha256.convert((await image.toByteData())!.buffer.asUint8List());
        final fittedPixels = await pixels(
          tester.widget<RawImage>(raster).image!,
        );
        await capture('columns-scan-$pageWidth-fallback');
        final nearZoom = pageWidth == 612 ? 4.4 : 1.5;
        for (final zoom in pageWidth == 50 ? [5.0] : [nearZoom, 5.0]) {
          final fitted = tester.widget<RawImage>(raster).image!;
          // Cross touch slop even for the smaller 1.5× request. Keep the
          // original 20→100 half-span for the reported over-limit gesture.
          final span = zoom == 1.5 ? 40.0 : 20.0;
          await pinch(tester, tester.getCenter(area), span, span * zoom);
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != fitted,
          );
          final enlarged = tester.widget<RawImage>(raster).image!;
          expect(
            enlarged.width * enlarged.height,
            lessThanOrEqualTo(pdfMaxBitmapPixels),
          );
          expect(enlarged.width, lessThanOrEqualTo(pdfMaxBitmapDimension));
          expect(enlarged.height, lessThanOrEqualTo(pdfMaxBitmapDimension));
          expect(tester.widget<Text>(folioText).data, 'page 1 of 1');
          if (pageWidth == 50) {
            expect(
              await pixels(enlarged),
              fittedPixels,
              reason: 'Whole-region fit is inadmissible; keep the crisp strip',
            );
            continue;
          }
          expect(
            enlarged.width,
            greaterThan(fitted.width * nearZoom - 1),
            reason: 'Legal detail must render newly dense pixels, not fail',
          );
          if (zoom == nearZoom) {
            expect(
              enlarged.width,
              closeTo(fitted.width * zoom, 1),
              reason: 'Below-limit requests keep their exact scale',
            );
          } else if (pageWidth == 612) {
            expect(
              enlarged.width * enlarged.height,
              greaterThan(39900000),
              reason: 'Use the admitted area rather than a fixed low zoom',
            );
          } else {
            expect(
              enlarged.height,
              16384,
              reason: 'Tall detail hits the edge cap',
            );
          }
          await capture('columns-scan-$pageWidth-zoom-$zoom');
          final origin = tester.getTopLeft(raster);
          await tester.fling(area, const Offset(-150, -100), 700);
          await tester.pumpAndSettle();
          expect(tester.widget<RawImage>(raster).image, same(enlarged));
          expect(tester.getTopLeft(raster).dx, lessThan(origin.dx));
          expect(tester.getTopLeft(raster).dy, lessThan(origin.dy));
          await capture('columns-scan-$pageWidth-pan-$zoom');
          await pinch(tester, tester.getCenter(area), 100, 10);
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != enlarged,
          );
          expect(tester.getSize(raster).width, box.width - 28);
          expect(
            await pixels(tester.widget<RawImage>(raster).image!),
            fittedPixels,
            reason: 'Pinching back preserves the exact strip cursor',
          );
          await capture('columns-scan-$pageWidth-return-$zoom');
        }
        if (pageWidth != 612) {
          final before = tester.widget<RawImage>(raster).image;
          await tester.tapAt(Offset(rect.left + 20, rect.center.dy));
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != before,
          );
          expect(
            await pixels(tester.widget<RawImage>(raster).image!),
            isNot(fittedPixels),
          );
          final previous = tester.widget<RawImage>(raster).image;
          await tester.tapAt(Offset(rect.right - 20, rect.center.dy));
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != previous,
          );
          expect(
            await pixels(tester.widget<RawImage>(raster).image!),
            fittedPixels,
            reason: 'Detail retains backward/forward screen history',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await closeApplicationCores();
        await directory.delete(recursive: true);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a figure in a mixed strip pinches sharply without changing Size',
    (tester) async {
      tester.view.physicalSize = const Size(880, 1800);
      tester.view.devicePixelRatio = 2;
      tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      final directory = await Directory.systemTemp.createTemp(
        'shosai-columns-figure-',
      );
      final path = '${directory.path}/Figure.pdf';
      await File('fixtures/pdf-columns/content-preservation.pdf').copy(path);
      final bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await tester.pumpWidget(
        ShosaiShell(
          locale: const Locale('ja'),
          home: RepaintBoundary(
            key: captureKey,
            child: ReaderScreen(
              bridge: bridge,
              initialPath: path,
              initialPlace: const ReaderPlace(2),
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
      await until(tester, () => raster.evaluate().isNotEmpty);
      expect(tester.getTopLeft(folio).dy, greaterThanOrEqualTo(59));
      final fitted = tester.widget<RawImage>(raster).image!;
      final fittedWidth = fitted.width;
      // Locate the fixture's gray raster figure in the actual composed pixels,
      // not through the layout function whose hit mapping is under test.
      final bytes = (await fitted.toByteData())!.buffer.asUint8List();
      var pixel = -1;
      for (var row = 0; row < fitted.height && pixel < 0; row++) {
        var run = 0;
        for (var x = 0; x < fittedWidth; x++) {
          final i = (row * fittedWidth + x) * 4;
          run = bytes[i] == 180 && bytes[i + 1] == 180 && bytes[i + 2] == 180
              ? run + 1
              : 0;
          if (run >= 200) {
            pixel = row * fittedWidth + x - run + 1;
            break;
          }
        }
      }
      expect(
        pixel,
        greaterThanOrEqualTo(0),
        reason: 'The labeled image must be on the mixed strip screen',
      );
      final origin = tester.getTopLeft(raster);
      final center =
          origin +
          Offset(
            (pixel % fittedWidth) / 2 + 60,
            (pixel ~/ fittedWidth) / 2 + 40,
          );
      await capture('columns-figure-ja');
      await pinch(tester, center, 30, 60);
      await until(
        tester,
        () => tester.widget<RawImage>(raster).image != fitted,
      );
      final enlarged = tester.widget<RawImage>(raster).image!;
      expect(enlarged.width, greaterThan(fittedWidth * 1.8));
      expect(tester.widget<Text>(folioText).data, '4 ページ中 3 ページ');
      await capture('columns-figure-pinched-ja');
      final area = find.byKey(const ValueKey('reader-page-tap-area'));
      await pinch(tester, tester.getCenter(area), 90, 40);
      await until(
        tester,
        () => tester.widget<RawImage>(raster).image != enlarged,
      );
      await tester.tapAt(tester.getCenter(area));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await tester.pumpAndSettle();
      expect(find.text('100% · 最大'), findsOneWidget);
      await capture('columns-size-maximum-ja');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    },
  );
}
