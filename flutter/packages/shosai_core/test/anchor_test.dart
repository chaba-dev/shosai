import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

ResolvedAnchor _resolve(String text, int start, int end, QuoteSelector quote) =>
    resolveTextAnchor(text, start, end, quote);

const _exact = AnnotationResolution.exact;
const _recovered = AnnotationResolution.recovered;
const _ambiguous = AnnotationResolution.ambiguous;
const _orphaned = AnnotationResolution.orphaned;

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
      final oversized = 'e${'́' * 1025}';
      expect(
        _resolve(text, 9, 1035, QuoteSelector.of(oversized, '', '')),
        const ResolvedAnchor(_exact, 9, 1035),
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
