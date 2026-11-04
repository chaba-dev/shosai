import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';

PdfTextLine line(String text, double x, double y, double width) => PdfTextLine(
  bounds: PdfRect(x, y, x + width, y + 10),
  text: text,
  start: text.codeUnitAt(0),
  end: text.codeUnitAt(0) + text.length,
);

List<PdfTextLine> columns(double y) => [
  for (var n = 0; n < 4; n++) ...[
    line('L$n', 54, y + n * 12, 239),
    line('R$n', 317, y + n * 12, 239),
  ],
];

PdfPageGeometry page(
  List<PdfTextLine> lines, {
  List<PdfRect> images = const [],
}) => PdfPageGeometry(width: 612, height: 792, lines: lines, images: images);

void main() {
  test('bands top-to-bottom, columns between bands, figures own regions', () {
    final input = page(
      [
        line('Title', 100, 24, 400),
        ...columns(120),
        line('Band label', 100, 250, 100),
        ...columns(320),
        line('Image label', 100, 390, 100),
      ],
      images: [
        const PdfRect(54, 230, 556, 290),
        const PdfRect(60, 370, 250, 430),
      ],
    );
    final ltr = analyzePdfColumns([input]).single;
    expect(ltr.columnCount, 2);
    expect(ltr.regions.map((r) => r.kind), [
      PdfRegionKind.band,
      PdfRegionKind.column,
      PdfRegionKind.column,
      PdfRegionKind.figure,
      PdfRegionKind.column,
      PdfRegionKind.figure,
      PdfRegionKind.column,
    ]);
    expect(
      ltr.regions
          .where((r) => r.kind == PdfRegionKind.column)
          .map((r) => r.lines.first.text),
      ['L0', 'R0', 'L0', 'R0'],
    );
    final rtl = analyzePdfColumns([input], rightToLeft: true).single;
    expect(
      rtl.regions
          .where((r) => r.kind == PdfRegionKind.column)
          .map((r) => r.lines.first.text),
      ['R0', 'L0', 'R0', 'L0'],
    );
    expect(rtl.regions.first.lines.single, same(input.lines.first));
    expect(ltr.regions.expand((r) => r.lines).toSet(), input.lines.toSet());
    expect(ltr.regions.expand((r) => r.lines), hasLength(input.lines.length));
    expect(
      ltr.regions
          .where((r) => r.kind == PdfRegionKind.figure)
          .map((r) => r.lines.single.text),
      ['Band label', 'Image label'],
    );
  });

  test('bounded graphics own labels; only unknown coverage needs fallback', () {
    final body = columns(120);
    for (final (graphics, unbounded, expected) in [
      ([const PdfRect(100, 125, 120, 150)], false, 2),
      ([const PdfRect(100, 180, 120, 200)], false, 2),
      (<PdfRect>[], true, 0),
    ]) {
      final result = analyzePdfColumns([
        PdfPageGeometry(
          width: 612,
          height: 792,
          lines: body,
          images: [],
          graphics: graphics,
          hasUnboundedGraphics: unbounded,
        ),
      ]).single;
      expect(result.columnCount, expected);
    }
    // A partial overlay owns complete physical lines, not clipped/repeated
    // labels, without losing the neighboring text column.
    final overlaid = analyzePdfColumns([
      page(body, images: [const PdfRect(54, 130, 293, 150)]),
    ]).single;
    expect(overlaid.columnCount, 2);
    expect(overlaid.regions.expand((r) => r.lines).toSet(), body.toSet());
    expect(overlaid.regions.expand((r) => r.lines), hasLength(body.length));
  });

  test('three columns and ragged edges are not reduced to two', () {
    final input = page([
      for (var n = 0; n < 6; n++)
        for (var col = 0; col < 3; col++)
          line('$col:$n', 54 + col * 172, 120 + n * 12, 145 - n * 2),
    ]);
    final result = analyzePdfColumns([input]).single;
    expect(result.columnCount, 3);
    expect(result.regions.map((r) => r.lines.first.text), [
      '0:0',
      '1:0',
      '2:0',
    ]);
  });

  test(
    'recurring margin heads and changing folios drop, body repeats stay',
    () {
      final pages = [
        for (var p = 0; p < 3; p++)
          page([
            line('Running head', 54, 24 + p * .5, 130),
            line('${p + 9}', 300, 760, 12),
            line('Unique $p', 54, 60, 100),
            ...columns(120),
            line('Running head', 54, 250, 130),
          ]),
      ];
      final result = analyzePdfColumns(pages);
      for (var p = 0; p < pages.length; p++) {
        final kept = result[p].regions.expand((r) => r.lines).toList();
        expect(kept, isNot(contains(pages[p].lines[0])));
        expect(kept, isNot(contains(pages[p].lines[1])));
        expect(kept, contains(pages[p].lines[2]));
        expect(kept, contains(pages[p].lines.last));
      }
      // One page is not enough evidence that a title is a running head.
      expect(
        analyzePdfColumns([pages.first]).single.regions.expand((r) => r.lines),
        contains(pages.first.lines.first),
      );
    },
  );

  test('no text, no gutter, narrow gap and sequential blocks fall back', () {
    final inputs = [
      page([], images: [const PdfRect(0, 0, 612, 792)]),
      page([
        for (var n = 0; n < 12; n++)
          line('Body', 54, 120 + n * 12, n % 3 == 0 ? 260 : 502),
      ]),
      page([
        for (var n = 0; n < 4; n++) ...[
          line('L', 54, 120 + n * 12, 248),
          line('R', 308, 120 + n * 12, 248),
        ],
      ]),
      page([
        for (var n = 0; n < 4; n++) ...[
          line('L', 54, 120 + n * 12, 239),
          line('R', 317, 320 + n * 12, 239),
        ],
      ]),
    ];
    final sizes = [(612, 792), (504, 144), (504, 48), (504, 248)];
    for (var p = 0; p < inputs.length; p++) {
      final input = inputs[p];
      final result = analyzePdfColumns([input]).single;
      expect(result.columnCount, 0);
      expect(result.regions.single.kind, PdfRegionKind.page);
      expect(result.regions.single.bounds.width, sizes[p].$1);
      expect(result.regions.single.bounds.height, sizes[p].$2);
      for (final line in input.lines) {
        expect(result.regions.single.bounds.contains(line.bounds), isTrue);
      }
    }
  });
}
