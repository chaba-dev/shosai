/// In-document search over extracted PDF page text.
///
/// Port of the retained core's `search.rs` for the PDF path: a
/// case-insensitive substring search whose offsets are scalar indexes into
/// the page text the engine extracted (one scalar per PDFium character), so a
/// match addresses the same characters the selection surface and the stored
/// annotations do.
library;

import 'package:shosai_flutter/core/bridge.dart';

/// Search limits shared with the retained core's defaults.
final class PdfSearchLimits {
  const PdfSearchLimits({
    this.maxQueryScalars = 4 * 1024,
    this.maxIndexedScalars = 8 * 1024 * 1024,
    this.maxMatches = 10000,
  });

  final int maxQueryScalars;
  final int maxIndexedScalars;
  final int maxMatches;
}

/// Thrown when a search exceeds one of its [PdfSearchLimits].
final class PdfSearchLimitException implements Exception {
  const PdfSearchLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Accumulates matches over the pages of one document.
final class PdfSearch {
  PdfSearch(String query, {this.limits = const PdfSearchLimits()})
    : _queryFolded = _fold(query).folded {
    if (query.runes.length > limits.maxQueryScalars) {
      throw PdfSearchLimitException(
        'search query exceeds its limit '
        '(${query.runes.length} > ${limits.maxQueryScalars})',
      );
    }
  }

  final PdfSearchLimits limits;
  final String _queryFolded;
  final List<FlutterSearchMatch> results = [];
  int _indexedScalars = 0;

  /// Whether the query folds to nothing, in which case no page can match.
  bool get isEmpty => _queryFolded.isEmpty;

  /// Indexes one page's text and appends its matches in document order.
  void addPage(int page, String text) {
    final scalars = text.runes.toList(growable: false);
    _indexedScalars += scalars.length;
    if (_indexedScalars > limits.maxIndexedScalars) {
      throw PdfSearchLimitException(
        'search text exceeds its limit '
        '($_indexedScalars > ${limits.maxIndexedScalars})',
      );
    }
    if (_queryFolded.isEmpty) return;
    final folded = _fold(text);
    var start = 0;
    while (true) {
      final position = folded.folded.indexOf(_queryFolded, start);
      if (position < 0) break;
      final foldedEnd = position + _queryFolded.length;
      final originalStart = folded.originalScalarAt(position);
      final originalEnd = folded.originalScalarAt(foldedEnd);
      if (originalStart == null || originalEnd == null) {
        // The match starts or ends inside one original character's folding;
        // advance by one folded code unit and keep looking.
        start = position + 1;
        continue;
      }
      if (results.length >= limits.maxMatches) {
        throw PdfSearchLimitException(
          'search result count exceeds its limit (${limits.maxMatches})',
        );
      }
      final contextStart = originalStart - 40 < 0 ? 0 : originalStart - 40;
      final contextEnd = originalEnd + 40 > scalars.length
          ? scalars.length
          : originalEnd + 40;
      final context = String.fromCharCodes(
        scalars.sublist(contextStart, contextEnd),
      ).trim().replaceAll('\n', ' ');
      results.add(
        FlutterSearchMatch(
          unit: BigInt.from(page),
          offset: BigInt.from(originalStart),
          length: BigInt.from(originalEnd - originalStart),
          context: context,
        ),
      );
      start = foldedEnd;
    }
  }
}

final class _Folded {
  _Folded(this.folded, this._boundaries);

  final String folded;

  /// Folded code-unit offset at the end of each original scalar, with the
  /// scalar index that offset closes. Entry 0 is `(0, 0)`.
  final List<(int, int)> _boundaries;

  /// The original scalar index that starts at folded code-unit [offset], or
  /// null when the offset falls inside one scalar's folding.
  int? originalScalarAt(int offset) {
    var low = 0;
    var high = _boundaries.length - 1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      final (boundary, scalar) = _boundaries[middle];
      if (boundary == offset) return scalar;
      if (boundary < offset) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return null;
  }
}

/// Case-folds [text] one scalar at a time, keeping a map from folded offsets
/// back to original scalar indexes.
_Folded _fold(String text) {
  final folded = StringBuffer();
  final boundaries = <(int, int)>[(0, 0)];
  var index = 0;
  for (final rune in text.runes) {
    final before = folded.length;
    folded.write(String.fromCharCode(rune).toLowerCase());
    index++;
    final boundary = (folded.length, index);
    if (folded.length == before) {
      boundaries[boundaries.length - 1] = boundary;
    } else {
      boundaries.add(boundary);
    }
  }
  return _Folded(folded.toString(), boundaries);
}
