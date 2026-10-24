import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/view.dart';

void main() {
  test('contain centers and scales the source inside the viewport', () {
    final transform = SurfaceTransform.create(
      BoxFit.contain,
      const Size(100, 50),
      const Size(200, 400),
    );

    expect(transform.source, const Rect.fromLTRB(0, 0, 100, 50));
    expect(transform.destination, const Rect.fromLTRB(0, 150, 200, 250));
    expect(transform.toSource(const Offset(100, 200)), const Offset(50, 25));
    expect(
      transform.toDestinationRect(const Rect.fromLTRB(0, 0, 100, 50)),
      const Rect.fromLTRB(0, 150, 200, 250),
    );
  });

  test('clamped mapping stays inside the source bounds', () {
    final transform = SurfaceTransform.create(
      BoxFit.contain,
      const Size(100, 50),
      const Size(200, 400),
    );

    expect(
      transform.toSource(const Offset(500, 500), clamp: true),
      const Offset(100, 50),
    );
  });

  test('cover fills the viewport and crops the source', () {
    final transform = SurfaceTransform.create(
      BoxFit.cover,
      const Size(100, 50),
      const Size(200, 400),
    );

    expect(transform.source, const Rect.fromLTRB(37.5, 0, 62.5, 50));
    expect(transform.destination, const Rect.fromLTRB(0, 0, 200, 400));
    expect(transform.toSource(const Offset(0, 0)), const Offset(37.5, 0));
  });
}
