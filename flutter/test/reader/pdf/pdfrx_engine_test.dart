import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

const _fixture = '../crates/shosai-core/tests/fixtures/sample.pdf';

void main() {
  final engine = PdfrxPdfEngine();

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

  test('a missing file fails to open with a clear error', () async {
    await expectLater(
      engine.open('../does-not-exist.pdf'),
      throwsA(isA<PdfEngineException>()),
    );
  });
}
