import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/reader/pdf/spread.dart';

/// A one-line page surface: one endpoint and one caret per character of
/// [text], each [advance] wide, starting at the left edge.
FlutterSelectionSurface _page(String text, {double width = 100}) {
  const advance = 10.0;
  final characters = text.runes.length;
  return FlutterSelectionSurface(
    width: width,
    height: 200,
    text: text,
    copyEligible: true,
    endpoints: [
      for (var index = 0; index < characters; index += 1)
        FlutterSelectionEndpoint(
          offset: BigInt.from(index),
          rangeStart: BigInt.from(index),
          rangeEnd: BigInt.from(index + 1),
          rect: FlutterSelectionRect(
            left: index * advance,
            top: 10,
            right: (index + 1) * advance,
            bottom: 30,
          ),
        ),
    ],
    graphemeBoundaries: Uint32List.fromList([
      for (var index = 0; index <= characters; index += 1) index,
    ]),
    wordBoundaries: Uint32List.fromList([0, characters]),
    visualLines: [
      FlutterSelectionVisualLine(
        carets: [
          for (var index = 0; index <= characters; index += 1)
            FlutterSelectionCaret(
              offset: BigInt.from(index),
              x: index * advance,
              alongLine: index * advance,
              vertical: false,
              top: 10,
              bottom: 30,
            ),
        ],
      ),
    ],
  );
}

PdfRenderedPage _raster(int width, int height, int value) => PdfRenderedPage(
  width: width,
  height: height,
  pixels: Uint8List(width * height * 4)
    ..fillRange(0, width * height * 4, value),
);

void main() {
  test('spreads pair pages from the start of the document', () {
    expect(
      [for (var page = 0; page < 5; page += 1) pdfSpreadStart(page)],
      [0, 0, 2, 2, 4],
    );
  });

  test('a merged surface puts the second page beside the first', () {
    final merged = mergePdfSpreadSurfaces(_page('abc'), _page('de', width: 80));
    final surface = merged.surface;
    expect(merged.textShift, 4, reason: 'three characters and a line break');
    expect(surface.text, 'abc\nde');
    expect(surface.width, 180);
    expect(surface.height, 200);

    final second = surface.endpoints.skip(3).toList();
    expect([for (final e in second) e.offset.toInt()], [4, 5]);
    expect([for (final e in second) e.rect.left], [100, 110]);
    expect(
      surface.graphemeBoundaries.toList(),
      [0, 1, 2, 3, 4, 5, 6],
      reason: 'the line break between the pages is a boundary of its own',
    );
    expect(surface.wordBoundaries.toList(), [0, 3, 4, 6]);
    final carets = surface.visualLines.last.carets;
    expect([for (final c in carets) c.offset.toInt()], [4, 5, 6]);
    expect([for (final c in carets) c.x], [100, 110, 120]);
    expect([for (final c in carets) c.alongLine], [100, 110, 120]);
  });

  test('spread offsets convert to each page\'s own', () {
    const spread = ReaderPdfSpread(facingUnit: 3, textShift: 4);
    expect(spread.unitOf(1, 2), 2);
    expect(spread.pageOffset(1), 1);
    expect(spread.unitOf(5, 2), 3);
    expect(spread.pageOffset(5), 1);
  });

  test('a composed raster lays the pages side by side, top-aligned', () {
    final spread = composePdfSpread(_raster(2, 3, 1), _raster(3, 2, 2));
    expect(spread.width, 5);
    expect(spread.height, 3);
    int at(int x, int y) => spread.pixels[(y * spread.width + x) * 4];
    expect([for (var x = 0; x < 5; x += 1) at(x, 0)], [1, 1, 2, 2, 2]);
    expect(
      [for (var x = 0; x < 5; x += 1) at(x, 2)],
      [1, 1, 0, 0, 0],
      reason: 'the shorter page leaves transparent pixels below it',
    );
  });
}
