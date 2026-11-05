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
    show
        ReaderController,
        ReaderDisplayChange,
        ReaderPlace,
        ReaderPlaceRequests;
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart'
    show pdfMaxBitmapDimension, pdfMaxBitmapPixels;
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';
import 'package:shosai_flutter/reader/view.dart'
    show PagePainter, SurfaceTransform;

import '../test/support/reference_documents.dart';

/// Production PDFium, controller, settings and gestures. Runs on Linux, not a
/// browser approximation of a native reader. Artifacts are opt-in.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Absolute fixture root for device and simulator runs; host runs keep the
  // repository-relative default. See pdf_columns_continuous_test.dart.
  const fixtureRoot = String.fromEnvironment(
    'SHOSAI_FIXTURES',
    defaultValue: 'fixtures',
  );
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

  Future<void> doubleTap(WidgetTester tester, Offset point) async {
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  for (final (theme, paper) in [
    ('light', [255, 255, 255]),
    ('sepia', [245, 235, 214]),
    ('dark', [31, 31, 36]),
  ]) {
    testWidgets('Columns sheet is continuous in $theme', (tester) async {
      tester.view.physicalSize = const Size(1290, 2796);
      tester.view.devicePixelRatio = 3;
      tester.view.viewPadding = const FakeViewPadding(top: 177, bottom: 102);
      addTearDown(tester.view.reset);
      final directory = await Directory.systemTemp.createTemp('columns-sheet-');
      final path = '${directory.path}/Thrift.pdf';
      await File('$fixtureRoot/pdf-columns/thrift.pdf').copy(path);
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
              initialSettings: FlutterReaderSettings(
                continuous: false,
                theme: theme,
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
      for (var step = 0; step < 4; step++) {
        final rect = tester.getRect(
          find.ancestor(of: raster, matching: find.byType(ClipRect)).first,
        );
        expect(rect.left, 16);
        expect(430 - rect.right, 16);
        // Return to touch presentation after the keyboard page step.
        final touch = await tester.startGesture(rect.center);
        await touch.cancel();
        await tester.pump();
        final boundary =
            captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        List<int> pixel(int x, int y) => bytes.sublist(
          (y * image.width + x) * 4,
          (y * image.width + x) * 4 + 3,
        );
        // Both gutters, the blank top of the PDF crop, and the home area
        // share a sheet; cream Paper and incorrectly inverted Night fail.
        // Leave the keyboard focus outline out of the paper measurement.
        for (final x in [3, 15, 414, 426]) {
          for (var y = rect.top.ceil() + 3; y < image.height - 3; y++) {
            expect(pixel(x, y), paper, reason: '$theme margin at $x,$y');
          }
        }
        expect(pixel(215, rect.top.ceil() + 1), paper);
        image.dispose();
        await capture('sheet-$theme-$step');
        if (step < 3) {
          final before = tester.widget<RawImage>(raster).image;
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != before,
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    });
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
      expect([image.width, image.height], [816, (stripHeight * 2).ceil()]);
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
        408 / bounds.width,
        (stripHeight - 28) / bounds.height,
      );
      final pixels = (await image.toByteData())!.buffer.asUint8List();
      int ink(PdfRect box) {
        final left = (408 - bounds.width * scale) / 2;
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

  PagePainter? painting(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((paint) => paint.painter)
      .whereType<PagePainter>()
      .firstOrNull;

  for (final paper in [
    (
      name: 'thrift',
      page: 6,
      turns: 6,
      path: '$fixtureRoot/pdf-columns/thrift.pdf',
    ),
    (name: 'bert', page: 0, turns: 5, path: Platform.environment['BERT_PDF']),
    (
      name: 'resnet',
      page: 0,
      turns: 5,
      path: Platform.environment['RESNET_PDF'],
    ),
  ]) {
    testWidgets(
      '${paper.name}: body scale survives column and page turns',
      (tester) async {
        tester.view.physicalSize = const Size(880, 1800);
        tester.view.devicePixelRatio = 2;
        tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
        addTearDown(tester.view.reset);
        final directory = await Directory.systemTemp.createTemp('body-scale-');
        final path = '${directory.path}/${paper.name}.pdf';
        await File(paper.path!).copy(path);
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
                initialPlace: ReaderPlace(paper.page),
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
        final pdf = await PdfrxPdfEngine().open(path);
        final geometry = [
          for (var p = 0; p < pdf.pageCount; p++) await pdf.pageGeometry(p),
        ];
        final regions = analyzePdfColumns(geometry);
        await pdf.dispose();
        double? bodyScale;
        var checkedOverflow = false;
        final bodyPages = <int>{};
        for (var turn = 0; turn < paper.turns; turn++) {
          final screen = painting(tester)!.columns!;
          for (final piece in screen.pieces) {
            if (regions[piece.page].regions[piece.region].kind !=
                PdfRegionKind.column) {
              continue;
            }
            bodyScale ??= piece.scale;
            expect(
              piece.scale,
              bodyScale,
              reason:
                  '${paper.name}: one body scale, including the first column',
            );
            expect(piece.scale, inInclusiveRange(1.65, 1.95));
            bodyPages.add(piece.page);
          }
          expect(tester.getTopLeft(folio).dy, greaterThanOrEqualTo(59));
          expect(tester.getBottomRight(raster).dy, lessThanOrEqualTo(866));
          await capture('${paper.name}-body-$turn');
          if (paper.name == 'thrift' && !checkedOverflow) {
            final reported = geometry[6].lines.singleWhere(
              (line) => line.text.contains('libevent and the TFramed'),
            );
            final overflow = screen.pieces
                .where(
                  (piece) =>
                      piece.page == 6 && piece.source.contains(reported.bounds),
                )
                .firstOrNull;
            if (overflow != null) {
              checkedOverflow = true;
              const viewportWidth = 440 - 2 * 16.0;
              final right = overflow.fromPage(
                reported.bounds.right,
                reported.bounds.bottom,
              );
              expect(right.x, greaterThan(viewportWidth + 20));
              expect(right.x, lessThanOrEqualTo(screen.width));
              final image = tester.widget<RawImage>(raster).image!;
              final pixels = (await image.toByteData())!.buffer.asUint8List();
              final density = image.width / screen.width;
              final top = overflow
                  .fromPage(reported.bounds.left, reported.bounds.top)
                  .y;
              var trailingInk = 0;
              for (
                var y = (top * density).ceil();
                y < (right.y * density).floor();
                y++
              ) {
                for (
                  var x = (viewportWidth * density).ceil();
                  x < (right.x * density).floor();
                  x++
                ) {
                  if (pixels[(y * image.width + x) * 4] < 200) trailingInk++;
                }
              }
              expect(
                trailingInk,
                greaterThan(20),
                reason:
                    'the reported p7 line retains actual trailing raster ink',
              );
              await capture('thrift-overflow-leading');
              final origin = tester.getTopLeft(raster);
              await tester.timedDragFrom(
                Offset(350, origin.dy + 180),
                const Offset(-200, 0),
                const Duration(milliseconds: 600),
              );
              await tester.pumpAndSettle();
              expect(
                painting(tester)!.columns,
                same(screen),
                reason: 'revealing overflow must not also turn the page',
              );
              expect(tester.getRect(raster).right, closeTo(440 - 16, 1));
              await capture('thrift-overflow-trailing');
              await tester.timedDragFrom(
                Offset(150, origin.dy + 180),
                const Offset(200, 0),
                const Duration(milliseconds: 600),
              );
              await tester.pumpAndSettle();
              expect(painting(tester)!.columns, same(screen));
              expect(tester.getTopLeft(raster).dx, closeTo(origin.dx, 1));
            }
          }
          if (turn + 1 == paper.turns) break;
          final before = tester.widget<RawImage>(raster).image;
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
          await until(
            tester,
            () => tester.widget<RawImage>(raster).image != before,
          );
        }
        if (paper.name == 'thrift') expect(checkedOverflow, isTrue);
        expect(bodyPages, containsAll([paper.page, paper.page + 1]));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await closeApplicationCores();
        await directory.delete(recursive: true);
        expect(tester.takeException(), isNull);
      },
      skip: paper.path == null,
    );
  }

  testWidgets('body scale after front matter survives jumps and reopen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(880, 1800);
    tester.view.devicePixelRatio = 2;
    tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
    addTearDown(tester.view.reset);
    final directory = await Directory.systemTemp.createTemp('front-matter-');
    final path = '${directory.path}/front-matter.pdf';
    await File(path).writeAsBytes(columnsAfterFrontMatterPdf());
    final pdf = await PdfrxPdfEngine().open(path);
    final regions = analyzePdfColumns([
      for (var p = 0; p < pdf.pageCount; p++) await pdf.pageGeometry(p),
    ]);
    await pdf.dispose();
    expect(regions.map((page) => page.columnCount), [0, 0, 0, 2, 2]);
    final requests = ReaderPlaceRequests();
    addTearDown(requests.dispose);

    Future<void> open(int page) async {
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
              initialPlace: ReaderPlace(page),
              placeRequests: requests,
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
    }

    Future<void> jump(int page) async {
      final before = tester.widget<RawImage>(raster).image;
      requests.go(ReaderPlace(page));
      await until(
        tester,
        () => tester.widget<RawImage>(raster).image != before,
      );
      expect(painting(tester)!.columns!.topPage, page);
    }

    await open(3);
    final scale = painting(tester)!.columns!.pieces.first.scale;
    await capture('front-matter-first-body');
    await jump(4);
    expect(painting(tester)!.columns!.pieces.first.scale, scale);
    await capture('front-matter-later-body');
    await jump(3);
    expect(painting(tester)!.columns!.pieces.first.scale, scale);
    await jump(0);
    final fallback = painting(tester)!.columns!;
    expect(
      fallback.pieces.first.scale,
      fallback.width / fallback.pieces.first.source.width,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await closeApplicationCores();
    await open(4);
    expect(painting(tester)!.columns!.pieces.first.scale, scale);
    await capture('front-matter-direct-open');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await closeApplicationCores();
    await directory.delete(recursive: true);
    expect(tester.takeException(), isNull);
  });

  for (final table in [
    (number: 1, page: 4, x: 300.0, y: 140.0),
    (number: 10, page: 10, x: 300.0, y: 225.0),
    (number: 11, page: 10, x: 300.0, y: 315.0),
  ]) {
    testWidgets(
      'ResNet Table ${table.number} keeps page taps and double taps into detail',
      (tester) async {
        tester.view.physicalSize = const Size(860, 1864);
        tester.view.devicePixelRatio = 2;
        tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
        addTearDown(tester.view.reset);
        final directory = await Directory.systemTemp.createTemp(
          'resnet-table-',
        );
        final path = '${directory.path}/ResNet.pdf';
        await File(Platform.environment['RESNET_PDF']!).copy(path);
        final bridge = await createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        );
        final requests = ReaderPlaceRequests();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await closeApplicationCores();
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(
          ShosaiShell(
            locale: const Locale('ja'),
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                bridge: bridge,
                initialPath: path,
                initialPlace: ReaderPlace(table.page),
                placeRequests: requests,
                initialSettings: FlutterReaderSettings(
                  continuous: false,
                  theme: 'light',
                  epubFontSize: 18,
                  epubLineSpacing: 1.6,
                  pdfZoom: 0,
                  pdfFit: FlutterPdfFit.columns,
                  twoPages: false,
                  zonesHintDismissed: true,
                  progress: table.number == 11
                      ? FlutterReaderProgress.off
                      : FlutterReaderProgress.page,
                ),
              ),
            ),
          ),
        );
        await until(tester, () => painting(tester)?.columns != null);
        final strip = painting(tester)!.columns!;
        bool atStart() {
          final start = painting(tester)!.columns!.start;
          return (start.page, start.region, start.y) ==
              (strip.start.page, strip.start.region, strip.start.y);
        }

        final piece = strip.pieces.singleWhere(
          (p) =>
              p.page == table.page &&
              p.source.contains(
                PdfRect(table.x, table.y, table.x + 1, table.y + 1),
              ),
        );
        expect(piece.zoomable, isTrue);
        final original = sha256.convert(
          (await tester.widget<RawImage>(raster).image!.toByteData())!.buffer
              .asUint8List(),
        );
        final point = piece.fromPage(table.x, table.y);
        await capture('resnet-table-${table.number}-strip-ja');
        final middle = tester.getTopLeft(raster) + Offset(point.x, point.y);
        await tester.tapAt(middle);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(
          painting(tester)!.columns!.strip,
          isNull,
          reason:
              'A middle single tap over a table must reveal chrome, not zoom',
        );
        expect(
          find.byKey(const ValueKey('reader-header-search')).hitTestable(),
          findsOneWidget,
        );
        await capture('resnet-table-${table.number}-chrome-ja');
        await tester.tapAt(middle);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        final area = tester.getRect(
          find.byKey(const ValueKey('reader-page-tap-area')),
        );
        for (final fraction in [.9, .1]) {
          final edge = Offset(area.left + area.width * fraction, middle.dy);
          final local = edge - tester.getTopLeft(raster);
          expect(
            Rect.fromLTWH(
              piece.left,
              piece.top,
              piece.width,
              piece.height,
            ).contains(local),
            isTrue,
            reason: 'The page-turn tap must land on the actual table piece',
          );
          await tester.tapAt(edge);
          await tester.pump(const Duration(milliseconds: 350));
          await until(tester, () => !atStart());
          final turned = painting(tester)!.columns!;
          expect(turned.strip, isNull);
          if (fraction > .5) {
            expect(
              (turned.start.page, turned.start.region, turned.start.y),
              (strip.next.page, strip.next.region, strip.next.y),
            );
          } else {
            expect(turned.topPage, lessThan(strip.topPage));
          }
          // A reverse turn from an explicit jump reconstructs the preceding
          // page's windows; its inverse need not have the jump's boundary.
          requests.go(ReaderPlace(table.page));
          await until(tester, atStart);
        }
        await doubleTap(tester, middle);
        await until(tester, () => painting(tester)!.columns!.strip != null);
        final detail = painting(tester)!.columns!;
        expect(detail.pieces.single.page, table.page);
        expect(detail.pieces.single.region, piece.region);
        expect(detail.detailZoom, closeTo(2, .01));
        expect(
          find.byKey(const ValueKey('reader-columns-detail-close')),
          findsOneWidget,
        );
        await capture('resnet-table-${table.number}-detail-ja');
        if (table.number == 11) {
          // A short table leaves paper below it. Double tap there must return
          // to the strip too, rather than switching the whole document's fit.
          await doubleTap(tester, const Offset(215, 800));
          await until(tester, () => painting(tester)!.columns?.strip == null);
          expect(painting(tester)!.columns, isNotNull);
          expect(atStart(), isTrue);
          await doubleTap(tester, middle);
          await until(tester, () => painting(tester)!.columns!.strip != null);
        }
        await pinch(
          tester,
          tester.getCenter(find.byKey(const ValueKey('reader-page-tap-area'))),
          30,
          60,
        );
        await until(tester, () => painting(tester)!.columns!.detailZoom > 2.5);
        final enlarged = painting(tester)!.columns;
        for (final x in [25.0, 430 * .75]) {
          await tester.tapAt(Offset(x, 800));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(painting(tester)!.columns, same(enlarged));
        }
        final beforePan = tester.getTopLeft(raster);
        await tester.fling(
          find.byKey(const ValueKey('reader-page-tap-area')),
          const Offset(-100, 0),
          700,
        );
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(raster).dx, lessThan(beforePan.dx - 50));
        final close = find.byKey(const ValueKey('reader-columns-detail-close'));
        expect(tester.getSize(close).shortestSide, greaterThanOrEqualTo(44));
        expect(tester.getTopLeft(close).dy, greaterThanOrEqualTo(59));
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: const Offset(200, 600));
        await mouse.moveTo(tester.getCenter(close));
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(const ValueKey('reader-header-search')).hitTestable(),
          findsNothing,
          reason: 'Hover must not put the toolbar on top of detail Close',
        );
        expect(close.hitTestable(), findsOneWidget);
        await mouse.removePointer();
        await tester.tap(close);
        await until(tester, () => painting(tester)!.columns!.strip == null);
        final returned = painting(tester)!.columns!;
        expect(
          (returned.start.page, returned.start.region, returned.start.y),
          (strip.start.page, strip.start.region, strip.start.y),
        );
        expect(
          sha256.convert(
            (await tester.widget<RawImage>(raster).image!.toByteData())!.buffer
                .asUint8List(),
          ),
          original,
          reason: 'Closing detail restores the exact composed strip pixels',
        );
        await capture('resnet-table-${table.number}-returned-ja');
        expect(tester.takeException(), isNull);
      },
      skip: Platform.environment['RESNET_PDF'] == null,
    );
  }

  for (final scenario in [
    (reopen: false, detail: false, scan: false),
    (reopen: true, detail: false, scan: false),
    (reopen: false, detail: true, scan: false),
    (reopen: true, detail: true, scan: false),
    (reopen: false, detail: true, scan: true),
    (reopen: true, detail: true, scan: true),
  ]) {
    final reopen = scenario.reopen;
    final subject = scenario.scan
        ? 'DPR 3 capped scan'
        : 'textless right-column figure';
    testWidgets('a $subject keeps its place after '
        '${scenario.detail ? 'both-axis detail pan, resize and ' : ''}'
        '${reopen ? 'reopen' : 'a fit round-trip'}', (tester) async {
      final density = scenario.scan ? 3.0 : 2.0;
      tester.view.physicalSize = Size(440 * density, 550 * density);
      tester.view.devicePixelRatio = density;
      tester.view.viewPadding = FakeViewPadding(
        top: 59 * density,
        bottom: 34 * density,
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      final directory = await Directory.systemTemp.createTemp('shosai-figure-');
      final path = '${directory.path}/Figure.pdf';
      final fixture = scenario.scan ? 'scanned' : 'right-column-figure';
      await File('$fixtureRoot/pdf-columns/$fixture.pdf').copy(path);
      var bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await closeApplicationCores();
        await directory.delete(recursive: true);
      });
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
      Future<void> open(FlutterPdfFit fit) async {
        await tester.pumpWidget(
          ShosaiShell(
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                key: UniqueKey(),
                bridge: bridge,
                initialPath: path,
                initialBookId: book.bookId,
                initialSettings: FlutterReaderSettings(
                  continuous: false,
                  theme: 'light',
                  epubFontSize: 18,
                  epubLineSpacing: 1.6,
                  pdfZoom: 0,
                  pdfFit: fit,
                  twoPages: false,
                  zonesHintDismissed: true,
                ),
              ),
            ),
          ),
        );
        await until(
          tester,
          () =>
              painting(tester) != null &&
              (painting(tester)!.columns != null) ==
                  (fit == FlutterPdfFit.columns),
        );
      }

      Future<void> fit(String value) async {
        final header = find.byKey(const ValueKey('reader-header-typography'));
        if (header.hitTestable().evaluate().isEmpty) {
          await tester.tap(folio);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
        }
        await tester.tap(header);
        await tester.pumpAndSettle();
        final before = painting(tester);
        await tester.tap(find.byKey(ValueKey('reader-typography-$value')));
        await until(
          tester,
          () =>
              painting(tester) != null &&
              painting(tester) != before &&
              (painting(tester)!.columns != null) == (value == 'columns'),
        );
        await tester.tapAt(const Offset(10, 100));
        await tester.pumpAndSettle();
      }

      await open(FlutterPdfFit.fitPage);
      final paint = painting(tester)!;
      final box = tester.getRect(
        find.byKey(const ValueKey('reader-selection-surface')),
      );
      final transform = SurfaceTransform.create(
        paint.fit,
        Size(paint.surface.width, paint.surface.height),
        box.size,
      );
      final target =
          box.topLeft +
          transform
              .toDestinationRect(
                Rect.fromLTWH(
                  paint.surface.width * 436 / 612,
                  paint.surface.height * 350 / 792,
                  0,
                  0,
                ),
              )
              .topLeft;
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(target);
      await until(tester, () => painting(tester)?.columns != null);
      final first = painting(tester)!.columns!.pieces.first;
      // The crop keeps a three-point guard around the figure's x317 ink edge.
      expect(first.source.left, scenario.scan ? 0 : 314);
      expect(first.source.top, closeTo(350, 1));
      expect(painting(tester)!.surface.endpoints, isEmpty);
      if (!scenario.scan && !scenario.detail && !reopen) {
        final strip = painting(tester)!.columns!;
        expect(strip.pieces.single.kind, PdfRegionKind.figure);
        final middle = tester.getCenter(raster);
        await tester.tapAt(middle);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(painting(tester)!.columns!.strip, isNull);
        expect(
          find.byKey(const ValueKey('reader-header-typography')).hitTestable(),
          findsOneWidget,
          reason: 'An all-figure screen still needs a middle tap for chrome',
        );
        await capture('all-figure-middle-chrome');
        await doubleTap(tester, middle);
        await until(tester, () => painting(tester)!.columns!.strip != null);
        await doubleTap(
          tester,
          tester.getCenter(find.byKey(const ValueKey('reader-page-tap-area'))),
        );
        await until(tester, () => painting(tester)!.columns!.strip == null);
        final returned = painting(tester)!.columns!.start;
        expect(
          (returned.page, returned.region, returned.y),
          (strip.start.page, strip.start.region, strip.start.y),
        );
      }
      await capture('$fixture-before-${reopen ? 'reopen' : 'fit'}');
      var expectedY = first.source.top;
      if (scenario.detail) {
        await pinch(
          tester,
          tester.getCenter(raster),
          scenario.scan ? 20 : 30,
          scenario.scan ? 100 : 90,
        );
        await until(tester, () => painting(tester)!.columns!.detailZoom > 1);
        if (scenario.scan) {
          expect(painting(tester)!.columns!.detailZoom, lessThan(5));
          final image = tester.widget<RawImage>(raster).image!;
          expect(
            image.width * image.height,
            lessThanOrEqualTo(pdfMaxBitmapPixels),
          );
        }
        final detail = painting(tester)!.columns!.pieces.single;
        final origin = tester.getTopLeft(raster);
        final area = find.byKey(const ValueKey('reader-page-tap-area'));
        await tester.fling(area, const Offset(-100, -120), 700);
        await tester.pumpAndSettle();
        final panned = tester.getTopLeft(raster);
        expect(panned.dx, lessThan(origin.dx - 50));
        expect(panned.dy, lessThan(origin.dy - 50));
        // Derive the original-page point from measured on-screen movement,
        // independently of the controller's saved-place implementation.
        expectedY = detail.source.top + (origin.dy - panned.dy) / detail.scale;
        final expectedX =
            detail.source.left +
            (tester.getCenter(area).dx - panned.dx) / detail.scale;
        final cancellation = bridge.createCancellation();
        FlutterReadingState? saved;
        for (var attempt = 0; attempt < 100; attempt++) {
          saved = await bridge.loadReadingState(
            bookId: book.bookId,
            cancellationId: cancellation,
          );
          if (saved?.pdfY != null &&
              (saved!.pdfY! - expectedY).abs() < .01 &&
              saved.pdfX != null &&
              (saved.pdfX! - expectedX).abs() < .01) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 30));
        }
        bridge.releaseCancellation(id: cancellation);
        expect(saved!.pdfY, closeTo(expectedY, .01));
        expect(saved.pdfX, closeTo(expectedX, .01));
        expect(saved.offset, isNull);
        await capture('$fixture-detail-panned-${reopen ? 'reopen' : 'fit'}');
        final beforeResize = painting(tester)!.columns;
        tester.view.physicalSize = Size(440 * density, 590 * density);
        await until(tester, () => painting(tester)!.columns != beforeResize);
        final resized = painting(tester)!.columns!.pieces.single;
        final moved = tester.getTopLeft(raster);
        expect(
          resized.source.top + (origin.dy - moved.dy) / resized.scale,
          closeTo(expectedY, .01),
        );
        expect(
          resized.source.left +
              (tester.getCenter(area).dx - moved.dx) / resized.scale,
          closeTo(expectedX, .01),
        );
        await capture('$fixture-detail-resized-${reopen ? 'reopen' : 'fit'}');
      }
      if (reopen) {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await closeApplicationCores();
        bridge = await createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        );
        await open(FlutterPdfFit.columns);
      } else {
        await fit('fit-page');
        await fit('columns');
      }
      final restored = painting(tester)!.columns!.pieces.first;
      await capture('$fixture-after-${reopen ? 'reopen' : 'fit'}');
      expect(restored.source.left, scenario.scan ? 0 : 314);
      expect(restored.source.top, closeTo(expectedY, .01));
      expect(painting(tester)!.surface.endpoints, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Aa fit belongs to a paper, not the Settings default', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final directory = await Directory.systemTemp.createTemp('paper-fit-');
    var admin = await createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );
    final token = admin.createCancellation();
    await admin.importPaths(
      pathKeys: [
        File('$fixtureRoot/pdf-columns/thrift.pdf').absolute.path,
        File('$fixtureRoot/pdf-columns/arxiv-first-five.pdf').absolute.path,
      ],
      managed: false,
      cancellationId: token,
    );
    final books = (await admin.libraryPage(
      limit: 10,
      offset: 0,
      cancellationId: token,
    )).books;
    admin.releaseCancellation(id: token);
    expect(books, hasLength(2));
    final paper = books.singleWhere(
      (book) => book.pathKey.endsWith('thrift.pdf'),
    );
    final other = books.singleWhere((book) => book.bookId != paper.bookId);
    final globalChanges = <ReaderDisplayChange>[];
    Future<FlutterReaderSettings> settings() async {
      final id = admin.createCancellation();
      final value = await admin.loadReaderSettings(cancellationId: id);
      admin.releaseCancellation(id: id);
      return value;
    }

    Future<FlutterReadingState?> position(FlutterLibraryBook book) async {
      await ReaderController.drainBookWrites(book.bookId);
      final id = admin.createCancellation();
      final value = await admin.loadReadingState(
        bookId: book.bookId,
        cancellationId: id,
      );
      admin.releaseCancellation(id: id);
      return value;
    }

    Future<void> defaultFit(FlutterPdfFit fit) async =>
        admin.saveReaderSettings(
          value: (await settings()).copyWith(
            pdfFit: fit,
            twoPages: false,
            zonesHintDismissed: true,
            animations: false,
          ),
        );
    Future<void> closePaper() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      for (final book in books) {
        await ReaderController.drainBookWrites(book.bookId);
      }
    }

    Future<void> open(FlutterLibraryBook book, FlutterPdfFit expected) async {
      await closePaper();
      final bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await tester.pumpWidget(
        ShosaiShell(
          locale: const Locale('ja'),
          home: RepaintBoundary(
            key: captureKey,
            child: ReaderScreen(
              key: UniqueKey(),
              bridge: bridge,
              initialPath: book.pathKey,
              initialBookId: book.bookId,
              initialSettings: await settings(),
              onDisplayChanged: globalChanges.add,
            ),
          ),
        ),
      );
      await until(tester, () => painting(tester) != null);
      expect(
        painting(tester)!.columns != null,
        expected == FlutterPdfFit.columns,
      );
      if (expected != FlutterPdfFit.columns) {
        expect(
          painting(tester)!.fit,
          expected == FlutterPdfFit.fitWidth ? BoxFit.fitWidth : BoxFit.contain,
        );
      }
    }

    await defaultFit(FlutterPdfFit.fitWidth);
    await open(paper, FlutterPdfFit.fitWidth);
    for (final fit in [
      FlutterPdfFit.fitWidth,
      FlutterPdfFit.columns,
      FlutterPdfFit.fitPage,
    ]) {
      final defaultBefore = (await settings()).pdfFit;
      final typography = find.byKey(const ValueKey('reader-header-typography'));
      if (typography.hitTestable().evaluate().isEmpty) {
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('reader-page-tap-area'))),
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
      }
      await tester.tap(typography.hitTestable());
      await tester.pumpAndSettle();
      final key = switch (fit) {
        FlutterPdfFit.columns => 'columns',
        FlutterPdfFit.fitWidth => 'fit-width',
        FlutterPdfFit.fitPage => 'fit-page',
      };
      await tester.tap(find.byKey(ValueKey('reader-typography-$key')));
      await tester.pumpAndSettle();
      await capture('paper-override-${fit.name}');
      await closePaper();
      final saved = await position(paper);
      expect(saved?.pdfFit, fit);
      expect(globalChanges, isEmpty, reason: 'Aa must never edit Settings');
      expect((await settings()).pdfFit, defaultBefore);
      final inherited = fit == FlutterPdfFit.columns
          ? FlutterPdfFit.fitPage
          : FlutterPdfFit.columns;
      await defaultFit(inherited);
      await open(other, inherited);
      await closePaper();
      expect(
        (await position(other))?.pdfFit,
        isNull,
        reason: 'Passive reading must not pin the default',
      );
      admin.dispose();
      await closeApplicationCores();
      admin = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await open(paper, fit);
      expect((await settings()).pdfFit, inherited);
      expect((await position(paper))?.unit, saved?.unit);
      await capture('paper-restored-${fit.name}');
    }
    await closePaper();
    admin.dispose();
    await closeApplicationCores();
    await directory.delete(recursive: true);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone defaults, explicit choices and larger screens stay distinct',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await Directory.systemTemp.createTemp('shosai-fit-');
      for (final scenario in [
        (
          width: 440.0,
          file: 'thrift',
          fit: null,
          columns: true,
          widthFit: false,
        ),
        (
          width: 440.0,
          file: 'scanned',
          fit: null,
          columns: false,
          widthFit: true,
        ),
        (
          width: 440.0,
          file: 'arxiv-first-five',
          fit: null,
          columns: false,
          widthFit: true,
        ),
        (
          width: 440.0,
          file: 'arxiv-first-five',
          fit: FlutterPdfFit.columns,
          columns: true,
          widthFit: false,
        ),
        if (Platform.environment['ATTENTION_PDF'] != null) ...[
          (
            width: 440.0,
            file: 'attention',
            fit: null,
            columns: false,
            widthFit: true,
          ),
          (
            width: 440.0,
            file: 'attention',
            fit: FlutterPdfFit.fitPage,
            columns: false,
            widthFit: false,
          ),
        ],
        (
          width: 440.0,
          file: 'thrift',
          fit: FlutterPdfFit.fitPage,
          columns: false,
          widthFit: false,
        ),
        (
          width: 440.0,
          file: 'thrift',
          fit: FlutterPdfFit.fitWidth,
          columns: false,
          widthFit: true,
        ),
        (
          width: 820.0,
          file: 'thrift',
          fit: null,
          columns: false,
          widthFit: false,
        ),
        (
          width: 1280.0,
          file: 'thrift',
          fit: null,
          columns: false,
          widthFit: false,
        ),
      ]) {
        tester.view.physicalSize = Size(scenario.width * 2, 1800);
        var bridge = await createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        );
        await bridge.saveReaderSettings(
          value: FlutterReaderSettings(
            continuous: false,
            theme: 'light',
            epubFontSize: 18,
            epubLineSpacing: 1.6,
            pdfZoom: 0,
            pdfFit: scenario.fit,
            twoPages: false,
            zonesHintDismissed: true,
          ),
        );
        bridge.dispose();
        await closeApplicationCores();
        bridge = await createApplicationBridge(
          applicationSupportDirectory: () async => directory,
        );
        final cancellation = bridge.createCancellation();
        final settings = await bridge.loadReaderSettings(
          cancellationId: cancellation,
        );
        bridge.releaseCancellation(id: cancellation);
        expect(settings.pdfFit, scenario.fit);
        await tester.pumpWidget(
          ShosaiShell(
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                key: UniqueKey(),
                bridge: bridge,
                initialPath:
                    Platform
                        .environment['${scenario.file.toUpperCase()}_PDF'] ??
                    File(
                      '$fixtureRoot/pdf-columns/${scenario.file}.pdf',
                    ).absolute.path,
                initialSettings: settings,
              ),
            ),
          ),
        );
        await until(
          tester,
          () =>
              painting(tester) != null &&
              (painting(tester)!.columns != null) == scenario.columns,
        );
        if (!scenario.columns) {
          expect(
            painting(tester)!.fit,
            scenario.widthFit ? BoxFit.fitWidth : BoxFit.contain,
            reason: '$scenario',
          );
        }
        await capture(
          'fit-${scenario.file}-${scenario.fit?.name ?? 'default'}-${scenario.width.toInt()}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Columns keeps original marks and page-height place across fits and reopen',
    (tester) async {
      tester.view.physicalSize = const Size(880, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await Directory.systemTemp.createTemp('shosai-place-');
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
      Future<void> open() async {
        await tester.pumpWidget(
          ShosaiShell(
            home: RepaintBoundary(
              key: captureKey,
              child: ReaderScreen(
                key: UniqueKey(),
                bridge: bridge,
                initialPath: path,
                initialBookId: book.bookId,
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

      Future<void> fit(String value) async {
        final button = find.byKey(ValueKey('reader-typography-$value'));
        if (button.hitTestable().evaluate().isEmpty) {
          final header = find.byKey(const ValueKey('reader-header-typography'));
          if (header.hitTestable().evaluate().isEmpty) {
            await tester.tapAt(
              tester.getCenter(
                find.byKey(const ValueKey('reader-page-tap-area')),
              ),
            );
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pumpAndSettle();
          }
          await tester.tap(header);
          await tester.pumpAndSettle();
        }
        final before = painting(tester);
        await tester.tap(button);
        await until(
          tester,
          () =>
              painting(tester) != before &&
              (value == 'columns'
                  ? painting(tester)?.columns != null
                  : painting(tester)?.columns == null &&
                        painting(tester)!.surface.width >= 612),
        );
        await tester.tapAt(const Offset(10, 100));
        await tester.pumpAndSettle();
      }

      Offset point(double x, double y) {
        final paint = painting(tester)!;
        final box = tester.getRect(
          find.byKey(const ValueKey('reader-selection-surface')),
        );
        final transform = SurfaceTransform.create(
          paint.fit,
          Size(paint.surface.width, paint.surface.height),
          box.size,
        );
        final rect = transform.toDestinationRect(Rect.fromLTWH(x, y, 0, 0));
        return box.topLeft + rect.topLeft;
      }

      await open();
      await fit('fit-page');
      await until(tester, () => painting(tester)?.columns == null);
      final surface = painting(tester)!.surface;
      // Deliberately choose the right column, not the page's first text.
      final tap = point(surface.width * 430 / 612, surface.height * 350 / 792);
      await tester.tapAt(tap);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(tap);
      await until(tester, () => painting(tester)?.columns != null);
      final first = painting(tester)!.columns!.pieces.first;
      expect(first.page, 0);
      expect(first.source.left, closeTo(314.04, .02));
      // PR1 now exposes physical ink rows rather than the loose paragraph
      // union. Keep up to 3pt of whitespace before the tapped row's ink,
      // not the earlier paragraph start or a cut through its antialiasing.
      final pdf = await PdfrxPdfEngine().open(path);
      final geometry = await pdf.pageGeometry(0);
      await pdf.dispose();
      final row = geometry.lines.singleWhere(
        (line) =>
            line.bounds.left > 300 && (line.bounds.top - 342.276).abs() < .01,
      );
      final precedingBottom = geometry.lines
          .where(
            (line) =>
                line.bounds.left > 300 && line.bounds.bottom <= row.bounds.top,
          )
          .map((line) => line.bounds.bottom)
          .reduce(math.max);
      expect(
        first.source.top,
        math.max(row.bounds.top - 3, (precedingBottom + row.bounds.top) / 2),
      );
      await capture('columns-right-column-entry');
      final endpoints = painting(tester)!.surface.endpoints;
      // The fit controls leave chrome visible. Select below its overlay, not
      // a character hidden underneath the header at the strip's top edge.
      final from = endpoints.firstWhere((e) => e.rect.top > 120);
      final to = endpoints.firstWhere(
        (e) => e.offset > from.offset + BigInt.from(10),
      );
      Offset center(FlutterSelectionEndpoint e) => point(
        (e.rect.left + e.rect.right) / 2,
        (e.rect.top + e.rect.bottom) / 2,
      );
      final drag = await tester.startGesture(
        center(from),
        kind: ui.PointerDeviceKind.mouse,
      );
      await drag.moveTo(center(to));
      await drag.up();
      await tester.pumpAndSettle();
      final selected = painting(tester)!;
      expect(selected.anchor, isNot(selected.focus));
      final start = selected.anchor! < selected.focus!
          ? selected.anchor!
          : selected.focus!;
      final end = selected.anchor! > selected.focus!
          ? selected.anchor!
          : selected.focus!;
      await capture('columns-selection');
      await tester.tap(find.byKey(const ValueKey('selection-note')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-note-editor-field')),
        'Original right column',
      );
      await tester.tap(find.text('Save').last);
      await until(tester, () => painting(tester)!.annotations.isNotEmpty);
      final mark = painting(tester)!.annotations.single;
      expect(mark.unit, BigInt.zero);
      expect(mark.textRange!.start.toInt(), start);
      expect(mark.textRange!.end.toInt(), end);
      expect(mark.body, 'Original right column');
      expect(painting(tester)!.savedSelections.single.start, start);
      await capture('columns-note-highlight');
      final top = painting(tester)!.columns!.pieces.first.source.top;
      await fit('fit-width');
      await until(tester, () => painting(tester)?.columns == null);
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('reader-vertical-scroll-1-0')),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(
        scroll.pixels,
        closeTo((top * 440 / 612).clamp(0, scroll.maxScrollExtent), 2),
      );
      await fit('columns');
      expect(
        painting(tester)!.columns!.pieces.first.source.left,
        closeTo(314.04, .02),
      );
      expect(
        painting(tester)!.columns!.pieces.first.source.top,
        closeTo(top, 1),
      );
      final stateCancellation = bridge.createCancellation();
      final saved = await bridge.loadReadingState(
        bookId: book.bookId,
        cancellationId: stateCancellation,
      );
      bridge.releaseCancellation(id: stateCancellation);
      expect(saved!.unit, BigInt.zero);
      expect(saved.pdfY, closeTo(top, 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await open();
      final restored = painting(tester)!.columns!.pieces.first;
      expect(restored.source.left, closeTo(314.04, .02));
      expect(restored.source.top, closeTo(top, 1));
      expect(
        painting(tester)!.annotations.single.body,
        'Original right column',
      );
      await capture('columns-restored-place');
      final restoredScreen = painting(tester)!.columns!;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await until(tester, () => painting(tester)!.columns != restoredScreen);
      final previousScreen = painting(tester)!.columns!;
      expect(
        (
          previousScreen.next.page,
          previousScreen.next.region,
          previousScreen.next.y,
        ),
        (
          restoredScreen.start.page,
          restoredScreen.start.region,
          restoredScreen.start.y,
        ),
      );
      expect(previousScreen.pieces.last.source.bottom, restored.source.top);
      await capture('columns-before-restored-place');
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await until(tester, () => painting(tester)!.columns != previousScreen);
      expect(
        painting(tester)!.columns!.pieces.first.source.top,
        restored.source.top,
      );
      final returnedCancellation = bridge.createCancellation();
      final returnedState = await bridge.loadReadingState(
        bookId: book.bookId,
        cancellationId: returnedCancellation,
      );
      bridge.releaseCancellation(id: returnedCancellation);
      expect(returnedState!.pdfY, restored.source.top);
      // Double-tap leaves Columns for the original fitted page, never 2x.
      final centerOfStrip = tester.getCenter(
        find.byKey(const ValueKey('reader-selection-surface')),
      );
      await tester.tapAt(centerOfStrip);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(centerOfStrip);
      await until(
        tester,
        () =>
            painting(tester)?.columns == null &&
            painting(tester)!.surface.width >= 612,
      );
      expect(painting(tester)!.fit, BoxFit.contain);
      await capture('columns-return-to-page');
      await fit('columns');
      Future<void> header(String action) async {
        final button = find.byKey(ValueKey('reader-header-$action'));
        if (button.hitTestable().evaluate().isEmpty) {
          await tester.tapAt(
            tester.getCenter(
              find.byKey(const ValueKey('reader-page-tap-area')),
            ),
          );
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
        }
        await tester.tap(button);
        await tester.pumpAndSettle();
      }

      await header('notes');
      final note = find.byKey(ValueKey('reader-annotation-${mark.id}-open'));
      await until(tester, () => note.hitTestable().evaluate().isNotEmpty);
      await tester.tap(note);
      await until(
        tester,
        () =>
            painting(tester)!.anchor == start && painting(tester)!.focus == end,
      );
      expect(
        painting(tester)!.columns!.pieces.first.source.left,
        closeTo(314.04, .02),
      );
      await capture('columns-note-jump');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await header('search');
      await tester.pumpAndSettle();
      final beforeSearch = painting(tester)!.columns;
      await tester.enterText(
        find.byKey(const ValueKey('reader-search-input')),
        'protocol',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await until(
        tester,
        () =>
            painting(tester)!.columns != beforeSearch &&
            painting(tester)!.anchor != null &&
            painting(tester)!.focus != painting(tester)!.anchor,
      );
      final hit = painting(tester)!;
      final text = String.fromCharCodes(
        hit.surface.text.runes.skip(hit.anchor!).take(hit.focus! - hit.anchor!),
      );
      expect(text.toLowerCase(), 'protocol');
      final visibleHit = hit.surface.endpoints.firstWhere(
        (e) =>
            e.rangeStart.toInt() <= hit.anchor! &&
            e.rangeEnd.toInt() > hit.anchor!,
      );
      final hitCenter = center(visibleHit);
      expect(
        hitCenter.dy,
        greaterThan(
          tester.getRect(find.byKey(const ValueKey('reader-header'))).bottom,
        ),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('selection-actions')))
            .contains(hitCenter),
        isFalse,
      );
      await capture('columns-search-hit');
      await tester.tap(find.byKey(const ValueKey('reader-search-close')));
      await tester.pumpAndSettle();
      for (
        var step = 0;
        step < 12 && painting(tester)!.columns!.topPage == 0;
        step++
      ) {
        final before = painting(tester)!.columns;
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await until(tester, () => painting(tester)!.columns != before);
      }
      final later = painting(tester)!.columns!.pieces.first;
      expect(later.page, greaterThan(0));
      final laterCancellation = bridge.createCancellation();
      final laterSaved = await bridge.loadReadingState(
        bookId: book.bookId,
        cancellationId: laterCancellation,
      );
      bridge.releaseCancellation(id: laterCancellation);
      expect(laterSaved!.unit.toInt(), later.page);
      expect(laterSaved.pdfY, closeTo(later.source.top, .01));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await open();
      final laterRestored = painting(tester)!.columns!.pieces.first;
      expect(laterRestored.page, later.page);
      expect(laterRestored.source.top, closeTo(later.source.top, 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    },
  );

  for (final detail in [false, true]) {
    testWidgets(
      'PDF link areas map through ${detail ? 'panned detail' : 'a strip piece'} '
      'to the original destination',
      (tester) async {
        tester.view.physicalSize = const Size(880, 1800);
        tester.view.devicePixelRatio = 2;
        tester.view.viewPadding = const FakeViewPadding(top: 118, bottom: 68);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewPadding);
        final directory = await Directory.systemTemp.createTemp(
          'shosai-strip-link-',
        );
        final path = '${directory.path}/Reference.pdf';
        await File(path).writeAsBytes(referencePdf());
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
                ),
              ),
            ),
          ),
        );
        await until(tester, () => painting(tester)?.columns != null);
        if (detail) {
          final area = find.byKey(const ValueKey('reader-page-tap-area'));
          await pinch(tester, tester.getCenter(raster), 30, 90);
          await until(tester, () => painting(tester)!.columns!.detailZoom > 1);
          final origin = tester.getTopLeft(raster);
          await tester.fling(area, const Offset(-100, -120), 700);
          await tester.pumpAndSettle();
          final panned = tester.getTopLeft(raster);
          expect(panned.dx, lessThan(origin.dx - 50));
          expect(panned.dy, lessThan(origin.dy - 50));
          final paint = painting(tester)!;
          final box = tester.getRect(
            find.byKey(const ValueKey('reader-selection-surface')),
          );
          final viewport = tester.getRect(area).deflate(20);
          final visible = paint.surface.endpoints.where((e) {
            final center =
                box.topLeft +
                Offset(
                  (e.rect.left + e.rect.right) / 2,
                  (e.rect.top + e.rect.bottom) / 2,
                );
            return viewport.contains(center);
          }).toList();
          final first = visible.first;
          final last = visible.where((e) => e.rect.top == first.rect.top).last;
          expect(last.offset, greaterThan(first.offset));
          final mouse = await tester.startGesture(
            box.topLeft + Offset(first.rect.left, first.rect.top + 2),
            kind: ui.PointerDeviceKind.mouse,
          );
          await mouse.moveTo(
            box.topLeft + Offset(last.rect.right, last.rect.bottom - 2),
          );
          await mouse.up();
          await tester.pumpAndSettle();
          final selected = painting(tester)!;
          expect(selected.anchor, isNot(selected.focus));
          expect(
            selected.anchor,
            greaterThanOrEqualTo(first.rangeStart.toInt()),
          );
          expect(selected.focus, lessThanOrEqualTo(last.rangeEnd.toInt()));
          await capture('columns-detail-selection');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        final piece = painting(tester)!.columns!.pieces.first;
        final local = piece.fromPage(
          130,
          260,
        ); // Named Footnote 1 link, page points.
        final box = tester.getRect(
          find.byKey(const ValueKey('reader-selection-surface')),
        );
        expect(
          tester
              .getRect(find.byKey(const ValueKey('reader-page-tap-area')))
              .contains(box.topLeft + Offset(local.x, local.y)),
          isTrue,
        );
        // This destination check includes a link in a touch turn zone.
        await tester.tapAt(
          box.topLeft + Offset(local.x, local.y),
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await until(
          tester,
          () => find
              .byKey(const ValueKey('reader-reference-peek'))
              .evaluate()
              .isNotEmpty,
        );
        expect(find.textContaining('Quiet is the old name'), findsOneWidget);
        await capture(
          detail ? 'columns-detail-link-peek' : 'columns-link-peek',
        );
        await tester.tap(find.byKey(const ValueKey('reader-reference-go-to')));
        await until(tester, () => painting(tester)!.columns!.topPage == 1);
        expect(
          painting(tester)!.columns!.pieces.first.source.top,
          greaterThan(600),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await closeApplicationCores();
        await directory.delete(recursive: true);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    await File('$fixtureRoot/pdf-columns/thrift.pdf').copy(path);
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
    await tester.pump(const Duration(milliseconds: 350));
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
    final viewport = tester.getRect(
      find.ancestor(of: raster, matching: find.byType(ClipRect)).first,
    );
    expect(viewport.width, rect.width - 32);
    expect(tester.getSize(raster).width, greaterThanOrEqualTo(viewport.width));
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
    final overflows = tester.getSize(raster).width > viewport.width;
    await tester.fling(area, const Offset(-180, 0), 1000);
    await tester.pumpAndSettle();
    if (overflows) {
      expect(image(), same(before), reason: 'first reveal the trailing crop');
      expect(tester.getRect(raster).right, closeTo(viewport.right, 1));
      await tester.fling(area, const Offset(-180, 0), 1000);
    }
    await until(tester, () => image() != before);
    expect(place(), 'page 1 of 8');
    // Middle reveals Display without advancing.
    before = image();
    await tester.tapAt(rect.center);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(image(), same(before));
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    expect(find.text('Columns'), findsOneWidget);
    await capture('columns-display');
    await tester.tap(find.byKey(const ValueKey('reader-typography-fit-width')));
    await until(tester, () => raster.evaluate().isEmpty);
    expect(saved, isEmpty, reason: 'Aa fit is not a global Display change');
    await tester.tap(find.byKey(const ValueKey('reader-typography-columns')));
    await until(tester, () => image() != null);
    expect(saved, isEmpty, reason: 'Aa fit is not a global Display change');
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
      await tester.pump(const Duration(milliseconds: 350));
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
      await tester.pump(const Duration(milliseconds: 350));
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
          await File('$fixtureRoot/pdf-columns/scanned.pdf').readAsBytes(),
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
        expect(tester.getSize(raster).width, box.width - 32);
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
          expect(tester.getSize(raster).width, box.width - 32);
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
    'a figure in a mixed strip double taps and pinches without changing Size',
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
      await File(
        '$fixtureRoot/pdf-columns/content-preservation.pdf',
      ).copy(path);
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
      final beforeSearch = painting(tester)!.columns;
      await tester.tap(folio);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-header-search')));
      await until(tester, () => painting(tester)!.columns != beforeSearch);
      final pinned = painting(tester)!.columns!;
      final figure = pinned.pieces.singleWhere(
        (piece) => piece.kind == PdfRegionKind.figure,
      );
      final pinnedCenter =
          tester.getTopLeft(raster) +
          Offset(
            figure.left + figure.width / 2,
            figure.top + figure.height / 2,
          );
      await doubleTap(tester, pinnedCenter);
      expect(
        painting(tester)!.columns!.strip,
        isNull,
        reason: 'Pinned Search must not cover a newly opened detail Close',
      );
      await pinch(tester, pinnedCenter, 30, 60);
      await tester.pumpAndSettle();
      expect(painting(tester)!.columns, same(pinned));
      expect(find.byKey(const ValueKey('reader-search-close')), findsOneWidget);
      await capture('columns-figure-search-pinned-ja');
      await tester.tap(find.byKey(const ValueKey('reader-search-close')));
      await until(tester, () => painting(tester)!.columns != pinned);
      await doubleTap(tester, center);
      await until(tester, () => painting(tester)!.columns!.strip != null);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await until(tester, () => painting(tester)!.columns!.strip == null);
      await doubleTap(tester, center);
      await until(tester, () => painting(tester)!.columns!.strip != null);
      await tester.tap(
        find.byKey(const ValueKey('reader-columns-detail-close')),
      );
      await until(tester, () => painting(tester)!.columns!.strip == null);
      await pinch(tester, center, 30, 60);
      await until(tester, () => painting(tester)!.columns!.strip != null);
      final enlarged = tester.widget<RawImage>(raster).image!;
      expect(enlarged.width, greaterThan(fittedWidth * 1.8));
      expect(tester.widget<Text>(folioText).data, '4 ページ中 3 ページ');
      await capture('columns-figure-pinched-ja');
      await tester.tap(folio);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final beforeDetailSearch = painting(tester)!.columns;
      await tester.tap(find.byKey(const ValueKey('reader-header-search')));
      await until(
        tester,
        () => painting(tester)!.columns != beforeDetailSearch,
      );
      final area = find.byKey(const ValueKey('reader-page-tap-area'));
      await pinch(tester, tester.getCenter(area), 90, 40);
      await until(tester, () => painting(tester)!.columns!.strip == null);
      final pinnedReturn = painting(tester)!.columns;
      expect(find.byKey(const ValueKey('reader-search-close')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-search-close')));
      await until(tester, () => painting(tester)!.columns != pinnedReturn);
      await tester.tap(folio);
      await tester.pump(const Duration(milliseconds: 350));
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
