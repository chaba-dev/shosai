import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderDisplayChange;

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

  testWidgets('Columns reads the real Thrift paper across screens and pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    for (var i = 0; i < 4; i++) {
      before = image();
      await tester.tap(find.byKey(const ValueKey('reader-typography-zoom-in')));
      await until(tester, () => image() != before);
    }
    expect(tester.getSize(raster).width, (rect.width - 28) * 2);
    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    await tester.tapAt(rect.center, kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await capture('columns-enlarged');
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
    await tester.pumpAndSettle();
    before = image();
    await tester.tap(find.byKey(const ValueKey('reader-typography-columns')));
    await until(tester, () => image() != before);
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
    for (var i = 0; i < 7; i++) {
      before = image();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await until(tester, () => image() != before);
      await capture('columns-screen-$i');
    }
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

  testWidgets('a scan remains a complete fit-width page in the Columns strip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = await Directory.systemTemp.createTemp(
      'shosai-columns-scan-',
    );
    final path = '${directory.path}/Scan.pdf';
    await File('fixtures/pdf-columns/scanned.pdf').copy(path);
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
    await capture('columns-scan-fallback');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await closeApplicationCores();
    await directory.delete(recursive: true);
    expect(tester.takeException(), isNull);
  });
}
