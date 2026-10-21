/// In-document search over a book's unit texts.
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../cancellation.dart';
import '../errors.dart';
import '../unit_text.dart';
import 'case_fold.dart';

/// Scalars of context kept on each side of a match.
const searchContextScalars = 40;

/// What one [SearchMatch] counts against [SearchLimits.maxResultBytes]
/// besides its context.
const searchMatchBaseBytes = 48;

/// Text searched in one isolate run, in UTF-16 code units. Cancellation is
/// checked between runs.
const _batchUnits = 1024 * 1024;

/// Bounds on one search. Each is at most its default, which is the hard
/// maximum.
final class SearchLimits {
  const SearchLimits({
    this.maxQueryBytes = 4 * 1024,
    this.maxIndexedTextBytes = 8 * 1024 * 1024,
    this.maxMatches = 10000,
    this.maxResultBytes = 8 * 1024 * 1024,
  });

  /// UTF-8 bytes of the query.
  final int maxQueryBytes;

  /// UTF-8 bytes of all unit texts searched.
  final int maxIndexedTextBytes;
  final int maxMatches;

  /// [searchMatchBaseBytes] plus the UTF-8 bytes of the context, summed over
  /// the matches.
  final int maxResultBytes;

  void _check() {
    const hard = SearchLimits();
    for (final (name, requested, maximum) in [
      ('query bytes', maxQueryBytes, hard.maxQueryBytes),
      ('indexed text bytes', maxIndexedTextBytes, hard.maxIndexedTextBytes),
      ('match count', maxMatches, hard.maxMatches),
      ('result bytes', maxResultBytes, hard.maxResultBytes),
    ]) {
      if (requested < 0 || requested > maximum) {
        throw CoreException.invalidRequest(
          'The search $name limit must be 0 to $maximum, not $requested.',
        );
      }
    }
  }
}

/// One occurrence of the query.
final class SearchMatch {
  const SearchMatch({
    required this.unit,
    required this.offset,
    required this.length,
    required this.context,
  });

  /// The EPUB spine index or PDF page.
  final int unit;

  /// Where the match starts in the unit's text, in Unicode scalars.
  final int offset;

  /// The match's length in Unicode scalars.
  final int length;

  /// Up to [searchContextScalars] scalars on each side of the match and the
  /// match itself, trimmed, with line breaks as spaces.
  final String context;

  @override
  bool operator ==(Object other) =>
      other is SearchMatch &&
      other.unit == unit &&
      other.offset == offset &&
      other.length == length &&
      other.context == context;

  @override
  int get hashCode => Object.hash(unit, offset, length, context);

  @override
  String toString() => 'SearchMatch($unit, $offset, $length, $context)';
}

/// Every case-insensitive occurrence of [query] in [source], in unit order.
///
/// Matching uses Unicode full case folding, so "STRASSE" finds "Straße", and
/// a match always covers whole characters of the text: "s" does not match
/// half of "ß". Matches do not overlap. Exceeding a limit fails with
/// `limitExceeded` rather than returning a truncated list.
Future<List<SearchMatch>> searchBook(
  UnitTextSource source,
  String query, {
  SearchLimits limits = const SearchLimits(),
  CancellationToken? cancellation,
}) async {
  final search = _Search(query, limits);
  final results = <SearchMatch>[];
  if (search.query.isEmpty) return results;
  var indexedBytes = 0;
  var resultBytes = 0;
  final batch = <(int, String)>[];
  var batchUnits = 0;

  Future<void> flush() async {
    if (batch.isEmpty) return;
    cancellation.throwIfCancelled();
    final (matches, bytes) = await _runBatch(
      search,
      List.of(batch),
      results.length,
      resultBytes,
    );
    batch.clear();
    batchUnits = 0;
    results.addAll(matches);
    resultBytes = bytes;
  }

  for (var unit = 0; unit < source.unitCount; unit++) {
    cancellation.throwIfCancelled();
    final text = await source.unitText(unit, cancellation: cancellation);
    if (text == null) continue;
    indexedBytes += utf8Length(text.text);
    if (indexedBytes > limits.maxIndexedTextBytes) {
      throw CoreException.limitExceeded(
        'The book has more text than one search covers '
        '(${limits.maxIndexedTextBytes} bytes).',
      );
    }
    if (batchUnits + text.text.length > _batchUnits) await flush();
    batch.add((unit, text.text));
    batchUnits += text.text.length;
  }
  await flush();
  return results;
}

/// [searchBook] over texts already in memory, one per unit, on the calling
/// isolate.
List<SearchMatch> searchTexts(
  List<String> units,
  String query, {
  SearchLimits limits = const SearchLimits(),
}) {
  final search = _Search(query, limits);
  if (search.query.isEmpty) return [];
  var indexedBytes = 0;
  for (final text in units) {
    indexedBytes += utf8Length(text);
    if (indexedBytes > limits.maxIndexedTextBytes) {
      throw CoreException.limitExceeded(
        'The book has more text than one search covers '
        '(${limits.maxIndexedTextBytes} bytes).',
      );
    }
  }
  return search
      .run([for (final (unit, text) in units.indexed) (unit, text)], 0, 0)
      .$1;
}

/// The UTF-8 length of [text]; a lone surrogate counts as its replacement
/// character.
int utf8Length(String text) {
  var bytes = 0;
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit < 0xDC00 &&
        index + 1 < text.length &&
        (text.codeUnitAt(index + 1) & 0xFC00) == 0xDC00) {
      bytes += 4;
      index++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// Search [batch] in another isolate. Top level so the closure sent there
/// captures only its arguments.
Future<(List<SearchMatch>, int)> _runBatch(
  _Search search,
  List<(int, String)> batch,
  int matches,
  int resultBytes,
) => Isolate.run(() => search.run(batch, matches, resultBytes));

/// A folded query and its limits.
final class _Search {
  factory _Search(String query, SearchLimits limits) {
    limits._check();
    final bytes = utf8Length(query);
    if (bytes > limits.maxQueryBytes) {
      throw CoreException.limitExceeded(
        'The search query is $bytes bytes, over ${limits.maxQueryBytes}.',
      );
    }
    final folded = Int32List.fromList([
      for (final scalar in query.runes) ...fullCaseFold(scalar),
    ]);
    return _Search._(folded, _failures(folded), limits);
  }

  const _Search._(this.query, this.failures, this.limits);

  final Int32List query;

  /// Knuth-Morris-Pratt failure function of [query].
  final Int32List failures;
  final SearchLimits limits;

  /// The matches in [batch], given [matches] and [resultBytes] so far, and
  /// the result bytes after them.
  (List<SearchMatch>, int) run(
    List<(int, String)> batch,
    int matches,
    int resultBytes,
  ) {
    final results = <SearchMatch>[];
    for (final (unit, text) in batch) {
      resultBytes = _searchUnit(unit, text, matches, resultBytes, results);
    }
    return (results, resultBytes);
  }

  int _searchUnit(
    int unit,
    String text,
    int earlier,
    int resultBytes,
    List<SearchMatch> results,
  ) {
    final original = Int32List.fromList(text.runes.toList());
    var folded = Int32List(original.length + 16);
    // For each folded position, the original scalar it starts, or -1 inside
    // the folding of one scalar.
    var boundaries = Int32List(original.length + 17);
    var length = 0;
    for (var index = 0; index < original.length; index++) {
      boundaries[length] = index;
      final simple = simpleCaseFold(original[index]);
      final codes = simple < 0 ? fullCaseFold(original[index]) : null;
      final count = codes?.length ?? 1;
      if (length + count >= folded.length) {
        final capacity = (folded.length * 3 ~/ 2) + count + 16;
        folded = Int32List(capacity)..setRange(0, length, folded);
        boundaries = Int32List(capacity + 1)
          ..setRange(0, length + 1, boundaries);
      }
      if (codes == null) {
        folded[length++] = simple;
      } else {
        for (var offset = 0; offset < count; offset++) {
          if (offset > 0) boundaries[length] = -1;
          folded[length++] = codes[offset];
        }
      }
    }
    boundaries[length] = original.length;

    // Every occurrence in one linear pass; a match is kept when it starts
    // after the previous kept one and both its ends are whole characters.
    var state = 0;
    var keptEnd = 0;
    for (var position = 0; position < length; position++) {
      final code = folded[position];
      while (state > 0 && query[state] != code) {
        state = failures[state - 1];
      }
      if (query[state] == code) state++;
      if (state < query.length) continue;
      state = failures[state - 1];
      final end = position + 1;
      final start = end - query.length;
      final originalStart = boundaries[start];
      final originalEnd = boundaries[end];
      if (start < keptEnd || originalStart < 0 || originalEnd < 0) continue;
      if (earlier + results.length >= limits.maxMatches) {
        throw CoreException.limitExceeded(
          'The search found more than ${limits.maxMatches} matches.',
        );
      }
      final context = _context(original, originalStart, originalEnd);
      resultBytes += searchMatchBaseBytes + utf8Length(context);
      if (resultBytes > limits.maxResultBytes) {
        throw CoreException.limitExceeded(
          'The search results exceed ${limits.maxResultBytes} bytes.',
        );
      }
      results.add(
        SearchMatch(
          unit: unit,
          offset: originalStart,
          length: originalEnd - originalStart,
          context: context,
        ),
      );
      keptEnd = end;
    }
    return resultBytes;
  }
}

String _context(Int32List original, int start, int end) {
  final from = start < searchContextScalars ? 0 : start - searchContextScalars;
  final to = end + searchContextScalars > original.length
      ? original.length
      : end + searchContextScalars;
  return String.fromCharCodes(original, from, to).trim().replaceAll('\n', ' ');
}

Int32List _failures(Int32List pattern) {
  final failures = Int32List(pattern.length);
  var state = 0;
  for (var index = 1; index < pattern.length; index++) {
    while (state > 0 && pattern[index] != pattern[state]) {
      state = failures[state - 1];
    }
    if (pattern[index] == pattern[state]) state++;
    failures[index] = state;
  }
  return failures;
}
