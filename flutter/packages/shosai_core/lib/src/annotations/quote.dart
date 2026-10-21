/// The quote profile annotations are matched by (RFD 6): normalized quote
/// text with bounded surrounding context.
library;

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

/// Normalize [value] by the quote-v1 profile: drop soft hyphens, turn CR
/// and CRLF into LF, compose each grapheme cluster to NFC, and collapse runs
/// of whitespace into one space without leading or trailing whitespace.
///
/// The profile pins Unicode 17.0.0. Grapheme clusters come from the
/// package's own Unicode 17.0.0 segmenter ([graphemeClusters]); NFC comes
/// from `unorm_dart` 0.3.2, pinned exactly because it carries Unicode 17.0.0
/// data (0.3.3 moved to Unicode 18). `test/unicode_test.dart` fails if either
/// changes version.
String normalizeQuoteV1(String value) {
  final normalized = <int>[];
  var pendingSpace = false;
  for (final grapheme in graphemeClusters(profileInput(value))) {
    for (final scalar in nfcGrapheme(grapheme).runes) {
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
  }
  return String.fromCharCodes(normalized);
}

/// [value] with soft hyphens removed and line breaks unified to LF.
String profileInput(String value) {
  if (!value.contains('­') && !value.contains('\r')) return value;
  return value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('­', '');
}

/// The NFC form of one grapheme cluster, skipping the normalizer for text
/// that is already composed (Latin, kana and CJK ideographs).
String nfcGrapheme(String grapheme) {
  for (final unit in grapheme.codeUnits) {
    if (!_alreadyComposed(unit)) return unorm.nfc(grapheme);
  }
  return grapheme;
}

/// UTF-16 units that are NFC-stable on their own and never combine with a
/// neighbour.
bool _alreadyComposed(int unit) =>
    unit < 0x0300 ||
    (unit >= 0x3041 && unit <= 0x3096) ||
    (unit >= 0x30a1 && unit <= 0x30fa) ||
    (unit >= 0x4e00 && unit <= 0x9fff);

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
    final exact = normalizeQuoteV1(selected);
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
    return QuoteSelector(
      original: selected,
      exact: exact,
      prefix: _context(before, prefix: true),
      suffix: _context(after, prefix: false),
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
/// [CoreErrorKind.malformed] for a stored one. Normalizes every field once,
/// so call it once per selector, not per candidate.
void checkQuoteSelector(
  QuoteSelector quote, {
  CoreErrorKind kind = CoreErrorKind.invalidRequest,
}) {
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
  if (normalizeQuoteV1(quote.exact) != quote.exact ||
      normalizeQuoteV1(quote.prefix) != quote.prefix ||
      normalizeQuoteV1(quote.suffix) != quote.suffix) {
    throw CoreException(
      kind,
      'The annotation quote selector is not normalized by $quoteProfileV1.',
    );
  }
  if (original != null && normalizeQuoteV1(original) != quote.exact) {
    throw CoreException(
      kind,
      'The annotation original and normalized quotes do not match.',
    );
  }
}

String _context(String value, {required bool prefix}) {
  final graphemes = graphemeClusters(normalizeQuoteV1(value));
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
