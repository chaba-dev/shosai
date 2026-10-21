import 'dart:async';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

/// A book's unit texts, as a format engine would supply them.
final class FakeText implements UnitTextSource {
  FakeText(this.units);

  final List<String?> units;
  var requested = 0;

  @override
  int get unitCount => units.length;

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async {
    requested++;
    final text = units[unit];
    return text == null ? null : UnitText(text);
  }
}

/// Unit texts each supplied when the test completes the unit's request.
final class PendingText implements UnitTextSource {
  PendingText(this.unitCount);

  @override
  final int unitCount;
  final requests = StreamController<Completer<UnitText?>>();

  @override
  Future<UnitText?> unitText(int unit, {CancellationToken? cancellation}) {
    final completer = Completer<UnitText?>();
    requests.add(completer);
    return completer.future;
  }
}

List<(int, int)> _ranges(List<SearchMatch> matches) => [
  for (final match in matches) (match.offset, match.length),
];

void main() {
  group('case folding', () {
    test('applies full Unicode case folding', () {
      expect(caseFold('Hello WORLD'), 'hello world');
      expect(caseFold('Straße'), 'strasse');
      expect(caseFold('ﬁ'), 'fi');
      expect(caseFold('ΣΑΣ'), 'σασ');
      expect(caseFold('ς'), 'σ');
      expect(caseFold('İ'), 'i̇');
      expect(caseFold('µ'), 'μ');
      expect(caseFold('𐐀'), '𐐨');
      expect(caseFold('日本語 かな'), '日本語 かな');
      expect(caseFoldUnicodeVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });
  });

  group('search', () {
    test('finds case-insensitive matches in each unit', () {
      final matches = searchTexts([
        'Hello World hello',
        'nothing',
        'HELLO',
      ], 'hello');

      expect(
        [for (final m in matches) (m.unit, m.offset, m.length)],
        [(0, 0, 5), (0, 12, 5), (2, 0, 5)],
      );
      expect(searchTexts(['Rust Programming in RUST'], 'rust'), hasLength(2));
      expect(searchTexts(['Σ'], 'ς'), hasLength(1));
      expect(searchTexts(['Hello World'], 'xyz'), isEmpty);
      expect(searchTexts(['Hello World'], ''), isEmpty);
    });

    test('ranges and context refer to the original text', () {
      final [match] = searchTexts(['${'K' * 50}target'], 'target');

      expect((match.offset, match.length), (50, 6));
      expect(match.context, '${'K' * 40}target');

      final [emoji] = searchTexts(['😀😀 the\ntarget\nhere 😀'], 'TARGET');
      expect((emoji.offset, emoji.length), (7, 6));
      expect(emoji.context, '😀😀 the target here 😀');
    });

    test('expansions match only whole characters', () {
      expect(_ranges(searchTexts(['Straße ﬁnd'], 'STRASSE')), [(0, 6)]);
      expect(_ranges(searchTexts(['Straße ﬁnd'], 'FIND')), [(7, 3)]);
      for (final query in ['s', 'as', 'sb']) {
        expect(searchTexts(['aßb'], query), isEmpty, reason: query);
      }
      // A rejected partial match does not hide a later whole one.
      expect(_ranges(searchTexts(['ßss'], 'ss')), [(0, 1), (1, 2)]);
      // "sß" folds to "sss": the first "ss" ends inside the ß, the second
      // is exactly the ß.
      expect(_ranges(searchTexts(['sß'], 'ss')), [(1, 1)]);
    });

    test('expansions in the query match whole text characters', () {
      expect(_ranges(searchTexts(['STRASSE'], 'Straße')), [(0, 7)]);
      // 😀 and 𐐀 are one scalar each, two UTF-16 code units.
      expect(_ranges(searchTexts(['😀Straße𐐀'], 'STRASSE𐐨')), [(1, 7)]);
    });

    test('ranges stay exact after many expanding characters', () {
      // Folded text starts with room for its scalars plus 16, so 60 ß
      // (120 folded code points) force it to grow several times.
      final text = '${'ß' * 30}x${'ß' * 30}Straße';

      expect(_ranges(searchTexts([text], 'ssXss')), [(29, 3)]);
      expect(_ranges(searchTexts([text], 'strasse')), [(61, 6)]);
      expect(_ranges(searchTexts([text], 'ss')), [
        for (var i = 0; i < 30; i++) (i, 1),
        for (var i = 31; i < 61; i++) (i, 1),
        (65, 1),
      ]);
    });

    test('matches do not overlap', () {
      expect(_ranges(searchTexts(['aaaa'], 'aa')), [(0, 2), (2, 2)]);
      expect(_ranges(searchTexts(['abababab'], 'abab')), [(0, 4), (4, 4)]);
    });

    test('a failed partial match falls back to a later start', () {
      expect(_ranges(searchTexts(['abababac'], 'ababac')), [(2, 6)]);
    });

    test('adversarial text stays linear', () {
      final text = 'ß' * 200000;
      final stopwatch = Stopwatch()..start();

      expect(searchTexts([text], 's' * 1001), isEmpty);
      expect(searchTexts(['a' * 1000000], '${'a' * 4000}b'), isEmpty);

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('reports query, text, match and result limits', () {
      const base = SearchLimits(
        maxQueryBytes: 2,
        maxIndexedTextBytes: 5,
        maxMatches: 1,
      );

      expect(
        () => searchTexts(['a'], 'abc', limits: base),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        () => searchTexts(['a'], 'é😀', limits: base),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        () => searchTexts(['aaa', 'aaa'], 'z', limits: base),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        () => searchTexts(['a a'], 'a', limits: base),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(searchTexts(['a b'], 'a', limits: base), hasLength(1));
      expect(
        () => searchTexts(
          ['a'],
          'a',
          limits: const SearchLimits(maxResultBytes: searchMatchBaseBytes),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        searchTexts(
          ['a'],
          'a',
          limits: const SearchLimits(maxResultBytes: searchMatchBaseBytes + 1),
        ),
        hasLength(1),
      );
    });

    test('limits cannot exceed the hard maxima', () {
      for (final limits in [
        const SearchLimits(maxIndexedTextBytes: 8 * 1024 * 1024 + 1),
        const SearchLimits(maxQueryBytes: 4097),
        const SearchLimits(maxMatches: 10001),
        const SearchLimits(maxResultBytes: -1),
      ]) {
        expect(
          () => searchTexts(['text'], 't', limits: limits),
          throwsCoreError(CoreErrorKind.invalidRequest),
        );
      }
    });

    test('UTF-8 lengths count scalars as UTF-8 does', () {
      expect(utf8Length('a'), 1);
      expect(utf8Length('é'), 2);
      expect(utf8Length('日'), 3);
      expect(utf8Length('😀'), 4);
      expect(utf8Length('\uD800x'), 4);
    });
  });

  group('book search', () {
    test('searches every unit with text in other isolates', () async {
      final source = FakeText([
        'The first page.',
        null,
        'A page in the middle of the book.',
        'PAGE',
      ]);

      final matches = await searchBook(source, 'page');

      expect(
        [for (final m in matches) (m.unit, m.offset)],
        [(0, 10), (2, 2), (3, 0)],
      );
      expect(matches.first.context, 'The first page.');
      expect(source.requested, 4);
    });

    test('carries the limits across batches', () async {
      final page = 'match ${'x' * 600000}';
      final source = FakeText([page, page, page]);

      expect(await searchBook(source, 'match'), hasLength(3));
      await expectLater(
        searchBook(
          FakeText([page, page, page]),
          'match',
          limits: const SearchLimits(maxMatches: 2),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      await expectLater(
        searchBook(
          FakeText([page, page]),
          'match',
          limits: const SearchLimits(maxIndexedTextBytes: 1000000),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('carries result bytes across batches', () async {
      // Each page is over half a batch, so each is searched in its own run.
      // Context: "é😀 match" plus 40 scalars after it, " " and 39 "é":
      // 2 + 4 + 1 + 5 + 1 + 39 * 2 = 91 bytes, 139 with the base.
      final page = 'é😀 match ${'é' * 600000}';
      const perMatch = searchMatchBaseBytes + 91;

      final matches = await searchBook(
        FakeText([page, page, page]),
        'match',
        limits: const SearchLimits(maxResultBytes: 3 * perMatch),
      );
      expect(
        [for (final m in matches) (m.unit, m.offset, m.length)],
        [(0, 3, 5), (1, 3, 5), (2, 3, 5)],
      );
      expect(matches.first.context, 'é😀 match ${'é' * 39}');
      await expectLater(
        searchBook(
          FakeText([page, page, page]),
          'match',
          limits: const SearchLimits(maxResultBytes: 3 * perMatch - 1),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('an empty query reads nothing', () async {
      final source = FakeText(['text']);

      expect(await searchBook(source, ''), isEmpty);
      expect(source.requested, 0);
    });

    test('observes cancellation before indexing', () async {
      final source = FakeText(['searchable' * 1024]);
      final cancellation = CancellationToken()..cancel();

      await expectLater(
        searchBook(source, 'missing', cancellation: cancellation),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      expect(source.requested, 0);
    });

    test('observes cancellation during the last run', () async {
      final source = PendingText(1);
      final cancellation = CancellationToken();
      final search = searchBook(source, 'missing', cancellation: cancellation);
      final request = await source.requests.stream.first;

      request.complete(UnitText('ß' * 500000));
      // Fires once the run has started in another isolate, before it ends.
      Timer.run(cancellation.cancel);

      await expectLater(search, throwsCoreError(CoreErrorKind.cancelled));
    });

    test('observes cancellation while the last unit has no text', () async {
      final source = PendingText(2);
      final cancellation = CancellationToken();
      final search = searchBook(source, 'text', cancellation: cancellation);
      final requests = StreamIterator(source.requests.stream);

      expect(await requests.moveNext(), isTrue);
      requests.current.complete(null);
      expect(await requests.moveNext(), isTrue);
      cancellation.cancel();
      requests.current.complete(null);

      await expectLater(search, throwsCoreError(CoreErrorKind.cancelled));
    });
  });
}
