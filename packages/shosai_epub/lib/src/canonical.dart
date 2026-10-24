/// Canonical text stream, scalar checkpoints and caret boundaries.
///
/// The canonical stream is a direct port of the production
/// `search::extract_text_from_nodes` order, including generated separators,
/// image alt text and math fallback. Normalization is a quote/search operation
/// and never edits this stream.
///
/// This file also ports the 5B bounded `CanonicalIndex` (checkpoints at most
/// `kCanonicalCheckpointScalars` apart) and the grapheme/word caret boundaries
/// used by selection snapping.
library;

import 'package:characters/characters.dart';

import 'limits.dart';
import 'model.dart';

/// Scalar distance between canonical checkpoints. The contract requires "at
/// most 1,024 scalars apart".
const int kCanonicalCheckpointScalars = 1024;

/// Result of building the canonical stream for one chapter.
class CanonicalBuildResult {
  const CanonicalBuildResult(this.text, this.scalarCount);

  final String text;
  final int scalarCount;
}

/// Direct port of the production extraction order. Used to cross-check the
/// offset-annotating walk in tests.
String extractCanonicalText(List<EpubContentNode> nodes) {
  final out = StringBuffer();
  for (final node in nodes) {
    _extractNodeText(node, out);
    out.write('\n');
  }
  return out.toString();
}

void _extractNodeText(EpubContentNode node, StringBuffer out) {
  switch (node) {
    case EpubHeading(:final spans):
      _extractSpansText(spans, out);
    case EpubParagraph(:final spans):
      _extractSpansText(spans, out);
    case EpubBlockQuote(:final children):
      for (final child in children) {
        _extractNodeText(child, out);
        out.write('\n');
      }
    case EpubFigure(:final children):
      for (var index = 0; index < children.length; index++) {
        if (index > 0) out.write('\n');
        _extractNodeText(children[index], out);
      }
    case EpubTable(:final caption, :final rowGroups):
      _extractSpansText(caption, out);
      if (caption.isNotEmpty) out.write('\n');
      for (final group in rowGroups) {
        for (final row in group.rows) {
          for (var index = 0; index < row.cells.length; index++) {
            final cell = row.cells[index];
            for (
              var childIndex = 0;
              childIndex < cell.children.length;
              childIndex++
            ) {
              if (cell.blockStarts.contains(childIndex)) out.write('\n');
              _extractNodeText(cell.children[childIndex], out);
            }
            if (index + 1 < row.cells.length) out.write('\t');
          }
          out.write('\n');
        }
      }
    case EpubMathNode(:final content):
      out.write(content.fallback);
    case EpubUnorderedList(:final items):
      for (final item in items) {
        _extractSpansText(item, out);
        out.write('\n');
      }
    case EpubOrderedList(:final items):
      for (final item in items) {
        _extractSpansText(item, out);
        out.write('\n');
      }
    case EpubCodeBlock(:final code):
      out.write(code);
    case EpubImage(:final alt, :final caption):
      out.write(alt);
      if (caption.isNotEmpty) {
        out.write('\n');
        _extractSpansText(caption, out);
      }
    case EpubHorizontalRule():
      break;
  }
}

void _extractSpansText(List<EpubTextSpan> spans, StringBuffer out) {
  for (final span in spans) {
    out.write(span.text);
  }
}

/// Whether [name] is an anchor the parser admits.
///
/// The production `record_anchor_name` skips an empty name, a name longer than
/// 1,024 UTF-8 bytes and any control character (Unicode category Cc, which
/// includes C1), so such an `id`/`name` attribute never becomes an anchor and
/// its fragment can never resolve to a position.
bool admitsAnchorName(String name) {
  if (name.isEmpty) return false;
  var bytes = 0;
  for (final rune in name.runes) {
    bytes += rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
    if (bytes > 1024) return false;
    if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) return false;
  }
  return true;
}

/// Builds the canonical stream while annotating every span, node, image alt
/// and generated separator with its scalar range.
///
/// The annotation walk mirrors [_extractNodeText] exactly; tests assert that
/// the produced text equals [extractCanonicalText].
class CanonicalTextBuilder {
  CanonicalTextBuilder({required this.maxScalars});

  final int maxScalars;
  final StringBuffer _out = StringBuffer();
  final Map<String, int> anchors = {};
  int _scalar = 0;

  int get scalarCount => _scalar;

  void _recordAnchor(String name, int offset) {
    if (!admitsAnchorName(name)) return;
    if (anchors.length >= 4096) return;
    anchors.putIfAbsent(name, () => offset);
  }

  void _recordAnchors(List<String> ids, int offset) {
    for (final id in ids) {
      _recordAnchor(id, offset);
    }
  }

  /// Records an anchor that resolves at the current end of the stream.
  ///
  /// Unresolved markers go through the same admission rules and the same
  /// 4,096-anchor ceiling as every other anchor.
  void recordEndAnchor(String name) => _recordAnchor(name, _scalar);

  void _write(String text, {EpubTextSpan? span}) {
    if (text.isEmpty) {
      final range = EpubCanonicalSpan(_scalar, _scalar);
      span?.canonical = range;
      _recordAnchors(span?.anchorIds ?? const [], _scalar);
      _recordAnchors(span?.endAnchorIds ?? const [], _scalar);
      return;
    }
    final start = _scalar;
    _scalar += text.runes.length;
    if (_scalar > maxScalars) {
      throw EpubLimitError('canonical scalars', maxScalars, _scalar);
    }
    _out.write(text);
    final range = EpubCanonicalSpan(start, _scalar);
    span?.canonical = range;
    _recordAnchors(span?.anchorIds ?? const [], start);
    _recordAnchors(span?.endAnchorIds ?? const [], _scalar);
  }

  void _writeSeparator(String text) {
    _scalar += text.runes.length;
    if (_scalar > maxScalars) {
      throw EpubLimitError('canonical scalars', maxScalars, _scalar);
    }
    _out.write(text);
  }

  CanonicalBuildResult build(List<EpubContentNode> nodes) {
    for (final node in nodes) {
      _node(node);
      _writeSeparator('\n');
    }
    return CanonicalBuildResult(_out.toString(), _scalar);
  }

  void _node(EpubContentNode node) {
    final start = _scalar;
    _recordAnchors(node.anchorIds, start);
    switch (node) {
      case EpubHeading(:final spans):
        _spans(spans);
      case EpubParagraph(:final spans):
        _spans(spans);
      case EpubBlockQuote(:final children):
        for (final child in children) {
          _node(child);
          _writeSeparator('\n');
        }
      case EpubFigure(:final children):
        for (var index = 0; index < children.length; index++) {
          if (index > 0) _writeSeparator('\n');
          _node(children[index]);
        }
      case EpubTable(:final caption, :final rowGroups):
        _spans(caption);
        if (caption.isNotEmpty) _writeSeparator('\n');
        for (final group in rowGroups) {
          for (final row in group.rows) {
            // The row's range opens before its first cell's content and
            // closes after its trailing row separator, so it covers every
            // scalar the row contributes — including a row whose cells are
            // all empty, which still owns its separators. Rows partition the
            // table's body: one row's end is the next row's start.
            final rowStart = _scalar;
            for (var index = 0; index < row.cells.length; index++) {
              final cell = row.cells[index];
              // The cell's own and inherited anchors resolve at its start.
              final cellStart = _scalar;
              _recordAnchors(cell.startAnchorIds, cellStart);
              for (
                var childIndex = 0;
                childIndex < cell.children.length;
                childIndex++
              ) {
                if (cell.blockStarts.contains(childIndex)) {
                  _writeSeparator('\n');
                }
                _node(cell.children[childIndex]);
              }
              // The cell's descendant anchors come from the production anchor
              // streams (a block walk or the inline collector over the cell's
              // source), so they are applied cell-locally here: within one
              // cell the stream's own first occurrence must win, like
              // `record_anchor_name`. A marker left pending after the walk
              // resolves at the walk's own end and arrives in this same map.
              for (final entry in cell.anchorOffsets.entries) {
                _recordAnchor(entry.key, cellStart + entry.value);
              }
              if (index + 1 < row.cells.length) _writeSeparator('\t');
            }
            _writeSeparator('\n');
            row.canonical = EpubCanonicalSpan(rowStart, _scalar);
          }
        }
      case EpubMathNode(:final content):
        _write(content.fallback);
      case EpubUnorderedList(:final items):
        for (final item in items) {
          _spans(item);
          _writeSeparator('\n');
        }
      case EpubOrderedList(:final items):
        for (final item in items) {
          _spans(item);
          _writeSeparator('\n');
        }
      case EpubCodeBlock(:final code):
        _write(code);
      case EpubImage(:final alt, :final caption):
        // Alt text is a hidden canonical fallback: it stays in the stream but
        // is not user-selectable when the image renders.
        final altSpan = EpubTextSpan(text: alt)..selectable = false;
        _write(alt, span: altSpan);
        if (caption.isNotEmpty) {
          _writeSeparator('\n');
          _spans(caption);
        }
      case EpubHorizontalRule():
        break;
    }
    _recordAnchors(node.endAnchorIds, _scalar);
    node.canonical = EpubCanonicalSpan(start, _scalar);
  }

  void _spans(List<EpubTextSpan> spans) {
    for (final span in spans) {
      _write(span.text, span: span);
    }
  }
}

/// A scalar checkpoint index over one canonical chapter stream.
///
/// Checkpoint `i` stores the UTF-16 code-unit offset of canonical scalar
/// `i * kCanonicalCheckpointScalars`, so resolving a scalar is a bounded walk
/// of fewer than 1,024 scalars from the nearest checkpoint. Rust stores UTF-8
/// byte offsets; Dart strings are UTF-16, so the unit differs while the bound
/// and the algorithm are the same.
class CanonicalIndex {
  CanonicalIndex._(this.scalarCount, this.codeUnitLength, this._checkpoints);

  factory CanonicalIndex(String text) {
    final checkpoints = <int>[];
    var codeUnit = 0;
    var scalar = 0;
    while (codeUnit < text.length) {
      if (scalar % kCanonicalCheckpointScalars == 0) {
        checkpoints.add(codeUnit);
      }
      final unit = text.codeUnitAt(codeUnit);
      codeUnit += unit >= 0xD800 && unit <= 0xDBFF ? 2 : 1;
      scalar++;
    }
    return CanonicalIndex._(scalar, text.length, checkpoints);
  }

  final int scalarCount;
  final int codeUnitLength;
  final List<int> _checkpoints;

  int get checkpointCount => _checkpoints.length;

  /// Bytes retained by the checkpoint index (4 bytes per checkpoint).
  int get retainedBytes => _checkpoints.length * 4;

  /// Code-unit offset of a canonical scalar, or `null` when out of range.
  int? codeUnitOffsetOfScalar(String text, int scalar) {
    if (scalar < 0 || scalar > scalarCount) return null;
    if (scalar == scalarCount) return text.length;
    var checkpointIndex = scalar ~/ kCanonicalCheckpointScalars;
    if (checkpointIndex >= _checkpoints.length) {
      checkpointIndex = _checkpoints.length - 1;
    }
    var codeUnit = _checkpoints[checkpointIndex];
    var current = checkpointIndex * kCanonicalCheckpointScalars;
    while (current < scalar) {
      final unit = text.codeUnitAt(codeUnit);
      codeUnit += unit >= 0xD800 && unit <= 0xDBFF ? 2 : 1;
      current++;
    }
    return codeUnit;
  }

  /// Canonical scalar offset of a UTF-16 code-unit offset, clamped to the
  /// stream end. Code units inside a surrogate pair resolve to the pair start.
  int scalarAtCodeUnit(String text, int codeUnit) {
    if (codeUnit <= 0) return 0;
    if (codeUnit >= text.length) return scalarCount;
    var scalar = 0;
    var index = 0;
    while (index < codeUnit) {
      final unit = text.codeUnitAt(index);
      index += unit >= 0xD800 && unit <= 0xDBFF ? 2 : 1;
      scalar++;
    }
    return scalar;
  }
}

/// Legal grapheme caret boundaries, in canonical scalars.
List<int> graphemeBoundaries(String text) {
  final boundaries = <int>[];
  var scalar = 0;
  for (final grapheme in text.characters) {
    boundaries.add(scalar);
    scalar += grapheme.runes.length;
  }
  boundaries.add(scalar);
  return boundaries;
}

/// Legal grapheme caret boundaries and word-segment stops, in canonical
/// scalars. Port of the 5B `navigation_boundaries`, with a bounded
/// approximation of UAX #29: runs of Latin letters/digits/marks form one word,
/// whitespace and punctuation separate words, and each CJK ideograph or kana
/// grapheme is its own stop (which is also the useful behaviour for CJK
/// selection stepping).
({List<int> graphemes, List<int> words}) navigationBoundaries(String text) {
  final graphemes = <int>[0];
  final words = <int>[0];
  var scalar = 0;
  var inWord = false;
  for (final grapheme in text.characters) {
    final isCjk = _isCjkGrapheme(grapheme);
    final isWordChar = isCjk || _isWordCodePoint(grapheme.runes.first);
    if (isWordChar && !inWord) {
      words.add(scalar);
      inWord = true;
    } else if (!isWordChar && inWord) {
      words.add(scalar);
      inWord = false;
    } else if (isCjk) {
      words.add(scalar);
    }
    scalar += grapheme.runes.length;
    graphemes.add(scalar);
    if (isCjk) {
      words.add(scalar);
      inWord = false;
    }
  }
  if (inWord) words.add(scalar);
  words
    ..sort()
    ..add(scalar);
  final deduped = <int>[];
  for (final value in words) {
    if (deduped.isEmpty || deduped.last != value) deduped.add(value);
  }
  return (graphemes: graphemes, words: deduped);
}

bool _isWordCodePoint(int rune) {
  // Latin letters, digits, combining marks and common word punctuation.
  if (rune >= 0x30 && rune <= 0x39) return true;
  if (rune >= 0x41 && rune <= 0x5A) return true;
  if (rune >= 0x61 && rune <= 0x7A) return true;
  if (rune >= 0xC0 && rune <= 0x24F) return true; // Latin-1 supplement/extended
  if (rune >= 0x300 && rune <= 0x36F) return true; // combining marks
  if (rune == 0x27 || rune == 0x2019) return true; // apostrophes
  return false;
}

bool _isCjkGrapheme(String grapheme) {
  for (final rune in grapheme.runes) {
    if (rune >= 0x3040 && rune <= 0x30FF) return true; // kana
    if (rune >= 0x3400 && rune <= 0x4DBF) return true; // CJK ext A
    if (rune >= 0x4E00 && rune <= 0x9FFF) return true; // CJK unified
    if (rune >= 0xF900 && rune <= 0xFAFF) return true; // CJK compat
    if (rune >= 0xAC00 && rune <= 0xD7AF) return true; // Hangul
    if (rune >= 0x20000 && rune <= 0x2FA1F) return true; // CJK ext B+
  }
  return false;
}

/// Snap a canonical scalar to the nearest legal grapheme boundary.
int snapToGrapheme(List<int> boundaries, int scalar) {
  if (boundaries.isEmpty) return scalar;
  if (scalar <= boundaries.first) return boundaries.first;
  if (scalar >= boundaries.last) return boundaries.last;
  var low = 0;
  var high = boundaries.length - 1;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (boundaries[mid] < scalar) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return boundaries[low];
}

/// Next/previous word stop from a canonical scalar.
int stepWord(List<int> words, int scalar, {required bool forward}) {
  if (words.isEmpty) return scalar;
  if (forward) {
    for (final word in words) {
      if (word > scalar) return word;
    }
    return words.last;
  }
  for (var index = words.length - 1; index >= 0; index--) {
    if (words[index] < scalar) return words[index];
  }
  return words.first;
}
