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
  test('tools visibility is a pure model transition', () {
    final controller = _controller();
    addTearDown(controller.dispose);

    expect(controller.model.toolsVisible, isFalse);
    controller.dispatch(const ReaderToolsToggled());
    expect(controller.model.toolsVisible, isTrue);
    controller.dispatch(const ReaderToolsToggled());
    expect(controller.model.toolsVisible, isFalse);
  });

  test('notifies listeners exactly once per accepted transition', () {
    final controller = _controller();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.dispatch(const ReaderToolsToggled());

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

    controller.dispatch(const ReaderToolsToggled());

    expect(notifications, 0);
  });
}
