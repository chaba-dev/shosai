import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/controller.dart';
import 'package:shosai_flutter/src/rust/api.dart';

class _ReaderBridge implements FlutterBridge {
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
  test('panels are mutually exclusive and search is independent', () {
    final controller = _controller();
    addTearDown(controller.dispose);

    expect(controller.model.openPanel, isNull);
    expect(controller.model.searchOpen, isFalse);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.contents));
    expect(controller.model.openPanel, ReaderPanel.contents);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.typography));
    expect(controller.model.openPanel, ReaderPanel.typography);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.more));
    expect(controller.model.openPanel, ReaderPanel.more);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.more));
    expect(controller.model.openPanel, isNull);

    controller.dispatch(const ReaderSearchToggled());
    expect(controller.model.searchOpen, isTrue);
    controller.dispatch(const ReaderPanelToggled(ReaderPanel.contents));
    expect(controller.model.searchOpen, isTrue);
    expect(controller.model.openPanel, ReaderPanel.contents);
    controller.dispatch(const ReaderSearchToggled());
    expect(controller.model.searchOpen, isFalse);
  });

  test('tab activation and close follow the fixture policy', () {
    final controller = ReaderController(
      bridge: _ReaderBridge(),
      decoder: _unusedDecoder,
      initialTabs: const [
        ReaderTabPresentation(id: 'a', title: 'A', selected: true),
        ReaderTabPresentation(id: 'b', title: 'B'),
        ReaderTabPresentation(id: 'c', title: 'C'),
      ],
    );
    addTearDown(controller.dispose);

    controller.dispatch(const ReaderTabActivated('b'));
    expect(controller.model.tabs.map((tab) => tab.selected).toList(), [
      false,
      true,
      false,
    ]);

    // Closing the active tab activates its successor; the last tab falls back
    // to the previous one (5F owns the real lifecycle policy).
    controller.dispatch(const ReaderTabCloseRequested('b'));
    expect(controller.model.tabs.map((tab) => tab.id).toList(), ['a', 'c']);
    expect(controller.model.tabs.last.selected, isTrue);
    controller.dispatch(const ReaderTabCloseRequested('c'));
    expect(controller.model.tabs.single.id, 'a');
    expect(controller.model.tabs.single.selected, isTrue);
    controller.dispatch(const ReaderTabCloseRequested('a'));
    expect(controller.model.tabs, isEmpty);

    // Unknown ids are ignored.
    controller.dispatch(const ReaderTabActivated('missing'));
    expect(controller.model.tabs, isEmpty);
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

    controller.dispatch(const ReaderPanelToggled(ReaderPanel.more));

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

    controller.dispatch(const ReaderPanelToggled(ReaderPanel.more));

    expect(notifications, 0);
  });
}
