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
import '../test/support/production_shell_harness.dart' show revealReaderChrome;
import '../test/support/reference_documents.dart';

/// Real engines, SQLite and the production reader at phone/tablet/desktop sizes.
/// Insets simulate an edge-to-edge iPhone; these are Linux, not device captures.
/// SHOSAI_QUIET_ARTIFACTS saves review captures; SHOSAI_QUIET_BASELINE records
/// the old behavior without asserting the corrected geometry/headings.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['SHOSAI_QUIET_VIDEO'] == '1') {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  }
  final boundaryKey = GlobalKey();
  final baseline = Platform.environment['SHOSAI_QUIET_BASELINE'] == '1';
  final artifacts = Platform.environment['SHOSAI_QUIET_ARTIFACTS'];
  Finder keyed(String key) => find.byKey(ValueKey(key));

  Future<void> capture(String name) async {
    if (artifacts == null) return;
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(artifacts).create(recursive: true);
    await File(
      '$artifacts/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 400 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue);
    await tester.pumpAndSettle();
  }

  ReaderEpubPageContentPainter? epub(WidgetTester tester) => tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((p) => p.painter)
      .whereType<ReaderEpubPageContentPainter>()
      .firstOrNull;

  const settings = FlutterReaderSettings(
    continuous: false,
    theme: 'light',
    epubFontSize: 18,
    epubLineSpacing: 1.6,
    pdfZoom: 0,
    twoPages: false,
    zonesHintDismissed: true,
  );

  Future<void> open(
    WidgetTester tester,
    FlutterBridge bridge,
    String path,
    Size size,
  ) async {
    final phone = size.width < 600;
    await binding.setSurfaceSize(size);
    addTearDown(() => binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ShosaiShell(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: size,
            child: RepaintBoundary(
              key: boundaryKey,
              child: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  devicePixelRatio: 2,
                  viewPadding: phone
                      ? const EdgeInsets.only(top: 59, bottom: 34)
                      : EdgeInsets.zero,
                ),
                child: ReaderScreen(
                  key: UniqueKey(),
                  bridge: bridge,
                  initialPath: path,
                  initialSettings: settings,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await until(
      tester,
      () => path.endsWith('epub')
          ? epub(tester) != null
          : tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((p) => p.painter)
                .whereType<PagePainter>()
                .any((p) => p.image != null),
    );
  }

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('tablet', const Size(820, 800)),
    ('desktop', const Size(1200, 800)),
  ]) {
    testWidgets('Contents jump and paging agree at the page top on $name', (
      tester,
    ) async {
      final directory = await Directory.systemTemp.createTemp('shosai-quiet-');
      final path = '${directory.path}/Quiet pages.epub';
      await File(path).writeAsBytes(
        buildTestEpub(
          chapters: {
            'OPS/Text/book.xhtml':
                '<h1>Chapter 1</h1>'
                '${List.generate(15, (i) => '<p>$i. The path follows the river through the old orchard. At the bend, the water mirrors the trees. A book leaves room for a small detour.</p>').join()}'
                '<p>The walk continues. <span id="second">Chapter 2 begins here.</span> The orchard stands on the far bank.</p>'
                '${List.generate(20, (i) => '<p>$i. Another path leads through the orchard, leaving room for the traveller to stop and look around.</p>').join()}',
          },
          nav:
              '<ol><li><a href="../Text/book.xhtml">Chapter 1</a></li>'
              '<li><a href="../Text/book.xhtml#second">Chapter 2</a></li></ol>',
        ),
      );
      final bridge = await createApplicationBridge(
        applicationSupportDirectory: () async => directory,
      );
      await open(tester, bridge, path, size);
      TestGesture? mouse;
      if (name == 'desktop') {
        mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(-1, -1));
        await mouse.moveTo(Offset(size.width / 2, size.height / 2));
        await tester.pump(const Duration(milliseconds: 200));
        await mouse.moveTo(Offset(size.width / 2, 16));
        await tester.pump(const Duration(milliseconds: 200));
      } else {
        await revealReaderChrome(tester);
      }
      final contents = keyed('reader-header-contents');
      await tester.tap(contents);
      await tester.pumpAndSettle();
      await tester.tap(keyed('reader-contents-entry-0-2'));
      if (baseline) {
        await until(
          tester,
          () => keyed('reader-reference-go-to').evaluate().isNotEmpty,
        );
        await tester.tap(keyed('reader-reference-go-to'));
      }
      await until(tester, () => epub(tester)!.page.pageIndex > 0);
      // Hide chrome without losing the jump's return point.
      await mouse?.moveTo(const Offset(-1, -1));
      Focus.of(
        tester.element(keyed('reader-selection-surface')),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(keyed('reader-header-contents').hitTestable(), findsNothing);
      final start = epub(tester)!.page.canonicalStart;
      final jumpHead = tester.widget<Text>(keyed('reader-running-head')).data;
      await capture('$name-contents-jump');
      if (!baseline) {
        expect(jumpHead, 'Chapter 1');
        final pill = tester.getRect(keyed('reader-back-pill'));
        for (final key in ['reader-folio', 'reader-running-head']) {
          expect(pill.overlaps(tester.getRect(keyed(key))), isFalse);
        }
      }
      Focus.of(
        tester.element(keyed('reader-selection-surface')),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await until(tester, () => epub(tester)!.page.canonicalStart < start);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await until(tester, () => epub(tester)!.page.canonicalStart == start);
      expect(epub(tester)!.page.canonicalStart, start);
      final pagedHead = tester.widget<Text>(keyed('reader-running-head')).data;
      // ignore: avoid_print
      print('QUIET_HEAD $name jump=$jumpHead paged=$pagedHead top=$start');
      if (!baseline) expect(pagedHead, jumpHead);
      await capture('$name-paged');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await closeApplicationCores();
      await directory.delete(recursive: true);
    });
  }

  testWidgets('a warm PDF turn starts the curl promptly', (tester) async {
    final directory = await Directory.systemTemp.createTemp('shosai-pdf-');
    final path = '${directory.path}/Quiet pages.pdf';
    await File(path).writeAsBytes(referencePdf());
    final bridge = await createApplicationBridge(
      applicationSupportDirectory: () async => directory,
    );
    final video =
        artifacts != null && Platform.environment['SHOSAI_QUIET_VIDEO'] == '1';
    final size = video ? const Size(1200, 800) : const Size(390, 844);
    await open(tester, bridge, path, size);
    await tester.pump(const Duration(seconds: 1));
    await capture('pdf-before-tap');
    final rect = tester.getRect(keyed('reader-selection-surface'));
    Process? recording;
    String? window;
    final frames = <({double time, ui.Image image})>[];
    final clock = Stopwatch();
    var takingFrames = false;
    addTearDown(() {
      takingFrames = false;
      binding.shouldPropagateDevicePointerEvents = false;
      for (final frame in frames) {
        frame.image.dispose();
      }
    });
    if (video) {
      final windows = await Process.run('xdotool', [
        'search',
        '--onlyvisible',
        '--pid',
        '$pid',
      ]);
      expect(windows.exitCode, 0);
      window = windows.stdout.toString().trim().split('\n').last;
      await Process.run('xdotool', ['windowmove', window, '0', '0']);
      await Process.run('xdotool', ['windowsize', window, '1200', '800']);
      await Process.run('xdotool', ['windowfocus', window]);
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      await Directory('${directory.path}/frames').create();
      clock.start();
      takingFrames = true;
      var lastFrame = -33333;
      // Xvfb's GPU window reads back black in this orb. Keep actual Flutter
      // frames (no pixel readback during the turn), then composite the real
      // X11 pointer recording below. This is a review clip, not a benchmark.
      binding.addPersistentFrameCallback((_) {
        if (!takingFrames || clock.elapsedMicroseconds - lastFrame < 33333) {
          return;
        }
        lastFrame = clock.elapsedMicroseconds;
        binding.addPostFrameCallback((_) {
          if (!takingFrames) return;
          final boundary =
              boundaryKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          frames.add((
            time: clock.elapsedMicroseconds / 1000000,
            image: boundary.toImageSync(),
          ));
        });
      });
      recording = await Process.start(
        'ffmpeg',
        [
          '-y',
          '-loglevel',
          'error',
          '-video_size',
          '1200x800',
          '-framerate',
          '60',
          '-f',
          'x11grab',
          '-i',
          Platform.environment['DISPLAY']!,
          '-t',
          '6',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-crf',
          '18',
          '-pix_fmt',
          'yuv420p',
          '${directory.path}/pointer.mp4',
        ],
        environment: {'LD_LIBRARY_PATH': ''},
      );
      binding.shouldPropagateDevicePointerEvents = true;
      // Cross both neighboring edge controls before clicking Next.
      for (var step = 0; step <= 29; step++) {
        await Process.run('xdotool', [
          'mousemove',
          '--window',
          window,
          '${20 + step * 40}',
          '${rect.center.dy.round()}',
        ]);
        await tester.pump(const Duration(milliseconds: 16));
      }
      final next = tester.getCenter(keyed('reader-edge-next'));
      await Process.run('xdotool', [
        'mousemove',
        '--window',
        window,
        '${next.dx.round()}',
        '${next.dy.round()}',
      ]);
      await tester.pump(const Duration(milliseconds: 100));
    }
    final watch = Stopwatch()..start();
    if (window != null) {
      await Process.run('xdotool', ['click', '1']);
    } else {
      await tester.tapAt(Offset(rect.left + rect.width * .9, rect.center.dy));
    }
    while (keyed('reader-page-curl').evaluate().isEmpty &&
        watch.elapsedMilliseconds < 2000) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    // ignore: avoid_print
    print('QUIET_PDF input_to_curl_ms=${watch.elapsedMilliseconds}');
    expect(keyed('reader-page-curl'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 80));
    // PNG encoding during the fold would stall the very clip being recorded.
    if (!video) await capture('pdf-curl-80ms');
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(keyed('reader-folio')).data, 'page 2 of 3');
    await capture('pdf-after-turn');
    if (recording != null) {
      await tester.pump(const Duration(seconds: 1));
      expect(await recording.exitCode, 0);
      takingFrames = false;
      binding.shouldPropagateDevicePointerEvents = false;
      expect(frames.length, greaterThan(5));
      final sequence = StringBuffer();
      for (var i = 0; i < frames.length; i++) {
        final bytes = await frames[i].image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File(
          '${directory.path}/frames/$i.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        sequence.writeln("file 'frames/$i.png'");
        sequence.writeln(
          'duration ${i + 1 < frames.length ? frames[i + 1].time - frames[i].time : .1}',
        );
      }
      sequence.writeln("file 'frames/${frames.length - 1}.png'");
      await File('${directory.path}/frames.txt').writeAsString('$sequence');
      final encoded = await Process.run(
        'ffmpeg',
        [
          '-y',
          '-loglevel',
          'error',
          '-f',
          'concat',
          '-safe',
          '0',
          '-i',
          '${directory.path}/frames.txt',
          '-i',
          '${directory.path}/pointer.mp4',
          '-filter_complex',
          '[0:v]fps=60,format=gbrp[app];[1:v]format=gbrp[pointer];'
              '[app][pointer]blend=all_mode=screen,format=yuv420p',
          '-shortest',
          '-c:v',
          'libx264',
          '-crf',
          '18',
          '$artifacts/pdf-turn.mp4',
        ],
        environment: {'LD_LIBRARY_PATH': ''},
      );
      expect(encoded.exitCode, 0, reason: '${encoded.stderr}');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await closeApplicationCores();
    await directory.delete(recursive: true);
  });
}
