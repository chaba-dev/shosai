/// Measurement entry point for the Phase C evaluation prototype.
///
/// Runs a scripted sequence against the real Flutter renderer and reports
/// frame-timestamp latencies plus process memory:
///
///   1. cold open: open request → first frame whose document pixels contain
///      content (content-aware; a blank placeholder fails the check)
///   2. warm navigation: page turn → frame with the new page's content
///   3. relayout: font-size change → frame with the new layout's content
///   4. mode switch: paginated → continuous → frame with content
///   5. retained memory: RSS after first content, after the navigation burst,
///      after a second document, and after disposal
///
/// Run through `tool/measure.sh` (Xvfb + release bundle) or directly:
///
///   flutter run -d linux --release -t lib/measure_main.dart \
///     --dart-define=SHOSAI_MEASURE_BOOKS=/path/a.epub,/path/b.epub
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'reader/capture.dart';
import 'reader/controller.dart';
import 'reader/effects.dart';
import 'reader/message.dart';
import 'reader/model.dart';
import 'reader/script_fonts.dart';
import 'reader/theme.dart';
import 'reader/view.dart';

String _captureDirectory(String outputPath) {
  final separator = outputPath.lastIndexOf('/');
  final directory = separator < 0 ? '.' : outputPath.substring(0, separator);
  return '$directory/captures';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final books = (Platform.environment['SHOSAI_MEASURE_BOOKS'] ?? '')
      .split(',')
      .where((value) => value.isNotEmpty)
      .toList();
  final spines = (Platform.environment['SHOSAI_MEASURE_SPINES'] ?? '')
      .split(',')
      .map((value) => int.tryParse(value.trim()) ?? 0)
      .toList();
  final out = Platform.environment['SHOSAI_MEASURE_OUT'] ?? '';
  final trials =
      int.tryParse(Platform.environment['SHOSAI_MEASURE_TRIALS'] ?? '') ?? 5;
  runApp(
    _MeasureApp(books: books, spines: spines, outputPath: out, trials: trials),
  );
}

class _MeasureApp extends StatefulWidget {
  const _MeasureApp({
    required this.books,
    required this.spines,
    required this.outputPath,
    required this.trials,
  });

  final List<String> books;
  final List<int> spines;
  final String outputPath;
  final int trials;

  @override
  State<_MeasureApp> createState() => _MeasureAppState();
}

class _MeasureAppState extends State<_MeasureApp> {
  final GlobalKey _documentKey = GlobalKey(debugLabel: 'measure-document');
  final Map<String, Object?> _report = {
    'measurement_caveats': {
      'rss':
          'ProcessInfo.currentRss is current resident memory, not a '
          'retained-heap measurement, and the snapshots do not identify which '
          'allocations account for a difference. A separate isolate or '
          'VM-service heap profile is required to attribute it.',
      'environment':
          'Linux release bundle under Xvfb with software rasterization '
          '(llvmpipe); absolute frame latencies are not desktop-GPU numbers.',
      'relayout_includes_coalescing':
          'relayout frame latency includes the 80 ms '
          'resize/typography coalescing delay; layout_work_micros reports the '
          'layout computation alone.',
    },
    'endpoint_definitions': {
      'first_displayed_content':
          'open request → the model state with the first laid-out content, '
          'then a content-aware capture of the document boundary (ink must be '
          'present; a blank placeholder fails). Not a presented-frame clock.',
      'warm_navigation':
          'page-turn dispatch → the model state with the next page, then a '
          'content-verified capture. Not a presented-frame clock.',
      'relayout':
          'font-size dispatch → the model state with the new layout, then a '
          'content-verified capture. Not a presented-frame clock.',
      'mode_switch':
          'mode dispatch → the model state with the new mode layout, then a '
          'content-verified capture. Not a presented-frame clock.',
    },
    'books': <Map<String, Object?>>[],
  };

  EpubReaderController? _controller;

  /// Progress log written synchronously so a stalled run is diagnosable even
  /// when stdout is block-buffered by a redirect.
  /// Writes the report after every completed book so partial results survive a
  /// stalled later book.
  void _writeReport() {
    final encoded = const JsonEncoder.withIndent('  ').convert(_report);
    for (final path in [
      if (widget.outputPath.isNotEmpty) widget.outputPath,
      'artifacts/measurements/report.json',
    ]) {
      try {
        File(path).writeAsStringSync(encoded);
        return;
      } catch (error) {
        _log('report write failed for $path: $error');
      }
    }
  }

  void _log(String message) {
    final line = '[measure] $message';
    stdout.writeln(line);
    try {
      File(
        'artifacts/measurements/run-progress.log',
      ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never fail the run.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    _report['generated_at'] = DateTime.now().toUtc().toIso8601String();
    _report['trials'] = widget.trials;
    // The same font registration the interactive app performs, so the
    // measurement environment matches the app.
    final bundled = await loadBundledContentFonts();
    final fallbacks = await loadScriptFallbackFamilies();
    _report['bundled_fonts'] = bundled;
    _report['script_fallbacks'] = fallbacks;
    for (var index = 0; index < widget.books.length; index++) {
      final spine = index < widget.spines.length ? widget.spines[index] : 0;
      final book = widget.books[index];
      try {
        await _measureBook(
          book,
          fallbacks,
          spine,
        ).timeout(const Duration(minutes: 6));
      } catch (_) {
        _log('book timed out (stalled): $book');
        (_report['books'] as List).add({
          'path': book,
          'book': book.split('/').last,
          'stalled': true,
          'reason': 'measurement step did not complete within 6 minutes',
        });
        _writeReport();
      }
    }
    _report['process_rss_after_all_books'] = ProcessInfo.currentRss;
    _writeReport();
    exit(0);
  }

  Future<void> _measureBook(
    String path,
    List<String> fallbacks,
    int spine,
  ) async {
    _log('book: $path (spine $spine)');
    final entry = <String, Object?>{
      'path': path,
      'book': path.split('/').last,
      'samples': <Map<String, Object?>>[],
    };
    // A fresh in-memory store: a persistent store would reopen at whatever
    // position a previous run stopped at, so runs would not be comparable.
    final controller = EpubReaderController(
      contentFallbackFamilies: fallbacks,
      positionStore: EpubMemoryPositionStore(),
    );
    entry['initial_spine'] = controller.model.spine;
    entry['initial_scalar'] = controller.model.scalar;
    // The reader view must be built before any viewport or layout can happen.
    setState(() => _controller = controller);
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 50));

    // Cold open.
    final open = await _measure(
      controller,
      () => controller.dispatch(EpubReaderOpenRequested(path)),
      () =>
          controller.model.status == EpubReaderStatus.ready &&
          controller.model.flow != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    _log(
      'cold open: state ${open.stateMicros}us '
      'verified ${open.verifiedMicros}us content=${open.contentVerified}',
    );
    entry['open_effect_micros'] = controller.model.firstContentMicros;
    entry['cold_open_layout_work_micros'] = controller.model.lastLayoutMicros;
    final firstContent = await _verifyContent(controller);
    _log('first content: $firstContent');
    (entry['samples'] as List).add({
      'operation': 'cold_open',
      'state_latency_micros': open.stateMicros,
      'verified_capture_micros': open.verifiedMicros,
      'content_verified': open.contentVerified,
      'capture': firstContent,
    });
    // Move to the requested spine (the long fixture's large chapter is spine 1)
    // before measuring, so the numbers describe that chapter.
    if (spine != controller.model.spine) {
      final jumpLatency = await _measure(
        controller,
        () => controller.dispatch(
          EpubReaderScalarJumpRequested(spine: spine, scalar: 0),
        ),
        () =>
            controller.model.spine == spine &&
            controller.model.flow != null &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      (entry['samples'] as List).add({
        'operation': 'spine_jump',
        'state_latency_micros': jumpLatency.stateMicros,
        'verified_capture_micros': jumpLatency.verifiedMicros,
        'content_verified': jumpLatency.contentVerified,
        'layout_work_micros': controller.model.lastLayoutMicros,
      });
    }
    entry['spine'] = controller.model.spine;
    entry['scalars'] = controller.model.chapter?.scalarCount;
    entry['pages'] = controller.model.paginated?.pages.length;
    entry['blocks'] = controller.model.flow?.blocks.length;
    entry['lines'] = controller.model.flow?.blocks
        .where((block) => block.text != null)
        .fold<int>(0, (sum, block) => sum + block.text!.lines.length);
    entry['painters'] = controller.model.flow?.blocks
        .where((block) => block.text != null)
        .length;
    entry['rss_after_first_content'] = ProcessInfo.currentRss;
    entry['max_rss_after_first_content'] = ProcessInfo.maxRss;

    // Warm navigation.
    final singleSpread = controller.model.unitCount <= 1;
    for (var trial = 0; trial < widget.trials; trial++) {
      final beforeUnit = controller.model.unit;
      final beforeSpine = controller.model.spine;
      final last = controller.model.unitCount - 1;
      final delta = beforeUnit < last ? 1 : -1;
      final latency = await _measure(
        controller,
        () {
          if (singleSpread) {
            // A one-spread document has no warm page turn: measure the warm
            // chapter transition instead and label it.
            final nextSpine =
                (beforeSpine + 1) %
                (controller.model.book?.chapters.length ?? 1);
            controller.dispatch(
              EpubReaderScalarJumpRequested(spine: nextSpine, scalar: 0),
            );
          } else {
            controller.dispatch(EpubReaderUnitRequested(delta));
          }
        },
        () => singleSpread
            ? controller.model.spine != beforeSpine &&
                  !controller.model.relayoutBusy
            : controller.model.unit != beforeUnit &&
                  !controller.model.relayoutBusy,
      );
      (entry['samples'] as List).add({
        'operation': singleSpread
            ? 'warm_chapter_transition'
            : 'warm_navigation',
        'state_latency_micros': latency.stateMicros,
        'verified_capture_micros': latency.verifiedMicros,
        'content_verified': latency.contentVerified,
        'page': controller.model.unit,
        'spine': controller.model.spine,
        'pages': controller.model.paginated?.pages.length,
        'layout_work_micros': controller.model.lastLayoutMicros,
      });
      stdout.writeln('[measure] warm nav $trial: $latency');
      if (singleSpread) {
        // Return to the measured chapter for the remaining steps.
        controller.dispatch(
          EpubReaderScalarJumpRequested(spine: spine, scalar: 0),
        );
        await _pumpUntil(
          () =>
              controller.model.spine == spine && !controller.model.relayoutBusy,
          timeout: const Duration(seconds: 30),
        );
      }
    }
    entry['rss_after_navigation'] = ProcessInfo.currentRss;
    final navigationCapture = await _verifyContent(controller);
    entry['navigation_capture'] = navigationCapture;

    // Relayout: font size.
    for (var trial = 0; trial < widget.trials; trial++) {
      final delta = trial.isEven ? 2.0 : -2.0;
      final target = controller.model.typography.fontSize + delta;
      final latency = await _measure(
        controller,
        () => controller.dispatch(EpubReaderFontSizeChanged(delta)),
        () =>
            controller.model.typography.fontSize == target &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      (entry['samples'] as List).add({
        'operation': 'relayout_font_size',
        'state_latency_micros': latency.stateMicros,
        'verified_capture_micros': latency.verifiedMicros,
        'content_verified': latency.contentVerified,
        'font_size': target,
        'layout_work_micros': controller.model.lastLayoutMicros,
      });
      _log(
        'relayout $trial: state ${latency.stateMicros}us '
        'verified ${latency.verifiedMicros}us',
      );
    }

    // Mode switch.
    final modeLatency = await _measure(
      controller,
      () => controller.dispatch(
        const EpubReaderModeChanged(EpubReaderMode.continuous),
      ),
      () =>
          controller.model.paginated == null &&
          controller.model.flow != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    (entry['samples'] as List).add({
      'operation': 'mode_switch_to_continuous',
      'state_latency_micros': modeLatency.stateMicros,
      'verified_capture_micros': modeLatency.verifiedMicros,
      'content_verified': modeLatency.contentVerified,
      'layout_work_micros': controller.model.lastLayoutMicros,
    });
    _log('mode switch: ${modeLatency.stateMicros}us');
    entry['rss_continuous'] = ProcessInfo.currentRss;
    final continuousCapture = await _verifyContent(controller);
    entry['continuous_capture'] = continuousCapture;

    // Back to paginated for a repeatable state, then dispose.
    await _measure(
      controller,
      () => controller.dispatch(
        const EpubReaderModeChanged(EpubReaderMode.paginated),
      ),
      () =>
          controller.model.paginated != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    controller.dispose();
    // Drop the model reference so the disposed document's flow can be
    // collected before the retained-memory sample.
    setState(() => _controller = null);
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 200));
    entry['rss_after_dispose'] = ProcessInfo.currentRss;
    entry['max_rss_after_dispose'] = ProcessInfo.maxRss;
    (_report['books'] as List).add(entry);
    _writeReport();
  }

  /// Dispatch [action], wait for [condition], then verify the rendered pixels.
  ///
  /// Returns two honest endpoints:
  /// - `state_latency_micros`: dispatch → the model state the operation
  ///   produces. This is a state-change latency, not a presented frame.
  /// - `verified_capture_micros`: dispatch → a content-verified capture of the
  ///   document boundary. This includes the capture round-trip, so it is an
  ///   upper bound on the user-visible update, not a presentation measurement.
  Future<({int stateMicros, int verifiedMicros, bool contentVerified})>
  _measure(
    EpubReaderController controller,
    void Function() action,
    bool Function() condition,
  ) async {
    final stopwatch = Stopwatch()..start();
    action();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (!condition()) {
      _log('timeout waiting for a condition');
      return (stateMicros: -1, verifiedMicros: -1, contentVerified: false);
    }
    // The state endpoint is sampled immediately; the capture below renders the
    // document boundary directly, so no frame wait is required (and waiting on
    // endOfFrame can hang when the window is not producing frames).
    final stateMicros = stopwatch.elapsedMicroseconds;
    final capture = await _verifyContent(controller);
    return (
      stateMicros: stateMicros,
      verifiedMicros: stopwatch.elapsedMicroseconds,
      contentVerified: capture['content_verified'] == true,
    );
  }

  /// Real-time settle wait (frames are produced by the running app).
  Future<void> _pumpUntil(
    bool Function() condition, {
    required Duration timeout,
  }) async {
    final end = DateTime.now().add(timeout);
    while (!condition() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  Future<Map<String, Object?>> _verifyContent(
    EpubReaderController controller,
  ) async {
    try {
      return await _verifyContentInner(
        controller,
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      _log('content verification timed out');
      return {'content_verified': false, 'reason': 'verification timed out'};
    }
  }

  Future<Map<String, Object?>> _verifyContentInner(
    EpubReaderController controller,
  ) async {
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 120));
    final boundary =
        _documentKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return {'content_verified': false, 'reason': 'no boundary'};
    }
    ui.Image? image;
    try {
      image = await boundary
          .toImage(pixelRatio: 1.0)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      _log('capture timed out');
      return {'content_verified': false, 'reason': 'capture timed out'};
    }
    final analysis = await analyzeCapture(
      image,
      controller.model.flow?.palette.background ??
          ReaderPalette.light.background,
    );
    if (widget.outputPath.isNotEmpty) {
      final directory = Directory(_captureDirectory(widget.outputPath));
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) {
        File(
          '${directory.path}/'
          '${controller.model.book?.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-') ?? 'book'}'
          '-spine${controller.model.spine}-${controller.model.mode.name}.png',
        ).writeAsBytesSync(data.buffer.asUint8List());
      }
    }
    return {
      'content_verified': analysis.hasContent,
      'ink_pixels': analysis.nonBackgroundPixels,
      'ink_ratio': double.parse(analysis.inkRatio.toStringAsFixed(4)),
      'ink_rows': analysis.inkRows,
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: controller == null
          ? const Scaffold(body: SizedBox.expand())
          : ListenableBuilder(
              listenable: controller,
              builder: (context, _) => EpubReaderView(
                controller: controller,
                model: controller.model,
                documentKey: _documentKey,
              ),
            ),
    );
  }
}
