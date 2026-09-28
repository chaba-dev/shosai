import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/view.dart';

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
}
