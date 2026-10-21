/// Resolving a stored text anchor against a document's current text.
library;

import 'package:characters/characters.dart';

import '../errors.dart';
import 'quote.dart';

/// Work units one resolution pass may spend (a unit is roughly one scalar
/// visited), so adversarial text cannot stall the reader.
const maxAnchorResolutionWork = 64 * 1024 * 1024;

/// Longest grapheme cluster resolution accepts, in Unicode scalars.
const maxAnchorGraphemeScalars = 1024;

/// How an annotation's anchor matched the current text.
enum AnnotationResolution {
  /// The stored range still holds the quote.
  exact,

  /// The quote was found once (or once in its context) elsewhere.
  recovered,

  /// The quote occurs more than once and the context does not decide.
  ambiguous,

  /// The quote no longer occurs.
  orphaned,
}

/// A resolved anchor: its resolution and, when it has one, the half-open
/// Unicode-scalar range it covers now.
final class ResolvedAnchor {
  const ResolvedAnchor(this.resolution, [this.start, this.end]);

  final AnnotationResolution resolution;
  final int? start;
  final int? end;

  @override
  bool operator ==(Object other) =>
      other is ResolvedAnchor &&
      other.resolution == resolution &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(resolution, start, end);

  @override
  String toString() => 'ResolvedAnchor(${resolution.name}, $start, $end)';
}

/// The work left to a resolution pass, shared by every anchor it resolves.
final class ResolutionBudget {
  ResolutionBudget([
    this.remaining = maxAnchorResolutionWork,
    this.isCancelled,
  ]);

  int remaining;

  /// Polled every few thousand work units.
  final bool Function()? isCancelled;
  var _sinceCheck = 0;

  void spend(int units) {
    remaining -= units;
    if (remaining < 0) {
      throw const CoreException.limitExceeded(
        'Resolving annotations exceeded its work limit.',
      );
    }
    _sinceCheck += units;
    if (_sinceCheck >= 1024) {
      _sinceCheck = 0;
      checkCancelled();
    }
  }

  void checkCancelled() {
    if (isCancelled?.call() ?? false) throw const CoreException.cancelled();
  }
}

/// Resolve [quote], stored at [start]..[end], against [text].
///
/// The stored range wins when it still holds the quote (exactly, or after
/// normalization). Otherwise the quote is searched for in the normalized
/// text: a single occurrence, or a single one whose context matches, is
/// recovered; several are ambiguous and none is orphaned.
ResolvedAnchor resolveTextAnchor(
  String text,
  int start,
  int end,
  QuoteSelector quote, {
  ResolutionBudget? budget,
}) {
  final resolver = AnchorText(text, budget: budget);
  return resolver.resolve(start, end, quote, budget: budget);
}

/// One unit's text, indexed for resolving many anchors against it.
final class AnchorText {
  AnchorText(String text, {ResolutionBudget? budget})
    : _scalars = _scalarsOf(text, budget ?? ResolutionBudget());

  final List<int> _scalars;
  _MappedText? _mapped;

  int get length => _scalars.length;

  /// The anchor at [start]..[end] when it still holds [quote], else null.
  ResolvedAnchor? resolveExact(
    int start,
    int end,
    QuoteSelector quote, {
    ResolutionBudget? budget,
  }) {
    budget ??= ResolutionBudget();
    _checkSelector(quote);
    if (start < 0 || start >= end || end > _scalars.length) return null;
    final selected = String.fromCharCodes(_scalars, start, end);
    budget.spend(end - start);
    if (selected == quote.original ||
        _boundedNormalize(selected, budget) == quote.exact) {
      return ResolvedAnchor(AnnotationResolution.exact, start, end);
    }
    return null;
  }

  /// Resolve [quote], stored at [start]..[end]. Pass an empty range for a
  /// quote captured from other content, which can only be recovered.
  ResolvedAnchor resolve(
    int start,
    int end,
    QuoteSelector quote, {
    ResolutionBudget? budget,
  }) {
    budget ??= ResolutionBudget();
    budget.checkCancelled();
    final exact = resolveExact(start, end, quote, budget: budget);
    if (exact != null) return exact;
    final mapped = _mapped ??= _MappedText.of(_scalars, budget);
    return mapped.search(quote, budget);
  }
}

void _checkSelector(QuoteSelector quote) {
  if (quote.exact.isEmpty ||
      quote.exact.length > 2 * maxQuoteScalars ||
      quote.prefix.length > 2 * maxContextScalars ||
      quote.suffix.length > 2 * maxContextScalars) {
    throw const CoreException.invalidRequest(
      'The annotation quote selector is invalid.',
    );
  }
}

List<int> _scalarsOf(String text, ResolutionBudget budget) {
  final scalars = <int>[];
  for (final scalar in text.runes) {
    budget.spend(1);
    scalars.add(scalar);
  }
  return scalars;
}

/// The grapheme clusters of [value], each at most
/// [maxAnchorGraphemeScalars] scalars long.
Iterable<String> _boundedGraphemes(
  String value,
  ResolutionBudget budget,
) sync* {
  for (final grapheme in value.characters) {
    final scalars = grapheme.runes.length;
    if (scalars > maxAnchorGraphemeScalars) {
      throw const CoreException.limitExceeded(
        'A grapheme cluster exceeds $maxAnchorGraphemeScalars Unicode scalars.',
      );
    }
    budget.spend(scalars);
    yield grapheme;
  }
}

String _boundedNormalize(String value, ResolutionBudget budget) {
  final input = profileInput(value);
  budget.spend(input.length);
  final normalized = <int>[];
  var pendingSpace = false;
  for (final grapheme in _boundedGraphemes(input, budget)) {
    for (final scalar in nfcGrapheme(grapheme).runes) {
      budget.spend(1);
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

/// Normalized text with, for every normalized scalar, the source scalar range
/// (a whole grapheme cluster, or a whole whitespace run) it came from.
final class _MappedText {
  _MappedText(this.text, this.sourceStarts, this.sourceEnds);

  factory _MappedText.of(List<int> source, ResolutionBudget budget) {
    // Profile input: soft hyphens dropped, CR and CRLF become LF, each
    // remembering the source scalars it stands for.
    final input = <int>[];
    final inputStarts = <int>[];
    final inputEnds = <int>[];
    for (var index = 0; index < source.length; index++) {
      budget.spend(1);
      final scalar = source[index];
      if (scalar == 0xad) continue;
      inputStarts.add(index);
      if (scalar == 0x0d) {
        if (index + 1 < source.length && source[index + 1] == 0x0a) index++;
        input.add(0x0a);
      } else {
        input.add(scalar);
      }
      inputEnds.add(index + 1);
    }

    final text = <int>[];
    final starts = <int>[];
    final ends = <int>[];
    int? pendingStart;
    int? pendingEnd;
    var inputIndex = 0;
    for (final grapheme in _boundedGraphemes(
      String.fromCharCodes(input),
      budget,
    )) {
      final length = grapheme.runes.length;
      final sourceStart = inputStarts[inputIndex];
      final sourceEnd = inputEnds[inputIndex + length - 1];
      inputIndex += length;
      for (final scalar in nfcGrapheme(grapheme).runes) {
        budget.spend(1);
        if (isQuoteWhitespace(scalar)) {
          if (text.isNotEmpty) {
            pendingStart ??= sourceStart;
            pendingEnd = sourceEnd;
          }
        } else {
          if (pendingStart != null) {
            text.add(0x20);
            starts.add(pendingStart);
            ends.add(pendingEnd!);
            pendingStart = null;
            pendingEnd = null;
          }
          text.add(scalar);
          starts.add(sourceStart);
          ends.add(sourceEnd);
        }
      }
    }
    return _MappedText(text, starts, ends);
  }

  final List<int> text;
  final List<int> sourceStarts;
  final List<int> sourceEnds;

  ResolvedAnchor search(QuoteSelector quote, ResolutionBudget budget) {
    final pattern = quote.exact.runes.toList();
    final prefix = quote.prefix.runes.toList();
    final suffix = quote.suffix.runes.toList();

    // Knuth–Morris–Pratt failure table.
    budget.spend(pattern.length);
    final failure = List<int>.filled(pattern.length, 0);
    var matched = 0;
    for (var index = 1; index < pattern.length; index++) {
      while (matched > 0 && pattern[index] != pattern[matched]) {
        budget.spend(1);
        matched = failure[matched - 1];
      }
      budget.spend(1);
      if (pattern[index] == pattern[matched]) {
        matched++;
        failure[index] = matched;
      }
    }

    var candidates = 0;
    int? onlyStart;
    int? onlyEnd;
    int? lastStart;
    int? lastEnd;
    var contextual = 0;
    int? contextualStart;
    int? contextualEnd;
    matched = 0;
    for (var index = 0; index < text.length; index++) {
      final scalar = text[index];
      while (matched > 0 && scalar != pattern[matched]) {
        budget.spend(1);
        matched = failure[matched - 1];
      }
      budget.spend(1);
      if (scalar == pattern[matched]) matched++;
      if (matched != pattern.length) continue;
      matched = failure[matched - 1];
      final end = index + 1;
      final start = end - pattern.length;
      if (!_legalBoundaries(start, end, budget)) continue;
      final sourceStart = sourceStarts[start];
      final sourceEnd = sourceEnds[end - 1];
      if (sourceStart == lastStart && sourceEnd == lastEnd) continue;
      lastStart = sourceStart;
      lastEnd = sourceEnd;
      candidates++;
      if (candidates == 1) {
        onlyStart = sourceStart;
        onlyEnd = sourceEnd;
      }
      budget.spend(prefix.length + suffix.length);
      if (_endsWith(start, prefix) && _startsWith(end, suffix)) {
        contextual++;
        if (contextual > 1) {
          return const ResolvedAnchor(AnnotationResolution.ambiguous);
        }
        contextualStart = sourceStart;
        contextualEnd = sourceEnd;
      }
    }
    if (candidates == 0) {
      return const ResolvedAnchor(AnnotationResolution.orphaned);
    }
    if (contextual == 1) {
      return ResolvedAnchor(
        AnnotationResolution.recovered,
        contextualStart,
        contextualEnd,
      );
    }
    if (contextual == 0 && candidates == 1) {
      return ResolvedAnchor(AnnotationResolution.recovered, onlyStart, onlyEnd);
    }
    return const ResolvedAnchor(AnnotationResolution.ambiguous);
  }

  /// A match must not start or end inside a source grapheme's normalized
  /// form, except next to the spaces that whitespace normalization emits.
  bool _legalBoundaries(int start, int end, ResolutionBudget budget) {
    for (var omitted = start; omitted > 0; omitted--) {
      if (!_sameSource(omitted - 1, start)) break;
      budget.spend(1);
      if (text[omitted - 1] != 0x20) return false;
    }
    for (var omitted = end; omitted < text.length; omitted++) {
      if (!_sameSource(omitted, end - 1)) break;
      budget.spend(1);
      if (text[omitted] != 0x20) return false;
    }
    return true;
  }

  bool _sameSource(int a, int b) =>
      sourceStarts[a] == sourceStarts[b] && sourceEnds[a] == sourceEnds[b];

  /// Whether the normalized text before [start], without trailing spaces,
  /// ends with [context].
  bool _endsWith(int start, List<int> context) {
    if (context.isEmpty) return true;
    var end = start;
    while (end > 0 && text[end - 1] == 0x20) {
      end--;
    }
    if (end < context.length) return false;
    for (var index = 0; index < context.length; index++) {
      if (text[end - context.length + index] != context[index]) return false;
    }
    return true;
  }

  /// Whether the normalized text from [end], without leading spaces, starts
  /// with [context].
  bool _startsWith(int end, List<int> context) {
    if (context.isEmpty) return true;
    var start = end;
    while (start < text.length && text[start] == 0x20) {
      start++;
    }
    if (text.length - start < context.length) return false;
    for (var index = 0; index < context.length; index++) {
      if (text[start + index] != context[index]) return false;
    }
    return true;
  }
}
