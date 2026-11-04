import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/column_strip.dart';
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';

PdfTextLine line(double top, double bottom) => PdfTextLine(
  bounds: PdfRect(20, top, 120, bottom),
  text: 'Original text',
  start: 0,
  end: 13,
);

PdfStripPage page(List<PdfReadingRegion> regions, {int columns = 2}) =>
    PdfStripPage(
      PdfPageGeometry(
        width: 300,
        height: 400,
        lines: regions.expand((r) => r.lines).toList(),
        images: const [],
      ),
      PdfColumnPage(columnCount: columns, regions: regions),
    );

void main() {
  test(
    'screens break between overlapping physical lines without losing ink',
    () {
      final lines = [line(10, 20), line(24, 35), line(30, 40), line(45, 55)];
      final pages = {
        0: page([
          PdfReadingRegion(
            kind: PdfRegionKind.column,
            bounds: const PdfRect(20, 10, 120, 55),
            lines: lines,
          ),
        ]),
      };
      final first = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 200,
        height: 50,
      );
      expect(first.pieces.single.source.bottom, 22);
      expect(first.next.y, 22);
      final second = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 1,
        start: first.next,
        width: 200,
        height: 50,
      );
      expect(second.pieces.single.source.top, 22);
      expect(second.pieces.single.source.bottom, 42.5);
      for (final screen in [first, second]) {
        final crop = screen.pieces.single.source;
        for (final l in lines) {
          expect(
            l.bounds.top < crop.bottom && l.bounds.bottom > crop.bottom,
            isFalse,
            reason: 'a physical line may not cross a screen edge',
          );
        }
      }
      final piece = second.pieces.single;
      final mapped = piece.fromPage(73, 32);
      final restored = piece.toPage(mapped.x, mapped.y);
      expect(restored, (x: 73.0, y: 32.0));
    },
  );

  test(
    'an indivisible tall row shrinks rather than stalling or cutting ink',
    () {
      final screen = layoutPdfColumnScreen(
        pages: {
          0: page([
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 10, 120, 105),
              lines: [line(10, 60), line(50, 90), line(95, 105)],
            ),
          ]),
        },
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 200,
        height: 50,
      );
      expect(screen.pieces.single.scale, .625);
      final source = screen.pieces.single.source;
      expect(
        [source.left, source.top, source.right, source.bottom],
        [20, 10, 120, 90],
      );
      expect(screen.pieces.single.height, 50);
      expect(screen.next.y, 90);
    },
  );

  test(
    'bands shrink, columns keep their fitted scale, pages join in order',
    () {
      final pages = {
        0: page([
          PdfReadingRegion(
            kind: PdfRegionKind.band,
            bounds: const PdfRect(10, 10, 290, 38),
          ),
          PdfReadingRegion(
            kind: PdfRegionKind.column,
            bounds: const PdfRect(20, 50, 120, 75),
          ),
          PdfReadingRegion(
            kind: PdfRegionKind.column,
            bounds: const PdfRect(170, 50, 270, 75),
          ),
        ]),
        1: page([
          PdfReadingRegion(
            kind: PdfRegionKind.page,
            bounds: const PdfRect(0, 0, 300, 400),
          ),
        ], columns: 0),
      };
      final screen = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 2,
        start: const PdfStripPosition(0),
        width: 200,
        height: 600,
        zoom: 2,
      );
      expect(screen.pieces.map((p) => p.page), [0, 0, 0, 1]);
      expect(screen.pieces.map((p) => p.width), [200, 400, 400, 200]);
      expect(screen.pieces.map((p) => p.left), [0, 0, 0, 0]);
      expect(screen.separators.map((s) => s.page), [null, 1]);
      expect(screen.next.page, 2);
      expect(screen.pieces.last.source.bottom, 400);
    },
  );

  test(
    'missing next-page geometry is explicit and the cursor makes progress',
    () {
      final pages = {
        0: page([
          PdfReadingRegion(
            kind: PdfRegionKind.page,
            bounds: const PdfRect(0, 0, 300, 400),
          ),
        ], columns: 0),
      };
      final first = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 2,
        start: const PdfStripPosition(0),
        width: 300,
        height: 420,
      );
      expect(first.needsPage, 1);
      expect(first.next.page, 1);
      expect(first.pieces.single.height, 400);
      final short = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 300,
        height: 123,
      );
      expect(short.pieces.single.source.bottom, 123);
      expect(short.next.y, 123);
      final smaller = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 300,
        height: 420,
        zoom: .5,
      );
      expect(
        smaller.pieces.single.width,
        300,
        reason: 'no-column pages remain fit width at every column-size setting',
      );
    },
  );
}
