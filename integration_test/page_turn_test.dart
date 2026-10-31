import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/view.dart';

import '../test/support/epub_navigation_fixture.dart';
import '../test/support/reference_documents.dart';

/// Real Dart engines, SQLite, PDFium, fonts and production reader. Optional
/// SHOSAI_CURL_ARTIFACTS captures held gestures; SHOSAI_CURL_POINTER=1 enables
/// native moving-pointer/key input for a Linux review recording.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  final baseline = Platform.environment['SHOSAI_CURL_BASELINE'] == '1';
  final frames = <ui.FrameTiming>[];
  void timings(List<ui.FrameTiming> batch) => frames.addAll(batch);

  Future<void> capture(String name) async {
    final directory = Platform.environment['SHOSAI_CURL_ARTIFACTS'];
    if (directory == null) return;
    final boundary =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(ready(), isTrue);
    await tester.pumpAndSettle();
  }

  for (final variant in [
    'epub',
    'epub-spread',
    'epub-rtl',
    'epub-vertical',
    'pdf',
    'pdf-spread',
  ]) {
    testWidgets('real $variant leaf turns and cancels', (tester) async {
      final directory = await Directory.systemTemp.createTemp('shosai-curl-');
      final pdf = variant.startsWith('pdf');
      final rtl = variant == 'epub-rtl' || variant == 'epub-vertical';
      final path = '${directory.path}/Quiet pages.${pdf ? 'pdf' : 'epub'}';
      final epub = buildTestEpub(
        chapters: {
          'OPS/Text/chapter-1.xhtml':
              '<h1>The quiet page</h1>${List.generate(60, (i) => '<p>${i + 1}. The path follows the river through the old orchard. At the bend, the water mirrors the trees. A book leaves room for a small detour.</p>').join()}',
          'OPS/Text/chapter-2.xhtml':
              '<h1>The walk continues</h1><p>Another quiet place.</p>',
        },
        nav:
            '<ol><li><a href="../Text/chapter-1.xhtml">The quiet page</a></li><li><a href="../Text/chapter-2.xhtml">The walk continues</a></li></ol>',
        pageProgression: rtl ? 'rtl' : 'ltr',
        bodyAttributes: variant == 'epub-vertical'
            ? ' style="writing-mode: vertical-rl"'
            : '',
      );
      await File(path).writeAsBytes(pdf ? referencePdf() : epub);
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
                theme: 'light',
                epubFontSize: 18,
                epubLineSpacing: 1.6,
                pdfZoom: 0,
                twoPages: variant.endsWith('spread'),
                zonesHintDismissed: true,
              ),
            ),
          ),
        ),
      );
      ReaderEpubPageContentPainter? page() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<ReaderEpubPageContentPainter>()
          .firstOrNull;
      PagePainter? raster() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<PagePainter>()
          .where((p) => p.image != null)
          .firstOrNull;
      int location() =>
          pdf ? raster()!.currentUnit : page()!.page.canonicalStart;
      await until(tester, () => pdf ? raster() != null : page() != null);
      final origin = location();
      await capture('$variant-rest');
      final surface = find.byKey(const ValueKey('reader-selection-surface'));
      final rect = tester.getRect(surface);
      final sign = rtl ? 1.0 : -1.0;
      final start = Offset(
        rect.left + rect.width * (rtl ? .08 : .92),
        rect.center.dy,
      );
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(Offset(sign * 30, 0));
      await gesture.moveBy(Offset(sign * rect.width * .26, 0));
      await tester.pump(const Duration(milliseconds: 180));
      expect(location(), origin);
      if (!baseline) {
        expect(find.byKey(const ValueKey('reader-page-curl')), findsOneWidget);
      }
      await capture('$variant-held');
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(location(), origin);

      await tester.sendKeyEvent(
        LogicalKeyboardKey.pageDown,
        physicalKey: PhysicalKeyboardKey.pageDown,
      );
      await until(tester, () => location() != origin);
      final next = location();
      expect(next, greaterThan(origin));
      await capture('$variant-next');
      final returning = await tester.startGesture(
        Offset(rect.left + rect.width * (rtl ? .92 : .08), rect.center.dy),
      );
      await returning.moveBy(Offset(-sign * 30, 0));
      await returning.moveBy(Offset(-sign * rect.width * .26, 0));
      await tester.pump(const Duration(milliseconds: 180));
      expect(location(), next);
      await capture('$variant-back-held');
      await returning.cancel();
      await tester.pumpAndSettle();
      expect(location(), next);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.pageUp,
        physicalKey: PhysicalKeyboardKey.pageUp,
      );
      await until(tester, () => location() == origin);

      // Warm snapshots/rendering, then measure turns without screenshot I/O.
      frames.clear();
      binding.addTimingsCallback(timings);
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(
          i.isEven ? LogicalKeyboardKey.pageDown : LogicalKeyboardKey.pageUp,
          physicalKey: i.isEven
              ? PhysicalKeyboardKey.pageDown
              : PhysicalKeyboardKey.pageUp,
        );
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
      }
      binding.removeTimingsCallback(timings);
      if (frames.isNotEmpty) {
        final build =
            frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList()
              ..sort();
        final raster =
            frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList()
              ..sort();
        // ignore: avoid_print
        print(
          'CURL_TIMING $variant frames=${frames.length} build_p95_ms=${build[(build.length * .95).floor()]} raster_p95_ms=${raster[(raster.length * .95).floor()]} over_16.7ms=${frames.where((f) => f.buildDuration.inMicroseconds > 16700 || f.rasterDuration.inMicroseconds > 16700).length}',
        );
      }

      if (Platform.environment['SHOSAI_CURL_POINTER'] == '1' &&
          variant == 'epub') {
        final recording = await Process.start(
          'ffmpeg',
          [
            '-y',
            '-loglevel',
            'error',
            '-video_size',
            '1280x900',
            '-framerate',
            '30',
            '-f',
            'x11grab',
            '-i',
            ':99',
            '-t',
            '14',
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            '-crf',
            '23',
            '-pix_fmt',
            'yuv420p',
            '${Platform.environment['SHOSAI_CURL_ARTIFACTS']}/turns.mp4',
          ],
          environment: {'LD_LIBRARY_PATH': ''},
        );
        binding.shouldPropagateDevicePointerEvents = true;
        final windows = await Process.run('xdotool', [
          'search',
          '--onlyvisible',
          '--pid',
          '$pid',
        ]);
        final id = windows.stdout.toString().trim().split('\n').last;
        await Process.run('xdotool', ['windowfocus', id]);
        // Cross the page and both neighboring edge controls with a real pointer.
        for (final fraction in [.9, .05, .95, .5]) {
          for (var step = 0; step < 20; step++) {
            await Process.run('xdotool', [
              'mousemove',
              '--window',
              id,
              '${(rect.left + rect.width * (step / 20 * fraction)).round()}',
              '${rect.center.dy.round()}',
            ]);
            await tester.pump(const Duration(milliseconds: 15));
          }
          final before = location();
          await Process.run('xdotool', [
            'key',
            fraction == .05 ? 'Prior' : 'Next',
          ]);
          for (var frame = 0; frame < 40; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            location(),
            fraction == .05 ? lessThan(before) : greaterThan(before),
          );
        }
        binding.shouldPropagateDevicePointerEvents = false;
        await tester.pumpAndSettle();
        expect(
          await recording.exitCode,
          0,
          reason: await recording.stderr.map(String.fromCharCodes).join(),
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
      expect(tester.takeException(), isNull);
    });
  }
}
