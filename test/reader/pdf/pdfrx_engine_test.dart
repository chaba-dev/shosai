import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/columns.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/reader/pdf/page_geometry.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../../support/reference_documents.dart';

const _fixture = 'fixtures/sample.pdf';

/// A one-page PDF whose catalog carries [catalogExtra], written to a
/// temporary file.
Future<String> _pdfWith(String catalogExtra) async {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R $catalogExtra >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>',
  ];
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index += 1) {
    offsets.add(pdf.length);
    pdf.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  final directory = await Directory.systemTemp.createTemp('shosai-pdf-');
  addTearDown(() => directory.delete(recursive: true));
  final file = File('${directory.path}/direction.pdf');
  await file.writeAsString(pdf.toString());
  return file.path;
}

void main() {
  final engine = PdfrxPdfEngine();

  test('crop admission includes outward rounding at area and edge limits', () {
    final exactArea = pdfBitmapSizeFor(const PdfPageSize(5000, 8000), 1);
    expect(exactArea.width * exactArea.height, 40000000);
    expect(
      () => pdfBitmapSizeFor(
        const PdfPageSize(6000, 9000),
        1,
        clip: const PdfRect(.2, .2, 5000.2, 8000.2),
      ),
      throwsA(isA<PdfEngineLimitException>()),
      reason: 'Outward rounding requires 5001 × 8001, not 5000 × 8000',
    );
    final exactEdge = pdfBitmapSizeFor(
      const PdfPageSize(20000, 3),
      1,
      clip: const PdfRect(0, 0, 16384, 1),
    );
    expect([exactEdge.width, exactEdge.height], [16384, 1]);
    expect(
      () => pdfBitmapSizeFor(
        const PdfPageSize(20000, 3),
        1,
        clip: const PdfRect(.2, .2, 16384.2, 1.2),
      ),
      throwsA(isA<PdfEngineLimitException>()),
      reason: 'The virtual page is legal, but the crop rounds to 16385 wide',
    );
  });

  test('clipped renders match full-page pixels at fitted density', () async {
    final document = await engine.open('fixtures/pdf-columns/thrift.pdf');
    addTearDown(document.dispose);
    const scale = 2.0;
    final full = await document.render(0, scale);
    final crop = await document.render(
      0,
      scale,
      clip: const PdfRect(53.8, 130.2, 293.3, 350.7),
    );
    final source = crop.source!;
    expect(crop.width, 480);
    expect(crop.height, 442);
    expect(source.left, 53.5);
    expect(source.top, 130);
    final x = (source.left * scale).round();
    final y = (source.top * scale).round();
    for (var row = 0; row < crop.height; row++) {
      expect(
        crop.pixels.sublist(row * crop.width * 4, (row + 1) * crop.width * 4),
        full.pixels.sublist(
          ((y + row) * full.width + x) * 4,
          ((y + row) * full.width + x + crop.width) * 4,
        ),
      );
    }
    // A tiny high-density crop must not allocate an inadmissible full bitmap.
    final detail = await document.render(
      0,
      30,
      clip: const PdfRect(54, 130, 64, 140),
    );
    expect([detail.width, detail.height], [300, 300]);
    // Noninteger virtual-page sizing must agree with the actual engine crop.
    final rounded = await document.render(
      0,
      2.013,
      clip: const PdfRect(53.8, 130.2, 293.3, 350.7),
    );
    expect([rounded.width, rounded.height], [483, 445]);
  });

  test(
    'column regions retain vector ink and own overlaid image labels',
    () async {
      final document = await engine.open(
        'fixtures/pdf-columns/content-preservation.pdf',
      );
      addTearDown(document.dispose);
      for (var p = 0; p < 4; p++) {
        final geometry = await document.pageGeometry(p);
        final result = analyzePdfColumns([geometry]).single;
        final raster = await document.render(p, 1);
        var missing = 0;
        var duplicated = 0;
        var painted = 0;
        for (var y = 0; y < raster.height; y++) {
          for (var x = 0; x < raster.width; x++) {
            final offset = (y * raster.width + x) * 4;
            if (raster.pixels[offset] >= 245 &&
                raster.pixels[offset + 1] >= 245 &&
                raster.pixels[offset + 2] >= 245) {
              continue;
            }
            painted++;
            final crops = result.regions.where((r) {
              final b = r.bounds;
              return x + .5 >= b.left &&
                  x + .5 < b.right &&
                  y + .5 >= b.top &&
                  y + .5 < b.bottom;
            }).length;
            if (crops == 0) missing++;
            if (crops > 1) duplicated++;
          }
        }
        expect(
          painted,
          greaterThan(16000),
          reason: 'real painted figure, page $p',
        );
        expect(
          missing,
          0,
          reason: 'every painted pixel survives region crops, page $p',
        );
        expect(
          duplicated,
          0,
          reason: 'no figure/label ink appears twice, page $p',
        );
        expect(result.columnCount, 2);
        expect(
          result.regions.where((r) => r.kind == PdfRegionKind.figure),
          hasLength(1),
          reason: 'vector/shading figures keep neighboring text columns',
        );
        if (p == 2) {
          final figure = result.regions.singleWhere(
            (r) => r.kind == PdfRegionKind.figure,
          );
          expect(figure.lines.single.text, 'Overlaid label');
          expect(
            result.regions.expand((r) => r.lines),
            hasLength(geometry.lines.length),
          );
          expect(result.regions.map((r) => r.kind), [
            PdfRegionKind.column,
            PdfRegionKind.figure,
            PdfRegionKind.column,
            PdfRegionKind.column,
          ]);
        }
      }
    },
  );

  test(
    'Thrift Letter title band, measured columns and stable text offsets',
    () async {
      final document = await engine.open('fixtures/pdf-columns/thrift.pdf');
      addTearDown(document.dispose);
      final geometry = await document.pageGeometry(0);
      expect([geometry.width, geometry.height], [612, 792]);
      final result = analyzePdfColumns([geometry]).single;
      expect(result.columnCount, 2);
      final title = result.regions.first;
      expect(title.kind, PdfRegionKind.band);
      // Tight painted bounds follow RFD's y24..104 title, with raster padding.
      expect(title.bounds.top, closeTo(24, 4));
      expect(title.bounds.bottom, closeTo(106, 1));
      final columns = result.regions
          .where((r) => r.kind == PdfRegionKind.column)
          .toList();
      expect(columns.first.bounds.left, closeTo(51, .1));
      expect(columns.first.bounds.right, closeTo(296, .5));
      expect(columns.last.bounds.left, closeTo(314, .1));
      expect(columns.last.bounds.right, closeTo(559, .5));
      expect(
        result.regions.where((r) => r.kind == PdfRegionKind.figure),
        hasLength(geometry.images.length),
      );
      final text = (await document.pageText(0)).runes.toList();
      for (final line in geometry.lines) {
        expect(
          line.text,
          String.fromCharCodes(text.sublist(line.start, line.end)),
        );
      }
      expect(
        result.regions.expand((r) => r.lines).toSet(),
        geometry.lines.toSet(),
      );
    },
  );

  test(
    'every Thrift page splits; physical rows expose real safe cuts',
    () async {
      final document = await engine.open('fixtures/pdf-columns/thrift.pdf');
      addTearDown(document.dispose);
      final pages = [
        for (var p = 0; p < document.pageCount; p++)
          await document.pageGeometry(p),
      ];
      expect(
        analyzePdfColumns(pages).map((p) => p.columnCount),
        List.filled(8, 2),
      );
      // Former loose-box chains on exactly the device-reported pages/blocks.
      for (final (p, top, bottom, count) in [
        (0, 339, 378, 4),
        (3, 403, 450, 5),
        (2, 549, 578, 3),
      ]) {
        final rows =
            pages[p].lines
                .where(
                  (l) =>
                      l.bounds.left < 60 &&
                      l.bounds.top >= top &&
                      l.bounds.top < bottom,
                )
                .toList()
              ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
        expect(rows, hasLength(count), reason: 'Thrift page ${p + 1}');
        for (var n = 1; n < rows.length; n++) {
          expect(
            rows[n].bounds.top - rows[n - 1].bounds.bottom,
            greaterThan(1),
          );
        }
        final text = (await document.pageText(p)).runes.toList();
        for (final row in rows) {
          expect(
            row.text,
            String.fromCharCodes(text.sublist(row.start, row.end)),
          );
        }
      }
    },
  );

  test('licensed ACM two-column and arXiv single-column corpus', () async {
    for (final (file, expected) in [
      ('acm-chi.pdf', 2),
      ('arxiv-first-five.pdf', 0),
    ]) {
      final document = await engine.open('fixtures/pdf-columns/$file');
      try {
        final pages = <PdfPageGeometry>[
          for (var p = 0; p < 5; p++) await document.pageGeometry(p),
        ];
        final results = analyzePdfColumns(pages);
        for (final result in results.take(3)) {
          // The arXiv blank verso and vertical identifier must not make columns.
          expect(result.columnCount, expected, reason: file);
        }
        if (expected == 2) {
          expect(results.first.regions.first.kind, PdfRegionKind.band);
          expect(
            results[2].regions
                .expand((r) => r.lines)
                .any((l) => l.text.startsWith('Exploring the Experiences')),
            isFalse,
            reason: 'recurring running head, not body text',
          );
        }
      } finally {
        await document.dispose();
      }
    }
  });

  test('image-only scan falls back to the complete page', () async {
    final document = await engine.open('fixtures/pdf-columns/scanned.pdf');
    addTearDown(document.dispose);
    final geometry = await document.pageGeometry(0);
    expect(geometry.lines, isEmpty);
    expect(geometry.images, hasLength(1));
    final result = analyzePdfColumns([geometry]).single;
    expect(result.columnCount, 0);
    expect(result.regions.single.kind, PdfRegionKind.page);
    expect(result.regions.single.bounds.width, 612);
    expect(result.regions.single.bounds.height, 792);
  });

  test('nested image bounds match rotated, cropped rendered pixels', () async {
    final document = await engine.open(
      'fixtures/pdf-columns/transformed-images.pdf',
    );
    addTearDown(document.dispose);
    final expected = [
      [100.0, 491.0, 120.0, 551.0],
      [201.0, 100.0, 261.0, 120.0],
      [472.0, 201.0, 492.0, 261.0],
      [491.0, 472.0, 551.0, 492.0],
    ];
    for (var p = 0; p < 4; p++) {
      final geometry = await document.pageGeometry(p);
      final rect = geometry.images.single;
      expect([rect.left, rect.top, rect.right, rect.bottom], expected[p]);
      expect(geometry.lines.single.text, 'Geometry control');
      final rendered = await document.render(p, 1);
      final x = ((rect.left + rect.right) / 2).floor();
      final y = ((rect.top + rect.bottom) / 2).floor();
      expect(
        rendered.pixels[(y * rendered.width + x) * 4],
        0,
        reason: 'the predicted image rectangle must contain the black image',
      );
    }
  });

  for (final fixture in [
    (
      rotation: 0,
      cropped: false,
      rect: [72.0, 570.0, 310.0, 596.0],
      target: (x: 72.0, y: 102.0),
    ),
    (
      rotation: 90,
      cropped: false,
      rect: [570.0, 302.0, 596.0, 540.0],
      target: (x: 690.0, y: 72.0),
    ),
    (
      rotation: 180,
      cropped: false,
      rect: [302.0, 196.0, 540.0, 222.0],
      target: (x: 540.0, y: 690.0),
    ),
    (
      rotation: 270,
      cropped: false,
      rect: [196.0, 72.0, 222.0, 310.0],
      target: (x: 102.0, y: 540.0),
    ),
    (
      rotation: 90,
      cropped: true,
      rect: [540.0, 290.0, 566.0, 528.0],
      target: (x: 660.0, y: 52.0),
    ),
  ]) {
    test('links match painted geometry at ${fixture.rotation} degrees, '
        'crop=${fixture.cropped}', () async {
      final directory = await Directory.systemTemp.createTemp('reference-pdf-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/references.pdf');
      await file.writeAsBytes(
        referencePdf(rotation: fixture.rotation, cropped: fixture.cropped),
      );
      final document = await engine.open(file.path);
      addTearDown(document.dispose);
      final links = await document.links(0);
      expect(links, hasLength(4));
      expect(links.map((link) => link.page), everyElement(1));
      final rect = links.first.rects.single;
      expect([rect.left, rect.bottom, rect.right, rect.top], fixture.rect);
      expect(links.first.destination, fixture.target);
      expect(links[1].destination, isNotNull, reason: 'named GoTo destination');
      expect(links[3].destination, isNotNull, reason: 'FitH destination');
      if (fixture.rotation == 0) {
        expect(links[1].destination, (x: 72.0, y: 628.0));
        expect(links[3].destination, (x: 0.0, y: 412.0));
      }
    });
  }

  test('opens the fixture and reports its pages', () async {
    final document = await engine.open(_fixture);
    addTearDown(document.dispose);
    expect(document.pageCount, greaterThan(0));
    expect(document.isEncrypted, isFalse);
    expect(document.allowsCopying, isTrue);
    final size = document.pageSize(0);
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThan(0));
  });

  test('renders a page as RGBA at ceil(points × scale)', () async {
    final document = await engine.open(_fixture);
    addTearDown(document.dispose);
    final size = document.pageSize(0);
    final rendered = await document.render(0, 1.5);
    expect(rendered.width, (size.width * 1.5).ceil());
    expect(rendered.height, (size.height * 1.5).ceil());
    expect(rendered.pixels.length, rendered.width * rendered.height * 4);
    // A white page background is opaque white in RGBA.
    expect(rendered.pixels[3], 255);
    expect(rendered.pixels.sublist(0, 3), [255, 255, 255]);
  });

  test(
    'builds a selection surface whose text has one scalar per character',
    () async {
      final document = await engine.open(_fixture);
      addTearDown(document.dispose);
      final surface = await document.selectionSurface(0, 1);
      final bitmap = document.bitmapSize(0, 1);
      expect(surface.width, bitmap.width.toDouble());
      expect(surface.height, bitmap.height.toDouble());
      expect(surface.text, isNotEmpty);
      expect(surface.endpoints, isNotEmpty);
      expect(surface.visualLines, isNotEmpty);
      expect(surface.graphemeBoundaries.first, 0);
      expect(surface.graphemeBoundaries.last, surface.text.runes.length);
      for (final endpoint in surface.endpoints) {
        expect(endpoint.rect.left, lessThan(endpoint.rect.right));
        expect(endpoint.rect.top, lessThan(endpoint.rect.bottom));
        expect(endpoint.rect.right, lessThanOrEqualTo(surface.width));
        expect(endpoint.rect.bottom, lessThanOrEqualTo(surface.height));
      }
      final text = await document.pageText(0);
      expect(text, surface.text);
      stdout.writeln('TEXT: ${text.substring(0, text.length.clamp(0, 120))}');
    },
  );

  test('search finds a word from the page text case-insensitively', () async {
    final document = await engine.open(_fixture);
    addTearDown(document.dispose);
    final text = await document.pageText(0);
    final word = RegExp(r'[A-Za-z]{4,}').firstMatch(text)!.group(0)!;
    final matches = await document.search(word.toUpperCase());
    expect(matches, isNotEmpty);
    expect(matches.first.unit, BigInt.zero);
    expect(matches.first.length, BigInt.from(word.length));
    final scalars = text.runes.toList();
    final found = String.fromCharCodes(
      scalars.sublist(
        matches.first.offset.toInt(),
        matches.first.offset.toInt() + matches.first.length.toInt(),
      ),
    );
    expect(found.toLowerCase(), word.toLowerCase());
  });

  test('outline and links load without error', () async {
    final document = await engine.open(_fixture);
    addTearDown(document.dispose);
    final outline = await document.outline();
    final links = await document.links(0);
    stdout.writeln('OUTLINE: ${outline.length} LINKS: ${links.length}');
  });

  test('reads the viewer preferences\' direction', () async {
    final rightToLeft = await engine.open(
      await _pdfWith('/ViewerPreferences << /Direction /R2L >>'),
    );
    addTearDown(rightToLeft.dispose);
    expect(rightToLeft.rightToLeft, isTrue);

    final leftToRight = await engine.open(
      await _pdfWith('/ViewerPreferences << /Direction /L2R >>'),
    );
    addTearDown(leftToRight.dispose);
    expect(leftToRight.rightToLeft, isFalse);

    final undeclared = await engine.open(_fixture);
    addTearDown(undeclared.dispose);
    expect(undeclared.rightToLeft, isFalse);
  });

  test('a missing file fails to open with a clear error', () async {
    await expectLater(
      engine.open('../does-not-exist.pdf'),
      throwsA(isA<PdfEngineException>()),
    );
  });
}
