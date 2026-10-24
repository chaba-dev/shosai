import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/controller.dart' show ReaderSelection;
import 'package:shosai_flutter/reader/pdf/spread.dart';
import 'package:shosai_flutter/reader/view.dart';
import 'package:shosai_flutter/theme_tokens.dart';

/// An area highlight on [unit] covering [left] to [left] + 20 × 10–30 of
/// its page.
FlutterAnnotation _area(int unit, double left) => FlutterAnnotation(
  id: 'area-$unit',
  unit: BigInt.from(unit),
  resolution: FlutterAnnotationResolution.exact,
  rectangles: [
    FlutterSelectionRect(left: left, top: 10, right: left + 20, bottom: 30),
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

  test(
    'PDF themes transform only raster tones, not geometry or overlays',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const swatches = [
        Colors.white,
        Colors.black,
        Color(0xff404040),
        Color(0xffc0c0c0),
        Color(0xffa0643c),
      ];
      for (var i = 0; i < swatches.length; i += 1) {
        canvas.drawRect(
          Rect.fromLTWH(i * 40, 0, 40, 50),
          Paint()..color = swatches[i],
        );
      }
      final picture = recorder.endRecording();
      final raster = await picture.toImage(200, 100);
      addTearDown(raster.dispose);
      addTearDown(picture.dispose);
      final surface = FlutterSelectionSurface(
        width: 200,
        height: 100,
        text: 'ab',
        copyEligible: true,
        endpoints: [
          for (var i = 0; i < 2; i += 1)
            FlutterSelectionEndpoint(
              offset: BigInt.from(i),
              rangeStart: BigInt.from(i),
              rangeEnd: BigInt.from(i + 1),
              rect: FlutterSelectionRect(
                left: 50 + i * 40,
                top: 10,
                right: 70 + i * 40,
                bottom: 30,
              ),
            ),
        ],
        graphemeBoundaries: Uint32List.fromList([0, 1, 2]),
        wordBoundaries: Uint32List.fromList([0, 2]),
        visualLines: const [],
      );
      Future<List<Color>> render(String theme, {bool overlays = false}) async {
        final colors = pageColors(theme);
        final painter = PagePainter(
          image: raster,
          surface: surface,
          backgroundColor: colors.background,
          foregroundColor: colors.foreground,
          recolorImage: false,
          anchor: overlays ? 1 : null,
          focus: overlays ? 2 : null,
          savedSelections: overlays
              ? [const ReaderSelection(0, 1, FlutterHighlightColor.blue)]
              : const [],
          annotations: overlays ? [_area(0, 10)] : const [],
        );
        final recording = ui.PictureRecorder();
        painter.paint(Canvas(recording), const Size(200, 100));
        final painted = recording.endRecording();
        final image = await painted.toImage(200, 100);
        try {
          final data = (await image.toByteData())!;
          return [
            for (final point in const [
              Offset(20, 20),
              Offset(60, 20),
              Offset(100, 20),
              Offset(140, 20),
              Offset(180, 20),
              Offset(180, 80),
            ])
              Color.fromARGB(
                255,
                data.getUint8((point.dy.toInt() * 200 + point.dx.toInt()) * 4),
                data.getUint8(
                  (point.dy.toInt() * 200 + point.dx.toInt()) * 4 + 1,
                ),
                data.getUint8(
                  (point.dy.toInt() * 200 + point.dx.toInt()) * 4 + 2,
                ),
              ),
          ];
        } finally {
          image.dispose();
          painted.dispose();
        }
      }

      void closeColor(Color actual, Color expected) {
        expect((actual.r - expected.r).abs(), lessThanOrEqualTo(1.1 / 255));
        expect((actual.g - expected.g).abs(), lessThanOrEqualTo(1.1 / 255));
        expect((actual.b - expected.b).abs(), lessThanOrEqualTo(1.1 / 255));
      }

      for (final theme in ['light', 'sepia', 'dark']) {
        final colors = pageColors(theme);
        final plain = await render(theme);
        closeColor(
          plain[0],
          theme == 'light' ? Colors.white : colors.background,
        );
        closeColor(
          plain[1],
          theme == 'light' ? Colors.black : colors.foreground,
        );
        closeColor(plain[5], colors.background); // Transparent spread padding.
        if (theme == 'dark') {
          expect(
            plain[2].computeLuminance(),
            greaterThan(plain[3].computeLuminance()),
          );
          expect(plain[4].r, greaterThan(plain[4].g));
          expect(plain[4].g, greaterThan(plain[4].b)); // Not a blue negative.
        } else {
          expect(
            plain[2].computeLuminance(),
            lessThan(plain[3].computeLuminance()),
          );
          if (theme == 'light') {
            for (var i = 0; i < swatches.length; i += 1) {
              closeColor(plain[i], swatches[i]);
            }
          }
        }
        final marked = await render(theme, overlays: true);
        for (final (index, fill) in [
          (0, ShosaiTokens.readerAnnotationYellow),
          (1, ShosaiTokens.readerAnnotationBlue),
          (2, ShosaiTokens.readerSelectionDragFill),
        ]) {
          closeColor(marked[index], Color.alphaBlend(fill, plain[index]));
        }
        expect(marked.skip(3), plain.skip(3));
      }
    },
  );

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
      annotations: [_area(4, 10), _area(5, 50)],
      currentUnit: 4,
      spread: spread,
      paintContent: false,
    );

    // Painted where each page's highlight is (page 4's at 10–30 of its page,
    // page 5's at 50–70) and nowhere a swapped page would put it.
    Future<List<bool>> paintedAt(PagePainter painter) async => [
      for (final x in [20, 60, 120, 160]) await _alphaAt(painter, x, 20) > 0,
    ];

    // Left to right: page 4 on the left, page 5 from x = 100.
    expect(
      await paintedAt(
        painter(
          const ReaderPdfSpread(facingUnit: 5, textShift: 0, facingLeft: 100),
        ),
      ),
      [true, false, false, true],
    );

    // Right to left: page 5 on the left, page 4 from x = 100.
    expect(
      await paintedAt(
        painter(
          const ReaderPdfSpread(facingUnit: 5, textShift: 0, firstLeft: 100),
        ),
      ),
      [false, true, true, false],
    );
  });
}
