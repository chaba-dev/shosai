import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/epub/content.dart';
import 'package:shosai_flutter/reader/epub/flow.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service/vm_service_io.dart' as vms_io;

import '../test/support/epub_navigation_fixture.dart';
import '../test/support/production_shell_harness.dart';

/// Frame times and memory while scrolling a long continuous EPUB chapter.
///
/// Opens the generated 250K-scalar chapter (`longChapterEpub`) in the
/// production [ReaderScreen] in continuous mode, scrolls it top to bottom and
/// back to the middle with one wheel event per frame, and records:
/// - engine-reported [FrameTiming]s (build and raster) of every frame,
/// - the synchronous time of every continuous window step,
/// - the laid-out window and the measured paragraphs it retains,
/// - Dart heap (VM service, after a requested GC) and process RSS at
///   checkpoints.
///
/// Prints one `CONTINUOUS_MEASUREMENT` JSON line, and writes it to
/// `SHOSAI_MEASURE_OUT` when set. Run from the repository root on a desktop host:
/// ```sh
/// flutter test integration_test/epub_continuous_long_chapter_test.dart \
///   -d linux --profile
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scrolling a 250K-scalar continuous chapter', (tester) async {
    tester.view.physicalSize = const ui.Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final epub = longChapterEpub();
    final bridge = HarnessBridge(
      books: const [
        FlutterLibraryBook(
          bookId: 1,
          title: 'Long chapter',
          format: FlutterBookFormat.epub,
          pathKey: '/books/long.epub',
          managed: true,
          progress: 0,
          dateAdded: '2026-10-21',
        ),
      ],
      unitCount: 2,
    )..epubBytes = epub;

    final timings = <FrameTiming>[];
    SchedulerBinding.instance.addTimingsCallback(timings.addAll);
    final steps = <({int micros, int measured})>[];
    final sessions = <ChapterLayoutSession>[];

    vms.VmService? vm;
    String? isolateId;
    try {
      final uri = (await developer.Service.getInfo()).serverUri;
      if (uri != null) {
        vm = await vms_io.vmServiceConnectUri(
          Uri(
            scheme: 'ws',
            host: uri.host,
            port: uri.port,
            path: '${uri.path}ws',
          ).toString(),
        );
        isolateId = developer.Service.getIsolateId(Isolate.current);
      }
    } catch (_) {}

    ReaderEpubPage? page() {
      for (final paint in tester.widgetList<CustomPaint>(
        find.byType(CustomPaint),
      )) {
        final painter = paint.painter;
        if (painter is ReaderEpubPageContentPainter) return painter.page;
      }
      return null;
    }

    final checkpoints = <Map<String, Object?>>[];
    Future<void> checkpoint(String label) async {
      int? heap;
      int? external;
      if (vm != null && isolateId != null) {
        final profile = await tester.runAsync(
          () => vm!.getAllocationProfile(isolateId!, gc: true),
        );
        heap = profile?.memoryUsage?.heapUsage;
        external = profile?.memoryUsage?.externalUsage;
      }
      final session = sessions.isEmpty ? null : sessions.last;
      final window = page()?.window;
      checkpoints.add({
        'label': label,
        'dartHeapBytes': heap,
        'dartExternalBytes': external,
        'rssBytes': ProcessInfo.currentRss,
        'laidOutNodes': session?.laidOutNodes,
        // Profile builds have no `debugDisposed`: count the paragraphs the
        // session's window retains instead.
        'windowPainters': session == null ? null : _painters(session),
        'window': window == null ? null : [window.firstNode, window.endNode],
      });
    }

    await tester.pumpWidget(
      productionShell(
        home: ReaderScreen(
          bridge: bridge,
          initialPath: '/books/long.epub',
          initialBookId: 1,
          initialSettings: const FlutterReaderSettings(
            continuous: true,
            theme: 'light',
            epubFontSize: 18,
            epubLineSpacing: 1.5,
            pdfZoom: 0,
          ),
          epubImageDecoder: (bytes) async => null,
          debugEpubSessionObserver: sessions.add,
          debugContinuousStepObserver: steps.add,
        ),
      ),
    );
    for (var round = 0; round < 200 && page() == null; round += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(page()?.continuous, isTrue);
    for (var frame = 0; frame < 60; frame += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await checkpoint('open');

    final view = find.byKey(const ValueKey('reader-continuous-presentation'));
    final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getBottomLeft(view) + const Offset(30, -30)),
    );
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: view, matching: find.byType(Scrollable)),
        )
        .position;

    final scrollStart = timings.length;
    final stepStart = steps.length;
    // One wheel event per frame: 400 px per frame, 24,000 px/s at 60 Hz.
    const delta = 400.0;
    var frames = 0;
    Future<void> scrollTo(double target, String label) async {
      for (
        var phase = 0;
        (position().pixels - target).abs() > delta && phase < 3000;
        phase += 1
      ) {
        final sign = target > position().pixels ? 1 : -1;
        await tester.sendEventToBinding(
          pointer.scroll(Offset(0, sign * delta)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        frames += 1;
      }
      for (var frame = 0; frame < 30; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await checkpoint(label);
    }

    final end = position().maxScrollExtent;
    await scrollTo(end / 4, 'quarter');
    await scrollTo(end / 2, 'half');
    await scrollTo(position().maxScrollExtent, 'end');
    await scrollTo(position().maxScrollExtent / 2, 'back-to-half');
    // FrameTimings are delivered in batches.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    List<double> percentiles(List<int> micros) {
      if (micros.isEmpty) return const [];
      final sorted = [...micros]..sort();
      double at(double p) =>
          sorted[math.min(sorted.length - 1, (p * sorted.length).floor())] /
          1000;
      return [at(0.5), at(0.95), at(0.99), sorted.last / 1000];
    }

    final scrolled = timings.sublist(scrollStart);
    final build = [for (final t in scrolled) t.buildDuration.inMicroseconds];
    final raster = [for (final t in scrolled) t.rasterDuration.inMicroseconds];
    final total = [
      for (final t in scrolled)
        t.buildDuration.inMicroseconds + t.rasterDuration.inMicroseconds,
    ];
    final result = {
      'scalars': openEpubBytes(epub).chapters.first.scalarCount,
      'chapterNodes': page()?.window?.nodeTops.length,
      'scrollFrames': frames,
      'reportedFrames': scrolled.length,
      'columnHeight': end,
      'frameMs_p50_p95_p99_max': {
        'build': percentiles(build),
        'raster': percentiles(raster),
        'buildPlusRaster': percentiles(total),
      },
      'framesOver16_7ms': total.where((value) => value > 16667).length,
      'windowSteps': steps.length - stepStart,
      'windowStepMs_p50_p95_p99_max': percentiles([
        for (final step in steps.sublist(stepStart)) step.micros,
      ]),
      'sessions': sessions.length,
      'checkpoints': checkpoints,
    };
    final line = jsonEncode(result);
    // ignore: avoid_print
    print('CONTINUOUS_MEASUREMENT $line');
    final out = Platform.environment['SHOSAI_MEASURE_OUT'];
    if (out != null) File(out).writeAsStringSync(line);

    await tester.pumpWidget(const SizedBox());
    await vm?.dispose();
  });
}

int _painters(ChapterLayoutSession session) {
  final painters = <TextPainter>{};
  collectPainters(session.blocks, painters);
  return painters.length;
}
