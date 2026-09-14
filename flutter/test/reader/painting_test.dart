import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_flutter/reader/view.dart';

void main() {
  test('page colors keep background and foreground distinct', () {
    for (final scheme in const [
      ShadStoneColorScheme.light(),
      ShadStoneColorScheme.dark(),
    ]) {
      final colors = pageColors(scheme);
      expect(colors.background, scheme.background);
      expect(colors.foreground, scheme.foreground);
      expect(
        ThemeData.estimateBrightnessForColor(colors.background),
        isNot(ThemeData.estimateBrightnessForColor(colors.foreground)),
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
