import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/selection.dart';

/// A left-to-right run of [text] laid out as 10×20 px glyphs on one baseline.
List<PdfCharacterSample> _row(
  String text, {
  int firstIndex = 0,
  int top = 100,
  int left = 0,
  bool visible = true,
  PdfBaselineProbe? baseline = const PdfBaselineProbe(1024, 0),
}) {
  final samples = <PdfCharacterSample>[];
  var index = firstIndex;
  var x = left;
  for (final rune in text.runes) {
    samples.add(
      PdfCharacterSample(
        index: index,
        codePoint: rune,
        generated: false,
        visible: visible,
        pageBounds: PdfPageBounds(
          x.toDouble(),
          (792 - top - 20).toDouble(),
          (x + 10).toDouble(),
          (792 - top).toDouble(),
        ),
        deviceBounds: PdfDeviceBounds(x, top, x + 10, top + 20),
        baseline: baseline,
      ),
    );
    index++;
    x += 10;
  }
  return samples;
}

void main() {
  group('page text', () {
    test('keeps one scalar per PDFium character', () {
      final samples = _row('ab');
      final result = pdfPageText(samples);
      expect(result.text, 'ab');
      expect(result.mappingComplete, isTrue);
    });

    test('substitutes U+FFFD for an unmapped or invisible character', () {
      final samples = [
        ..._row('a'),
        const PdfCharacterSample(
          index: 1,
          codePoint: 0,
          generated: false,
          visible: true,
        ),
        ..._row('c', firstIndex: 2, left: 20, visible: false),
      ];
      final result = pdfPageText(samples);
      expect(result.text, 'a��');
      expect(result.mappingComplete, isFalse);
    });

    test('keeps a generated character without bounds', () {
      final samples = [
        ..._row('a'),
        const PdfCharacterSample(
          index: 1,
          codePoint: 0x0A,
          generated: true,
          visible: false,
        ),
      ];
      final result = pdfPageText(samples);
      expect(result.text, 'a\n');
      expect(result.mappingComplete, isTrue);
    });
  });

  group('selection surface', () {
    test('splits every glyph into two half-zones with caret offsets', () {
      final selection = buildPdfPageSelection(
        bitmapWidth: 300,
        bitmapHeight: 400,
        samples: _row('ab'),
      );
      final surface = selection.surface;
      expect(surface.width, 300);
      expect(surface.height, 400);
      expect(surface.text, 'ab');
      expect(surface.copyEligible, isTrue);
      expect(surface.endpoints, hasLength(4));
      final first = surface.endpoints[0];
      expect(first.offset, BigInt.zero);
      expect(first.rangeStart, BigInt.zero);
      expect(first.rangeEnd, BigInt.one);
      expect(first.rect.left, 0);
      expect(first.rect.right, 5);
      final second = surface.endpoints[1];
      expect(second.offset, BigInt.one);
      expect(second.rangeStart, BigInt.zero);
      expect(second.rect.left, 5);
      expect(second.rect.right, 10);
      expect(surface.endpoints[3].offset, BigInt.two);
      expect(surface.graphemeBoundaries, [0, 1, 2]);
      expect(surface.wordBoundaries, [0, 2]);
    });

    test('a right-to-left run mirrors its half-zones', () {
      // Hebrew alef, bet drawn right to left: index 0 is the rightmost glyph.
      final samples = [
        ..._row('א', left: 10),
        ..._row('ב', firstIndex: 1, left: 0),
      ];
      final surface = buildPdfPageSelection(
        bitmapWidth: 100,
        bitmapHeight: 200,
        samples: samples,
      ).surface;
      final byOffset = {
        for (final endpoint in surface.endpoints)
          (endpoint.rangeStart.toInt(), endpoint.offset.toInt()): endpoint.rect,
      };
      // The caret before alef (offset 0) sits on its right half.
      expect(byOffset[(0, 0)]!.left, 15);
      expect(byOffset[(0, 1)]!.left, 10);
      expect(byOffset[(1, 1)]!.left, 5);
      expect(byOffset[(1, 2)]!.left, 0);
    });

    test('rows group zones that overlap vertically, in reading order', () {
      final samples = [
        ..._row('ab', top: 100),
        ..._row('cd', firstIndex: 2, top: 200),
      ];
      final surface = buildPdfPageSelection(
        bitmapWidth: 100,
        bitmapHeight: 400,
        samples: samples,
      ).surface;
      final tops = [for (final e in surface.endpoints) e.rect.top];
      expect(tops, [100, 100, 100, 100, 200, 200, 200, 200]);
      expect(surface.visualLines, hasLength(2));
      final carets = [
        for (final caret in surface.visualLines.first.carets)
          caret.offset.toInt(),
      ];
      expect(carets, [0, 1, 2]);
      expect(surface.visualLines.first.carets.first.x, 0);
      expect(surface.visualLines.first.carets.last.x, 20);
      expect(surface.visualLines.first.carets.first.top, 100);
      expect(surface.visualLines.first.carets.first.bottom, 120);
    });

    test('vertical text advances carets along the line', () {
      final samples = <PdfCharacterSample>[];
      for (var i = 0; i < 2; i++) {
        samples.add(
          PdfCharacterSample(
            index: i,
            codePoint: 0x3042 + i,
            generated: false,
            visible: true,
            pageBounds: PdfPageBounds(0, 0, 20, 20),
            deviceBounds: PdfDeviceBounds(50, 10 + i * 20, 70, 30 + i * 20),
            baseline: const PdfBaselineProbe(0, 1024),
          ),
        );
      }
      final surface = buildPdfPageSelection(
        bitmapWidth: 100,
        bitmapHeight: 100,
        samples: samples,
      ).surface;
      expect(surface.visualLines, hasLength(1));
      final line = surface.visualLines.single;
      expect(line.carets.every((caret) => caret.vertical), isTrue);
      expect([for (final c in line.carets) c.alongLine], [10, 30, 50]);
      expect(line.carets.first.x, 60);
      // Half-zones split the glyph top and bottom.
      expect(surface.endpoints.first.rect.bottom, 20);
    });

    test('snaps carets to grapheme boundaries', () {
      // e + combining acute: one grapheme, two PDFium characters.
      final samples = _row('éx');
      final surface = buildPdfPageSelection(
        bitmapWidth: 100,
        bitmapHeight: 200,
        samples: samples,
      ).surface;
      expect(surface.graphemeBoundaries, [0, 2, 3]);
      final offsets = {for (final e in surface.endpoints) e.offset.toInt()};
      expect(offsets, {0, 2, 3});
      // Range geometry still addresses each PDFium character.
      final ranges = {for (final e in surface.endpoints) e.rangeStart.toInt()};
      expect(ranges, {0, 1, 2});
      final carets = [
        for (final caret in surface.visualLines.single.carets)
          caret.offset.toInt(),
      ];
      expect(carets, [0, 2, 3]);
    });

    test('copy eligibility follows text mapping', () {
      final samples = [
        ..._row('a'),
        const PdfCharacterSample(
          index: 1,
          codePoint: 0,
          generated: false,
          visible: true,
          pageBounds: PdfPageBounds(10, 672, 20, 692),
          deviceBounds: PdfDeviceBounds(10, 100, 20, 120),
        ),
      ];
      final selection = buildPdfPageSelection(
        bitmapWidth: 100,
        bitmapHeight: 200,
        samples: samples,
      );
      expect(selection.mappingComplete, isFalse);
      expect(selection.surface.copyEligible, isFalse);
      expect(selection.surface.text, 'a�');
      // The unmapped glyph keeps its hit geometry.
      expect(selection.surface.endpoints, hasLength(4));
    });

    test('clamps geometry to the bitmap and drops empty glyphs', () {
      final samples = [
        const PdfCharacterSample(
          index: 0,
          codePoint: 0x61,
          generated: false,
          visible: true,
          pageBounds: PdfPageBounds(-5, 0, 5, 20),
          deviceBounds: PdfDeviceBounds(-5, 0, 5, 20),
        ),
        const PdfCharacterSample(
          index: 1,
          codePoint: 0x62,
          generated: false,
          visible: true,
          pageBounds: PdfPageBounds(200, 0, 210, 20),
          deviceBounds: PdfDeviceBounds(200, 0, 210, 20),
        ),
      ];
      final surface = buildPdfPageSelection(
        bitmapWidth: 100,
        bitmapHeight: 50,
        samples: samples,
      ).surface;
      expect(surface.text, 'ab');
      expect(surface.endpoints, hasLength(2));
      expect(surface.endpoints.first.rect.left, 0);
      expect(surface.endpoints.last.rect.right, 5);
    });

    test('refuses a page over the endpoint ceiling', () {
      final samples = [
        for (var i = 0; i < pdfSelectionMaxEndpoints ~/ 2 + 1; i++)
          PdfCharacterSample(
            index: i,
            codePoint: 0x61,
            generated: false,
            visible: true,
          ),
      ];
      expect(
        () => buildPdfPageSelection(
          bitmapWidth: 10,
          bitmapHeight: 10,
          samples: samples,
        ),
        throwsA(isA<PdfSelectionLimitException>()),
      );
    });
  });

  group('text direction', () {
    test('classifies strong and neutral scalars', () {
      expect(pdfTextDirection(0x61), PdfTextDirection.leftToRight);
      expect(pdfTextDirection(0x31), PdfTextDirection.leftToRight);
      expect(pdfTextDirection(0x3042), PdfTextDirection.leftToRight);
      expect(pdfTextDirection(0x05D0), PdfTextDirection.rightToLeft);
      expect(pdfTextDirection(0x0627), PdfTextDirection.rightToLeft);
      expect(pdfTextDirection(0x20), isNull);
      expect(pdfTextDirection(0x2E), isNull);
    });
  });
}
