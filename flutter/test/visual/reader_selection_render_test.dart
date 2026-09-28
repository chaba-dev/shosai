import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// Package 4D reader-selection renders (row RD-15).
///
/// RD-12 and RD-15 have no Iced counterpart (plan decision 8; the 1C
/// non-Iced authority record), so these are **candidate** Flutter renders for
/// owner inspection rather than comparisons against a committed reference: the
/// file deliberately does not compare them with a baseline, because accepting a
/// reader baseline is the owner's decision, not 4D's. The matched-state
/// comparison with the pinned Iced chrome/palette captures lives in
/// `reader_selection_parity_test.dart`.
///
/// The document content here is the shared harness document (a deterministic
/// raster and a deterministic selectable surface); the parity captures open the
/// committed 1C fixtures through the real bridge instead.
class _SelectionRenderBridge extends HarnessBridge {
  _SelectionRenderBridge({super.unitCount});

  List<FlutterAnnotation> annotations = const [];

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => annotations;

  @override
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) async {
    final base = await super.selectionSurface(
      document: document,
      unit: unit,
      scale: scale,
      width: width,
      fontSize: fontSize,
      lineSpacing: lineSpacing,
      cancellationId: cancellationId,
    );
    return selectionFixtureSurface(base);
  }
}

FlutterReaderSettings _settings(String theme) => FlutterReaderSettings(
  continuous: false,
  theme: theme,
  epubFontSize: 18,
  epubLineSpacing: 1.6,
  pdfZoom: 0,
);

FlutterAnnotation _annotation({
  String id = 'one',
  int unit = 0,
  FlutterAnnotationResolution resolution = FlutterAnnotationResolution.exact,
  FlutterHighlightColor color = FlutterHighlightColor.yellow,
  String? body,
}) => FlutterAnnotation(
  id: id,
  unit: BigInt.from(unit),
  resolution: resolution,
  textRange: FlutterAnnotationTextRange(
    start: BigInt.from(4),
    end: BigInt.from(14),
  ),
  color: color,
  body: body,
);

int _readerKeyCounter = 0;

Widget _reader({
  required HarnessBridge bridge,
  Locale? locale,
  String theme = 'light',
}) => productionShell(
  locale: locale,
  home: ReaderScreen(
    key: ValueKey('selection-render-${_readerKeyCounter++}'),
    bridge: bridge,
    decoder: (pixels, {required width, required height}) => _testImage(),
    initialPath: '/books/slow-rivers.epub',
    initialSettings: _settings(theme),
  ),
);

Future<ui.Image> _testImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 420, 560),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(420, 560);
}

bool _ready(WidgetTester tester) =>
    harnessReaderPageReady(tester) &&
    find
        .byKey(const ValueKey('reader-selection-surface'))
        .evaluate()
        .isNotEmpty;

void main() {
  setUpAll(loadHarnessFonts);

  Future<void> render(
    WidgetTester tester,
    String name,
    HarnessView view,
    Widget widget, {
    Map<String, Object?> metadata = const {},
    Future<void> Function(WidgetTester tester)? after,
    double pixelRatio = 1,
  }) async {
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);
    view.apply(tester);
    await renderHarnessState(tester, widget, ready: () => _ready(tester));
    if (after != null) await after(tester);
    final defects = await findRenderDefects(tester);
    final artifactMetadata = <String, Object?>{
      ...view.toMetadata(),
      ...metadata,
      ...harnessPlatformMetrics(),
      'defects': defects.map((defect) => defect.toMetadata()).toList(),
    };
    if (pixelRatio == 1) {
      await captureHarnessArtifact(tester, name, metadata: artifactMetadata);
    } else {
      // The D2 sharpness state is captured at the device pixel ratio, not at
      // the logical size: a 1x capture of a 2x viewport cannot show blur or
      // double scaling.
      writeHarnessArtifact(
        name,
        await captureHarnessPng(tester, pixelRatio: pixelRatio),
        metadata: artifactMetadata,
      );
    }
    expect(
      recorder.overflowErrors,
      isEmpty,
      reason: 'Flutter reported a layout overflow in $name',
    );
    expect(tester.takeException(), isNull);
    expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  }

  /// Opens the selection action surface with a real pointer drag.
  Future<void> select(WidgetTester tester) async {
    await dragFixtureSelection(tester, from: 4, to: 14);
    await settleReaderSelection(tester);
    expect(
      find.byKey(const ValueKey('selection-actions')),
      findsOneWidget,
      reason: 'the drag opened the selection action surface',
    );
  }

  testWidgets('selection actions (EN, wide)', (tester) async {
    await render(
      tester,
      'reader-selection-actions-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(bridge: _SelectionRenderBridge(), locale: const Locale('en')),
      metadata: const <String, Object?>{
        'state': 'selection-actions-open',
        'chrome': 'expanded',
        'palette': 'light',
      },
      after: select,
    );
  });

  testWidgets('selection actions (JA, compact)', (tester) async {
    await render(
      tester,
      'reader-selection-actions-390-ja',
      const HarnessView(size: Size(390, 844)),
      _reader(bridge: _SelectionRenderBridge(), locale: const Locale('ja')),
      metadata: const <String, Object?>{
        'state': 'selection-actions-open',
        'chrome': 'compact',
        'palette': 'light',
      },
      after: select,
    );
  });

  testWidgets('selection actions (JA, compact, 200% text)', (tester) async {
    await render(
      tester,
      'reader-selection-actions-390-ja-t200',
      const HarnessView(size: Size(390, 844), textScale: 2),
      _reader(bridge: _SelectionRenderBridge(), locale: const Locale('ja')),
      metadata: const <String, Object?>{
        'state': 'selection-actions-open',
        'chrome': 'compact',
        'palette': 'light',
        'textScale': 2,
      },
      after: select,
    );
  });

  testWidgets('selection actions (EN, wide, dark palette)', (tester) async {
    await render(
      tester,
      'reader-selection-actions-1280-en-dark',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _SelectionRenderBridge(),
        locale: const Locale('en'),
        theme: 'dark',
      ),
      metadata: const <String, Object?>{
        'state': 'selection-actions-open',
        'palette': 'dark',
      },
      after: select,
    );
  });

  testWidgets('selection actions (EN, wide, sepia palette)', (tester) async {
    await render(
      tester,
      'reader-selection-actions-1280-en-sepia',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _SelectionRenderBridge(),
        locale: const Locale('en'),
        theme: 'sepia',
      ),
      metadata: const <String, Object?>{
        'state': 'selection-actions-open',
        'palette': 'sepia',
      },
      after: select,
    );
  });

  testWidgets('selection actions at DPR 2 (sharpness)', (tester) async {
    await render(
      tester,
      'reader-selection-actions-dpr2-1280-en',
      const HarnessView(size: Size(2560, 1600), devicePixelRatio: 2),
      _reader(bridge: _SelectionRenderBridge(), locale: const Locale('en')),
      metadata: const <String, Object?>{
        'state': 'selection-actions-open',
        'purpose':
            'RD-15/D2 sharpness: the same logical 1280x800 composition at DPR 2; '
            'text and control edges stay crisp, no double scaling',
      },
      after: select,
      pixelRatio: 2,
    );
  });

  testWidgets('annotation strip with saved highlights (EN, wide)', (
    tester,
  ) async {
    await render(
      tester,
      'reader-annotations-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _SelectionRenderBridge(unitCount: 4)
          ..annotations = [
            _annotation(
              id: 'one',
              color: FlutterHighlightColor.yellow,
              body: 'the survey notes',
            ),
            _annotation(
              id: 'two',
              resolution: FlutterAnnotationResolution.ambiguous,
              color: FlutterHighlightColor.blue,
            ),
            _annotation(
              id: 'three',
              resolution: FlutterAnnotationResolution.orphaned,
              color: FlutterHighlightColor.purple,
            ),
          ],
        locale: const Locale('en'),
      ),
      metadata: const <String, Object?>{
        'state': 'annotations',
        'savedHighlights': 3,
      },
    );
  });

  testWidgets('annotation strip (EN, wide, dark palette)', (tester) async {
    await render(
      tester,
      'reader-annotations-1280-en-dark',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _SelectionRenderBridge(unitCount: 4)
          ..annotations = [
            _annotation(
              id: 'one',
              color: FlutterHighlightColor.yellow,
              body: 'the survey notes',
            ),
          ],
        locale: const Locale('en'),
        theme: 'dark',
      ),
      metadata: const <String, Object?>{
        'state': 'annotations',
        'palette': 'dark',
      },
    );
  });

  testWidgets('annotation strip (EN, wide, sepia palette)', (tester) async {
    await render(
      tester,
      'reader-annotations-1280-en-sepia',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _SelectionRenderBridge(unitCount: 4)
          ..annotations = [
            _annotation(
              id: 'one',
              color: FlutterHighlightColor.yellow,
              body: 'the survey notes',
            ),
          ],
        locale: const Locale('en'),
        theme: 'sepia',
      ),
      metadata: const <String, Object?>{
        'state': 'annotations',
        'palette': 'sepia',
      },
    );
  });

  testWidgets('annotation menu (EN, wide)', (tester) async {
    await render(
      tester,
      'reader-annotation-menu-1280-en',
      const HarnessView(size: Size(1280, 800)),
      _reader(
        bridge: _SelectionRenderBridge()..annotations = [_annotation()],
        locale: const Locale('en'),
      ),
      metadata: const <String, Object?>{
        'state': 'annotation-menu-open',
        'source':
            'secondary click on the annotation card (salvaged #114 action set)',
      },
      after: (tester) async {
        await tester.tapAt(
          tester.getCenter(
            find.byKey(const ValueKey('reader-annotation-navigate-one')),
          ),
          buttons: kSecondaryMouseButton,
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('Change color'), findsOneWidget);
      },
    );
  });

  testWidgets('annotation menu (JA, compact, 200% text)', (tester) async {
    await render(
      tester,
      'reader-annotation-menu-390-ja-t200',
      const HarnessView(size: Size(390, 844), textScale: 2),
      _reader(
        bridge: _SelectionRenderBridge()..annotations = [_annotation()],
        locale: const Locale('ja'),
      ),
      metadata: const <String, Object?>{
        'state': 'annotation-menu-open',
        'chrome': 'compact',
        'textScale': 2,
      },
      after: (tester) async {
        await tester.tapAt(
          tester.getCenter(
            find.byKey(const ValueKey('reader-annotation-navigate-one')),
          ),
          buttons: kSecondaryMouseButton,
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('色を変更'), findsOneWidget);
      },
    );
  });
}
