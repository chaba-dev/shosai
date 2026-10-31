import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import '../support/bridge_pdf_engine.dart';
import '../support/bridge_records.dart';
import '../support/production_shell_harness.dart';

class _ReferenceBridge extends HarnessBridge {
  _ReferenceBridge() : super(pageWidth: 612, pageHeight: 792);

  Completer<List<PdfPageLink>>? pending;

  @override
  Future<List<PdfPageLink>> pdfEngineLinks(int page) async {
    final gate = pending;
    pending = null;
    return gate == null ? _links : gate.future;
  }

  static const _links = [
    PdfPageLink(rects: [PdfLinkRect(80, 500, 200, 650)], page: 1),
  ];
}

class _ReaderBridge
    with BridgePdfEngine, BridgeRecords
    implements FlutterBridge {
  var disposeCount = 0;

  @override
  bool get isDisposed => disposeCount != 0;

  @override
  void dispose() => disposeCount += 1;

  @override
  BigInt createCancellation() => BigInt.one;

  @override
  bool cancel({required BigInt id}) => true;

  @override
  bool releaseCancellation({required BigInt id}) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ui.Image> _unusedDecoder(
  Uint8List pixels, {
  required int width,
  required int height,
}) => throw UnimplementedError();

ReaderController _controller({FlutterBridge? bridge}) => ReaderController(
  bridge: bridge ?? _ReaderBridge(),
  decoder: _unusedDecoder,
);

void main() {
  for (final action in ['keep', 'show', 'replace', 'suspend', 'dispose']) {
    testWidgets(
      'system bars restoration respects $action after keyboard close',
      (tester) async {
        final calls = <bool>[];
        final controller = ReaderController(
          bridge: HarnessBridge(),
          systemBars: calls.add,
          decoder: (pixels, {required width, required height}) async {
            final recorder = ui.PictureRecorder();
            ui.Canvas(recorder);
            final picture = recorder.endRecording();
            final image = await picture.toImage(1, 1);
            picture.dispose();
            return image;
          },
        );
        addTearDown(controller.dispose);
        controller.dispatch(const ReaderOpenRequested('/books/quiet.pdf'));
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (controller.model.pageImage != null && !controller.model.busy) {
            break;
          }
        }
        expect(controller.model.chromeShown, isFalse);
        controller.dispatch(const ReaderSystemBarsRestoreRequested());
        await tester.pump(const Duration(milliseconds: 1000));
        switch (action) {
          case 'show':
            controller.dispatch(
              const ReaderPageTapped(.5, width: 390, touch: true),
            );
          case 'replace':
            controller.dispatch(const ReaderOpenRequested('/books/other.pdf'));
          case 'suspend':
            controller.dispatch(const ReaderSuspended());
          case 'dispose':
            controller.dispose();
        }
        final beforeRetry = calls.length;
        await tester.pump(const Duration(milliseconds: 100));
        if (action == 'keep' || action == 'show') {
          expect(calls.length, beforeRetry + 1);
          expect(calls.last, action == 'show');
        } else {
          // Replacement may publish its own visibility transitions, but may not
          // receive the old document's delayed restoration.
          await tester.pumpAndSettle();
          final afterReplacement = calls.length;
          await tester.pump(const Duration(seconds: 2));
          expect(calls.length, afterReplacement);
          if (action == 'replace') {
            // Only initial quiet, replacement loading, replacement quiet.
            // A stale retry at 1100 ms would add a fourth call, even if it
            // happened before the post-replacement baseline above.
            expect(controller.model.busy, isFalse);
            expect(calls, [false, true, false]);
          } else {
            expect(calls.length, beforeRetry);
          }
        }
        controller.dispose();
      },
    );
  }

  for (final action in ['keep', 'dismiss', 'navigate', 'suspend', 'replace']) {
    testWidgets('a delayed PDF preview respects $action', (tester) async {
      final bridge = _ReferenceBridge();
      final controller = ReaderController(
        bridge: bridge,
        decoder: (pixels, {required width, required height}) async {
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder);
          final picture = recorder.endRecording();
          final image = await picture.toImage(1, 1);
          picture.dispose();
          return image;
        },
      );
      addTearDown(controller.dispose);
      controller.dispatch(const ReaderOpenRequested('/books/references.pdf'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (controller.model.pageImage != null && !controller.model.busy) break;
      }
      expect(controller.model.pageImage, isNotNull);
      final gate = Completer<List<PdfPageLink>>();
      bridge.pending = gate;
      controller.dispatch(const ReaderPdfLinkTapped(100, 200));
      switch (action) {
        case 'dismiss':
          controller.dispatch(const ReaderReferenceDismissed());
        case 'navigate':
          controller.dispatch(const ReaderUnitRequested(2));
        case 'suspend':
          controller.dispatch(const ReaderSuspended());
        case 'replace':
          controller.dispatch(const ReaderOpenRequested('/books/new.pdf'));
      }
      gate.complete(_ReferenceBridge._links);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      if (action == 'keep') {
        expect(controller.model.referencePeek?.unit, 1);
        expect(controller.model.unit, 0);
      } else {
        expect(controller.model.referencePeek, isNull);
      }
      expect(controller.model.returnPoints, isEmpty);
      expect(controller.model.error, isNull);
      controller.dispose();
      await tester.pump();
      expect(bridge.isDisposed, isTrue);
    });
  }

  test('panels are mutually exclusive and search is independent', () {
    final controller = _controller();
    addTearDown(controller.dispose);

    expect(controller.model.openPanel, isNull);
    expect(controller.model.searchOpen, isFalse);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.contents));
    expect(controller.model.openPanel, ReaderPanel.contents);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.typography));
    expect(controller.model.openPanel, ReaderPanel.typography);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.notes));
    expect(controller.model.openPanel, ReaderPanel.notes);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.notes));
    expect(controller.model.openPanel, isNull);

    controller.dispatch(const ReaderSearchToggled());
    expect(controller.model.searchOpen, isTrue);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.contents));
    expect(controller.model.searchOpen, isTrue);
    expect(controller.model.openPanel, ReaderPanel.contents);
    controller.dispatch(const ReaderSearchToggled());
    expect(controller.model.searchOpen, isFalse);
  });

  test('progress precedence is loading, none, then supplied data', () {
    final controller = _controller();
    addTearDown(controller.dispose);

    expect(controller.model.progress.kind, ReaderProgressKind.none);
    expect(controller.model.progress.hasDocument, isFalse);
  });

  test('notifies listeners exactly once per accepted transition', () {
    final controller = _controller();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.dispatch(const ReaderPanelToggled(ReaderPanel.notes));

    expect(notifications, 1);
  });

  test('layout changes update the model when no document is open', () {
    final controller = _controller();
    addTearDown(controller.dispose);
    const layout = ReaderLayout(
      scale: 2,
      width: 640,
      fontSize: 20,
      lineSpacing: 1.6,
    );

    controller.dispatch(const ReaderLayoutChanged(layout));

    expect(controller.model.layout, layout);
  });

  test('invalid layouts are ignored', () {
    final controller = _controller();
    addTearDown(controller.dispose);
    final initial = controller.model.layout;

    controller.dispatch(
      const ReaderLayoutChanged(ReaderLayout(width: 0, fontSize: 0)),
    );

    expect(controller.model.layout, initial);
  });

  test('viewport observations update the reported layout', () {
    final controller = _controller();
    addTearDown(controller.dispose);
    const observed = ReaderLayout(
      scale: 3,
      width: 800,
      fontSize: 22,
      lineSpacing: 2,
    );

    controller.dispatch(const ReaderViewportChanged(observed));

    expect(controller.model.layout, observed);
  });

  test('dispose clears listeners so later transitions are not observed', () {
    final controller = _controller();
    var notifications = 0;
    controller.addListener(() => notifications += 1);
    controller.dispose();

    controller.dispatch(const ReaderPanelToggled(ReaderPanel.notes));

    expect(notifications, 0);
  });
}
