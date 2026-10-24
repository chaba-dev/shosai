/// The quote profile annotations are matched by (RFD 16): normalized quote
/// text with bounded surrounding context.
library;

import 'dart:collection';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../errors.dart';
import 'graphemes.dart';

/// The name stored with every quote normalized by [normalizeQuoteV1].
const quoteProfileV1 = 'shosai-quote-v1';

/// Longest annotation quote, in Unicode scalars.
const maxQuoteScalars = 65536;

/// Longest prefix or suffix context, in Unicode scalars.
const maxContextScalars = 32;

/// Longest text before or after a selection [QuoteSelector.of] accepts, in
/// Unicode scalars.
const maxQuoteContextInputScalars = 65536;

/// How much text around a selection [QuoteSelector.fromText] reads to build
/// its context, in Unicode scalars.
const quoteContextWindowScalars = 1024;

/// Longest grapheme cluster the quote-v1 profile normalizes, in Unicode
/// scalars, before and after normalization. NFC's cost grows quadratically
/// with a cluster's length, so no longer cluster ever reaches it.
const maxQuoteGraphemeScalars = 1024;

/// Normalization work one [QuoteSelector.of] call, one selector check, one
/// resolution pass or one annotation listing may spend, in the units
/// [quoteNormalizationCost] charges.
///
/// `unorm_dart` 0.3.2 normalizes a cluster in time quadratic in its length,
/// about 15 to 25 ns per unit here, after a fixed 1.5 to 2.5 µs per call.
/// An operation normalizes each distinct cluster once and is charged only
/// then, so the allowance stops any input within about a third of a second:
/// it covers seven clusters at [maxQuoteGraphemeScalars] or about 128,000
/// distinct single-scalar clusters, while ordinary text, whatever its
/// length, repeats a few thousand distinct clusters at most.
const maxQuoteNormalizationWork = 32 * 1024 * 1024;

/// The work units normalizing one distinct grapheme cluster of [scalars]
/// Unicode scalars costs: a fixed charge for the call plus a quadratic term,
/// a weighting calibrated against the timings above rather than a bound on
/// how far decomposition expands a cluster.
int quoteNormalizationCost(int scalars) => 256 + 4 * scalars * scalars;

/// The normalization work left to an operation, charged before each distinct
/// grapheme cluster is normalized, and the clusters it normalized. Not
/// exported.
final class NormalizationAllowance {
  NormalizationAllowance([this.remaining = maxQuoteNormalizationWork]);

  int remaining;

  /// The NFC form of every cluster normalized so far. Bounded: each entry
  /// was charged at least [quoteNormalizationCost] of one scalar.
  ///
  /// Looked up by comparison, not by hash: `String.hashCode` is unsalted, so
  /// crafted clusters sharing one hash would make every uncharged lookup in a
  /// hash map walk all of them.
  final _composed = SplayTreeMap<String, String>();

  /// Whether a charge has failed; every later charge fails too.
  bool get isExhausted => remaining < 0;

  /// Charge normalizing a cluster of [scalars] Unicode scalars. Throws
  /// [CoreErrorKind.limitExceeded] when the allowance cannot cover it.
  void charge(int scalars) {
    remaining -= quoteNormalizationCost(scalars);
    if (remaining < 0) {
      throw const CoreException.limitExceeded(
        'Normalizing annotation quotes exceeded its work limit.',
      );
    }
  }
}

/// Normalize [value] by the quote-v1 profile: drop soft hyphens, turn CR
/// and CRLF into LF, compose each grapheme cluster to NFC, and collapse runs
/// of whitespace into one space without leading or trailing whitespace.
///
/// Throws [CoreErrorKind.limitExceeded] when a grapheme cluster exceeds
/// [maxQuoteGraphemeScalars], before normalizing any of it, or when the
/// clusters need more than [maxQuoteNormalizationWork] to normalize.
///
/// The profile pins Unicode 17.0.0. Grapheme clusters come from the
/// package's own Unicode 17.0.0 segmenter ([GraphemeBreaker]); NFC comes
/// from `unorm_dart` 0.3.2, pinned exactly because it carries Unicode 17.0.0
/// data (0.3.3 moved to Unicode 18). `test/unicode_test.dart` fails if either
/// changes version.
String normalizeQuoteV1(String value) =>
    normalizeQuoteText(value, allowance: NormalizationAllowance());

/// [normalizeQuoteV1], charging [spend] for every scalar it reads and
/// writes and [allowance] for every cluster it normalizes. Not exported.
String normalizeQuoteText(
  String value, {
  required NormalizationAllowance allowance,
  void Function(int units)? spend,
}) {
  final input = profileInput(value).runes.toList();
  spend?.call(input.length);
  final normalized = <int>[];
  var pendingSpace = false;
  forEachQuoteCluster(input, spend: spend, (start, end) {
    for (final scalar in nfcCluster(input, start, end, allowance)) {
      spend?.call(1);
      if (isQuoteWhitespace(scalar)) {
        pendingSpace = normalized.isNotEmpty;
      } else {
        if (pendingSpace) {
          normalized.add(0x20);
          pendingSpace = false;
        }
        normalized.add(scalar);
      }
    }
  });
  return String.fromCharCodes(normalized);
}

/// Call [visit] with the half-open range of every grapheme cluster of
/// [scalars], each at most [maxQuoteGraphemeScalars] scalars long, charging
/// [spend] one unit per scalar read. Not exported.
///
/// Clusters are found one scalar at a time ([GraphemeBreaker] carries the
/// ZWJ, regional-indicator and conjunct state across them), so an oversized
/// cluster is rejected with [CoreErrorKind.limitExceeded] after reading
/// [maxQuoteGraphemeScalars] + 1 of its scalars, before any of it is
/// visited.
void forEachQuoteCluster(
  List<int> scalars,
  void Function(int start, int end) visit, {
  void Function(int units)? spend,
}) {
  final breaker = GraphemeBreaker();
  var start = 0;
  for (var index = 0; index < scalars.length; index++) {
    spend?.call(1);
    if (breaker.next(scalars[index])) {
      if (index > start) visit(start, index);
      start = index;
    } else if (index - start >= maxQuoteGraphemeScalars) {
      throw const CoreException.limitExceeded(
        'A grapheme cluster exceeds $maxQuoteGraphemeScalars Unicode scalars.',
      );
    }
  }
  if (scalars.length > start) visit(start, scalars.length);
}

/// The NFC form of the grapheme cluster [start]..[end] of [scalars],
/// charging [allowance] before normalizing it unless [allowance] already
/// holds it. Not exported.
///
/// Every quote-v1 normalization reaches the normalizer through here, so the
/// allowance bounds it however the cluster was found.
Iterable<int> nfcCluster(
  List<int> scalars,
  int start,
  int end,
  NormalizationAllowance allowance,
) {
  if (end - start == 1 && scalars[start] < 0x0300) return [scalars[start]];
  for (var index = start; index < end; index++) {
    if (!_alreadyComposed(scalars[index])) {
      final cluster = String.fromCharCodes(scalars, start, end);
      final known = allowance._composed[cluster];
      if (known != null) return known.runes;
      allowance.charge(end - start);
      return (allowance._composed[cluster] = unorm.nfc(cluster)).runes;
    }
  }
  return scalars.getRange(start, end);
}

/// [value] with soft hyphens removed and line breaks unified to LF.
String profileInput(String value) {
  if (!value.contains('­') && !value.contains('\r')) return value;
  return value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('­', '');
}

/// Scalars that are NFC-stable on their own and compose with no other
/// scalar of this set (Latin, kana, CJK ideographs and precomposed Hangul
/// syllables), so clusters of only them skip the normalizer. A syllable
/// composes only with a following conjoining jamo, which is not in the set.
bool _alreadyComposed(int scalar) =>
    scalar < 0x0300 ||
    (scalar >= 0x3041 && scalar <= 0x3096) ||
    (scalar >= 0x30a1 && scalar <= 0x30fa) ||
    (scalar >= 0x4e00 && scalar <= 0x9fff) ||
    (scalar >= 0xac00 && scalar <= 0xd7a3);

/// Whitespace in the quote-v1 profile (the Unicode White_Space property).
bool isQuoteWhitespace(int scalar) =>
    (scalar >= 0x09 && scalar <= 0x0d) ||
    scalar == 0x20 ||
    scalar == 0x85 ||
    scalar == 0xa0 ||
    scalar == 0x1680 ||
    (scalar >= 0x2000 && scalar <= 0x200a) ||
    scalar == 0x2028 ||
    scalar == 0x2029 ||
    scalar == 0x202f ||
    scalar == 0x205f ||
    scalar == 0x3000;

/// The selected text of an annotation and the context around it, normalized
/// by the quote-v1 profile.
final class QuoteSelector {
  const QuoteSelector({
    required this.original,
    required this.exact,
    required this.prefix,
    required this.suffix,
  });

  /// Build a selector from the selected text and the text before and after
  /// it. Only the [maxContextScalars] scalars of context nearest the
  /// selection are kept, cut at grapheme boundaries.
  ///
  /// Throws [CoreErrorKind.limitExceeded] when the text exceeds its scalar
  /// limits, holds a grapheme cluster over [maxQuoteGraphemeScalars] before
  /// or after normalization, or needs more than [maxQuoteNormalizationWork]
  /// to normalize.
  factory QuoteSelector.of(String selected, String before, String after) {
    if (_exceeds(selected, maxQuoteScalars)) {
      throw const CoreException.limitExceeded(
        'An annotation quote exceeds $maxQuoteScalars Unicode scalars.',
      );
    }
    if (_exceeds(before, maxQuoteContextInputScalars) ||
        _exceeds(after, maxQuoteContextInputScalars)) {
      throw const CoreException.limitExceeded(
        'An annotation quote context exceeds $maxQuoteContextInputScalars '
        'Unicode scalars.',
      );
    }
    final allowance = NormalizationAllowance();
    final exact = normalizeQuoteText(selected, allowance: allowance);
    if (exact.isEmpty) {
      throw const CoreException.invalidRequest(
        'An annotation quote must not be empty.',
      );
    }
    // NFC can expand: U+0958 decomposes into two scalars.
    if (_exceeds(exact, maxQuoteScalars)) {
      throw const CoreException.limitExceeded(
        'An annotation quote exceeds $maxQuoteScalars Unicode scalars once '
        'normalized.',
      );
    }
    // NFC can lengthen a cluster too: U+0344 decomposes into two marks, so
    // 513 of them normalize to one cluster of 1026 scalars, which
    // checkQuoteSelector would reject. The normalized clusters are only
    // segmented here, never normalized again.
    try {
      forEachQuoteCluster(exact.runes.toList(), (_, _) {});
    } on CoreException catch (error) {
      if (error.kind != CoreErrorKind.limitExceeded) rethrow;
      throw const CoreException.limitExceeded(
        'An annotation quote has a grapheme cluster over '
        '$maxQuoteGraphemeScalars Unicode scalars once normalized.',
      );
    }
    return QuoteSelector(
      original: selected,
      exact: exact,
      prefix: _context(before, allowance, prefix: true),
      suffix: _context(after, allowance, prefix: false),
    );
  }

  /// Build a selector for the half-open scalar range [start]..[end] of
  /// [scalars], reading at most [quoteContextWindowScalars] of context on
  /// each side.
  factory QuoteSelector.fromText(List<int> scalars, int start, int end) {
    if (start < 0 || start >= end || end > scalars.length) {
      throw const CoreException.invalidRequest(
        'The annotation range is empty or outside the text.',
      );
    }
    if (end - start > maxQuoteScalars) {
      throw const CoreException.limitExceeded(
        'An annotation quote exceeds $maxQuoteScalars Unicode scalars.',
      );
    }
    final beforeStart = start > quoteContextWindowScalars
        ? start - quoteContextWindowScalars
        : 0;
    final afterEnd = scalars.length - end > quoteContextWindowScalars
        ? end + quoteContextWindowScalars
        : scalars.length;
    return QuoteSelector.of(
      String.fromCharCodes(scalars, start, end),
      String.fromCharCodes(scalars, beforeStart, start),
      String.fromCharCodes(scalars, end, afterEnd),
    );
  }

  /// The selected text exactly as it was, when known.
  final String? original;

  /// The selected text normalized by the quote-v1 profile; never empty.
  final String exact;
  final String prefix;
  final String suffix;

  @override
  bool operator ==(Object other) =>
      other is QuoteSelector &&
      other.original == original &&
      other.exact == exact &&
      other.prefix == prefix &&
      other.suffix == suffix;

  @override
  int get hashCode => Object.hash(original, exact, prefix, suffix);

  @override
  String toString() => 'QuoteSelector($exact, $prefix, $suffix)';
}

bool _exceeds(String value, int scalars) =>
    value.length > scalars && value.runes.length > scalars;

/// Throw unless [quote] is a selector [QuoteSelector.of] could have built:
/// a non-empty exact quote and contexts within their scalar limits, each
/// already normalized, and an original quote, when present, that normalizes
/// to the exact one.
///
/// Throws [kind]: [CoreErrorKind.invalidRequest] for a caller's selector,
/// [CoreErrorKind.malformed] for a stored one, including when a field holds
/// a grapheme cluster over [maxQuoteGraphemeScalars] (which is never
/// normalized). Normalizes every field once, so call it once per selector,
/// not per candidate.
///
/// Throws [CoreErrorKind.limitExceeded], whatever [kind] is, when
/// normalizing the fields needs more than [allowance] has left (a fresh
/// [maxQuoteNormalizationWork] by default); pass one allowance to check many
/// selectors within it.
void checkQuoteSelector(
  QuoteSelector quote, {
  CoreErrorKind kind = CoreErrorKind.invalidRequest,
  NormalizationAllowance? allowance,
}) {
  allowance ??= NormalizationAllowance();
  final original = quote.original;
  if (quote.exact.isEmpty ||
      _exceeds(quote.exact, maxQuoteScalars) ||
      _exceeds(quote.prefix, maxContextScalars) ||
      _exceeds(quote.suffix, maxContextScalars) ||
      (original != null && _exceeds(original, maxQuoteScalars))) {
    throw CoreException(
      kind,
      'The annotation quote selector is empty or exceeds its scalar limit.',
    );
  }
  final String exact;
  final String prefix;
  final String suffix;
  final String? normalizedOriginal;
  try {
    exact = normalizeQuoteText(quote.exact, allowance: allowance);
    prefix = normalizeQuoteText(quote.prefix, allowance: allowance);
    suffix = normalizeQuoteText(quote.suffix, allowance: allowance);
    normalizedOriginal = original == null
        ? null
        : normalizeQuoteText(original, allowance: allowance);
  } on CoreException catch (error) {
    // Running out of work is not evidence the selector is invalid.
    if (error.kind != CoreErrorKind.limitExceeded || allowance.isExhausted) {
      rethrow;
    }
    throw CoreException(
      kind,
      'The annotation quote selector has a grapheme cluster over '
      '$maxQuoteGraphemeScalars Unicode scalars.',
    );
  }
  if (exact != quote.exact ||
      prefix != quote.prefix ||
      suffix != quote.suffix) {
    throw CoreException(
      kind,
      'The annotation quote selector is not normalized by $quoteProfileV1.',
    );
  }
  if (original != null && normalizedOriginal != quote.exact) {
    throw CoreException(
      kind,
      'The annotation original and normalized quotes do not match.',
    );
  }
}

String _context(
  String value,
  NormalizationAllowance allowance, {
  required bool prefix,
}) {
  final graphemes = graphemeClusters(
    normalizeQuoteText(value, allowance: allowance),
  );
  var scalars = 0;
  final kept = <String>[];
  for (final grapheme in prefix ? graphemes.reversed : graphemes) {
    scalars += grapheme.runes.length;
    if (scalars > maxContextScalars) break;
    kept.add(grapheme);
  }
  final context = (prefix ? kept.reversed : kept).join();
  return prefix ? _trimSpaces(context, start: true) : _trimSpaces(context);
}

String _trimSpaces(String value, {bool start = false}) {
  if (start) {
    var index = 0;
    while (index < value.length && value.codeUnitAt(index) == 0x20) {
      index++;
    }
    return value.substring(index);
  }
  var end = value.length;
  while (end > 0 && value.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  return value.substring(0, end);
}

/// Convert the half-open Unicode-scalar range [start]..[end] of [text] to
/// UTF-16 code units, as EPUB CFI and Dart string indices count them.
({int start, int end}) scalarRangeToUtf16(String text, int start, int end) {
  if (start < 0 || start > end) {
    throw const CoreException.invalidRequest(
      'The Unicode-scalar range is reversed.',
    );
  }
  int? utf16Start;
  var scalar = 0;
  var unit = 0;
  for (final rune in text.runes) {
    if (scalar == start) utf16Start = unit;
    if (scalar == end) return (start: utf16Start!, end: unit);
    unit += rune > 0xffff ? 2 : 1;
    scalar++;
  }
  if (end != scalar) {
    throw const CoreException.invalidRequest(
      'The Unicode-scalar range exceeds the text.',
    );
  }
  return (start: utf16Start ?? unit, end: unit);
}
