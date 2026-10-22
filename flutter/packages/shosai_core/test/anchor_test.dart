import 'dart:collection';
import 'dart:math';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_core/src/annotations/graphemes.dart'
    show graphemeClusters;
import 'package:shosai_core/src/annotations/resolution.dart'
    show forEachBoundedGrapheme;
import 'package:test/test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'support/library_fixtures.dart';

ResolvedAnchor _resolve(String text, int start, int end, QuoteSelector quote) =>
    resolveTextAnchor(text, start, end, quote);

/// A huge list of scalars that counts how many of them are read.
final class _CountingScalars extends ListBase<int> {
  _CountingScalars(this.length, this.scalarAt);

  @override
  final int length;
  final int Function(int index) scalarAt;
  var reads = 0;

  @override
  set length(int value) => throw UnsupportedError('fixed length');

  @override
  int operator [](int index) {
    reads++;
    return scalarAt(index);
  }

  @override
  void operator []=(int index, int value) => throw UnsupportedError('fixed');
}

const _exact = AnnotationResolution.exact;
const _recovered = AnnotationResolution.recovered;
const _ambiguous = AnnotationResolution.ambiguous;
const _orphaned = AnnotationResolution.orphaned;

/// The message of an exhausted normalization allowance.
final _workLimit = contains('work limit');

void main() {
  group('quote-v1 profile', () {
    test('golden vectors pin normalization', () {
      expect(normalizeQuoteV1('Café'), 'Café');
      expect(normalizeQuoteV1(' a\r\n\t b c '), 'a b c');
      expect(normalizeQuoteV1('co­operate'), 'cooperate');
      expect(normalizeQuoteV1('Case—A-B! ﬁ'), 'Case—A-B! ﬁ');
      expect(normalizeQuoteV1('Résumé'), isNot(normalizeQuoteV1('résumé')));
      expect(normalizeQuoteV1('がな'), 'がな');
      expect(normalizeQuoteV1('﻿word'), '﻿word');
    });

    test('Hangul syllables skip NFC only where it would not change them', () {
      for (var syllable = 0xac00; syllable <= 0xd7a3; syllable++) {
        final text = String.fromCharCode(syllable);
        expect(unorm.nfc(text), text);
        expect(normalizeQuoteV1(text), text);
      }
      // A syllable composes with conjoining jamo in its cluster.
      expect(normalizeQuoteV1('\uAC00\u11A8'), '\uAC01');
      expect(normalizeQuoteV1('\u1100\u1161\u11A8'), '\uAC01');
      for (final cluster in ['\u1100\uAC00', '\uAC00\u1161']) {
        expect(normalizeQuoteV1(cluster), unorm.nfc(cluster));
      }
    });

    test('context keeps the nearest 32 scalars at grapheme boundaries', () {
      const alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      var selector = QuoteSelector.of('selected', alphabet, alphabet);
      expect(selector.prefix, '456789ABCDEFGHIJKLMNOPQRSTUVWXYZ');
      expect(selector.suffix, '0123456789ABCDEFGHIJKLMNOPQRSTUV');

      selector = QuoteSelector.of('selected', '${'x' * 31}é', '');
      expect(selector.prefix, '${'x' * 31}é');

      selector = QuoteSelector.of(
        'selected',
        '👩‍🔬${'x' * 31}',
        '${'x' * 31}👩‍🔬',
      );
      expect(selector.prefix, 'x' * 31);
      expect(selector.suffix, 'x' * 31);

      selector = QuoteSelector.of(
        'selected',
        'discarded ${'p' * 31}',
        '${'s' * 31} discarded',
      );
      expect(selector.prefix, 'p' * 31);
      expect(selector.suffix, 's' * 31);
    });

    test('context cuts Unicode 17 clusters at the 32-scalar boundary', () {
      // U+1ACF is Extend from Unicode 17 (unassigned in 16), so a + U+1ACF
      // is one cluster that does not fit beside 31 other scalars.
      final selector = QuoteSelector.of(
        'selected',
        'a\u1ACF${'x' * 31}',
        '${'x' * 31}a\u1ACF',
      );
      expect(selector.prefix, 'x' * 31);
      expect(selector.suffix, 'x' * 31);
      final fits = QuoteSelector.of('selected', 'a\u1ACF${'x' * 30}', '');
      expect(fits.prefix, 'a\u1ACF${'x' * 30}');
    });

    test('a selector from text reads a bounded window of context', () {
      final text = '${'a' * 5000} middle ${'b' * 5000}'.runes.toList();

      final selector = QuoteSelector.fromText(text, 5001, 5007);

      expect(selector.original, 'middle');
      expect(selector.prefix, 'a' * 32);
      expect(selector.suffix, 'b' * 32);
    });

    test('quotes are bounded and never empty', () {
      expect(
        QuoteSelector.of('x' * maxQuoteScalars, '', '').exact,
        hasLength(maxQuoteScalars),
      );
      expect(
        () => QuoteSelector.of('x' * (maxQuoteScalars + 1), '', ''),
        throwsA(isA<CoreException>()),
      );
      expect(
        () => QuoteSelector.of(' ­\r\n', '', ''),
        throwsA(isA<CoreException>()),
      );
      expect(
        () => QuoteSelector.fromText('abc'.runes.toList(), 2, 2),
        throwsA(isA<CoreException>()),
      );
      // U+0958 is composition-excluded: NFC expands it to two scalars.
      expect(
        () => QuoteSelector.of('\u0958' * 32769, '', ''),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        QuoteSelector.of('\u0958' * 32768, '', '').exact.runes,
        hasLength(maxQuoteScalars),
      );
      expect(
        () => QuoteSelector.of(
          'quote',
          'x' * (maxQuoteContextInputScalars + 1),
          '',
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        () => QuoteSelector.fromText('abc'.runes.toList(), 1, 4),
        throwsA(isA<CoreException>()),
      );
    });

    test('scalar offsets convert explicitly to UTF-16 units', () {
      expect(scalarRangeToUtf16('A😀é', 1, 3), (start: 1, end: 4));
      expect(scalarRangeToUtf16('A😀é', 3, 3), (start: 4, end: 4));
      expect(
        () => scalarRangeToUtf16('short', 4, 3),
        throwsA(isA<CoreException>()),
      );
      expect(
        () => scalarRangeToUtf16('short', 0, 6),
        throwsA(isA<CoreException>()),
      );
    });
  });

  group('selector validation', () {
    QuoteSelector selector({
      String? original,
      String exact = 'quote',
      String prefix = '',
      String suffix = '',
    }) => QuoteSelector(
      original: original,
      exact: exact,
      prefix: prefix,
      suffix: suffix,
    );

    test('resolution rejects selectors QuoteSelector.of cannot build', () {
      for (final invalid in [
        selector(exact: ''),
        // Within twice the limit in UTF-16 units, over it in scalars.
        selector(prefix: 'p' * (maxContextScalars + 1)),
        selector(suffix: 's' * (maxContextScalars + 1)),
        selector(exact: 'q' * (maxQuoteScalars + 1)),
        selector(original: 'o' * (maxQuoteScalars + 1)),
        // Not normalized.
        selector(exact: 'a  b'),
        selector(exact: 'Cafe\u0301'),
        selector(prefix: ' p'),
        selector(suffix: 'x\u00ADy'),
        // The original does not normalize to the exact quote.
        selector(original: 'a', exact: 'b'),
      ]) {
        expect(
          () => resolveTextAnchor('quote a b', 0, 5, invalid),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$invalid',
        );
        expect(
          () => AnchorText('quote').resolveExact(0, 5, invalid),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$invalid',
        );
        expect(
          () => AnchorText('quote').resolve(0, 5, invalid),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '$invalid',
        );
      }
      expect(
        resolveTextAnchor(
          'a Café',
          2,
          6,
          selector(original: 'Cafe\u0301', exact: 'Café'),
        ),
        const ResolvedAnchor(_exact, 2, 6),
      );
    });

    test('oversized clusters are rejected before normalization', () {
      // Combining marks alone are one cluster, already normalized, and within
      // the scalar limits; NFC would take quadratic time over them.
      final marks = '\u0301' * maxQuoteScalars;
      final watch = Stopwatch()..start();
      for (final invalid in [
        selector(exact: marks),
        selector(original: marks, exact: 'x'),
        selector(exact: 'x', prefix: '\u0301' * maxContextScalars * 2),
        selector(exact: 'x', suffix: '\u0301' * maxContextScalars * 2),
      ]) {
        expect(
          () => resolveTextAnchor('x', 0, 1, invalid),
          throwsCoreError(CoreErrorKind.invalidRequest),
          reason: '${invalid.exact.length} ${invalid.original?.length}',
        );
        expect(
          () => AnchorText('x').resolve(0, 1, invalid),
          throwsCoreError(CoreErrorKind.invalidRequest),
        );
      }
      expect(
        () => QuoteSelector.of(marks, '', ''),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        () => QuoteSelector.of('x', marks, ''),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(
        () => QuoteSelector.of('x', '', 'a$marks'),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));

      // A cluster at the ceiling is still accepted, in a quote, its context
      // and the text it resolves against.
      final ceiling = '\u0301' * maxAnchorGraphemeScalars;
      final text = '$ceiling x';
      final built = QuoteSelector.of(ceiling, ceiling, '\n$ceiling');
      expect(built.exact, ceiling);
      expect(
        resolveTextAnchor(text, 0, maxAnchorGraphemeScalars, built),
        const ResolvedAnchor(_exact, 0, maxAnchorGraphemeScalars),
      );
      expect(
        resolveTextAnchor(text, 0, 0, selector(exact: ceiling)),
        const ResolvedAnchor(_recovered, 0, maxAnchorGraphemeScalars),
      );
      expect(
        () => QuoteSelector.of('$ceiling\u0301', '', ''),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );

      // Cancellation wins over validating the selector.
      expect(
        () => resolveTextAnchor(
          'x',
          0,
          1,
          selector(exact: marks),
          budget: ResolutionBudget(maxAnchorResolutionWork, () => true),
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      expect(
        () => AnchorText('x').resolveExact(
          0,
          1,
          selector(exact: marks),
          budget: ResolutionBudget(maxAnchorResolutionWork, () => true),
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
    });

    test('supplementary-plane selectors at their limits resolve', () {
      final exact = '😀' * maxQuoteScalars;
      final context = '🇯' * maxContextScalars;
      final quote = selector(
        original: exact,
        exact: exact,
        prefix: '𝒜' * maxContextScalars,
        suffix: '😀' * maxContextScalars,
      );
      final text =
          '${'𝒜' * maxContextScalars}$exact${'😀' * maxContextScalars}';
      expect(
        resolveTextAnchor(text, 32, 32 + maxQuoteScalars, quote),
        const ResolvedAnchor(_exact, 32, 32 + maxQuoteScalars),
      );
      final built = QuoteSelector.of(exact, '$context$context', '😀' * 40);
      expect(built.exact, exact);
      expect(built.prefix.runes, hasLength(maxContextScalars));
      expect(built.suffix, '😀' * maxContextScalars);
    });

    test('NFC expansion is bounded at construction', () {
      // U+0344 decomposes into U+0308 U+0301: 512 of them normalize to one
      // cluster at the ceiling, 513 to one over it.
      final atLimit = QuoteSelector.of('\u0344' * 512, '', '');
      expect(atLimit.exact, '\u0308\u0301' * 512);
      expect(graphemeClusters(atLimit.exact).single.runes, hasLength(1024));
      checkQuoteSelector(atLimit);
      expect(
        resolveTextAnchor('\u0344' * 512, 0, 512, atLimit),
        const ResolvedAnchor(_exact, 0, 512),
      );
      for (final over in [
        '\u0344' * 513,
        'q${'\u0344' * 512}',
        '\u0F73' * 1000,
        '\u0958${'\u0344' * 512}',
      ]) {
        expect(
          () => QuoteSelector.of(over, '', ''),
          throwsCoreError(CoreErrorKind.limitExceeded),
          reason: '${over.runes.length}',
        );
      }
      // Context is cut to its 32 scalars, so an expanded cluster there is
      // dropped rather than kept.
      final context = QuoteSelector.of('x', '\u0344' * 513, '\u0344' * 513);
      expect((context.prefix, context.suffix), ('', ''));
      checkQuoteSelector(context);
    });

    test('every selector QuoteSelector.of builds passes validation', () {
      const pieces = [
        'a',
        'e\u0301',
        '\u0301',
        '\u0316',
        '\u0344',
        '\u0F73',
        '\u0F75',
        '\u0F81',
        '\u0958',
        '\u1F82',
        '\u212B',
        '\u1100',
        '\u1161',
        '\u11A8',
        '\uAC00',
        '\u0915\u094D',
        '\u200D',
        '😀',
        '🇯',
        '𝒜',
        '\u{1D15E}',
        '\u{1611E}',
        ' ',
        '\r\n',
        '\r',
        '\u00AD',
        '\u3000',
        'が',
        '\u3099',
      ];
      final random = Random(158);
      final mixed = [
        for (var index = 0; index < 300; index++)
          [
            for (var part = random.nextInt(48); part >= 0; part--)
              pieces[random.nextInt(pieces.length)],
          ].join(),
      ];
      final inputs = <String>[
        for (final piece in pieces) ...[
          for (final count in [1, 2, 511, 512, 513, 1024]) piece * count,
          'a${piece * 512}',
        ],
        ...mixed,
      ];
      var built = 0;
      for (var index = 0; index < inputs.length; index++) {
        final selected = inputs[index];
        final before = mixed[(index * 7 + 3) % mixed.length];
        final after = mixed[(index * 13 + 5) % mixed.length];
        final QuoteSelector quote;
        try {
          quote = QuoteSelector.of(selected, before, after);
        } on CoreException catch (error) {
          // Only limits, or a quote that normalizes to nothing.
          final reason = selected.runes.map((r) => r.toRadixString(16));
          if (error.kind == CoreErrorKind.invalidRequest) {
            expect(normalizeQuoteV1(selected), isEmpty, reason: '$reason');
          } else {
            expect(error.kind, CoreErrorKind.limitExceeded, reason: '$reason');
          }
          continue;
        }
        built++;
        expect(
          () => checkQuoteSelector(quote, kind: CoreErrorKind.malformed),
          returnsNormally,
          reason: '$quote',
        );
      }
      expect(built, greaterThan(inputs.length ~/ 2));
    });

    test('normalization work is bounded across the fields of a selector', () {
      // Each cluster is within the ceiling (its base composes with none of
      // its marks, and the spaces stay between clusters) and distinct, since
      // an operation normalizes a repeated cluster once; together they need
      // more NFC work than one operation may spend.
      String clusters(int first) => [
        for (var index = first; index < first + 6; index++)
          'q${'\u0F73' * (maxQuoteGraphemeScalars - 1 - index)}',
      ].join(' ');
      final marks = 'x${'\u0301' * (maxQuoteGraphemeScalars - 1)}';
      final normalized = [
        for (var index = 0; index < 16; index++)
          'x${'\u0301' * (maxQuoteGraphemeScalars - 1 - index)}',
      ].join(' ');
      final watch = Stopwatch()..start();
      expect(
        () => QuoteSelector.of('x', clusters(0), clusters(6)),
        throwsCoreError(CoreErrorKind.limitExceeded, _workLimit),
      );
      for (final quote in [
        QuoteSelector(
          original: null,
          exact: normalized,
          prefix: '',
          suffix: '',
        ),
        QuoteSelector(
          original: normalized,
          exact: normalized,
          prefix: '',
          suffix: '',
        ),
      ]) {
        // Running out of work is reported as such, never as an invalid or
        // malformed selector.
        for (final kind in [
          CoreErrorKind.invalidRequest,
          CoreErrorKind.malformed,
        ]) {
          expect(
            () => checkQuoteSelector(quote, kind: kind),
            throwsCoreError(CoreErrorKind.limitExceeded, _workLimit),
          );
        }
        expect(
          () => resolveTextAnchor(normalized, 0, 1, quote),
          throwsCoreError(CoreErrorKind.limitExceeded, _workLimit),
        );
        expect(
          () => AnchorText('x').resolve(0, 1, quote),
          throwsCoreError(CoreErrorKind.limitExceeded, _workLimit),
        );
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

      // Resolution charges the text it normalizes to the same allowance.
      final quote = QuoteSelector.of(marks, '', '');
      final budget = ResolutionBudget();
      expect(
        () => resolveTextAnchor(normalized, 0, 0, quote, budget: budget),
        throwsCoreError(CoreErrorKind.limitExceeded, _workLimit),
      );
      expect(budget.normalization, lessThan(0));
      expect(
        resolveTextAnchor('$marks x', 0, 0, quote),
        const ResolvedAnchor(_recovered, 0, maxQuoteGraphemeScalars),
      );
    });

    test('every distinct short cluster is charged; repeats are not', () {
      // Each scalar is a cluster of its own the normalizer must see, and
      // each costs a call however short it is.
      final selected = String.fromCharCodes([
        for (var index = 0; index < 0x10000; index++) 0x20000 + index,
      ]);
      final before = String.fromCharCodes([
        for (var index = 0; index < 0x10000; index++) 0x30000 + index,
      ]);
      expect(
        0x20000 * quoteNormalizationCost(1),
        greaterThan(maxQuoteNormalizationWork),
      );
      final watch = Stopwatch()..start();
      expect(
        () => QuoteSelector.of(selected, before, ''),
        throwsCoreError(CoreErrorKind.limitExceeded, _workLimit),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

      // Ordinary text repeats its clusters, however long it is: every Yi
      // syllable, many times over, is charged once per syllable.
      final yi = String.fromCharCodes([
        for (var index = 0; index < 8 * 1165; index++) 0xa000 + index % 1165,
      ]);
      final budget = ResolutionBudget();
      expect(
        resolveTextAnchor(
          yi,
          0,
          0,
          QuoteSelector.of('x', '', ''),
          budget: budget,
        ),
        const ResolvedAnchor(AnnotationResolution.orphaned),
      );
      expect(
        budget.normalization,
        maxQuoteNormalizationWork - 1165 * quoteNormalizationCost(1),
      );
    });

    test('clusters sharing one hash code do not slow repeated lookups', () {
      // Twelve pairs of mark sequences, each pair giving `String.hashCode`
      // the same state, make 4,096 distinct 37-scalar clusters after `q`
      // that share one hash code. After `r` they do not collide. The
      // collisions are particular to the Dart VM's string hash (3.11); if an
      // SDK update breaks the first expectation, rebuild the pairs for it.
      const pairs = [
        ['\u0307\u031A\u034F', '\u0307\u0341\u0300'],
        ['\u0302\u0308\u0353', '\u0302\u031B\u0300'],
        ['\u030F\u0307\u0300', '\u030F\u032E\u036E'],
        ['\u030F\u031A\u033B', '\u030F\u034D\u0300'],
        ['\u0303\u034D\u0300', '\u0303\u034E\u0320'],
        ['\u0304\u0312\u0337', '\u0304\u034B\u0300'],
        ['\u0304\u0321\u0300', '\u0304\u033B\u033E'],
        ['\u0301\u0306\u0300', '\u0301\u031B\u0339'],
        ['\u030E\u0317\u0300', '\u030E\u0340\u036A'],
        ['\u030E\u0332\u0339', '\u030E\u0347\u0300'],
        ['\u031A\u032F\u033F', '\u031A\u033C\u0300'],
        ['\u0306\u0317\u0360', '\u0306\u0348\u0300'],
      ];
      List<String> clusters(String base) {
        var keys = [base];
        for (final pair in pairs) {
          keys = [
            for (final prefix in keys)
              for (final suffix in pair) '$prefix$suffix',
          ];
        }
        return keys;
      }

      final colliding = clusters('q');
      final control = clusters('r');
      expect(colliding.map((key) => key.hashCode).toSet(), hasLength(1));
      expect(control.map((key) => key.hashCode).toSet(), hasLength(4096));

      // Every cluster is normalized and charged once, then the last one is
      // looked up 100,000 more times, uncharged.
      Duration time(List<String> keys) {
        final text = '${keys.join(' ')} ${'${keys.last} ' * 100000}';
        final watch = Stopwatch()..start();
        expect(
          resolveTextAnchor(text, 0, 0, QuoteSelector.of('x', '', '')),
          const ResolvedAnchor(AnnotationResolution.orphaned),
        );
        return watch.elapsed;
      }

      // Interleaved samples, compared by median, so one pause in either
      // family does not decide the result.
      time(control);
      final controlRuns = <Duration>[];
      final collidingRuns = <Duration>[];
      for (var run = 0; run < 3; run++) {
        controlRuns.add(time(control));
        collidingRuns.add(time(colliding));
      }
      Duration median(List<Duration> runs) => (runs..sort())[1];
      expect(median(collidingRuns), lessThan(median(controlRuns) * 2));
    });
  });

  group('anchor resolution', () {
    test('distinguishes exact and unique recovery', () {
      final quote = QuoteSelector.of('Café\ttext', 'lead ', ' tail');

      expect(
        _resolve('lead Café\ttext tail', 5, 15, quote),
        const ResolvedAnchor(_exact, 5, 15),
      );
      expect(
        _resolve('inserted lead Café text tail', 5, 15, quote),
        const ResolvedAnchor(_recovered, 14, 23),
      );
      // Normalization alone keeps the stored range exact.
      expect(
        _resolve('lead Café  text tail', 5, 15, quote),
        const ResolvedAnchor(_exact, 5, 15),
      );
    });

    test('uses context without guessing repeated quotes', () {
      expect(
        _resolve(
          'target noise alpha target omega',
          1,
          7,
          QuoteSelector.of('target', 'alpha ', ' omega'),
        ),
        const ResolvedAnchor(_recovered, 19, 25),
      );
      expect(
        _resolve('target target', 1, 7, QuoteSelector.of('target', '', '')),
        const ResolvedAnchor(_ambiguous),
      );
      expect(
        _resolve('aaa', 1, 2, QuoteSelector.of('aa', '', '')).resolution,
        _ambiguous,
      );
    });

    test('reports missing quotes as orphaned', () {
      expect(
        _resolve('other text', 0, 7, QuoteSelector.of('missing', '', '')),
        const ResolvedAnchor(_orphaned),
      );
    });

    test('preserves the profile at source boundaries', () {
      expect(
        _resolve('xe­́', 0, 1, QuoteSelector.of('é', '', '')),
        const ResolvedAnchor(_recovered, 1, 4),
      );
      expect(
        _resolve('x👩‍💻', 0, 1, QuoteSelector.of('👩', '', '')),
        const ResolvedAnchor(_orphaned),
      );
      expect(
        _resolve('x ́', 0, 1, QuoteSelector.of(' ́', '', '')),
        const ResolvedAnchor(_recovered, 1, 3),
      );
      expect(
        _resolve('a\r\nb', 9, 9, QuoteSelector.of('a\nb', '', '')),
        const ResolvedAnchor(_recovered, 0, 4),
      );
    });

    test('handles grapheme clusters anywhere in the text', () {
      for (final selected in ['😀', '👩‍💻', '🇷🇸', 'क्‍ष']) {
        final prefix = 'a' * 1023;
        final start = prefix.runes.length;
        final end = start + selected.runes.length;
        expect(
          _resolve(
            '$prefix$selected',
            0,
            1,
            QuoteSelector.of(selected, '', ''),
          ),
          ResolvedAnchor(_recovered, start, end),
          reason: selected,
        );
      }
      expect(
        _resolve(
          '${'a' * 1023}👩‍💻',
          0,
          1,
          QuoteSelector.of('💻', '', ''),
        ).resolution,
        _orphaned,
      );
      expect(
        _resolve('${'a' * 1023}🇷🇸🇮', 0, 1, QuoteSelector.of('🇷🇸', '', '')),
        const ResolvedAnchor(_recovered, 1023, 1025),
      );
    });

    test('clusters by Unicode 17', () {
      // U+1ACF joins the a before it from Unicode 17, so a alone is gone.
      expect(
        _resolve('xa\u1ACF', 0, 1, QuoteSelector.of('a', '', '')),
        const ResolvedAnchor(_orphaned),
      );
      expect(
        _resolve('xa\u1ACF', 0, 1, QuoteSelector.of('a\u1ACF', '', '')),
        const ResolvedAnchor(_recovered, 1, 3),
      );
      // A Khmer conjunct (GB9c from Unicode 17) is one cluster.
      expect(
        _resolve(
          'x\u179F\u17D2\u178F',
          0,
          1,
          QuoteSelector.of('\u179F\u17D2', '', ''),
        ),
        const ResolvedAnchor(_orphaned),
      );
    });

    test('rejects an oversized cluster with bounded work', () {
      // One cluster of a hundred million scalars: a and combining acutes.
      final scalars = _CountingScalars(
        100000000,
        (index) => index == 0 ? 0x61 : 0x0301,
      );
      final budget = ResolutionBudget();
      expect(
        () => forEachBoundedGrapheme(scalars, budget, (_, _) {}),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      expect(scalars.reads, maxAnchorGraphemeScalars + 1);
      expect(
        maxAnchorResolutionWork - budget.remaining,
        maxAnchorGraphemeScalars + 1,
      );

      // A cluster at the ceiling is accepted, and cancellation is polled
      // while one long cluster is read.
      final clusters = <(int, int)>[];
      forEachBoundedGrapheme(
        [0x61, for (var i = 1; i < maxAnchorGraphemeScalars; i++) 0x0301, 0x62],
        ResolutionBudget(),
        (start, end) => clusters.add((start, end)),
      );
      expect(clusters, [
        (0, maxAnchorGraphemeScalars),
        (maxAnchorGraphemeScalars, maxAnchorGraphemeScalars + 1),
      ]);
      var polls = 0;
      expect(
        () => forEachBoundedGrapheme(
          _CountingScalars(5000, (index) => index == 0 ? 0x61 : 0x0301),
          ResolutionBudget(maxAnchorResolutionWork, () => ++polls > 0),
          (_, _) {},
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
    });

    test('observes cancellation and work limits', () {
      var checks = 0;
      expect(
        () => AnchorText(
          'x' * 4096,
          budget: ResolutionBudget(maxAnchorResolutionWork, () => ++checks > 1),
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );

      final text = AnchorText('different');
      expect(
        () => text.resolve(
          0,
          1,
          QuoteSelector.of('missing', '', ''),
          budget: ResolutionBudget(0),
        ),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('bounds adversarial prefixes and graphemes', () {
      final text = AnchorText('a' * 32768);
      final quote = QuoteSelector.of('a' * 16384, 'z', '');
      expect(text.resolve(0, 1, quote).resolution, _ambiguous);

      expect(
        () => AnchorText(
          'e${'́' * 1025}',
        ).resolve(0, 1, QuoteSelector.of('missing', '', '')),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );

      var checks = 0;
      expect(
        () => text.resolve(
          0,
          1,
          quote,
          budget: ResolutionBudget(maxAnchorResolutionWork, () => ++checks > 1),
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
    });

    test('an exact anchor does not scan unrelated graphemes', () {
      final text = 'ordinary e${'́' * 1025}';
      expect(
        _resolve(text, 0, 8, QuoteSelector.of('ordinary', '', '')),
        const ResolvedAnchor(_exact, 0, 8),
      );
      // A quote holding the oversized cluster is never built.
      expect(
        () => QuoteSelector.of('e${'́' * 1025}', '', ''),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('rejects empty selectors and survives large stale ranges', () {
      expect(
        () => _resolve(
          'quote',
          0,
          5,
          const QuoteSelector(
            original: null,
            exact: '',
            prefix: '',
            suffix: '',
          ),
        ),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      final text = 'a' * 131072;
      expect(
        _resolve(text, 0, text.length, QuoteSelector.of('missing', '', '')),
        const ResolvedAnchor(_orphaned),
      );
    });
  });
}
