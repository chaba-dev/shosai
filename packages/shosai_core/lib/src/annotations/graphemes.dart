/// Unicode 17.0.0 extended grapheme clusters (UAX #29), as the quote-v1
/// profile pins them.
///
/// The `characters` package (pinned by the Flutter SDK, 1.4.1) implements
/// Unicode 16, which clusters Khmer, Myanmar and Balinese conjuncts and the
/// combining marks new in Unicode 17 differently, so the profile carries its
/// own segmenter over tables generated from the Unicode 17.0.0 Character
/// Database by `scripts/generate-quote-unicode-tables.py`. It is tested
/// against the full Unicode 17.0.0 `GraphemeBreakTest.txt`.
library;

import 'dart:typed_data';

import 'grapheme_table.dart';

/// The Unicode version of [GraphemeBreaker].
const graphemeUnicodeVersion = graphemeTableUnicodeVersion;

// Grapheme_Cluster_Break values, as encoded by the generator (0 is Other).
const _cr = 1;
const _lf = 2;
const _control = 3;
const _extend = 4;
const _zwj = 5;
const _regionalIndicator = 6;
const _prepend = 7;
const _spacingMark = 8;
const _l = 9;
const _v = 10;
const _t = 11;
const _lv = 12;
const _lvt = 13;

const _extendedPictographic = 1 << 4;
const _incbLinker = 1 << 5;
const _incbConsonant = 2 << 5;
const _incbExtend = 3 << 5;
const _incbMask = 3 << 5;

/// The Basic Multilingual Plane's properties, one byte per code point,
/// expanded from the range table on first use.
final Uint8List _bmp = () {
  final table = Uint8List(0x10000);
  for (var index = 0; index < graphemeRangeStarts.length; index++) {
    final start = graphemeRangeStarts[index];
    if (start >= 0x10000) break;
    final end = index + 1 < graphemeRangeStarts.length
        ? graphemeRangeStarts[index + 1]
        : 0x110000;
    table.fillRange(
      start,
      end < 0x10000 ? end : 0x10000,
      graphemeRangeValues[index],
    );
  }
  return table;
}();

int _properties(int scalar) {
  if (scalar < 0x10000) return _bmp[scalar];
  var low = 0;
  var high = graphemeRangeStarts.length - 1;
  while (low < high) {
    final middle = (low + high + 1) >> 1;
    if (graphemeRangeStarts[middle] <= scalar) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return graphemeRangeValues[low];
}

/// Finds extended grapheme cluster boundaries one scalar at a time, so a
/// caller can stop (or reject an oversized cluster) without looking ahead.
final class GraphemeBreaker {
  /// The previous scalar's properties; -1 before the first scalar.
  var _previous = -1;

  /// Regional indicators immediately before the current scalar.
  var _regionalIndicators = 0;

  /// GB11: 1 after Extended_Pictographic Extend*, 2 after a ZWJ ending it.
  var _emoji = 0;

  /// GB9c: 1 after InCB=Consonant [InCB=Extend InCB=Linker]*, 2 once that
  /// run holds a linker.
  var _conjunct = 0;

  /// Whether a cluster boundary falls before [scalar], which follows every
  /// scalar given to this breaker so far. True for the first scalar.
  bool next(int scalar) {
    final properties = _properties(scalar);
    final kind = properties & 0x0f;
    final previous = _previous;
    final boundary = previous < 0 || _breaks(previous, properties, kind);

    _previous = properties;
    _regionalIndicators = kind == _regionalIndicator
        ? _regionalIndicators + 1
        : 0;
    if (properties & _extendedPictographic != 0) {
      _emoji = 1;
    } else if (_emoji == 1 && kind == _extend) {
      _emoji = 1;
    } else if (_emoji == 1 && kind == _zwj) {
      _emoji = 2;
    } else {
      _emoji = 0;
    }
    final incb = properties & _incbMask;
    if (incb == _incbConsonant) {
      _conjunct = 1;
    } else if (_conjunct != 0 && incb == _incbLinker) {
      _conjunct = 2;
    } else if (_conjunct == 0 || incb != _incbExtend) {
      _conjunct = 0;
    }
    return boundary;
  }

  bool _breaks(int previousProperties, int properties, int kind) {
    final previous = previousProperties & 0x0f;
    // GB3 to GB5.
    if (previous == _cr && kind == _lf) return false;
    if (previous == _cr || previous == _lf || previous == _control) {
      return true;
    }
    if (kind == _cr || kind == _lf || kind == _control) return true;
    // GB6 to GB8: Hangul syllables.
    if (previous == _l &&
        (kind == _l || kind == _v || kind == _lv || kind == _lvt)) {
      return false;
    }
    if ((previous == _lv || previous == _v) && (kind == _v || kind == _t)) {
      return false;
    }
    if ((previous == _lvt || previous == _t) && kind == _t) return false;
    // GB9 to GB9b.
    if (kind == _extend || kind == _zwj || kind == _spacingMark) return false;
    if (previous == _prepend) return false;
    // GB9c: Indic conjuncts.
    if (_conjunct == 2 && properties & _incbMask == _incbConsonant) {
      return false;
    }
    // GB11: emoji ZWJ sequences.
    if (_emoji == 2 && properties & _extendedPictographic != 0) return false;
    // GB12 and GB13: regional indicator pairs.
    if (kind == _regionalIndicator && _regionalIndicators.isOdd) return false;
    return true;
  }
}

/// The extended grapheme clusters of [value], by Unicode 17.0.0.
List<String> graphemeClusters(String value) {
  final clusters = <String>[];
  final breaker = GraphemeBreaker();
  var start = 0;
  var index = 0;
  for (final scalar in value.runes) {
    if (breaker.next(scalar) && index > start) {
      clusters.add(value.substring(start, index));
      start = index;
    }
    index += scalar > 0xffff ? 2 : 1;
  }
  if (index > start) clusters.add(value.substring(start, index));
  return clusters;
}
