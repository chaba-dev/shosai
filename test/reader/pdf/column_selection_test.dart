import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/reader/pdf/column_selection.dart';
import 'package:shosai_flutter/reader/pdf/column_strip.dart';
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';

FlutterSelectionSurface page(
  String text,
  List<FlutterSelectionEndpoint> endpoints, {
  List<FlutterSelectionVisualLine> lines = const [],
}) => FlutterSelectionSurface(
  width: 612,
  height: 792,
  text: text,
  copyEligible: true,
  endpoints: endpoints,
  graphemeBoundaries: Uint32List.fromList(
    List.generate(text.length + 1, (i) => i),
  ),
  wordBoundaries: Uint32List.fromList([0, text.length]),
  visualLines: lines,
);

FlutterSelectionEndpoint endpoint(int offset, FlutterSelectionRect rect) =>
    FlutterSelectionEndpoint(
      offset: BigInt.from(offset),
      rangeStart: BigInt.from(offset),
      rangeEnd: BigInt.from(offset + 1),
      rect: rect,
    );

void main() {
  test(
    'crops map visible endpoints once and preserve each original page address',
    () {
      const left = PdfStripPiece(
        page: 3,
        region: 0,
        source: PdfRect(54, 110, 293, 200),
        left: 8,
        top: 0,
        scale: 2,
      );
      const right = PdfStripPiece(
        page: 3,
        region: 1,
        source: PdfRect(317, 110, 556, 200),
        left: 8,
        top: 196,
        scale: 2,
      );
      const next = PdfStripPiece(
        page: 4,
        region: 0,
        source: PdfRect(30, 50, 300, 120),
        left: 4,
        top: 404,
        scale: 1.5,
      );
      final screen = PdfStripScreen(
        start: const PdfStripPosition(3),
        next: const PdfStripPosition(4, y: 120),
        width: 500,
        height: 600,
        pageWidth: 612,
        pageHeight: 792,
        pieces: [left, right, next],
        separators: [],
      );
      const firstRect = FlutterSelectionRect(
        left: 60,
        top: 120,
        right: 70,
        bottom: 130,
      );
      const rightRect = FlutterSelectionRect(
        left: 320,
        top: 150,
        right: 330,
        bottom: 160,
      );
      const nextRect = FlutterSelectionRect(
        left: 40,
        top: 60,
        right: 50,
        bottom: 70,
      );
      final selection = PdfStripSelection(screen, {
        3: page(
          'left right',
          [
            endpoint(0, firstRect),
            endpoint(5, rightRect),
            endpoint(
              9,
              const FlutterSelectionRect(
                left: 60,
                top: 300,
                right: 70,
                bottom: 310,
              ),
            ),
          ],
          lines: [
            FlutterSelectionVisualLine(
              carets: [
                FlutterSelectionCaret(
                  offset: BigInt.zero,
                  x: 61,
                  alongLine: 61,
                  vertical: false,
                  top: 120,
                  bottom: 130,
                ),
              ],
            ),
            FlutterSelectionVisualLine(
              carets: [
                FlutterSelectionCaret(
                  offset: BigInt.from(5),
                  x: 322,
                  alongLine: 154,
                  vertical: true,
                  top: 150,
                  bottom: 160,
                ),
              ],
            ),
          ],
        ),
        4: page('next', [endpoint(2, nextRect)]),
      });
      final visible = selection.surface.endpoints;
      expect(visible.map((e) => e.offset.toInt()), [0, 5, 13]);
      expect(
        visible[0].rect,
        const FlutterSelectionRect(left: 20, top: 20, right: 40, bottom: 40),
      );
      expect(
        visible[1].rect,
        const FlutterSelectionRect(left: 14, top: 276, right: 34, bottom: 296),
      );
      expect(
        visible[2].rect,
        const FlutterSelectionRect(left: 19, top: 419, right: 34, bottom: 434),
      );
      expect(selection.location(13), (page: 4, offset: 2));
      expect(selection.location(5), (page: 3, offset: 5));
      final carets = selection.surface.visualLines
          .expand((l) => l.carets)
          .toList();
      expect(carets, [
        FlutterSelectionCaret(
          offset: BigInt.zero,
          x: 22,
          alongLine: 22,
          vertical: false,
          top: 20,
          bottom: 40,
        ),
        FlutterSelectionCaret(
          offset: BigInt.from(5),
          x: 18,
          alongLine: 284,
          vertical: true,
          top: 276,
          bottom: 296,
        ),
      ]);
      expect(
        PdfStripSelection.mapRect(
          right,
          const FlutterSelectionRect(
            left: 310,
            top: 100,
            right: 325,
            bottom: 115,
          ),
        ),
        const FlutterSelectionRect(left: 8, top: 196, right: 24, bottom: 206),
      );
    },
  );
}
