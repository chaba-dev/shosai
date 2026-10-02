import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/epub/content.dart'
    show EpubFontCoverageLoader;
import 'package:shosai_flutter/reader/epub/font_coverage.dart'
    show EpubFontCoverage;
import 'package:shosai_flutter/reader/view.dart'
    show ReaderEpubPageContentPainter;
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service/vm_service_io.dart' as vms_io;

import '../test/support/corpus_interactive_support.dart';

/// Opt-in real-book EPUB production-reader pass.
///
/// Drives the actual production reader ([ReaderScreen] inside the real
/// [ShosaiShell] composition, over the real Rust bridge) against books from an
/// opt-in manifest, and records:
/// - open-to-first-page timing,
/// - engine-reported frame timing ([FrameTiming]: vsync → raster completion)
///   for warm page turns and relayouts. A sample's slice is a *window* of
///   presented frames that includes cheap forced settling pumps, so it bounds
///   every frame presented during the window rather than attributing frames
///   to a single action (input-to-present latency is *not* measured — see the
///   corpus report),
/// - Contents navigation, selection/copy/highlight, durable-position restore
///   across a reader reopen, resize- and font-size-driven relayouts,
/// - Dart retained heap (VM service allocation profile after a requested
///   service GC, with the GC confirmed via the service-GC timestamp) at
///   checkpoints — labeled as Dart heap only, not process RSS and not native
///   (Skia/Rust) allocations.
///
/// Everything runs against a disposable database (`SHOSAI_EPUB_INTERACTIVE_DB`)
/// and books from an opt-in manifest (`SHOSAI_EPUB_INTERACTIVE_MANIFEST`,
/// anonymous ids). Manifest paths point at private copies; no book content is
/// printed — captures go to `SHOSAI_EPUB_INTERACTIVE_OUT`, a private directory.
/// Without the environment the test registers a skip.
///
/// Run (from `flutter/`):
/// ```sh
/// flutter test integration_test/epub_real_corpus_reader_test.dart \
///   -d linux --profile
/// ```

const _turnWarmups = 3;
const _turnSamples = 12;

final GlobalKey _captureKey = GlobalKey(debugLabel: 'reader-capture');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final manifestPath = Platform.environment['SHOSAI_EPUB_INTERACTIVE_MANIFEST'];
  final dbPath = Platform.environment['SHOSAI_EPUB_INTERACTIVE_DB'];
  final outDir = Platform.environment['SHOSAI_EPUB_INTERACTIVE_OUT'];
  // Optional injected font coverage: the production loader reads
  // `../assets/fonts/*.ttf` through rootBundle, a key that cannot exist in a
  // packaged app bundle (see the corpus report); setting this directory points
  // the existing `fontCoverageLoader` test hook at the same two bundled faces
  // on disk so the routing gate is exercised as designed.
  final fontDir = Platform.environment['SHOSAI_EPUB_INTERACTIVE_FONTS'];

  testWidgets(
    'real-book EPUB production-reader pass',
    (tester) async {
      final anyConfigured =
          manifestPath != null ||
          dbPath != null ||
          outDir != null ||
          fontDir != null;
      if (!anyConfigured) {
        // Opt-in: nothing configured, skip.
        return;
      }
      if (manifestPath == null || dbPath == null || outDir == null) {
        fail(
          'partial interactive configuration: set all of '
          'SHOSAI_EPUB_INTERACTIVE_MANIFEST, SHOSAI_EPUB_INTERACTIVE_DB and '
          'SHOSAI_EPUB_INTERACTIVE_OUT together (or none)',
        );
      }
      final out = Directory(outDir)..createSync(recursive: true);
      final manifest =
          jsonDecode(File(manifestPath).readAsStringSync())
              as Map<String, Object?>;
      final books = (manifest['books'] as List<Object?>)
          .cast<Map<String, Object?>>();
      // An empty or malformed manifest must fail the run instead of producing
      // a vacuous pass.
      if (books.isEmpty) {
        fail('interactive manifest lists no books');
      }
      {
        final seen = <String>{};
        for (final entry in books) {
          final id = entry['id'];
          final path = entry['path'];
          if (id is! String || id.isEmpty || path is! String || path.isEmpty) {
            fail(
              'interactive manifest entry (id: ${id is String ? id : '<missing>'}) '
              'lacks a non-empty id or path',
            );
          }
          if (!seen.add(id)) {
            fail('interactive manifest has duplicate id: $id');
          }
        }
      }

      await RustLib.init(externalLibrary: nativeLibrary());

      // Real engine-reported frame timing. FrameTimings arrive in batches
      // (roughly every 100 ms) in profile builds, so samples are attributed by
      // draining delivery, taking a marker of the newest delivered vsync
      // timestamp, running the action, then draining again and keeping only
      // frames whose vsync is newer than the marker. Once delivery has
      // quiesced before the action, a frame whose vsync predates the action
      // cannot pass the marker. Note: the settling pumps themselves produce
      // frames, so a sample's slice is a *window* of presented frames
      // (including cheap forced settling frames), not a single action frame —
      // the report describes the windows as such.
      final timings = <FrameTiming>[];
      void onTimings(List<FrameTiming> list) => timings.addAll(list);
      SchedulerBinding.instance.addTimingsCallback(onTimings);

      Future<void> runAsyncDelay(Duration duration) =>
          tester.runAsync(() => Future<void>.delayed(duration));

      Future<void> drainTimingDeliveries() async {
        for (var i = 0; i < 30; i++) {
          final before = timings.length;
          await runAsyncDelay(const Duration(milliseconds: 150));
          if (timings.length == before) return;
        }
      }

      int maxVsyncStart() {
        var maxUs = -1;
        for (final t in timings) {
          final us = t.timestampInMicroseconds(ui.FramePhase.vsyncStart);
          if (us > maxUs) maxUs = us;
        }
        return maxUs;
      }

      /// Runs [action] and returns engine metrics for every frame presented
      /// during the action's window (which includes cheap forced settling
      /// pumps — this is a window bound, not a single-action attribution). An
      /// empty result means the window presented no frame at all (e.g. the
      /// action had no visual effect), which callers use to reject
      /// non-actions instead of recording them as measurements.
      Future<List<Map<String, Object?>>> timed(
        Future<void> Function() action,
      ) async {
        await drainTimingDeliveries();
        final marker = maxVsyncStart();
        await action();
        await drainTimingDeliveries();
        return [
          for (final t in timings)
            if (t.timestampInMicroseconds(ui.FramePhase.vsyncStart) > marker)
              {
                'buildMs': t.buildDuration.inMicroseconds / 1000,
                'rasterMs': t.rasterDuration.inMicroseconds / 1000,
                'totalSpanMs': t.totalSpan.inMicroseconds / 1000,
              },
        ];
      }

      vms.VmService? vmService;
      String? isolateId;
      try {
        final info = await developer.Service.getInfo();
        final uri = info.serverUri;
        if (uri != null) {
          final ws = Uri(
            scheme: 'ws',
            host: uri.host,
            port: uri.port,
            path: '${uri.path}ws',
          );
          vmService = await vms_io.vmServiceConnectUri(ws.toString());
          isolateId = developer.Service.getIsolateId(Isolate.current);
        }
      } catch (error) {
        stdout.writeln('memory: vm service unavailable (${error.runtimeType})');
      }

      Future<Map<String, Object?>> retainedHeap() async {
        final vm = vmService;
        final id = isolateId;
        if (vm == null || id == null) {
          return {'available': false, 'reason': 'vm-service-unavailable'};
        }
        // One checkpoint failing must not abort the remaining book exercise.
        try {
          // Read the service-GC timestamp before requesting a GC, so the
          // returned `gcConfirmed` reflects an actual service GC for this
          // isolate rather than the protocol's "attempt" semantics.
          final baseline = await vm.getAllocationProfile(id);
          final beforeLastGc = baseline.dateLastServiceGC;
          final profile = await vm.getAllocationProfile(id, gc: true);
          final mem = profile.memoryUsage;
          final heap = mem?.heapUsage;
          final external = mem?.externalUsage;
          if (heap == null) {
            return {'available': false, 'reason': 'no-memory-usage'};
          }
          final lastGc = profile.dateLastServiceGC;
          return {
            'available': true,
            'heapUsageBytes': heap,
            'externalUsageBytes': external,
            'gcRequested': true,
            'gcConfirmed':
                lastGc != null &&
                (beforeLastGc == null || lastGc > beforeLastGc),
          };
        } catch (error) {
          return {'available': false, 'error': error.runtimeType.toString()};
        }
      }

      final routedSessionSpines = <int>[];

      Future<void> settle([int rounds = 6]) async {
        for (var i = 0; i < rounds; i++) {
          await tester.pump(const Duration(milliseconds: 32));
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        for (var i = 0; i < rounds; i++) {
          await tester.pump(const Duration(milliseconds: 32));
        }
      }

      // Font coverage: when `SHOSAI_EPUB_INTERACTIVE_FONTS` is set (the
      // discriminating experiment for the packaged-coverage defect) the
      // existing `fontCoverageLoader` test hook reads the same two bundled
      // faces from disk; when unset, `fontCoverageLoader: null` keeps the
      // production bundled loader unmodified.
      final EpubFontCoverageLoader? fontCoverage = fontDir == null
          ? null
          : () async {
              final inter = await File(
                '$fontDir/InterVariable.ttf',
              ).readAsBytes();
              final noto = await File(
                '$fontDir/NotoSansJP-Variable.ttf',
              ).readAsBytes();
              return EpubFontCoverage.fromFonts([inter, noto]);
            };

      Widget reader({
        required FlutterBridge bridge,
        required String path,
        required int bookId,
        void Function(String path, int? bookId)? onLocatorChanged,
      }) => RepaintBoundary(
        key: _captureKey,
        child: ReaderScreen(
          bridge: bridge,
          initialPath: path,
          initialBookId: bookId,
          onLocatorChanged: onLocatorChanged,
          debugEpubSessionObserver: (session) {
            stdout.writeln('observer: session spine=${session.chapter.spine}');
            routedSessionSpines.add(session.chapter.spine);
          },
          fontCoverageLoader: fontCoverage,
        ),
      );

      Future<void> capture(String name) async {
        try {
          final boundary =
              _captureKey.currentContext?.findRenderObject()
                  as RenderRepaintBoundary?;
          if (boundary == null) return;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          if (bytes != null) {
            File(
              '${out.path}/$name',
            ).writeAsBytesSync(bytes.buffer.asUint8List());
          }
        } catch (_) {
          // Captures are best-effort evidence, never gate the pass.
        }
      }

      int? unitFromSemantics() {
        final finder = find.byKey(const ValueKey('reader-document-semantics'));
        if (finder.evaluate().isEmpty) return null;
        final semantics = tester.widget<Semantics>(finder.first);
        final label = semantics.properties.label ?? '';
        // PDF labels say "page N of M"; EPUB labels say "EPUB chapter N of M".
        final match = RegExp(r'(?:page|chapter) (\d+) of').firstMatch(label);
        return match == null ? null : int.parse(match.group(1)!);
      }

      /// Exact painted position when the Dart EPUB renderer is active: the
      /// production painter exposes its page (chapter unit + page index).
      /// Returns null on the retained path (use [unitFromSemantics] there).
      List<(int, int)> paintedPositionsAll() {
        final painterFinder = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is ReaderEpubPageContentPainter,
        );
        return painterFinder.evaluate().map((element) {
          final painter =
              (element.widget as CustomPaint).painter!
                  as ReaderEpubPageContentPainter;
          return (painter.page.unit, painter.page.pageIndex);
        }).toList();
      }

      /// Underlying durable scalars of every painted page window.
      List<String> paintedScalarsAll() {
        final painterFinder = find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is ReaderEpubPageContentPainter,
        );
        return painterFinder.evaluate().map((element) {
          final painter =
              (element.widget as CustomPaint).painter!
                  as ReaderEpubPageContentPainter;
          final page = painter.page;
          return 'unit=${page.unit} idx=${page.pageIndex}/${page.pageCount} '
              'start=${page.canonicalStart} end=${page.canonicalEnd} '
              'complete=${page.layoutComplete} nodes=${page.laidOutNodes}/${page.totalNodes}';
        }).toList();
      }

      (int, int)? paintedPosition() {
        final all = paintedPositionsAll();
        return all.isEmpty ? null : all.first;
      }

      /// True when the reader's relayout-failure banner is visible.
      bool layoutFailedBannerVisible() => find
          .byWidgetPredicate((widget) {
            if (widget is Text) {
              final text = widget.data ?? widget.textSpan?.toPlainText() ?? '';
              return text.contains('Layout failed');
            }
            if (widget is RichText) {
              return widget.text.toPlainText().contains('Layout failed');
            }
            return false;
          })
          .evaluate()
          .isNotEmpty;

      /// Waits for a Contents jump to actually land: the painted position
      /// (or chapter signal) must reach the requested unit, or the reader
      /// must surface a *fresh* relayout-failure banner (a banner that was
      /// already up before the jump is never this jump's outcome), or the
      /// deadline expires. Production keeps the old page painted during a
      /// relayout, so an immediate sample after the tap cannot decide
      /// arrival. The decision per iteration is the extracted
      /// [classifyJumpArrivalStep], whose discriminating tests pin the
      /// stale-banner and fresh-banner cases.
      Future<String> waitJumpArrival(
        int? targetUnit, {
        required bool bannerBeforeJump,
        required Duration deadline,
      }) async {
        if (targetUnit == null) return 'no-target';
        final end = DateTime.now().add(deadline);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 50));
          await runAsyncDelay(const Duration(milliseconds: 100));
          final painted = paintedPosition();
          final step = classifyJumpArrivalStep(
            targetUnit: targetUnit,
            paintedUnit: painted?.$1,
            semanticsUnit: unitFromSemantics(),
            bannerVisible: layoutFailedBannerVisible(),
            bannerBeforeJump: bannerBeforeJump,
          );
          switch (step) {
            case CorpusJumpStep.arrived:
              return 'arrived';
            case CorpusJumpStep.layoutFailed:
              return 'layout-failed';
            case CorpusJumpStep.pending:
              break;
          }
        }
        return 'timeout';
      }

      Future<bool> waitReady({
        Duration deadline = const Duration(minutes: 2),
      }) async {
        final end = DateTime.now().add(deadline);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          final document = find.byKey(
            const ValueKey('reader-document-semantics'),
          );
          // Any progress indicator counts as busy: the production relayout
          // path can show a linear/determinate progress surface, not only a
          // circular spinner.
          final busy = find.byWidgetPredicate(
            (widget) => widget is ProgressIndicator,
          );
          if (document.evaluate().isNotEmpty && busy.evaluate().isEmpty) {
            return true;
          }
        }
        return false;
      }

      // Per-stage progress markers keep long interactive runs attributable in
      // the driver log when a stage is slow or hangs.
      Future<void> mark(String id, String stage) async {
        stdout.writeln('stage $id: $stage');
        await stdout.flush();
      }

      try {
        var harnessFailures = 0;
        for (final entry in books) {
          final id = entry['id']! as String;
          final path = entry['path']! as String;
          final record = <String, Object?>{'id': id};
          routedSessionSpines.clear();
          // Owned per book; disposed in the book's finally when it was never
          // handed to a reader (the reader disposes a bridge it owns when idle
          // after teardown).
          FlutterBridge? bookBridge;
          var bridgeHandedToReader = false;
          FlutterBridge? reopenBridge;
          var reopenBridgeHanded = false;
          try {
            // Each book runs against its own bridge, like a fresh production
            // app launch: the reader disposes the bridge it owns when idle
            // after teardown, so a shared bridge would be dead for the next
            // book. The disposable database file is shared across bridges.
            bookBridge = FlutterBridge.withDatabasePath(databasePath: dbPath);
            // Locate the book row in the disposable library.
            FlutterLibraryBook? row;
            for (var offset = 0; row == null; offset += 100) {
              final cancellation = bookBridge.createCancellation();
              try {
                final page = await bookBridge.libraryPage(
                  format: FlutterBookFormat.epub,
                  limit: 100,
                  offset: offset,
                  cancellationId: cancellation,
                );
                for (final book in page.books) {
                  if (book.pathKey == path || book.pathKey.endsWith(path)) {
                    row = book;
                  }
                }
                if (!page.hasMore) break;
              } finally {
                bookBridge.releaseCancellation(id: cancellation);
              }
            }
            if (row == null) {
              record['outcome'] = 'not-in-library';
              harnessFailures += 1;
              continue;
            }
            record['outcome'] = 'ran';

            // Baseline annotation count for this book in the disposable
            // library, probed through the same bridge before the reader opens.
            // Persistence of this run's highlight is then judged by a delta, so
            // annotations left by earlier attempts cannot fake a pass.
            Future<int> annotationCount(FlutterBridge probeBridge) async {
              final cancellation = probeBridge.createCancellation();
              FlutterDocumentHandle? probeHandle;
              try {
                final summary = await probeBridge.openLibraryBook(
                  bookId: row!.bookId,
                  cancellationId: cancellation,
                );
                probeHandle = summary.handle;
                final annotations = await probeBridge.listAnnotations(
                  document: probeHandle,
                  scale: 1.0,
                  cancellationId: cancellation,
                );
                return annotations.length;
              } finally {
                if (probeHandle != null) {
                  probeBridge.releaseDocument(handle: probeHandle);
                }
                probeBridge.releaseCancellation(id: cancellation);
              }
            }

            record['annotationsBefore'] = await annotationCount(bookBridge);

            // Drain durable writes without failing the pass: a failed save is a
            // finding about the reader, not a harness failure.
            Future<void> drainSafely(String stage) async {
              try {
                await drainBookWrites(row!.bookId);
                record['drainOk'] = true;
              } catch (error) {
                record['drainOk'] = false;
                record['persistenceError'] = error is ReaderPersistenceException
                    ? error.toString()
                    : '${error.runtimeType}: $error';
                stdout.writeln('persistence-error $id at $stage: $error');
              }
            }

            // Open.
            final openClock = Stopwatch()..start();
            bridgeHandedToReader = true;
            await tester.pumpWidget(
              ShosaiShell(
                home: _SizedShell(
                  child: reader(
                    bridge: bookBridge,
                    path: path,
                    bookId: row.bookId,
                  ),
                ),
              ),
            );
            final ready = await waitReady(
              deadline: Duration(
                milliseconds: int.parse(
                  Platform.environment['SHOSAI_EPUB_INTERACTIVE_OPEN_TIMEOUT_MS'] ??
                      '120000',
                ),
              ),
            );
            openClock.stop();
            record['openReady'] = ready;
            record['openMs'] = openClock.elapsedMilliseconds;
            if (!ready) {
              await capture('$id-open-failed.png');
              continue;
            }
            await settle();
            await capture('$id-open.png');
            await mark(id, 'opened spines=${routedSessionSpines.length}');
            // Routing evidence from the live tree: the Dart layout engine paints
            // via ReaderEpubPageContentPainter, the retained fallback via
            // _PageContentPainter (both private, matched by runtime type name).
            bool hasPainter(String name) => find
                .byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter?.runtimeType.toString() == name,
                )
                .evaluate()
                .isNotEmpty;
            record['dartPagePainted'] = hasPainter(
              'ReaderEpubPageContentPainter',
            );
            record['retainedPagePainted'] = hasPainter('_PageContentPainter');
            record['fontCoverageInjected'] = fontDir != null;
            record['memoryAfterOpen'] = await retainedHeap();
            await mark(id, 'turns');

            // Warm page turns with real frame timing. Each sample records the
            // painted position (chapter unit + page index) before and after; a
            // sample only counts when the turn changed the painted position and
            // produced frames, so a no-op key event is never recorded as a turn
            // measurement. (The sample's frame slice is still a window that
            // includes cheap forced settling frames — disclosed in the report.)
            final turnMetrics = <Map<String, Object?>>[];
            var turnSamples = 0;
            var turnUnitChanges = 0;
            var turnSamplesRejected = 0;
            final turnSamplePositions = <String>[];
            for (var i = 0; i < _turnWarmups + _turnSamples; i++) {
              final paintedBefore = paintedPosition();
              final paintedAllBefore = paintedPositionsAll();
              final semBefore = unitFromSemantics();
              final scalarsBefore = paintedScalarsAll().join(' | ');
              final posBefore =
                  paintedBefore ??
                  () {
                    final unit = unitFromSemantics();
                    return unit == null ? null : (unit, -1);
                  }();
              final frames = await timed(() async {
                await tester.sendKeyEvent(
                  LogicalKeyboardKey.pageDown,
                  physicalKey: PhysicalKeyboardKey.pageDown,
                );
                await settle();
              });
              final paintedAfter = paintedPosition();
              final paintedAllAfter = paintedPositionsAll();
              final semAfter = unitFromSemantics();
              final scalarsAfter = paintedScalarsAll().join(' | ');
              final posAfter =
                  paintedAfter ??
                  () {
                    final unit = unitFromSemantics();
                    return unit == null ? null : (unit, -1);
                  }();
              turnSamplePositions.add(
                'painted=$paintedBefore->$paintedAfter '
                'sem=$semBefore->$semAfter '
                'scalars=$scalarsBefore->$scalarsAfter '
                'allB=$paintedAllBefore allA=$paintedAllAfter '
                'pos=$posBefore->$posAfter frames=${frames.length}',
              );
              if (i < _turnWarmups) continue;
              final qualifies = turnSampleQualifies(
                frameCount: frames.length,
                positionBefore: posBefore,
                positionAfter: posAfter,
              );
              if (!qualifies) {
                turnSamplesRejected += 1;
                continue;
              }
              turnSamples += 1;
              if (posBefore!.$1 != posAfter!.$1) turnUnitChanges += 1;
              turnMetrics.addAll(frames);
            }
            record['pageTurnSamples'] = turnSamples;
            record['pageTurnSamplesWithUnitChange'] = turnUnitChanges;
            record['pageTurnSamplesRejected'] = turnSamplesRejected;
            record['pageTurnSamplePositions'] = turnSamplePositions;
            record['pageTurnFrames'] = turnMetrics;
            record['memoryAfterTurns'] = await retainedHeap();
            record['unitAfterTurns'] = unitFromSemantics();
            await capture('$id-turns.png');
            await mark(id, 'contents');

            // Contents panel: open, capture, navigate to a middle row.
            await tester.tap(
              find.byKey(const ValueKey('reader-header-contents')),
            );
            await settle();
            final panelReady = find
                .byKey(const ValueKey('reader-panel-contents'))
                .evaluate()
                .isNotEmpty;
            record['contentsPanel'] = panelReady;
            if (panelReady) {
              await capture('$id-contents.png');
              // Chapter rows carry `reader-contents-entry-<unit>` keys (with an
              // occurrence suffix for duplicate TOC entries); they are custom
              // rows, not InkWells.
              final rows = find.byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'reader-contents-entry',
                    ),
              );
              record['contentsRowCount'] = rows.evaluate().length;
              final unitBefore = unitFromSemantics();
              if (rows.evaluate().isNotEmpty) {
                // The panel scrolls: only a laid-out, visible row can be tapped.
                // Prefer the lowest fully visible row so a jump to another
                // chapter is likely.
                final panelRect = tester.getRect(
                  find.byKey(const ValueKey('reader-panel-contents')),
                );
                Element? target;
                for (final element in rows.evaluate()) {
                  final rect = tester.getRect(find.byWidget(element.widget));
                  if (rect.height > 0 &&
                      rect.top >= panelRect.top &&
                      rect.bottom <= panelRect.bottom) {
                    target = element;
                  }
                }
                record['contentsRowsVisible'] = target != null;
                if (target != null) {
                  // A relayout-failure banner from an earlier stage could still
                  // be up; record it so a post-jump banner is only treated as
                  // this jump's failure signal when it is new.
                  final bannerBeforeJump = layoutFailedBannerVisible();
                  record['layoutFailedBannerBeforeJump'] = bannerBeforeJump;
                  final targetKey =
                      (target.widget.key! as ValueKey<String>).value;
                  final unitMatch = RegExp(
                    r'entry-(\d+)',
                  ).firstMatch(targetKey);
                  final targetUnit = unitMatch == null
                      ? null
                      : int.parse(unitMatch.group(1)!);
                  record['contentsTargetUnit'] = targetUnit;
                  // A row targeting the current chapter is not an arrival
                  // test: record it as such instead of treating the
                  // pre-existing page as evidence of completion. The current
                  // chapter is normalized on both paths: the Dart page
                  // exposes the 0-based unit directly; the retained path has
                  // no painter, so its 1-based semantics label maps to
                  // unit - 1.
                  final paintedUnitBefore = paintedPosition()?.$1;
                  final currentUnitBefore =
                      paintedUnitBefore ??
                      (unitFromSemantics() == null
                          ? null
                          : unitFromSemantics()! - 1);
                  if (jumpTargetsCurrentUnit(
                    targetUnit: targetUnit,
                    currentUnitBefore: currentUnitBefore,
                  )) {
                    record['unitBeforeContentsJump'] = unitBefore;
                    record['unitAfterContentsJump'] = unitBefore;
                    record['contentsNavigationChangedUnit'] = false;
                    record['contentsJumpResult'] = 'already-at-target';
                    record['contentsJumpArrived'] = false;
                    await capture('$id-after-contents-jump.png');
                  } else {
                    await tester.tap(
                      find.byWidget(target.widget),
                      warnIfMissed: false,
                    );
                    // A jump into a huge chapter re-paginates for minutes, and
                    // production keeps the old page painted while the relayout
                    // runs: wait until the painted position reaches the target
                    // unit, the reader surfaces a fresh relayout-failure
                    // banner, or the deadline expires.
                    final jump = await waitJumpArrival(
                      targetUnit,
                      bannerBeforeJump: bannerBeforeJump,
                      deadline: Duration(
                        milliseconds: int.parse(
                          Platform.environment['SHOSAI_EPUB_INTERACTIVE_OPEN_TIMEOUT_MS'] ??
                              '120000',
                        ),
                      ),
                    );
                    await capture('$id-after-contents-jump.png');
                    final unitAfter = unitFromSemantics();
                    record['unitBeforeContentsJump'] = unitBefore;
                    record['unitAfterContentsJump'] = unitAfter;
                    record['contentsNavigationChangedUnit'] =
                        (unitBefore != null &&
                        unitAfter != null &&
                        unitBefore != unitAfter);
                    record['contentsJumpResult'] = jump;
                    // Arrival at the requested chapter is strict: only the
                    // painted page reaching the tapped row's unit counts. A
                    // fresh failure banner is recorded as 'layout-failed', a
                    // deadline expiry as 'timeout' — never as an arrival.
                    record['contentsJumpArrived'] = jump == 'arrived';
                  }
                }
              }
            }

            // Selection, copy, highlight.
            try {
              record['selection'] = await selectCopyHighlight(tester, settle);
            } catch (error, stack) {
              record['selection'] = {
                'error': '${error.runtimeType}: $error',
                'stack': stack.toString().split('\n').take(8).join('\n'),
              };
            }
            await settle();
            await capture('$id-selection.png');
            // Let any queued highlight write land before teardown.
            await drainSafely('after-selection');
            record['memoryAfterSelection'] = await retainedHeap();
            record['unitAfterSelection'] = unitFromSemantics();
            await mark(id, 'font');

            // Font-size relayout through the real typography panel.
            record['fontIncreaseFrames'] = await fontChange(
              tester,
              settle,
              up: true,
              timed: timed,
            );
            record['memoryAfterFontChange'] = await retainedHeap();
            record['unitAfterFontChange'] = unitFromSemantics();
            await fontChange(tester, settle, up: false, timed: timed);

            // Resize-driven relayout: shrink then restore the reader viewport.
            // The actual painted reader size is recorded because the shell
            // composition can clamp the requested size; callers must treat a
            // run whose recorded viewport did not change as no resize evidence.
            double viewportWidth() {
              final box = _captureKey.currentContext?.findRenderObject();
              return box is RenderBox ? box.size.width : -1;
            }

            final sized = tester.state<_SizedShellState>(
              find.byType(_SizedShell),
            );
            final viewportWidths = <double>[viewportWidth()];
            final resizeMetrics = <Map<String, Object?>>[];
            for (final width in const [760.0, 1000.0]) {
              final frames = await timed(() async {
                sized.setSize(width, 720);
                await settle(8);
              });
              viewportWidths.add(viewportWidth());
              resizeMetrics.addAll(frames);
            }
            record['resizeFrames'] = resizeMetrics;
            record['viewportWidths'] = viewportWidths;
            record['resizeApplied'] =
                viewportWidths.length == 3 &&
                viewportWidths.every((width) => width > 0) &&
                viewportWidths[0] != viewportWidths[1] &&
                viewportWidths[2] == viewportWidths[0];
            record['unitAfterResize'] = unitFromSemantics();
            await mark(id, 'reopen');

            // Durable position across a full reader teardown and reopen through
            // the same database — a fresh bridge, because the reader owns its
            // bridge and disposes it when idle after teardown (`_disposeBridgeIfIdle`),
            // exactly like relaunching the production app.
            final unitBefore = unitFromSemantics();
            record['unitBeforeReopen'] = unitBefore;
            // Let the queued durable position write land before teardown.
            await drainSafely('before-reopen');
            await mark(id, 'teardown');
            await tester.pumpWidget(const SizedBox.shrink());
            await settle();
            reopenBridge = FlutterBridge.withDatabasePath(databasePath: dbPath);
            reopenBridgeHanded = true;
            await tester.pumpWidget(
              ShosaiShell(
                home: _SizedShell(
                  child: reader(
                    bridge: reopenBridge,
                    path: path,
                    bookId: row.bookId,
                  ),
                ),
              ),
            );
            final reopenReady = await waitReady(
              deadline: Duration(
                milliseconds: int.parse(
                  Platform.environment['SHOSAI_EPUB_INTERACTIVE_OPEN_TIMEOUT_MS'] ??
                      '120000',
                ),
              ),
            );
            await settle();
            record['reopenReady'] = reopenReady;
            if (!reopenReady) {
              // Diagnostic state for a reopen that never became interactive.
              record['reopenBusyVisible'] = find
                  .byWidgetPredicate((widget) => widget is ProgressIndicator)
                  .evaluate()
                  .isNotEmpty;
              record['reopenDocumentVisible'] = find
                  .byKey(const ValueKey('reader-document-semantics'))
                  .evaluate()
                  .isNotEmpty;
            }
            final unitAfter = unitFromSemantics();
            record['unitAfterReopen'] = unitAfter;
            // A restored position is only meaningful for a reopen that actually
            // became interactive; a stuck reopen must not claim restoration.
            record['positionRestored'] =
                reopenReady &&
                unitBefore != null &&
                unitAfter != null &&
                unitBefore == unitAfter;
            // Verify the highlight persisted through the reopen: the annotation
            // count must exceed this run's pre-highlight baseline (the
            // disposable database can hold annotations from earlier attempts).
            // The probe uses the reopen bridge; the probe document handle and
            // its cancellation are both released.
            try {
              record['annotationsAfterReopen'] = await annotationCount(
                reopenBridge,
              );
              record['highlightPersisted'] =
                  (record['annotationsAfterReopen'] as int) >
                  (record['annotationsBefore'] as int);
            } catch (error) {
              record['annotationsAfterReopen'] = {
                'error': error.runtimeType.toString(),
              };
            }
            await capture('$id-reopen.png');
            record['routedSessionSpines'] = routedSessionSpines.toList();
            record['memoryAfterReopen'] = await retainedHeap();
          } catch (error, stack) {
            record['outcome'] = 'harness-error';
            harnessFailures += 1;
            record['detail'] = '${error.runtimeType}: $error';
            record['stack'] = stack.toString().split('\n').take(12).join('\n');
          } finally {
            // Teardown must run on every path: a failure that leaves the
            // previous book's reader mounted would make the next book pump over
            // it, and the production controller keeps its controller when only
            // the constructor arguments change.
            try {
              await tester.pumpWidget(const SizedBox.shrink());
              await settle();
            } catch (error) {
              record['teardownError'] = '${error.runtimeType}: $error';
              harnessFailures += 1;
            }
            if (bookBridge != null && !bridgeHandedToReader) {
              try {
                bookBridge.dispose();
              } catch (error) {
                record['bridgeDisposeError'] = '${error.runtimeType}: $error';
                harnessFailures += 1;
              }
            }
            if (reopenBridge != null && !reopenBridgeHanded) {
              try {
                reopenBridge.dispose();
              } catch (error) {
                record['reopenBridgeDisposeError'] =
                    '${error.runtimeType}: $error';
                harnessFailures += 1;
              }
            }
            // Exactly one record per manifest input, flushed from here so early
            // exits and failures still leave their evidence.
            sinkWrite(out, id, record);
            stdout.writeln(
              'book $id: outcome=${record['outcome']} open=${record['openMs']}ms '
              'ready=${record['openReady']} restored=${record['positionRestored']}',
            );
            await stdout.flush();
          }
        }
        expect(
          harnessFailures,
          0,
          reason:
              'harness/configuration failures are infrastructure failures; '
              'reader behavior failures are recorded outcomes, not failures',
        );
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(onTimings);
        await vmService?.dispose();
      }
    },
    timeout: const Timeout(Duration(hours: 4)),
  );
}

void sinkWrite(Directory out, String id, Map<String, Object?> record) {
  File('${out.path}/interactive-results.jsonl').writeAsStringSync(
    '${jsonEncode(record)}\n',
    mode: FileMode.append,
    flush: true,
  );
}

/// Drag-select across the middle of the page, copy, then highlight yellow.
/// The copied text is book content: only its presence is asserted, never
/// printed.
Future<Map<String, Object?>> selectCopyHighlight(
  WidgetTester tester,
  Future<void> Function([int rounds]) settle,
) async {
  final viewportFinder = find.byKey(
    const ValueKey('reader-document-semantics'),
  );
  if (viewportFinder.evaluate().isEmpty) {
    return {'selectionWorked': false, 'reason': 'no-document'};
  }
  final surface = find.byKey(const ValueKey('reader-selection-surface'));
  if (surface.evaluate().isEmpty) {
    return {'selectionWorked': false, 'reason': 'no-selection-surface'};
  }
  // Control: start from a known-empty clipboard so a non-empty read after
  // Copy reflects this run's copy action, not leftover content.
  await Clipboard.setData(const ClipboardData(text: ''));
  // Drag inside the painted page box when available: origins computed from the
  // whole document area can land in the page margin, where the surface maps
  // no text and the press counts as outside.
  final paint = find.byKey(const ValueKey('reader-page-paint'));
  final base = paint.evaluate().isNotEmpty
      ? tester.getRect(paint.first)
      : tester.getRect(viewportFinder.first);
  // A mouse drag is the real selection interaction on Linux: the selection
  // surface only starts a drag selection for a primary mouse pointer.
  for (final (index, origin) in const [
    Offset(-0.3, 0.0),
    Offset(-0.35, -0.2),
    Offset(-0.25, 0.25),
  ].indexed) {
    final start =
        base.center + Offset(base.width * origin.dx, base.height * origin.dy);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    for (var step = 0; step < 12; step++) {
      await tester.pump(const Duration(milliseconds: 25));
      await gesture.moveBy(
        Offset(base.width * 0.3 / 12, base.height * 0.12 / 12),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await settle();
    if (find.byKey(const ValueKey('selection-actions')).evaluate().isNotEmpty) {
      final result = <String, Object?>{
        'selectionWorked': true,
        'attempt': index + 1,
      };
      return await copyHighlightFromActions(tester, settle, result);
    }
  }
  return {'selectionWorked': false, 'reason': 'no-selection-actions'};
}

/// With the selection actions visible: copy, then highlight yellow. The copied
/// text is book content: only its presence is asserted, never printed.
Future<Map<String, Object?>> copyHighlightFromActions(
  WidgetTester tester,
  Future<void> Function([int rounds]) settle,
  Map<String, Object?> result,
) async {
  final copyButton = find.text('Copy');
  result['copyOffered'] = copyButton.evaluate().isNotEmpty;
  if (result['copyOffered'] as bool) {
    await tester.tap(copyButton.first);
    await settle();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    result['copyNonEmpty'] = data?.text != null && data!.text!.isNotEmpty;
  }
  final highlight = find.text('Yellow');
  result['highlightOffered'] = highlight.evaluate().isNotEmpty;
  if (result['highlightOffered'] as bool) {
    await tester.tap(highlight.first);
    await settle();
  }
  return result;
}

/// Waits for every queued durable write for [bookId] to land (the production
/// drain), so reopen and annotation checks observe committed state.
Future<void> drainBookWrites(int bookId) =>
    ReaderController.drainBookWrites(bookId);

/// One font-size change through the real typography panel, with engine frame
/// metrics attributed via [timed].
Future<List<Map<String, Object?>>> fontChange(
  WidgetTester tester,
  Future<void> Function([int rounds]) settle, {
  required bool up,
  required Future<List<Map<String, Object?>>> Function(Future<void> Function())
  timed,
}) async {
  await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
  await settle();
  final button = find.byKey(
    ValueKey(
      up
          ? 'reader-typography-font-increase'
          : 'reader-typography-font-decrease',
    ),
  );
  if (button.evaluate().isEmpty) return [];
  final List<Map<String, Object?>> metrics;
  try {
    metrics = await timed(() async {
      await tester.tap(button.first);
      await settle();
    });
  } finally {
    // Close the panel for later steps.
    if (find
        .byKey(const ValueKey('reader-panel-typography'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('reader-header-typography')));
      await settle();
    }
  }
  return metrics;
}

/// Sizes the reader viewport like a window would; the relayout path is the
/// production one, though the OS window-manager resize itself is not exercised
/// (recorded as a limitation). The [Align] loosens the tight constraints the
/// shell composition imposes, so the inner [SizedBox] can actually shrink the
/// reader below the shell's width — the harness records the real painted
/// viewport so a run where the size did not change is visible.
class _SizedShell extends StatefulWidget {
  const _SizedShell({required this.child});

  final Widget child;

  @override
  State<_SizedShell> createState() => _SizedShellState();
}

class _SizedShellState extends State<_SizedShell> {
  double _width = 1000;
  double _height = 720;

  void setSize(double width, double height) {
    setState(() {
      _width = width;
      _height = height;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: _width, height: _height, child: widget.child),
    );
  }
}
