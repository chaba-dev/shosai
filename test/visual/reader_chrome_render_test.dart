import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../support/production_shell_harness.dart';

/// Package 4B reader-chrome renders (`4B-RENDER`).
///
/// Every state renders the production shell through the shared harness, runs
/// the geometry detectors and captures an artifact for inspection. These are
/// **candidate** renders for owner approval: the file deliberately does not
/// compare them with a committed baseline, because accepting a reader baseline
/// is the owner's decision, not 4B's.
///
/// The chrome is fixture-backed where the bridge has no API: the tab list and
/// the progress ordinals are injected presentation data (contract §2.2). The
/// document raster is the harness's deterministic page, so the renders exercise
/// the chrome rather than the renderer.
class _RenderBridge extends HarnessBridge {
  _RenderBridge({
    super.books,
    this.bookmarks = const [],
    this.hangOpen = false,
    this.failOpen = false,
  });

  final List<FlutterBookmark> bookmarks;
  final bool hangOpen;
  final bool failOpen;

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) async => bookmarks;

  /// Fails the next selection-surface call, so the layout-failure chrome can be
  /// captured.
  bool failNextSelectionSurface = false;

  @override
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) {
    if (failNextSelectionSurface) {
      failNextSelectionSurface = false;
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.invalidRequest,
        message: 'chapter layout rejected',
      );
    }
    return super.selectionSurface(
      document: document,
      unit: unit,
      scale: scale,
      width: width,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      cancellationId: cancellationId,
    );
  }

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) async {
    if (hangOpen) return Completer<FlutterDocumentSummary>().future;
    if (failOpen) {
      throw const FlutterBridgeError(
        kind: FlutterBridgeErrorKind.notFound,
        message:
            'Failed to open EPUB: EPUB archive is corrupt: Invalid ZIP '
            'archive: ZIP end-of-central-directory record is missing',
      );
    }
    return super.openDocument(request: request, cancellationId: cancellationId);
  }
}

/// The reference state's progress wording: `Pages 1–2 · 25%` for the wide
/// paginated EPUB spread, `1ページ · 33%` for the compact single page. Ordinals
/// and percentage are supplied presentation values (contract §3.4); producing
/// them from real layout is 5A/5G.
ReaderProgressSource _referenceProgress({
  required int first,
  int? last,
  required int percentage,
}) =>
    (_) => ReaderProgressPresentation(
      kind: last == null ? ReaderProgressKind.single : ReaderProgressKind.range,
      hasDocument: true,
      firstOrdinal: first,
      lastOrdinal: last,
      percentage: percentage,
    );

const _settings = FlutterReaderSettings(
  continuous: false,
  theme: 'light',
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
  zonesHintDismissed: true,
);

Widget _reader({
  required HarnessBridge bridge,
  Locale? locale,
  String? initialPath = '/books/quiet-cartographer.epub',
  int? initialBookId,
  ReaderProgressSource? progressSource,
}) => productionShell(
  locale: locale,
  home: ReaderScreen(
    bridge: bridge,
    initialPath: initialPath,
    initialBookId: initialBookId,
    initialSettings: _settings,
    progressSource: progressSource,
  ),
);

/// True when the reader page is painted and the chrome is settled.
bool _chromeReady(WidgetTester tester) {
  if (!harnessReaderPageReady(tester)) return false;
  final contents = find.byKey(const ValueKey('reader-header-contents'));
  if (contents.evaluate().isEmpty) return false;
  return tester
      .widget<ShadButton>(
        find.descendant(of: contents, matching: find.byType(ShadButton)),
      )
      .enabled;
}

void main() {
  setUpAll(loadHarnessFonts);

  Future<void> render(
    WidgetTester tester,
    String name,
    HarnessView view,
    Widget widget, {
    required bool Function() ready,
    Map<String, Object?> metadata = const {},
  }) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    view.apply(tester);
    await renderHarnessState(tester, widget, ready: ready);
    await revealReaderChrome(tester);
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      name,
      metadata: <String, Object?>{
        ...view.toMetadata(),
        ...metadata,
        ...harnessPlatformMetrics(),
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expect(
      recorder.overflowErrors,
      isEmpty,
      reason: 'Flutter reported a layout overflow in $name',
    );
    expect(tester.takeException(), isNull);
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  }

  testWidgets('wide English reader chrome', (tester) async {
    await render(
      tester,
      'reader-chrome-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _RenderBridge(),
        locale: const Locale('en'),
        progressSource: _referenceProgress(first: 1, last: 2, percentage: 25),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{
        'state': 'ready',
        'chrome': 'header+status+edges',
        'progress': 'fixture: pages 1-2 of 8, 25% (5G owns real ranges)',
      },
    );
  });

  testWidgets('compact Japanese reader chrome', (tester) async {
    await render(
      tester,
      'reader-chrome-390-ja',
      const HarnessView(size: Size(390, 844)),
      _reader(
        bridge: _RenderBridge(),
        locale: const Locale('ja'),
        progressSource: _referenceProgress(first: 1, percentage: 33),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{
        'state': 'ready',
        'chrome': 'compact',
        'progress': 'fixture: page 1 of 3, 33% (5G owns real ranges)',
      },
    );
  });

  testWidgets('compact Japanese reader chrome at 200% interface text', (
    tester,
  ) async {
    await render(
      tester,
      'reader-chrome-390-ja-t200',
      const HarnessView(size: Size(390, 844), textScale: 2),
      _reader(
        bridge: _RenderBridge(),
        locale: const Locale('ja'),
        progressSource: _referenceProgress(first: 1, percentage: 33),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{
        'state': 'ready',
        'textScale': 2,
        'progress': 'fixture: page 1 of 3, 33% (5G owns real ranges)',
      },
    );
  });

  testWidgets('opening document chrome', (tester) async {
    await render(
      tester,
      'reader-opening-900-en',
      const HarnessView(size: Size(900, 700)),
      _reader(
        bridge: _RenderBridge(hangOpen: true),
        locale: const Locale('en'),
      ),
      ready: () =>
          find.byKey(const ValueKey('reader-opening')).evaluate().isNotEmpty,
      metadata: const <String, Object?>{'state': 'opening'},
    );
  });

  testWidgets('open failure chrome', (tester) async {
    await render(
      tester,
      'reader-open-error-900-en',
      const HarnessView(size: Size(900, 700)),
      _reader(
        bridge: _RenderBridge(failOpen: true),
        locale: const Locale('en'),
      ),
      ready: () =>
          find.byKey(const ValueKey('reader-open-error')).evaluate().isNotEmpty,
      metadata: const <String, Object?>{'state': 'open-failure'},
    );
  });

  testWidgets('layout failure chrome', (tester) async {
    final bridge = _RenderBridge();
    await render(
      tester,
      'reader-layout-error-900-en',
      const HarnessView(size: Size(900, 700)),
      _reader(bridge: bridge, locale: const Locale('en')),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'layout-failure'},
    );
    // Drive the failure through page navigation and capture again, so
    // the artifact shows the failure chrome itself.
    bridge.failNextSelectionSurface = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    final defects = await findRenderDefects(tester);
    await captureHarnessArtifact(
      tester,
      'reader-layout-error-900-en',
      metadata: <String, Object?>{
        'state': 'layout-failure',
        'failure': 'bridge invalidRequest: chapter layout rejected',
        'defects': defects.map((defect) => defect.toMetadata()).toList(),
      },
    );
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  });

  testWidgets('no-document chrome', (tester) async {
    await render(
      tester,
      'reader-no-document-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _RenderBridge(),
        initialPath: null,
        locale: const Locale('en'),
      ),
      ready: () => find.text('No book open').evaluate().isNotEmpty,
      metadata: const <String, Object?>{'state': 'no-document'},
    );
  });

  for (final panel in ReaderPanel.values) {
    testWidgets('${panel.name} panel host', (tester) async {
      // A library open carries a book id, so the retained bookmark controls in
      // the more panel and the saved-places list in the contents panel render
      // (the reference captures are library opens too).
      final bridge = _RenderBridge(
        books: harnessLibraryBooks(),
        bookmarks: [
          FlutterBookmark(
            id: 1,
            bookId: 1,
            unit: BigInt.zero,
            color: 'yellow',
            createdAt: '2026-09-20T00:00:00Z',
          ),
        ],
      );
      await render(
        tester,
        'reader-panel-${panel.name}-1280-en',
        const HarnessView(size: Size(1280, 800)),
        _reader(bridge: bridge, locale: const Locale('en'), initialBookId: 1),
        ready: () => _chromeReady(tester),
        metadata: <String, Object?>{
          'state': 'panel',
          'panel': panel.name,
          'body': 'retained live controls until 4C lands the Iced bodies',
        },
      );
      // The panel is opened through the rendered header control and the state
      // is captured again, so the artifact shows the panel actually open.
      await tester.tap(find.byKey(ValueKey('reader-header-${panel.name}')));
      await pumpHarnessFrames(tester, frames: 4);
      final defects = await findRenderDefects(tester);
      await captureHarnessArtifact(
        tester,
        'reader-panel-${panel.name}-open-1280-en',
        metadata: <String, Object?>{
          'state': 'panel-open',
          'panel': panel.name,
          'defects': defects.map((defect) => defect.toMetadata()).toList(),
        },
      );
      expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
    });
  }

  testWidgets('page-range progress wording from fixture data', (tester) async {
    await render(
      tester,
      'reader-progress-range-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _RenderBridge(),
        locale: const Locale('en'),
        progressSource: (_) => const ReaderProgressPresentation(
          kind: ReaderProgressKind.range,
          hasDocument: true,
          firstOrdinal: 4,
          lastOrdinal: 5,
          percentage: 42,
        ),
      ),
      ready: () => _chromeReady(tester),
      metadata: const <String, Object?>{'state': 'range-wording'},
    );
  });
}
