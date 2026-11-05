import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/column_strip.dart';
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

// These papers do not grant CC redistribution rights. CI uses only numeric
// layout facts with prose replaced by hashes. Optional local originals test
// PDFium extraction and the actual painted pixels, not a mocked renderer.
const _papers = [
  (
    name: 'resnet',
    pages: 12,
    columns: 2,
    sha: '1e0651b6810ecba34a3dbc5b5b0209226f889004607c1f203540a48d64e5a93a',
  ),
  (
    name: 'attention',
    pages: 15,
    columns: 0,
    sha: 'bdfaa68d8984f0dc02beaca527b76f207d99b666d31d1da728ee0728182df697',
  ),
];

List<double> _box(PdfRect r) => [r.left, r.top, r.right, r.bottom];
PdfRect _rect(dynamic values) => PdfRect(
  (values[0] as num).toDouble(),
  (values[1] as num).toDouble(),
  (values[2] as num).toDouble(),
  (values[3] as num).toDouble(),
);

Map<String, Object> _facts(PdfPageGeometry page) => {
  'width': page.width,
  'height': page.height,
  'unknown': page.hasUnboundedGraphics,
  'lines': [
    for (final line in page.lines)
      {
        'bounds': _box(line.bounds),
        'text': RegExp(r'^\d+$').hasMatch(line.text.trim())
            ? line.text.trim()
            : sha256.convert(utf8.encode(line.text)).toString(),
        'start': line.start,
        'end': line.end,
      },
  ],
  'images': page.images.map(_box).toList(),
  'graphics': page.graphics.map(_box).toList(),
};

void main() {
  for (final paper in _papers) {
    test(
      '${paper.name}: exact pages, columns, ownership and crop coverage',
      () async {
        final fixture = File(
          'fixtures/pdf-columns/${paper.name}-geometry.json',
        );
        final original =
            Platform.environment['${paper.name.toUpperCase()}_PDF'];
        final pages = <PdfPageGeometry>[];
        if (original != null) {
          expect(
            sha256.convert(await File(original).readAsBytes()).toString(),
            paper.sha,
          );
          final document = await PdfrxPdfEngine().open(original);
          addTearDown(document.dispose);
          for (var p = 0; p < document.pageCount; p++) {
            pages.add(await document.pageGeometry(p));
          }
          final facts = {
            'sha256': paper.sha,
            'pages': pages.map(_facts).toList(),
          };
          if (Platform.environment['UPDATE_PAPER_GEOMETRY'] == '1') {
            await fixture.writeAsString('${jsonEncode(facts)}\n');
          } else {
            expect(facts, jsonDecode(await fixture.readAsString()));
          }
          final results = analyzePdfColumns(pages);
          for (var p = 0; p < pages.length; p++) {
            final result = results[p];
            final kept = result.regions.expand((r) => r.lines).toSet();
            final omitted = pages[p].lines.where((l) => !kept.contains(l));
            final raster = await document.render(p, 1);
            var painted = 0;
            var missing = 0;
            var repeated = 0;
            for (var y = 0; y < raster.height; y++) {
              for (var x = 0; x < raster.width; x++) {
                final offset = (y * raster.width + x) * 4;
                if (raster.pixels[offset] >= 245 &&
                    raster.pixels[offset + 1] >= 245 &&
                    raster.pixels[offset + 2] >= 245) {
                  continue;
                }
                // Deliberately suppressed running folios, including AA fringe.
                if (omitted.any(
                  (l) =>
                      x + .5 >= l.bounds.left - 1 &&
                      x + .5 <= l.bounds.right + 1 &&
                      y + .5 >= l.bounds.top - 1 &&
                      y + .5 <= l.bounds.bottom + 1,
                )) {
                  continue;
                }
                painted++;
                final count = result.regions
                    .where(
                      (r) =>
                          x + .5 >= r.bounds.left &&
                          x + .5 < r.bounds.right &&
                          y + .5 >= r.bounds.top &&
                          y + .5 < r.bounds.bottom,
                    )
                    .length;
                if (count == 0) missing++;
                if (count > 1) repeated++;
              }
            }
            expect(painted, greaterThan(10000));
            expect(
              (missing, repeated),
              (0, 0),
              reason: '${paper.name} page ${p + 1}',
            );
            // ignore: avoid_print
            print(
              '${paper.name} p${p + 1}: columns=${result.columnCount} painted=$painted missing=$missing repeated=$repeated',
            );
          }
        } else {
          final source = jsonDecode(await fixture.readAsString()) as Map;
          expect(source['sha256'], paper.sha);
          for (final p in source['pages'] as List) {
            pages.add(
              PdfPageGeometry(
                width: (p['width'] as num).toDouble(),
                height: (p['height'] as num).toDouble(),
                lines: [
                  for (final l in p['lines'])
                    PdfTextLine(
                      bounds: _rect(l['bounds']),
                      text: l['text'],
                      start: l['start'],
                      end: l['end'],
                    ),
                ],
                images: [for (final b in p['images']) _rect(b)],
                graphics: [for (final b in p['graphics']) _rect(b)],
                hasUnboundedGraphics: p['unknown'],
              ),
            );
          }
        }
        expect(pages, hasLength(paper.pages));
        final results = analyzePdfColumns(pages);
        if (paper.name == 'resnet') {
          // Page 4's three network headers must travel with the diagram, not
          // survive as an orphan text crop on the preceding strip screen.
          // Offsets identify the pinned original without redistributing prose.
          final headers = [
            for (final start in [995, 1002, 1558])
              pages[3].lines.singleWhere((line) => line.start == start),
          ];
          final diagram = results[3].regions.singleWhere(
            (r) => r.bounds.contains(pages[3].graphics.first),
          );
          expect(diagram.kind, PdfRegionKind.figure);
          expect(diagram.lines, containsAll(headers));
          expect(
            diagram.lines.any((line) => line.bounds.bottom > 600),
            isTrue,
            reason: 'headers and bottom network layers stay indivisible',
          );
          expect(
            diagram.lines.every((line) => line.bounds.right < 300),
            isTrue,
            reason: 'neighboring body column remains independent',
          );
        }
        for (var p = 0; p < pages.length; p++) {
          final result = results[p];
          expect(
            result.columnCount,
            paper.columns,
            reason: '${paper.name} page ${p + 1}',
          );
          final kept = result.regions.expand((r) => r.lines).toList();
          expect(
            kept.toSet(),
            hasLength(kept.length),
            reason: 'labels owned once',
          );
          for (final line in pages[p].lines) {
            if (kept.contains(line)) continue;
            expect(line.text.trim(), '${p + 1}');
            expect(line.bounds.top, greaterThan(pages[p].height * .9));
          }
          for (final ink in [
            ...kept.map((l) => l.bounds),
            ...pages[p].images,
            ...pages[p].graphics,
          ]) {
            final owners = result.regions.where((r) => r.bounds.overlaps(ink));
            expect(owners, hasLength(1));
            expect(owners.single.bounds.contains(ink), isTrue);
          }
          if (paper.columns == 2) {
            for (final r in result.regions.where(
              (r) => r.kind == PdfRegionKind.column,
            )) {
              expect(
                r.bounds.right < 300 || r.bounds.left > 296,
                isTrue,
                reason: 'real body gutter, not gaps inside a table/plot',
              );
            }
            if ([0, 1, 2, 3, 4, 5, 6, 7, 10, 11].contains(p)) {
              expect(
                result.regions.any((r) => r.kind == PdfRegionKind.figure),
                isTrue,
              );
            }
          } else {
            expect(result.regions.single.kind, PdfRegionKind.page);
            expect(
              result.regions.single.bounds.width,
              lessThan(pages[p].width),
            );
          }
        }
        if (paper.name == 'resnet') {
          // The Mac-reported page-4 network headers are three labels on one
          // physical row, not a separate paragraph. Exact-once ink alone
          // allowed that row to be stranded before the full-height diagram.
          const headerOffsets = {995, 1002, 1558};
          final headers = pages[3].lines
              .where((line) => headerOffsets.contains(line.start))
              .toList();
          expect(headers, hasLength(3));
          const diagram = PdfRect(51.045, 92.112, 284.799, 618.042);
          final metadata = {
            for (var p = 0; p < pages.length; p++)
              p: PdfStripPage(pages[p], results[p]),
          };
          final screens = <PdfStripScreen>[];
          var cursor = const PdfStripPosition(0);
          while (cursor.page < pages.length && screens.length < 100) {
            final screen = layoutPdfColumnScreen(
              pages: metadata,
              pageCount: pages.length,
              start: cursor,
              width: 412,
              height: 775,
            );
            expect(screen.pieces, isNotEmpty);
            screens.add(screen);
            cursor = screen.next;
          }
          expect(cursor.page, pages.length);
          final diagramScreen = screens.singleWhere(
            (screen) => screen.pieces.any(
              (piece) => piece.page == 3 && piece.source.contains(diagram),
            ),
          );
          final object = diagramScreen.pieces.singleWhere(
            (piece) => piece.page == 3 && piece.source.contains(diagram),
          );
          expect(
            headers.every((line) => object.source.contains(line.bounds)),
            isTrue,
            reason: 'VGG/plain/residual headers must travel with the diagram',
          );
          for (final screen in screens.where((s) => s != diagramScreen)) {
            expect(
              screen.pieces.any(
                (piece) =>
                    piece.page == 3 &&
                    headers.any((line) => piece.source.overlaps(line.bounds)),
              ),
              isFalse,
              reason: 'No labels-only screen before or after the figure',
            );
          }
          final standalone = layoutPdfColumnScreen(
            pages: metadata,
            pageCount: pages.length,
            start: PdfStripPosition(3, region: object.region),
            width: 412,
            height: 775,
          );
          expect(object.scale, standalone.pieces.first.scale);
          expect(object.source.contains(diagram), isTrue);
          final preceding = screens[screens.indexOf(diagramScreen) - 1];
          final last = preceding.pieces.last;
          final tail = 775 - last.top - last.height;
          expect(
            object.height,
            greaterThan(tail),
            reason: 'Defer the intact figure, never shrink it into the tail',
          );
          // ignore: avoid_print
          print(
            'ResNet p4: headers+diagram screen ${screens.indexOf(diagramScreen)}, '
            'height=${object.height}, scale=${object.scale}; '
            'preceding tail=$tail (${(tail / 775 * 100).toStringAsFixed(1)}%)',
          );
        }
      },
    );
  }
}
