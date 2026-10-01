/// Which code points the fonts the Dart EPUB renderer can address actually
/// cover.
///
/// The renderer lays text out with the reader's bundled document faces plus the
/// book's admitted `@font-face` faces. A chapter whose text needs a code point
/// none of them carries would be painted by whatever the host happens to
/// provide — and as a missing-glyph box where it provides nothing. The routing
/// gate asks this object before a chapter is served, so a chapter the bundled
/// faces cannot draw stays on the retained renderer (whose host font database
/// is the capability being preserved) until font coverage is extended
/// (5C/FM-22).
///
/// The coverage is read from each font's `cmap` table, so it is the font's own
/// answer rather than a table that can drift from the shipped binaries. Only
/// the format-12 subtable is read: it is the one both bundled fonts and every
/// admitted face the engine accepts carry, and a face without it is reported as
/// unknown coverage (the gate then refuses rather than guesses).
library;

import 'dart:typed_data';

/// The code-point ranges of a set of font faces, merged and sorted.
class EpubFontCoverage {
  const EpubFontCoverage(this.ranges);

  /// Sorted, non-overlapping `(first, last)` inclusive ranges.
  final List<(int, int)> ranges;

  /// Whether every painted scalar of [text] is covered.
  ///
  /// The canonical stream carries generated separators — the newline between
  /// blocks and the tab between table cells — that no face maps because the
  /// layout turns them into breaks rather than glyphs. They are skipped here;
  /// every other scalar must be carried by a face.
  bool coversText(String text) {
    for (final rune in text.runes) {
      if (rune == 0x0A || rune == 0x0D || rune == 0x09) continue;
      if (!covers(rune)) return false;
    }
    return true;
  }

  /// Whether [rune] is covered by any of the faces.
  bool covers(int rune) {
    var low = 0;
    var high = ranges.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final (first, last) = ranges[mid];
      if (rune < first) {
        high = mid - 1;
      } else if (rune > last) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  /// The merged coverage of [fonts], or null when a font's `cmap` cannot be
  /// read (in which case the gate must not assume coverage).
  static EpubFontCoverage? fromFonts(List<Uint8List> fonts) {
    final ranges = <(int, int)>[];
    for (final font in fonts) {
      final face = _cmapFormat12Ranges(font);
      if (face == null) return null;
      ranges.addAll(face);
    }
    return EpubFontCoverage(_merge(ranges));
  }

  /// The merged coverage of [faces], ignoring the ones whose `cmap` cannot be
  /// read.
  ///
  /// Used for a book's admitted `@font-face` faces: a face that cannot be
  /// inspected narrows nothing (the bundled faces still decide), while a face
  /// that can be inspected may admit text the bundled faces do not carry.
  static EpubFontCoverage merge(List<EpubFontCoverage> faces) =>
      EpubFontCoverage(_merge([for (final face in faces) ...face.ranges]));

  static List<(int, int)> _merge(List<(int, int)> input) {
    if (input.isEmpty) return const [];
    final sorted = List<(int, int)>.of(input)
      ..sort((left, right) => left.$1.compareTo(right.$1));
    final merged = <(int, int)>[];
    var (first, last) = sorted.first;
    for (final (start, end) in sorted.skip(1)) {
      if (start <= last + 1) {
        if (end > last) last = end;
        continue;
      }
      merged.add((first, last));
      first = start;
      last = end;
    }
    merged.add((first, last));
    return List.unmodifiable(merged);
  }
}

/// Reads the format-12 `cmap` groups of one TTF/OTF face.
List<(int, int)>? _cmapFormat12Ranges(Uint8List font) {
  final bytes = ByteData.sublistView(font);
  if (font.length < 12) return null;
  final tableCount = bytes.getUint16(4);
  var cmapOffset = -1;
  for (var index = 0; index < tableCount; index += 1) {
    final entry = 12 + index * 16;
    if (entry + 16 > font.length) return null;
    final tag = String.fromCharCodes(font.sublist(entry, entry + 4));
    if (tag == 'cmap') {
      cmapOffset = bytes.getUint32(entry + 8);
      break;
    }
  }
  if (cmapOffset < 0 || cmapOffset + 4 > font.length) return null;
  final subtableCount = bytes.getUint16(cmapOffset + 2);
  for (var index = 0; index < subtableCount; index += 1) {
    final record = cmapOffset + 4 + index * 8;
    if (record + 8 > font.length) return null;
    final offset = cmapOffset + bytes.getUint32(record + 4);
    if (offset + 16 > font.length) continue;
    if (bytes.getUint16(offset) != 12) continue;
    final groupCount = bytes.getUint32(offset + 12);
    final groups = <(int, int)>[];
    var cursor = offset + 16;
    for (var group = 0; group < groupCount; group += 1) {
      if (cursor + 12 > font.length) return null;
      final start = bytes.getUint32(cursor);
      final end = bytes.getUint32(cursor + 4);
      cursor += 12;
      if (end < start || end > 0x10FFFF) return null;
      groups.add((start, end));
    }
    return groups;
  }
  return null;
}
