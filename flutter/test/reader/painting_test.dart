import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/pdf/spread.dart';
import 'package:shosai_flutter/reader/view.dart';

/// An area highlight on [unit] covering 10–30 × 10–30 of its page.
FlutterAnnotation _area(int unit) => FlutterAnnotation(
  id: 'area-$unit',
  unit: BigInt.from(unit),
  resolution: FlutterAnnotationResolution.exact,
  rectangles: const [
    FlutterSelectionRect(left: 10, top: 10, right: 30, bottom: 30),
  ],
  color: FlutterHighlightColor.yellow,
);

/// The alpha at ([x], [y]) once [painter] paints a 200 × 100 surface.
Future<int> _alphaAt(PagePainter painter, int x, int y) async {
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder), const Size(200, 100));
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 100);
  try {
    final bytes = await image.toByteData();
    return bytes!.getUint8((y * 200 + x) * 4 + 3);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  test('page colors keep background and foreground distinct', () {
    // The reader palette is the document palette (owner decision 2026-09-28):
    // every reader theme keeps its paper and foreground distinct.
    for (final theme in const [null, 'light', 'dark', 'sepia']) {
      final colors = pageColors(theme);
      expect(
        ThemeData.estimateBrightnessForColor(colors.background),
        isNot(ThemeData.estimateBrightnessForColor(colors.foreground)),
        reason: '$theme',
      );
    }
  });

  test('page image source uses raster pixel dimensions', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    final image = await picture.toImage(4, 2);
    try {
      expect(pageImageSource(image), const Rect.fromLTWH(0, 0, 4, 2));
    } finally {
      image.dispose();
      picture.dispose();
    }
  });

  test('a spread paints each page\'s area highlights on that page', () async {
    final surface = FlutterSelectionSurface(
      width: 200,
      height: 100,
      text: '',
      copyEligible: false,
      endpoints: const [],
      graphemeBoundaries: Uint32List.fromList([0]),
      wordBoundaries: Uint32List.fromList([0]),
      visualLines: const [],
    );
    PagePainter painter(ReaderPdfSpread spread) => PagePainter(
      image: null,
      surface: surface,
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      recolorImage: false,
      anchor: null,
      focus: null,
      savedSelections: const [],
      annotations: [_area(4), _area(5)],
      currentUnit: 4,
      spread: spread,
      paintContent: false,
    );

    // Left to right: page 4 on the left, page 5 from x = 100.
    final leftToRight = painter(
      const ReaderPdfSpread(facingUnit: 5, textShift: 0, facingLeft: 100),
    );
    expect(await _alphaAt(leftToRight, 20, 20), greaterThan(0));
    expect(await _alphaAt(leftToRight, 120, 20), greaterThan(0));
    expect(await _alphaAt(leftToRight, 60, 20), 0);

    // Right to left: page 5 on the left, page 4 from x = 100.
    final rightToLeft = painter(
      const ReaderPdfSpread(facingUnit: 5, textShift: 0, firstLeft: 100),
    );
    expect(await _alphaAt(rightToLeft, 20, 20), greaterThan(0));
    expect(await _alphaAt(rightToLeft, 120, 20), greaterThan(0));
  });
}
