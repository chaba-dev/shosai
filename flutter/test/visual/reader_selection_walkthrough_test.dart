import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import '../support/production_shell_harness.dart';
import '../support/selection_surface_fixture.dart';

/// Package 4D's assertion-backed walkthrough frames (RD-12/RD-15).
///
/// Each frame is captured only after the state it claims has been asserted
/// through the rendered surface, so the sequence is evidence of the interaction
/// and not a set of poses: open → pointer selection → keyboard actions →
/// committed highlight → annotation menu → note editor → cancel → delete. The
/// frames are composed into a labeled walkthrough by
/// `.amp/in/make_walkthrough_4d.py`.
class _WalkthroughBridge extends HarnessBridge {
  _WalkthroughBridge();

  List<FlutterAnnotation> annotations = const [];
  final List<FlutterAnnotation> created = [];
  final List<String> deleted = [];

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

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => annotations;

  @override
  Future<FlutterAnnotation> createAnnotation({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required BigInt start,
    required BigInt end,
    required double displayScale,
    required FlutterHighlightColor color,
    String? body,
    required BigInt cancellationId,
  }) async {
    final annotation = FlutterAnnotation(
      id: 'walkthrough',
      unit: unit,
      resolution: FlutterAnnotationResolution.exact,
      textRange: FlutterAnnotationTextRange(start: start, end: end),
      color: color,
      body: body,
    );
    created.add(annotation);
    annotations = [annotation];
    return annotation;
  }

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentHandle document,
    required String id,
  }) async {
    deleted.add(id);
    annotations = const [];
    return true;
  }
}

int _readerKeyCounter = 0;

Widget _reader(HarnessBridge bridge) => productionShell(
  locale: const Locale('en'),
  home: ReaderScreen(
    key: ValueKey('walkthrough-${_readerKeyCounter++}'),
    bridge: bridge,
    decoder: (pixels, {required width, required height}) => _testImage(),
    initialPath: '/books/slow-rivers.epub',
    initialSettings: const FlutterReaderSettings(
      continuous: false,
      theme: 'light',
      epubFontSize: 18,
      epubLineSpacing: 1.6,
      pdfZoom: 0,
    ),
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

Future<void> _open(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var round = 0; round < 8; round += 1) {
    await tester.pump(const Duration(milliseconds: 32));
    if (find.byKey(const ValueKey('reader-page-paint')).evaluate().isNotEmpty) {
      break;
    }
  }
  await tester.pump(const Duration(milliseconds: 32));
}

Future<void> _frame(
  WidgetTester tester,
  String name, {
  required String step,
  required String assertion,
}) async {
  final defects = await findRenderDefects(tester);
  await captureHarnessArtifact(
    tester,
    name,
    metadata: <String, Object?>{
      ...harnessPlatformMetrics(),
      'step': step,
      'assertion': assertion,
      'defects': defects.map((defect) => defect.toMetadata()).toList(),
    },
  );
  expectOnlyKnownDefects(defects, const <KnownRenderDefect>[]);
  // The capture ran inside a real-event-loop window; give the widget tree a
  // frame back before the next interaction.
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUpAll(loadHarnessFonts);

  testWidgets('the selection and annotation walkthrough', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorder = RenderErrorRecorder.install();
    addTearDown(recorder.dispose);

    final bridge = _WalkthroughBridge();
    await _open(tester, _reader(bridge));
    expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
    await _frame(
      tester,
      'walkthrough-01-open',
      step: '1. document open',
      assertion: 'no selection action surface is rendered before a selection',
    );

    await dragFixtureSelection(tester, from: 4, to: 14);
    await settleReaderSelection(tester);
    expect(find.byKey(const ValueKey('selection-actions')), findsOneWidget);
    await _frame(
      tester,
      'walkthrough-02-pointer-selection',
      step: '2. pointer selection',
      assertion: 'a mouse drag over the selectable surface opened the actions',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await settleReaderSelection(tester);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'selection actions',
      reason: 'the keyboard equivalent focused the actions',
    );
    await _frame(
      tester,
      'walkthrough-03-keyboard-actions',
      step: '3. keyboard actions (Shift+F10)',
      assertion: 'Shift+F10 focused the selection action surface',
    );

    await tester.tap(find.text('Green'));
    await settleReaderSelection(tester);
    expect(bridge.created.single.color, FlutterHighlightColor.green);
    expect(find.byKey(const ValueKey('selection-actions')), findsNothing);
    expect(find.text('Highlight 1'), findsOneWidget);
    await _frame(
      tester,
      'walkthrough-04-committed',
      step: '4. committed highlight',
      assertion:
          'the green action committed the range and the strip shows Highlight 1',
    );

    await tester.tapAt(
      tester.getCenter(
        find.byKey(const ValueKey('reader-annotation-navigate-walkthrough')),
      ),
      buttons: kSecondaryMouseButton,
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Change color'), findsOneWidget);
    await _frame(
      tester,
      'walkthrough-05-annotation-menu',
      step: '5. annotation menu (secondary click)',
      assertion: 'the salvaged #114 action menu opened over the card',
    );

    await tester.tap(find.text('Edit note'));
    await tester.pumpAndSettle();
    expect(find.text('Highlight note'), findsOneWidget);
    await _frame(
      tester,
      'walkthrough-06-note-editor',
      step: '6. note editor',
      assertion: 'the controller-owned note dialog opened for the highlight',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(ShadDialog),
        matching: find.widgetWithText(ShadButton, 'Cancel'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShadDialog), findsNothing);
    expect(find.text('Highlight 1'), findsOneWidget);
    await _frame(
      tester,
      'walkthrough-07-note-cancelled',
      step: '7. note editor cancelled',
      assertion: 'cancelling the editor kept the highlight and created nothing',
    );

    await tester.tap(
      find.byKey(const ValueKey('reader-annotation-delete-walkthrough')),
    );
    await settleReaderSelection(tester);
    expect(bridge.deleted, ['walkthrough']);
    expect(find.text('Highlight 1'), findsNothing);
    await _frame(
      tester,
      'walkthrough-08-deleted',
      step: '8. highlight deleted',
      assertion: 'the delete action removed the highlight from the strip',
    );
  });
}
