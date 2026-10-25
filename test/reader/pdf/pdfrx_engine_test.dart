import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
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
