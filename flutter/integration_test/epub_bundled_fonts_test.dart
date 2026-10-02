import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_epub/shosai_epub.dart' show openEpubBytes;
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/reader/epub/font_coverage.dart'
    show EpubFontCoverage;
import 'package:shosai_flutter/reader/view.dart'
    show ReaderEpubPageContentPainter;
import 'package:shosai_flutter/src/rust/api.dart';
import 'package:shosai_flutter/src/rust/frb_generated.dart';

/// Packaged-bundle font regression for the EPUB routing gate.
///
/// Finding 1 of the 2026-10-02 corpus pass: the bundled faces were declared in
/// `pubspec.yaml` with paths that escape the Flutter project
/// (`../assets/fonts/...`). The tool records those keys in the asset manifest
/// but never places the files in the built bundle, so in a *built* desktop app
/// `rootBundle.load` fails, the production bundled coverage comes back null,
/// and every chapter stays on the retained renderer.
///
/// This test drives the production reader in the **built** app
/// (`flutter drive -d linux --profile`): the faces are read through the real
/// `rootBundle` — no disk files, no repo fallback, no injected coverage — the
/// engine must have the bundled family registered, an eligible self-authored
/// chapter must route to the Dart EPUB renderer, and a chapter with a
/// genuinely uncovered rune must stay on the retained renderer, so the gate is
/// exercised on both sides of the decision.
///
/// This is manually exercised regression coverage: CI runs the structural
/// bundle check (`scripts/check_flutter_bundle.py`) but does not drive this
/// test, so the documented pass below is the routing regression's evidence.
///
/// Run (from `flutter/`, on a display or under Xvfb):
/// ```sh
/// flutter drive --driver=integration_test/driver.dart \
///   --target=integration_test/epub_bundled_fonts_test.dart -d linux --profile
/// ```
///
/// Optional: `SHOSAI_EPUB_FONT_BUNDLE_ARTIFACTS=<dir>` copies page captures
/// there for inspection; a capture failure never gates the pass.

/// The prose and the control rune. The covered chapter's routing proves the
/// fixture's canonical parity with the retained parser, and the uncovered
/// variant's parity is proven directly in the test, so its refusal is
/// attributable to the rune alone.
const _uncoveredRune = 0x10005; // Linear B; neither bundled face carries it.

/// The same prose with one uncovered rune appended.
final String _uncoveredProseBody =
    '<p>An uncovered rune must stay on the retained renderer.</p>'
    '${'<p>Filler paragraph for pagination.</p>' * 12}'
    '<p>Uncovered rune: ${String.fromCharCode(_uncoveredRune)}.</p>';

final GlobalKey _captureKey = GlobalKey(debugLabel: 'bundled-fonts-capture');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled document faces load from the built asset bundle', (
    tester,
  ) async {
    final artifacts = Platform.environment['SHOSAI_EPUB_FONT_BUNDLE_ARTIFACTS'];

    await RustLib.init(externalLibrary: nativeLibrary());

    // The bundled bytes must be loadable through the platform asset bundle
    // itself, and they must be real font binaries whose own `cmap` coverage
    // covers the interface scripts while leaving the control rune uncovered —
    // the fallback control's precondition, read from the very bytes the
    // production loader uses.
    final inter = await rootBundle.load('fonts/InterVariable.ttf');
    final noto = await rootBundle.load('fonts/NotoSansJP-Variable.ttf');
    expect(inter.lengthInBytes, greaterThan(0));
    expect(noto.lengthInBytes, greaterThan(0));
    final coverage = EpubFontCoverage.fromFonts([
      inter.buffer.asUint8List(),
      noto.buffer.asUint8List(),
    ]);
    expect(coverage, isNotNull);
    expect(coverage!.covers(0x61), isTrue, reason: 'Latin a');
    expect(coverage.covers(0x3042), isTrue, reason: 'Hiragana a');
    expect(
      coverage.covers(_uncoveredRune),
      isFalse,
      reason: 'the fallback control must be genuinely uncovered',
    );

    // The engine must also have registered the bundled families themselves
    // (the whole interface paints with them, and the Dart EPUB renderer
    // shapes with both): laying out a glyph with each family must produce
    // *different* metrics than laying out with a family the engine does not
    // have. If a bundled face were missing, the two would share the host
    // fallback and match. Limitations: a host with the same-named face
    // installed can satisfy this via the host font database, and a glyph the
    // host covers itself (Japanese on a CJK-equipped host) falls back
    // identically in both cases, so the assertion uses Latin glyphs, which
    // no documented run host maps to either bundled family name.
    double advanceWidthOf(String family, String glyph) {
      final painter = TextPainter()
        ..textDirection = TextDirection.ltr
        ..text = TextSpan(
          text: glyph,
          style: TextStyle(fontFamily: family, fontSize: 100),
        );
      painter.layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    expect(
      advanceWidthOf('Inter', 'W'),
      isNot(closeTo(advanceWidthOf('ShosaiAbsentFamily', 'W'), 0.01)),
      reason: 'the bundled Inter face must be registered with the engine',
    );
    expect(
      advanceWidthOf('Noto Sans JP', 'W'),
      isNot(closeTo(advanceWidthOf('ShosaiAbsentFamily', 'W'), 0.01)),
      reason:
          'the bundled Noto Sans JP face must be registered with the engine',
    );

    final directory = await Directory.systemTemp.createTemp(
      'shosai-epub-bundled-fonts-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    // Covered and uncovered variants of the same prose: the covered chapter's
    // routing proves the fixture's canonical parity with the retained parser,
    // so the uncovered chapter's refusal is attributable to the rune alone
    // (both parsers pass the rune through identically, so its parity matches).
    final coveredBytes = _epub(
      chapters: {
        'OPS/chapter-1.xhtml':
            '<p>Packaged fonts route this chapter: あいうえお.</p>'
            '${'<p>Filler paragraph for pagination.</p>' * 12}',
      },
    );
    final coveredPath = '${directory.path}/covered.epub';
    await File(coveredPath).writeAsBytes(coveredBytes);
    final uncoveredBytes = _epub(
      chapters: {'OPS/chapter-1.xhtml': _uncoveredProseBody},
    );
    final uncoveredPath = '${directory.path}/uncovered.epub';
    await File(uncoveredPath).writeAsBytes(uncoveredBytes);

    // An eligible self-authored chapter routes to the Dart EPUB renderer with
    // the production bundled loader (fontCoverageLoader unset). The routing
    // observer records each relayout's gate outcome, so the painted page is
    // confirmed as a gate decision, not just an appearance.
    final coveredAttempts = <_RoutingAttempt>[];
    final coveredBridge = FlutterBridge.withDatabasePath(
      databasePath: '${directory.path}/covered.sqlite3',
    );
    try {
      await _openBook(tester, coveredBridge, coveredPath, coveredAttempts);
      final routed = await _pumpUntil(
        tester,
        () =>
            _dartPage(tester) != null &&
            coveredAttempts.any((attempt) => attempt.routed),
        const Duration(minutes: 2),
      );
      expect(
        routed,
        isTrue,
        reason:
            'the covered chapter must route to the Dart renderer: a completed '
            'gate decision routed it and the page is painted',
      );
      final page = _dartPage(tester)!;
      expect(page.page.unit, 0);
      expect(page.page.canonicalStart, 0);
      await _capture(tester, artifacts, 'bundled-fonts-routed-page');
    } finally {
      await _closeReader(tester, coveredBridge);
    }

    // The genuinely uncovered rune keeps the retained renderer: no Dart page
    // may be painted for that chapter. To attribute the refusal to coverage
    // alone, first prove this fixture's canonical parity independently: the
    // real retained canonical stream (the one the routing gate compares) must
    // equal the engine's, and must carry the rune through both parsers.
    final uncoveredAttempts = <_RoutingAttempt>[];
    final uncoveredBridge = FlutterBridge.withDatabasePath(
      databasePath: '${directory.path}/uncovered.sqlite3',
    );
    try {
      final cancellation = uncoveredBridge.createCancellation();
      FlutterDocumentSummary? probeHandle;
      try {
        final summary = await uncoveredBridge.openDocument(
          request: FlutterOpenRequest(
            localId: uncoveredPath,
            pathKey: uncoveredPath,
          ),
          cancellationId: cancellation,
        );
        probeHandle = summary;
        final retained = await uncoveredBridge.epubCanonicalText(
          document: summary.handle,
          unit: BigInt.zero,
          cancellationId: cancellation,
        );
        final engine = openEpubBytes(uncoveredBytes).chapters[0].canonicalText;
        expect(retained, engine, reason: 'canonical parity of the control');
        expect(engine.runes.contains(_uncoveredRune), isTrue);
      } finally {
        if (probeHandle != null) {
          uncoveredBridge.releaseDocument(handle: probeHandle.handle);
        }
        uncoveredBridge.releaseCancellation(id: cancellation);
      }

      await _openBook(
        tester,
        uncoveredBridge,
        uncoveredPath,
        uncoveredAttempts,
      );
      final ready = await _pumpUntil(
        tester,
        () => _readerReady(tester),
        const Duration(minutes: 2),
      );
      expect(ready, isTrue, reason: 'the uncovered chapter must still open');
      // A refusal must be observed as a *completed* gate attempt, not merely
      // as "nothing painted yet" (which an in-flight attempt also satisfies).
      // The observer is attached from the shell's first mount, so it records
      // the open's own attempts, including the first height report's — the
      // one that runs the full gate (canonical compare + coverage) — and it
      // reports only attempts that were still current when their gate
      // evaluation returned. The settled count drains every open-time attempt
      // before the baseline.
      final baseline = await _stableCount(
        tester,
        () => uncoveredAttempts.length,
      );
      expect(
        baseline,
        greaterThan(0),
        reason: 'the open must complete routing attempts for the chapter',
      );
      expect(
        uncoveredAttempts.map((attempt) => attempt.routed),
        everyElement(isFalse),
        reason: 'every open-time gate decision refused the chapter',
      );
      // Then force one more gate evaluation and await that identifiable,
      // non-stale completion: a page-width change dispatches a viewport
      // relayout (the chapter has no Dart session, so nothing else re-runs
      // the gate for it). The reader's test surface is ~800x600 logical px
      // and the shell pads the reader, so the width *shrinks* below the
      // settled viewport (600 fits the surface); the awaited record is a
      // strictly narrower attempt's own refusal, not quiet time and not
      // stale work.
      final settledWidth = uncoveredAttempts
          .map((attempt) => attempt.width)
          .reduce((a, b) => a < b ? a : b);
      await tester.pumpWidget(
        _readerShell(
          uncoveredPath,
          uncoveredBridge,
          uncoveredAttempts,
          width: 600,
        ),
      );
      expect(
        await _pumpUntil(
          tester,
          () => uncoveredAttempts.any(
            (attempt) => !attempt.routed && attempt.width < settledWidth,
          ),
          const Duration(minutes: 2),
        ),
        isTrue,
        reason:
            'the narrower viewport must complete a refused gate attempt '
            '(settled width $settledWidth, attempts $uncoveredAttempts)',
      );
      // Every reported gate decision for this chapter refused it, and none
      // routed it after the fact.
      expect(
        uncoveredAttempts.map((attempt) => attempt.routed),
        everyElement(isFalse),
        reason: 'an uncovered rune must stay on the retained renderer',
      );
      expect(
        _dartPage(tester),
        isNull,
        reason: 'an uncovered rune must stay on the retained renderer',
      );
      await _capture(tester, artifacts, 'bundled-fonts-retained-fallback');
    } finally {
      await _closeReader(tester, uncoveredBridge);
    }
  });
}

/// The outcome record of one EPUB routing attempt (one relayout's gate
/// evaluation), qualified by its generation, layout revision and the
/// attempted page width; only attempts that were still current when their
/// gate evaluation returned are reported.
typedef _RoutingAttempt = ({
  int generation,
  int revision,
  double width,
  bool routed,
});

ReaderEpubPageContentPainter? _dartPage(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = paint.painter;
    if (painter is ReaderEpubPageContentPainter) return painter;
  }
  return null;
}

/// Whether the reader has installed the document surface and stopped its
/// opening progress indicators (the interactive corpus harness' readiness
/// signal).
bool _readerReady(WidgetTester tester) {
  final document = find.byKey(const ValueKey('reader-document-semantics'));
  final busy = find.byWidgetPredicate((widget) => widget is ProgressIndicator);
  return document.evaluate().isNotEmpty && busy.evaluate().isEmpty;
}

/// The production reader composition for one book path, at [width], recording
/// every routing attempt's outcome into [attempts].
Widget _readerShell(
  String path,
  FlutterBridge bridge,
  List<_RoutingAttempt> attempts, {
  double width = 1000,
}) => ShosaiShell(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      height: 720,
      child: RepaintBoundary(
        key: _captureKey,
        child: ReaderScreen(
          bridge: bridge,
          initialPath: path,
          debugEpubRoutingObserver: (generation, revision, width, routed) {
            attempts.add((
              generation: generation,
              revision: revision,
              width: width,
              routed: routed,
            ));
          },
        ),
      ),
    ),
  ),
);

/// Opens one book path through the production reader composition.
Future<void> _openBook(
  WidgetTester tester,
  FlutterBridge bridge,
  String path,
  List<_RoutingAttempt> attempts,
) async {
  await tester.pumpWidget(_readerShell(path, bridge, attempts));
}

/// Unmounts the reader and waits for the controller to dispose the bridge it
/// was handed (the controller disposes it itself once its operations drain).
/// A run whose drain never completes is a failure: the bridge is disposed
/// here so a native bridge cannot leak past the test, and the failure is
/// reported. A bridge the reader never received (an earlier failure during
/// the parity probe) is disposed directly.
Future<void> _closeReader(WidgetTester tester, FlutterBridge bridge) async {
  if (find.byKey(_captureKey).evaluate().isEmpty) {
    if (!bridge.isDisposed) bridge.dispose();
    return;
  }
  await tester.pumpWidget(const SizedBox.shrink());
  final disposed = await _pumpUntil(
    tester,
    () => bridge.isDisposed,
    const Duration(seconds: 10),
  );
  if (!disposed) {
    bridge.dispose();
    throw StateError('the reader did not drain the bridge after unmount');
  }
}

/// Pumps with real event-loop windows until [condition] holds or the deadline
/// passes (the reader routes asynchronously over the real bridge).
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
  Duration deadline,
) async {
  final end = DateTime.now().add(deadline);
  while (DateTime.now().isBefore(end)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  return condition();
}

/// Pumps with real event-loop windows until [count] has held one value for a
/// quiet window, then returns that value (a settled asynchronous effect count
/// — completions stop arriving once the reader's attempts are done).
Future<int> _stableCount(
  WidgetTester tester,
  int Function() count, {
  Duration quiet = const Duration(milliseconds: 600),
  Duration deadline = const Duration(minutes: 2),
}) async {
  final end = DateTime.now().add(deadline);
  var last = count();
  var changed = DateTime.now();
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    final current = count();
    if (current != last) {
      last = current;
      changed = DateTime.now();
      continue;
    }
    if (DateTime.now().isAfter(changed.add(quiet))) return last;
  }
  return last;
}

/// Writes a PNG of the capture boundary to [artifacts] when configured.
Future<void> _capture(
  WidgetTester tester,
  String? artifacts,
  String name,
) async {
  if (artifacts == null) return;
  // Best-effort visual evidence; a capture failure never gates the pass.
  try {
    final boundary =
        _captureKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return;
    final dir = Directory(artifacts)..createSync(recursive: true);
    File(
      '${dir.path}/$name.png',
    ).writeAsBytesSync(bytes.buffer.asUint8List(), flush: true);
  } catch (_) {}
}

/// An EPUB archive built in memory with the reader's own fixture conventions.
///
/// Self-authored synthetic content with the same container/OPF/spine structure
/// the committed reader fixtures use
/// (`test/support/epub_navigation_fixture.dart`), kept local here so this
/// regression does not extend the shared fixture set.
Uint8List _epub({required Map<String, String> chapters}) {
  final files = <String, String>{
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?>'
        '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
        'version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  };
  final manifest = <String>[];
  final spine = <String>[];
  var index = 1;
  for (final path in chapters.keys) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    manifest.add(
      '<item id="chapter-$index" href="$name" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.add('<itemref idref="chapter-$index"/>');
    files[path] =
        '<?xml version="1.0"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
        '${chapters[path]}</body></html>';
    index += 1;
  }
  manifest.add(
    '<item id="nav" href="nav.xhtml" '
    'media-type="application/xhtml+xml" properties="nav"/>',
  );
  final nav = chapters.keys.map((path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    return '<li><a href="$name">${name.replaceAll('.', ' ')}</a></li>';
  }).join();
  files['OPS/package.opf'] =
      '<?xml version="1.0"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="id"><metadata '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="id">bundled-fonts</dc:identifier>'
      '<dc:title>Bundled Fonts</dc:title><dc:language>en</dc:language>'
      '</metadata><manifest>${manifest.join()}</manifest>'
      '<spine>${spine.join()}</spine></package>';
  files['OPS/nav.xhtml'] =
      '<?xml version="1.0"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
      '<nav epub:type="toc"><ol>$nav</ol></nav></body></html>';

  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = Uint8List.fromList(utf8.encode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
