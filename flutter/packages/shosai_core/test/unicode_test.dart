import 'dart:io';

import 'package:shosai_core/src/annotations/graphemes.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

void main() {
  group('quote-v1 Unicode version', () {
    test('grapheme clusters pass the Unicode 17.0.0 conformance file', () {
      final file = File('test/fixtures/GraphemeBreakTest-17.0.0.txt');
      final lines = file.readAsLinesSync();
      expect(lines.first, contains('GraphemeBreakTest-17.0.0.txt'));
      expect(graphemeUnicodeVersion, '17.0.0');
      var cases = 0;
      for (final line in lines) {
        final fields = line.split('#').first.trim();
        if (fields.isEmpty) continue;
        cases++;
        final expected = <String>[];
        var cluster = StringBuffer();
        for (final field in fields.split(RegExp(r'\s+'))) {
          if (field == '÷') {
            if (cluster.isNotEmpty) expected.add(cluster.toString());
            cluster = StringBuffer();
          } else if (field != '×') {
            cluster.writeCharCode(int.parse(field, radix: 16));
          }
        }
        expect(graphemeClusters(expected.join()), expected, reason: line);
      }
      expect(cases, greaterThan(700));
    });

    // Canaries: each pair separates the pinned Unicode version from the one
    // before and the one after, so a dependency upgrade that changes the
    // profile's Unicode data fails here.
    test('NFC is Unicode 17.0.0', () {
      // U+1ACF COMBINING DOUBLE CARON (ccc 230) is new in Unicode 17, so it
      // reorders after U+0323 (ccc 220), which then composes with the a.
      expect(normalizeQuoteV1('a\u1ACF\u0323'), '\u1EA1\u1ACF');
      // U+1ADE COMBINING GRAVE-DOT (ccc 230) is new in Unicode 18: still
      // unassigned, it is a starter and blocks the composition.
      expect(normalizeQuoteV1('a\u1ADE\u0323'), 'a\u1ADE\u0323');
    });

    test('grapheme clusters are Unicode 17.0.0', () {
      // Extend in Unicode 17, unassigned (Other) in Unicode 16.
      expect(graphemeClusters('a\u1ACF'), ['a\u1ACF']);
      // Khmer conjuncts join by GB9c from Unicode 17.
      expect(graphemeClusters('\u179F\u17D2\u178F'), ['\u179F\u17D2\u178F']);
      // Unassigned in Unicode 17 (Extend in Unicode 18).
      expect(graphemeClusters('a\u1ADE'), ['a', '\u1ADE']);
    });
  });
}
