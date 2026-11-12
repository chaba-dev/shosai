import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/column_strip.dart';
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';

PdfTextLine line(double top, double bottom, {String text = 'Original text'}) =>
    PdfTextLine(
      bounds: PdfRect(20, top, 120, bottom),
      text: text,
      start: 0,
      end: text.length,
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
  test('continuous overflow reduces overscan, not crop or document scale', () {
    final wide = page([
      PdfReadingRegion(
        kind: PdfRegionKind.column,
        bounds: const PdfRect(0, 0, 120, 400),
      ),
    ]);
    final screen = layoutPdfColumnWindow(
      pages: {for (var p = 0; p < 20; p++) p: wide},
      pageCount: 20,
      position: const PdfStripPosition(10, y: 200),
      width: 1248,
      height: 1500,
      columnWidth: 100,
      density: 3,
    );
    expect(screen.needsPage, isNull);
    expect(screen.width, closeTo(1497.6, .001));
    final bitmap = pdfBitmapSizeFor(
      PdfPageSize(screen.width, screen.height),
      3,
    );
    expect(bitmap.width * bitmap.height, lessThanOrEqualTo(40000000));
    expect(screen.height, lessThan(3560));
    expect(screen.pieces.every((p) => p.scale == 12.48), isTrue);
    expect(screen.pieces.every((p) => p.source.width == 120), isTrue);
    final anchor = screen.pieces.singleWhere((p) => p.page == 10);
    expect(anchor.toPage(0, screen.viewportTop).y, closeTo(200, .001));
  });

  test('backward continuous steps admit enough short preceding pages', () {
    final short = page([
      PdfReadingRegion(
        kind: PdfRegionKind.page,
        bounds: const PdfRect(0, 0, 400, 100),
      ),
    ], columns: 0);
    final retained = {for (var p = 18; p < 30; p++) p: short};
    PdfStripScreen window(PdfStripPosition position) {
      while (true) {
        final result = layoutPdfColumnWindow(
          pages: retained,
          pageCount: 30,
          position: position,
          width: 400,
          height: 800,
        );
        if (result.needsPage == null) return result;
        retained[result.needsPage!] = short;
      }
    }

    double origin(PdfStripScreen screen) {
      final first = screen.pieces.first;
      // Authored 100px pages with 28px bands; independently known strip origin.
      return first.page * 128 +
          first.source.top -
          first.top +
          screen.viewportTop;
    }

    var screen = window(const PdfStripPosition(20, y: 50));
    expect(origin(screen), closeTo(20 * 128 + 50, .001));
    for (var i = 0; i < 3; i++) {
      final before = origin(screen);
      final target = screen.viewportTop - (800 - 16);
      final piece = screen.pieces.firstWhere((p) => p.top + p.height > target);
      screen = window(
        PdfStripPosition(
          piece.page,
          region: piece.region,
          y: piece.toPage(piece.left, target).y,
        ),
      );
      expect(before - origin(screen), closeTo(784, .001));
      expect(screen.height, lessThanOrEqualTo(2400));
    }
    expect(retained.keys.any((page) => page < 18), isTrue);
  });

  test('continuous windows keep tall figures and headings in the strip', () {
    final pages = {
      0: page([
        PdfReadingRegion(
          kind: PdfRegionKind.column,
          bounds: const PdfRect(20, 10, 120, 55),
          lines: [line(10, 20), line(24, 35), line(30, 40), line(45, 55)],
        ),
        PdfReadingRegion(
          kind: PdfRegionKind.figure,
          bounds: const PdfRect(180, 0, 280, 400),
        ),
      ]),
      1: page([
        PdfReadingRegion(
          kind: PdfRegionKind.column,
          bounds: const PdfRect(20, 0, 120, 200),
        ),
      ]),
    };
    PdfStripScreen window(PdfStripPosition position) => layoutPdfColumnWindow(
      pages: pages,
      pageCount: 2,
      position: position,
      width: 200,
      height: 150,
    );
    final first = window(const PdfStripPosition(0));
    expect(first.continuous, isTrue);
    expect(first.pieces.first.source.bottom, 55);
    expect(first.pieces[1].top, 106); // 90pt of text, then the 16pt rule.
    expect(first.pieces[1].scale, 2); // No shrinking a tall figure to a screen.
    expect(first.separators.single.page, isNull);
    expect(first.height, 300);
    final later = window(const PdfStripPosition(0, region: 1, y: 380));
    expect(later.height, lessThanOrEqualTo(450));
    final figure = later.pieces.firstWhere((p) => p.region == 1 && p.page == 0);
    final original = figure.toPage(figure.left, later.viewportTop);
    expect(original.y, closeTo(380, .001));
    expect(later.separators.single.page, 1);
    expect(later.visiblePage(later.viewportTop, 150), 1);
    final tail = later.pieces.last;
    final mapped = tail.fromPage(73, 32);
    expect(tail.toPage(mapped.x, mapped.y), (x: 73.0, y: 32.0));
  });

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

      final carriedLines = [
        line(0, 8),
        line(10, 40),
        line(20, 22),
        line(30, 35),
        line(40, 50),
        line(51, 59),
        line(61, 69),
      ];
      final carriedPages = {
        0: page([
          PdfReadingRegion(
            kind: PdfRegionKind.column,
            bounds: const PdfRect(20, 0, 120, 69),
            lines: carriedLines,
          ),
        ]),
      };
      final crops = <PdfRect>[];
      var cursor = const PdfStripPosition(0);
      for (var screen = 0; screen < 2; screen++) {
        final layout = layoutPdfColumnScreen(
          pages: carriedPages,
          pageCount: 1,
          start: cursor,
          width: 100,
          height: 50.5,
        );
        final crop = layout.pieces.single.source;
        expect(crop.top, crops.isEmpty ? 0 : crops.last.bottom);
        crops.add(crop);
        cursor = layout.next;
      }
      expect(cursor.page, 1);
      for (final physicalLine in carriedLines) {
        expect(
          crops.where((crop) => crop.contains(physicalLine.bounds)),
          hasLength(1),
          reason: 'Repeated carries must keep each overlapping line whole once',
        );
      }
      final heading = line(0, 8, text: '1. Heading');
      final overlap = [line(12, 24), line(20, 32)];
      for (final height in [28.0, 40.0]) {
        final restored = layoutPdfColumnScreen(
          pages: {
            0: page([
              PdfReadingRegion(
                kind: PdfRegionKind.column,
                bounds: const PdfRect(20, 0, 120, 50),
                lines: [heading, ...overlap, line(34, 42), line(46, 50)],
              ),
            ]),
          },
          pageCount: 1,
          start: const PdfStripPosition(0, y: 10),
          width: 100,
          height: height,
          locate: true,
        );
        final crop = restored.pieces.single.source;
        for (final row in overlap) {
          expect(crop.contains(row.bounds), isTrue);
        }
        expect(crop.contains(heading.bounds), height == 40);
      }
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
        height: 65,
        topInset: 15,
      );
      expect(screen.pieces.single.scale, .625);
      final source = screen.pieces.single.source;
      expect(
        [source.left, source.top, source.right, source.bottom],
        [20, 10, 120, 90],
      );
      expect(screen.pieces.single.top, 15);
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
      expect(screen.pieces.map((p) => p.width), [200, 200, 200, 200]);
      expect(screen.pieces.map((p) => p.left), [0, 0, 0, 0]);
      expect(screen.separators.map((s) => s.page), [null, 1]);
      expect(screen.next.page, 2);
      expect(screen.pieces.last.source.bottom, 400);
    },
  );

  test(
    'a paragraph first row carries forward but ordinary rows fill the screen',
    () {
      final rows = [
        line(0, 8),
        line(10, 18, text: '2.4 Measurements continue in the same paragraph'),
        line(30, 38),
        line(40, 48),
      ];
      PdfStripScreen screen(double height) => layoutPdfColumnScreen(
        pages: {
          0: page([
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 0, 120, 48),
              lines: rows,
            ),
          ]),
        },
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 100,
        height: height,
      );
      expect(screen(39).pieces.single.source.bottom, 24);
      expect(
        screen(19).pieces.single.source.bottom,
        18.5,
        reason: 'Numbering without a block gap must not carry an ordinary row',
      );
      expect(screen(48).next.page, 1);
      final heading = layoutPdfColumnScreen(
        pages: {
          0: page([
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 0, 120, 52),
              lines: [
                line(0, 8),
                line(10, 18),
                line(22, 35),
                line(38, 46),
                line(48, 52),
              ],
            ),
          ]),
        },
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 100,
        height: 36,
      );
      expect(
        heading.pieces.single.source.bottom,
        20,
        reason: 'A larger heading stays with the following body',
      );
      final newBlock = layoutPdfColumnScreen(
        pages: {
          0: page([
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 0, 120, 30),
            ),
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 45, 120, 73),
              lines: [line(45, 53), line(55, 63), line(65, 73)],
            ),
          ]),
        },
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 100,
        height: 55,
      );
      expect(
        newBlock.pieces.length,
        1,
        reason: 'A new block cannot leave just its first row in a tail',
      );
      expect(newBlock.next.region, 1);
      final headingBlock = layoutPdfColumnScreen(
        pages: {
          0: page([
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 0, 120, 30),
            ),
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 45, 120, 89),
              lines: [line(45, 53), line(61, 69), line(71, 79), line(81, 89)],
            ),
          ]),
        },
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 100,
        height: 67,
      );
      expect(
        headingBlock.pieces.length,
        1,
        reason: 'Carrying the first body row must also carry its heading',
      );
      expect(headingBlock.next.region, 1);
    },
  );

  test(
    'a figure fits indivisibly after text, preserving its selection lines',
    () {
      final pages = {
        0: page([
          PdfReadingRegion(
            kind: PdfRegionKind.column,
            bounds: const PdfRect(20, 0, 120, 30),
          ),
          PdfReadingRegion(
            kind: PdfRegionKind.figure,
            bounds: const PdfRect(20, 40, 120, 240),
            lines: [line(50, 60), line(210, 220)],
          ),
        ]),
      };
      final first = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 100,
        height: 150,
      );
      expect(first.pieces.length, 1);
      expect(first.next.region, 1);
      final next = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 1,
        start: first.next,
        width: 100,
        height: 150,
      );
      expect(next.pieces.single.source.bottom, 240);
      expect(next.pieces.single.height, 150);
      expect(next.pieces.single.zoomable, isTrue);
      expect(next.next.page, 1);
    },
  );

  test(
    'short fragments and opposite columns share the document body scale',
    () {
      final screen = layoutPdfColumnScreen(
        pages: {
          0: page([
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(20, 0, 120, 20),
            ),
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(35, 40, 85, 48),
            ),
            PdfReadingRegion(
              kind: PdfRegionKind.column,
              bounds: const PdfRect(180, 0, 260, 20),
            ),
          ]),
        },
        pageCount: 1,
        start: const PdfStripPosition(0),
        width: 200,
        height: 300,
      );
      expect(screen.pieces.map((p) => p.scale), [2, 2, 2]);
      expect(screen.pieces.map((p) => p.width), [200, 100, 160]);
    },
  );

  test('an overflowing line and an inset abstract do not resize body text', () {
    PdfReadingRegion body(double left, double width, {bool overflow = false}) =>
        PdfReadingRegion(
          kind: PdfRegionKind.column,
          bounds: PdfRect(left, 10, left + width, 100),
          lines: [
            for (var i = 0; i < 6; i++)
              PdfTextLine(
                bounds: PdfRect(
                  left,
                  10 + i * 15,
                  left + (overflow && i == 2 ? width : 100),
                  20 + i * 15,
                ),
                text: 'Body $i',
                start: i * 10,
                end: i * 10 + 6,
              ),
          ],
        );
    final pages = {
      0: page([body(20, 102), body(160, 132, overflow: true)]),
      1: page([
        PdfReadingRegion(
          kind: PdfRegionKind.column,
          bounds: const PdfRect(30, 10, 122, 40),
          lines: [
            for (final y in [10.0, 30.0])
              PdfTextLine(
                bounds: PdfRect(30, y, 120, y + 10),
                text: 'Abstract',
                start: 0,
                end: 8,
              ),
          ],
        ),
        body(170, 102),
      ]),
    };
    var cursor = const PdfStripPosition(0);
    final pieces = <PdfStripPiece>[];
    while (cursor.page < 2) {
      final screen = layoutPdfColumnScreen(
        pages: pages,
        pageCount: 2,
        start: cursor,
        width: 204,
        height: 130,
      );
      expect(screen.pieces, isNotEmpty);
      expect(screen.width, greaterThanOrEqualTo(204));
      for (final piece in screen.pieces) {
        expect(piece.left, greaterThanOrEqualTo(0));
        expect(piece.left + piece.width, lessThanOrEqualTo(screen.width));
      }
      pieces.addAll(screen.pieces);
      cursor = screen.next;
    }
    expect(pieces.map((p) => p.scale).toSet(), {2});
    final overflow = pieces.firstWhere((p) => p.page == 0 && p.region == 1);
    expect(
      overflow.left,
      0,
      reason: 'start at the leading edge before panning',
    );
    expect(overflow.width, 264, reason: 'retain source ink without shrinking');
    for (final entry in pages.entries) {
      for (var r = 0; r < entry.value.columns.regions.length; r++) {
        for (final row in entry.value.columns.regions[r].lines) {
          expect(
            pieces.where(
              (p) =>
                  p.page == entry.key &&
                  p.region == r &&
                  p.source.top <= row.bounds.top &&
                  p.source.bottom >= row.bounds.bottom,
            ),
            hasLength(1),
            reason: 'each physical row belongs to exactly one screen',
          );
        }
      }
    }
  });

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
