import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/reader/pdf/search.dart';

void main() {
  test('finds every case-insensitive occurrence with its page and offset', () {
    final search = PdfSearch('the')
      ..addPage(0, 'The cat. the dog.')
      ..addPage(1, 'Also THEME');
    expect(search.results, hasLength(3));
    expect(search.results[0].unit, BigInt.zero);
    expect(search.results[0].offset, BigInt.zero);
    expect(search.results[0].length, BigInt.from(3));
    expect(search.results[1].offset, BigInt.from(9));
    expect(search.results[2].unit, BigInt.one);
    expect(search.results[2].offset, BigInt.from(5));
  });

  test('offsets are scalar indexes, not UTF-16 units', () {
    final search = PdfSearch('b')..addPage(0, '😀😀b');
    expect(search.results.single.offset, BigInt.two);
  });

  test('context is the surrounding text, trimmed, on one line', () {
    final search = PdfSearch('needle')
      ..addPage(0, 'line one\nthe needle sits here\nline three');
    expect(
      search.results.single.context,
      'line one the needle sits here line three',
    );
  });

  test('folds non-ASCII letters', () {
    final search = PdfSearch('élan')..addPage(0, 'ÉLAN vital');
    expect(search.results, hasLength(1));
    expect(search.results.single.offset, BigInt.zero);
    expect(search.results.single.length, BigInt.from(4));
  });

  test('an empty or whitespace-only query matches nothing', () {
    expect(PdfSearch('').isEmpty, isTrue);
    final search = PdfSearch('')..addPage(0, 'anything');
    expect(search.results, isEmpty);
  });

  test('stops at the match ceiling', () {
    final search = PdfSearch('a', limits: const PdfSearchLimits(maxMatches: 2));
    expect(
      () => search.addPage(0, 'aaa'),
      throwsA(isA<PdfSearchLimitException>()),
    );
  });

  test('refuses an over-long query', () {
    expect(
      () => PdfSearch('x' * 5000),
      throwsA(isA<PdfSearchLimitException>()),
    );
  });
}
