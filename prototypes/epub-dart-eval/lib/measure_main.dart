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
import 'reader/layout/cache.dart';
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
  final strategy = switch (Platform.environment['SHOSAI_MEASURE_LAYOUT']) {
    'eager' => EpubLayoutStrategy.eager,
    _ => EpubLayoutStrategy.progressive,
  };
  final cacheEntries =
      int.tryParse(Platform.environment['SHOSAI_MEASURE_LAYOUT_CACHE'] ?? '') ??
      2;
  runApp(
    _MeasureApp(
      books: books,
      spines: spines,
      outputPath: out,
      trials: trials,
      strategy: strategy,
      cacheEntries: cacheEntries,
    ),
  );
}

/// Longest event-loop gap seen while an operation ran.
///
/// A periodic timer that cannot run while the UI thread is inside a
/// synchronous layout call reports the gap when it finally runs, so the
/// longest gap is a lower bound on the longest uninterrupted UI-thread work
/// interval. It is not a presented-frame measurement: the harness runs
/// headless under Xvfb and does not drive vsync.
class _ResponsivenessProbe {
  static const Duration _interval = Duration(milliseconds: 2);
  static const int longGapMicros = 50000;

  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  int _lastMicros = 0;
  int samples = 0;
  int longestGapMicros = 0;
  int longGaps = 0;

  void start() {
    _clock
      ..reset()
      ..start();
    _lastMicros = _clock.elapsedMicroseconds;
    _timer = Timer.periodic(_interval, (_) => _tick());
  }

  void _tick() {
    final now = _clock.elapsedMicroseconds;
    final gap = now - _lastMicros;
    _lastMicros = now;
    samples++;
    if (gap > longestGapMicros) longestGapMicros = gap;
    if (gap >= longGapMicros) longGaps++;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  ({int longestGapMicros, int longGaps, int samples}) take() => (
    longestGapMicros: longestGapMicros,
    longGaps: longGaps,
    samples: samples,
  );
}

/// The endpoints of one measured operation.
class _Measurement {
  const _Measurement({
    required this.usableMicros,
    required this.completeMicros,
    required this.verifiedMicros,
    required this.contentVerified,
    required this.layoutWorkMicros,
    required this.probe,
  });

  final int usableMicros;
  final int completeMicros;
  final int verifiedMicros;
  final bool contentVerified;

  /// Synchronous layout work this operation spent (0 for the eager baseline,
  /// which does not run through a session).
  final int layoutWorkMicros;
  final ({int longestGapMicros, int longGaps, int samples}) probe;

  Map<String, Object?> toJson() => {
    'usable_state_micros': usableMicros,
    'complete_state_micros': completeMicros,
    'verified_capture_micros': verifiedMicros,
    'content_verified': contentVerified,
    'layout_work_micros': layoutWorkMicros,
    'longest_block_micros': probe.longestGapMicros,
    'long_gaps': probe.longGaps,
    'probe_samples': probe.samples,
  };
}

class _MeasureApp extends StatefulWidget {
  const _MeasureApp({
    required this.books,
    required this.spines,
    required this.outputPath,
    required this.trials,
    required this.strategy,
    required this.cacheEntries,
  });

  final List<String> books;
  final List<int> spines;
  final String outputPath;
  final int trials;
  final EpubLayoutStrategy strategy;
  final int cacheEntries;

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
          'relayout state latency includes the 80 ms resize/typography '
          'coalescing delay; layout_work_micros reports the layout computation '
          'alone and longest_block_micros the longest event-loop gap during the '
          'operation.',
      'responsiveness_probe':
          'longest_block_micros is the longest gap between 2 ms event-loop '
          'timer ticks while the operation ran. It is a lower bound on the '
          'longest uninterrupted UI-thread work interval (a blocking layout '
          'call delays the tick), not a presented-frame or vsync measurement.',
      'layout_strategy':
          'layout_strategy is the controller strategy under test; eager is the '
          'pre-progressive baseline (measure the whole chapter, then install), '
          'progressive installs a window around the durable location first and '
          'extends it in bounded batches that yield.',
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
    String encoded;
    try {
      encoded = const JsonEncoder.withIndent('  ').convert(_report);
    } catch (error) {
      _log('report encode failed: $error');
      return;
    }
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
    final cache = EpubLayoutCache(maxEntries: widget.cacheEntries);
    final controller = EpubReaderController(
      contentFallbackFamilies: fallbacks,
      positionStore: EpubMemoryPositionStore(),
      layoutStrategy: widget.strategy,
      layoutCache: cache,
    );
    entry['layout_strategy'] = widget.strategy.name;
    entry['layout_cache_max_entries'] = widget.cacheEntries;
    entry['initial_spine'] = controller.model.spine;
    entry['initial_scalar'] = controller.model.scalar;
    // The reader view must be built before any viewport or layout can happen.
    setState(() => _controller = controller);
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 50));

    // Idle calibration: what the probe reports when the UI thread is free.
    final idleProbe = _ResponsivenessProbe()..start();
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 250));
    idleProbe.stop();
    final idleStats = idleProbe.take();
    entry['idle_probe'] = {
      'longest_gap_micros': idleStats.longestGapMicros,
      'long_gaps': idleStats.longGaps,
      'samples': idleStats.samples,
    };

    // Cold open.
    final open = await _measure(
      controller,
      () => controller.dispatch(EpubReaderOpenRequested(path)),
      usable: () =>
          controller.model.status == EpubReaderStatus.ready &&
          controller.model.flow != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    _log(
      'cold open: usable ${open.usableMicros}us complete '
      '${open.completeMicros}us verified ${open.verifiedMicros}us '
      'content=${open.contentVerified} longestBlock=${open.probe.longestGapMicros}us',
    );
    entry['open_effect_micros'] = controller.model.firstContentMicros;
    entry['cold_open_layout_work_micros'] = controller.model.lastLayoutMicros;
    final firstContent = await _verifyContent(controller);
    _log('first content: $firstContent');
    (entry['samples'] as List).add({
      'operation': 'cold_open',
      ...open.toJson(),
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
        usable: () =>
            controller.model.spine == spine &&
            controller.model.flow != null &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      (entry['samples'] as List).add({
        'operation': 'spine_jump',
        ...jumpLatency.toJson(),
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
        usable: () => singleSpread
            ? controller.model.spine != beforeSpine &&
                  !controller.model.relayoutBusy
            : controller.model.unit != beforeUnit &&
                  !controller.model.relayoutBusy,
      );
      (entry['samples'] as List).add({
        'operation': singleSpread
            ? 'warm_chapter_transition'
            : 'warm_navigation',
        ...latency.toJson(),
        'page': controller.model.unit,
        'spine': controller.model.spine,
        'pages': controller.model.paginated?.pages.length,
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
        usable: () =>
            controller.model.typography.fontSize == target &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending,
      );
      (entry['samples'] as List).add({
        'operation': 'relayout_font_size',
        ...latency.toJson(),
        'font_size': target,
      });
      _log(
        'relayout $trial: usable ${latency.usableMicros}us complete '
        '${latency.completeMicros}us longestBlock '
        '${latency.probe.longestGapMicros}us',
      );
    }

    // Cancellation burst: intents spaced past the 80 ms coalescing delay and
    // inside the chapter's measurement time, so each one starts a layout and
    // is then superseded by the next.
    final burstProbe = _ResponsivenessProbe()..start();
    final burstStopwatch = Stopwatch()..start();
    for (final delta in [2.0, 2.0, -2.0, -2.0]) {
      controller.dispatch(EpubReaderFontSizeChanged(delta));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    while (!(controller.model.layoutComplete &&
            !controller.model.relayoutBusy &&
            !controller.model.relayoutPending) &&
        burstStopwatch.elapsed < const Duration(seconds: 60)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    burstProbe.stop();
    final burstProbeStats = burstProbe.take();
    final burst = {
      'operation': 'cancellation_burst',
      'settle_micros': burstStopwatch.elapsedMicroseconds,
      'final_font_size': controller.model.typography.fontSize,
      'layout_complete': controller.model.layoutComplete,
      'cache_hits': cache.hits,
      'cache_misses': cache.misses,
      'cache_evictions': cache.evictions,
      'layout_work_micros_total': controller.layoutWorkMicros,
      'longest_block_micros': burstProbeStats.longestGapMicros,
      'long_gaps': burstProbeStats.longGaps,
      'probe_samples': burstProbeStats.samples,
    };
    (entry['samples'] as List).add(burst);
    _log('cancellation burst: $burst');

    // Mode switch.
    final modeLatency = await _measure(
      controller,
      () => controller.dispatch(
        const EpubReaderModeChanged(EpubReaderMode.continuous),
      ),
      usable: () =>
          controller.model.paginated == null &&
          controller.model.flow != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    (entry['samples'] as List).add({
      'operation': 'mode_switch_to_continuous',
      ...modeLatency.toJson(),
    });
    _log('mode switch: usable ${modeLatency.usableMicros}us');
    entry['rss_continuous'] = ProcessInfo.currentRss;
    final continuousCapture = await _verifyContent(controller);
    entry['continuous_capture'] = continuousCapture;

    // Back to paginated for a repeatable state, then dispose.
    await _measure(
      controller,
      () => controller.dispatch(
        const EpubReaderModeChanged(EpubReaderMode.paginated),
      ),
      usable: () =>
          controller.model.paginated != null &&
          !controller.model.relayoutBusy &&
          !controller.model.relayoutPending,
    );
    entry['cache_hits'] = cache.hits;
    entry['cache_misses'] = cache.misses;
    entry['cache_evictions'] = cache.evictions;
    entry['layout_work_micros_total'] = controller.layoutWorkMicros;
    controller.dispose();
    // Drop the model reference so the disposed document's flow can be
    // collected before the retained-memory sample.
    setState(() => _controller = null);
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 200));
    entry['rss_after_dispose'] = ProcessInfo.currentRss;
    entry['max_rss_after_dispose'] = ProcessInfo.maxRss;

    // A new session at a distant location: reopen the book where a previous
    // session stopped (85 % of the measured chapter).
    final chapter = controller.model.book!.chapters[spine];
    final distantScalar = (chapter.scalarCount * 0.85).round();
    final distantStore = EpubMemoryPositionStore();
    await distantStore.write(
      path,
      EpubStoredPosition(spine: spine, scalar: distantScalar),
    );
    final distantController = EpubReaderController(
      contentFallbackFamilies: fallbacks,
      positionStore: distantStore,
      layoutStrategy: widget.strategy,
      layoutCache: EpubLayoutCache(maxEntries: widget.cacheEntries),
    );
    setState(() => _controller = distantController);
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 50));
    final distant = await _measure(
      distantController,
      () => distantController.dispatch(EpubReaderOpenRequested(path)),
      usable: () =>
          distantController.model.status == EpubReaderStatus.ready &&
          distantController.model.flow != null &&
          !distantController.model.relayoutBusy &&
          !distantController.model.relayoutPending,
    );
    (entry['samples'] as List).add({
      'operation': 'distant_new_session_open',
      ...distant.toJson(),
      'requested_scalar': distantScalar,
      'restored_scalar': distantController.model.scalar,
      'window_first_node': distantController.model.flow?.firstNodeIndex,
    });
    _log(
      'distant reopen: usable ${distant.usableMicros}us complete '
      '${distant.completeMicros}us restored '
      '${distantController.model.scalar}',
    );
    entry['rss_after_distant_open'] = ProcessInfo.currentRss;
    distantController.dispose();
    setState(() => _controller = null);
    await _pumpUntil(() => false, timeout: const Duration(milliseconds: 100));
    (_report['books'] as List).add(entry);
    _writeReport();
  }

  /// Dispatch [action] and measure two state endpoints with a responsiveness
  /// probe running:
  ///
  /// - `usable_state_micros`: dispatch → the model state that renders the
  ///   requested location. This is a state-change latency, not a presented
  ///   frame.
  /// - `complete_state_micros`: dispatch → `layoutComplete`. For the eager
  ///   baseline this equals the usable endpoint.
  /// - `verified_capture_micros`: dispatch → a content-verified capture of the
  ///   document boundary, including the capture round-trip (an upper bound).
  /// - `longest_block_micros`: the longest event-loop gap while the operation
  ///   ran (a lower bound on the longest UI-thread work interval).
  Future<_Measurement> _measure(
    EpubReaderController controller,
    void Function() action, {
    required bool Function() usable,
    bool Function()? complete,
  }) async {
    final probe = _ResponsivenessProbe()..start();
    final stopwatch = Stopwatch()..start();
    final workBefore = controller.layoutWorkMicros;
    action();
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!usable() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    if (!usable()) {
      _log('timeout waiting for a usable state');
      probe.stop();
      return _Measurement(
        usableMicros: -1,
        completeMicros: -1,
        verifiedMicros: -1,
        contentVerified: false,
        layoutWorkMicros: 0,
        probe: probe.take(),
      );
    }
    final usableMicros = stopwatch.elapsedMicroseconds;
    final isComplete = complete ?? () => controller.model.layoutComplete;
    while (!isComplete() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final completeMicros = stopwatch.elapsedMicroseconds;
    // The capture below renders the document boundary directly, so no frame
    // wait is required (and waiting on endOfFrame can hang when the window is
    // not producing frames).
    final capture = await _verifyContent(controller);
    final verifiedMicros = stopwatch.elapsedMicroseconds;
    probe.stop();
    return _Measurement(
      usableMicros: usableMicros,
      completeMicros: completeMicros,
      verifiedMicros: verifiedMicros,
      contentVerified: capture['content_verified'] == true,
      layoutWorkMicros: controller.layoutWorkMicros - workBefore,
      probe: probe.take(),
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
