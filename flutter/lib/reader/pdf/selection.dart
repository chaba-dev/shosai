/// PDFium-independent selection geometry for one rendered PDF page.
///
/// This is the Dart port of the retained core's `PdfSelectionSnapshot`
/// (`crates/shosai-core/src/pdf.rs`): the engine samples every PDFium
/// character once (its code point, loose glyph box, device rectangle and
/// baseline orientation) and this module turns the samples into the
/// `FlutterSelectionSurface` the reader already consumes. Nothing here touches
/// PDFium, so the contract is testable from fixtures alone.
///
/// Offsets in the surface are PDFium character indexes, which are also scalar
/// indexes into [FlutterSelectionSurface.text]: the text carries exactly one
/// scalar per PDFium character, with U+FFFD standing in for a character whose
/// text PDFium could not map. Annotation anchors are therefore stable across
/// the engine replacement.
library;

import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:shosai_epub/shosai_epub.dart' show navigationBoundaries;
import 'package:shosai_flutter/core/bridge.dart';

/// Maximum number of character endpoints retained for one selectable page.
const int pdfSelectionMaxEndpoints = 65536;

/// Maximum page text, in scalars, retained for one selectable page.
const int pdfSelectionMaxTextScalars = 8 * 1024 * 1024;

/// One PDFium character as sampled by the engine.
///
/// Geometry that PDFium could not report is left null and the character then
/// contributes to the page text only.
final class PdfCharacterSample {
  const PdfCharacterSample({
    required this.index,
    required this.codePoint,
    required this.generated,
    required this.visible,
    this.pageBounds,
    this.deviceBounds,
    this.baseline,
  });

  /// PDFium character index on the page.
  final int index;

  /// Unicode scalar PDFium reports for the character, `0` when it has none.
  final int codePoint;

  /// Whether PDFium generated the character (a synthetic space or line break).
  final bool generated;

  /// Whether the loose glyph box overlaps the page's bounding box.
  final bool visible;

  /// Loose glyph box in PDF page points, `(left, bottom, right, top)`.
  final PdfPageBounds? pageBounds;

  /// Loose glyph box in bitmap pixels, before clamping to the bitmap.
  final PdfDeviceBounds? deviceBounds;

  /// Device-space delta of a probe along the text matrix baseline.
  final PdfBaselineProbe? baseline;
}

/// A rectangle in PDF page points.
final class PdfPageBounds {
  const PdfPageBounds(this.left, this.bottom, this.right, this.top);

  final double left;
  final double bottom;
  final double right;
  final double top;

  @override
  bool operator ==(Object other) =>
      other is PdfPageBounds &&
      other.left == left &&
      other.bottom == bottom &&
      other.right == right &&
      other.top == top;

  @override
  int get hashCode => Object.hash(left, bottom, right, top);
}

/// An integer rectangle in bitmap pixels.
final class PdfDeviceBounds {
  const PdfDeviceBounds(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;
}

/// Device-space delta of a probe advanced along a character's baseline.
final class PdfBaselineProbe {
  const PdfBaselineProbe(this.dx, this.dy);

  final int dx;
  final int dy;
}

/// The selection surface built for one page, plus the extraction verdicts the
/// reader records.
final class PdfPageSelection {
  const PdfPageSelection({
    required this.surface,
    required this.mappingComplete,
  });

  final FlutterSelectionSurface surface;

  /// Whether every PDFium character mapped to genuine text. U+FFFD reported by
  /// PDFium itself is genuine; only extractor substitution makes this false.
  final bool mappingComplete;
}

/// Thrown when a page exceeds a retained-geometry ceiling.
final class PdfSelectionLimitException implements Exception {
  const PdfSelectionLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds the selection surface for one rendered page.
///
/// [samples] are in PDFium index order. [bitmapWidth] and [bitmapHeight] are
/// the pixel size the page was rendered at for the same scale.
PdfPageSelection buildPdfPageSelection({
  required int bitmapWidth,
  required int bitmapHeight,
  required List<PdfCharacterSample> samples,
}) {
  if (samples.length * 2 > pdfSelectionMaxEndpoints) {
    throw const PdfSelectionLimitException(
      'PDF page exceeds the $pdfSelectionMaxEndpoints-endpoint selection '
      'ceiling',
    );
  }
  if (samples.length > pdfSelectionMaxTextScalars) {
    throw const PdfSelectionLimitException(
      'PDF page text exceeds its scalar limit',
    );
  }
  final geometries = <_CharacterGeometry>[];
  for (final sample in samples) {
    final pageBounds = sample.pageBounds;
    final device = sample.deviceBounds;
    if (pageBounds == null || device == null) continue;
    final bounds = _Rect(
      device.left.clamp(0, bitmapWidth).toDouble(),
      device.top.clamp(0, bitmapHeight).toDouble(),
      device.right.clamp(0, bitmapWidth).toDouble(),
      device.bottom.clamp(0, bitmapHeight).toDouble(),
    );
    if (bounds.left >= bounds.right || bounds.top >= bounds.bottom) continue;
    final direction = sample.codePoint == 0
        ? null
        : pdfTextDirection(sample.codePoint);
    final probe = sample.baseline;
    ({bool vertical, bool forwardPositive})? orientation;
    if (probe != null && (probe.dx != 0 || probe.dy != 0)) {
      final vertical = probe.dy.abs() > probe.dx.abs();
      orientation = _logicalOrientation((
        vertical: vertical,
        forwardPositive: vertical ? probe.dy > 0 : probe.dx > 0,
      ), direction);
    }
    geometries.add(
      _CharacterGeometry(
        bounds: bounds,
        pageBounds: pageBounds,
        character: sample.index,
        pageX: (pageBounds.left + pageBounds.right) / 2,
        pageY: (pageBounds.bottom + pageBounds.top) / 2,
        orientation: orientation,
        direction: direction,
      ),
    );
  }
  _resolveNeutralDirections(geometries);

  final zones = <_Zone>[];
  final glyphs = <({int start, int end})>[];
  var start = 0;
  while (start < geometries.length) {
    var end = start + 1;
    while (end < geometries.length &&
        geometries[end].character == geometries[end - 1].character + 1 &&
        _sameGlyph(geometries[start], geometries[end])) {
      end++;
    }
    glyphs.add((start: start, end: end));
    start = end;
  }
  for (var position = 0; position < glyphs.length; position++) {
    final glyph = glyphs[position];
    final first = geometries[glyph.start];
    final last = geometries[glyph.end - 1];
    final previous = position == 0
        ? null
        : geometries[glyphs[position - 1].end - 1];
    final next = position + 1 < glyphs.length
        ? geometries[glyphs[position + 1].start]
        : null;
    final direction = _characterDirection(previous, first, last, next);
    _appendGlyphZones(
      zones,
      geometries.sublist(glyph.start, glyph.end),
      direction.vertical,
      direction.forwardPositive,
    );
  }
  if (zones.length > pdfSelectionMaxEndpoints) {
    throw const PdfSelectionLimitException(
      'PDF page exceeds the $pdfSelectionMaxEndpoints-endpoint selection '
      'ceiling',
    );
  }

  final text = StringBuffer();
  var mappingComplete = true;
  for (final sample in samples) {
    // Generated whitespace and line breaks keep their index even though they
    // often have no visible bounds.
    final visible = sample.generated || sample.visible;
    if (visible && sample.codePoint != 0 && _isScalar(sample.codePoint)) {
      text.writeCharCode(sample.codePoint);
    } else {
      text.writeCharCode(0xFFFD);
      mappingComplete = false;
    }
  }
  final ownedText = text.toString();
  _snapZonesToGraphemes(zones, ownedText);
  final lines = _keyboardLines(List.of(zones));
  final rows = _selectionRows(zones);
  final boundaries = navigationBoundaries(ownedText);
  final endpoints = <FlutterSelectionEndpoint>[
    for (final row in rows)
      for (final zone in row.zones)
        FlutterSelectionEndpoint(
          offset: BigInt.from(zone.caret),
          rangeStart: BigInt.from(zone.character),
          rangeEnd: BigInt.from(zone.character + 1),
          rect: FlutterSelectionRect(
            left: zone.bounds.left,
            top: zone.bounds.top,
            right: zone.bounds.right,
            bottom: zone.bounds.bottom,
          ),
        ),
  ];
  final visualLines = <FlutterSelectionVisualLine>[];
  for (final line in lines) {
    final carets = <FlutterSelectionCaret>[
      for (final zone in line.zones)
        if (zone.visualCaret)
          FlutterSelectionCaret(
            offset: BigInt.from(zone.caret),
            x: zone.caretX,
            alongLine: zone.vertical ? zone.caretY : zone.caretX,
            vertical: zone.vertical,
            top: line.bounds.top,
            bottom: line.bounds.bottom,
          ),
    ];
    carets.sort((left, right) => left.alongLine.compareTo(right.alongLine));
    final deduped = <FlutterSelectionCaret>[];
    for (final caret in carets) {
      if (deduped.isNotEmpty &&
          deduped.last.offset == caret.offset &&
          deduped.last.alongLine == caret.alongLine) {
        continue;
      }
      deduped.add(caret);
    }
    visualLines.add(FlutterSelectionVisualLine(carets: deduped));
  }
  return PdfPageSelection(
    surface: FlutterSelectionSurface(
      width: bitmapWidth.toDouble(),
      height: bitmapHeight.toDouble(),
      text: ownedText,
      copyEligible: mappingComplete,
      resourcePath: null,
      endpoints: endpoints,
      graphemeBoundaries: Uint32List.fromList(boundaries.graphemes),
      wordBoundaries: Uint32List.fromList(boundaries.words),
      visualLines: visualLines,
    ),
    mappingComplete: mappingComplete,
  );
}

/// Page text alone, one scalar per PDFium character, with the mapping verdict.
///
/// This is the search and store-side view of a page: the same substitution
/// rule as [buildPdfPageSelection] without any geometry.
({String text, bool mappingComplete}) pdfPageText(
  List<PdfCharacterSample> samples,
) {
  if (samples.length > pdfSelectionMaxTextScalars) {
    throw const PdfSelectionLimitException(
      'PDF page text exceeds its scalar limit',
    );
  }
  final text = StringBuffer();
  var complete = true;
  for (final sample in samples) {
    final visible = sample.generated || sample.visible;
    if (visible && sample.codePoint != 0 && _isScalar(sample.codePoint)) {
      text.writeCharCode(sample.codePoint);
    } else {
      text.writeCharCode(0xFFFD);
      complete = false;
    }
  }
  return (text: text.toString(), mappingComplete: complete);
}

bool _isScalar(int codePoint) =>
    codePoint >= 0 &&
    codePoint <= 0x10FFFF &&
    !(codePoint >= 0xD800 && codePoint <= 0xDFFF);

/// Strong bidi direction of a scalar, or null for a neutral one.
///
/// A bounded port of `unicode_bidi::bidi_class`: letters and decimal digits
/// outside the right-to-left scripts are left-to-right (`L`, `EN`, `AN`), the
/// right-to-left script blocks are right-to-left (`R`, `AL`), and everything
/// else (punctuation, whitespace, marks, symbols) is neutral.
PdfTextDirection? pdfTextDirection(int codePoint) {
  if (_isRightToLeft(codePoint)) return PdfTextDirection.rightToLeft;
  if (_strongLeftToRight.hasMatch(String.fromCharCode(codePoint))) {
    return PdfTextDirection.leftToRight;
  }
  return null;
}

final RegExp _strongLeftToRight = RegExp(r'^[\p{L}\p{Nd}]$', unicode: true);

bool _isRightToLeft(int c) =>
    (c >= 0x0590 && c <= 0x08FF) ||
    (c >= 0xFB1D && c <= 0xFDFF) ||
    (c >= 0xFE70 && c <= 0xFEFF) ||
    (c >= 0x10800 && c <= 0x10FFF) ||
    (c >= 0x1E800 && c <= 0x1EFFF);

/// Strong text direction of a PDF character.
enum PdfTextDirection { leftToRight, rightToLeft }

final class _Rect {
  const _Rect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  bool contains(double x, double y) =>
      x >= left && x < right && y >= top && y < bottom;

  @override
  bool operator ==(Object other) =>
      other is _Rect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

final class _CharacterGeometry {
  _CharacterGeometry({
    required this.bounds,
    required this.pageBounds,
    required this.character,
    required this.pageX,
    required this.pageY,
    required this.orientation,
    required this.direction,
  });

  final _Rect bounds;
  final PdfPageBounds pageBounds;
  final int character;
  final double pageX;
  final double pageY;
  ({bool vertical, bool forwardPositive})? orientation;
  PdfTextDirection? direction;
}

final class _Zone {
  _Zone({
    required this.bounds,
    required this.lineBounds,
    required this.character,
    required this.caret,
    required this.caretX,
    required this.caretY,
    required this.vertical,
    required this.visualCaret,
  });

  final _Rect bounds;

  /// Unsplit glyph geometry used for keyboard line classification.
  final _Rect lineBounds;

  /// PDFium character whose glyph bounds own this half-zone.
  final int character;

  /// Caret boundary represented by this half-zone.
  int caret;
  final double caretX;
  final double caretY;
  final bool vertical;
  bool visualCaret;
}

final class _Row {
  _Row(this.bounds, this.zones);

  _Rect bounds;
  final List<_Zone> zones;
}

({bool vertical, bool forwardPositive}) _logicalOrientation(
  ({bool vertical, bool forwardPositive}) orientation,
  PdfTextDirection? direction,
) => (
  vertical: orientation.vertical,
  forwardPositive: direction == PdfTextDirection.rightToLeft
      ? !orientation.forwardPositive
      : orientation.forwardPositive,
);

void _resolveNeutralDirections(List<_CharacterGeometry> characters) {
  var start = 0;
  while (start < characters.length) {
    if (characters[start].direction != null) {
      start++;
      continue;
    }
    var end = start + 1;
    while (end < characters.length && characters[end].direction == null) {
      end++;
    }
    final previous = start == 0 ? null : characters[start - 1];
    final next = end < characters.length ? characters[end] : null;
    var contiguous = true;
    for (var i = start + 1; i < end; i++) {
      if (characters[i].character != characters[i - 1].character + 1) {
        contiguous = false;
        break;
      }
    }
    final direction = previous?.direction;
    if (contiguous &&
        previous != null &&
        characters[start].character == previous.character + 1 &&
        next != null &&
        next.character == characters[end - 1].character + 1 &&
        direction != null &&
        direction == next.direction) {
      for (var i = start; i < end; i++) {
        final character = characters[i];
        character.direction = direction;
        final orientation = character.orientation;
        if (orientation != null) {
          character.orientation = _logicalOrientation(orientation, direction);
        }
      }
    }
    start = end;
  }
}

({bool vertical, bool forwardPositive})? _neighborDirection(
  _Rect current,
  _Rect next,
) {
  final dx = next.left + next.right - current.left - current.right;
  final dy = next.top + next.bottom - current.top - current.bottom;
  final vertical = dy.abs() > dx.abs();
  final sharesRunAxis = vertical
      ? next.right > current.left && next.left < current.right
      : next.bottom > current.top && next.top < current.bottom;
  if (!sharesRunAxis || (dx == 0 && dy == 0)) return null;
  return (vertical: vertical, forwardPositive: vertical ? dy > 0 : dx > 0);
}

({bool vertical, bool forwardPositive}) _characterDirection(
  _CharacterGeometry? previous,
  _CharacterGeometry first,
  _CharacterGeometry last,
  _CharacterGeometry? next,
) {
  ({bool vertical, bool forwardPositive})? nextDirection;
  if (next != null &&
      next.character == last.character + 1 &&
      last.direction == next.direction) {
    nextDirection = _neighborDirection(first.bounds, next.bounds);
  }
  ({bool vertical, bool forwardPositive})? previousDirection;
  if (previous != null &&
      first.character == previous.character + 1 &&
      previous.direction == first.direction) {
    previousDirection = _neighborDirection(previous.bounds, first.bounds);
  }
  return nextDirection ??
      previousDirection ??
      first.orientation ??
      (vertical: false, forwardPositive: true);
}

bool _sameGlyph(_CharacterGeometry left, _CharacterGeometry right) =>
    left.bounds == right.bounds &&
    left.pageBounds == right.pageBounds &&
    left.pageX == right.pageX &&
    left.pageY == right.pageY;

_Rect _subdivision(_Rect bounds, bool vertical, int index, int count) {
  final start = index / count;
  final end = (index + 1) / count;
  if (vertical) {
    final height = bounds.bottom - bounds.top;
    return _Rect(
      bounds.left,
      bounds.top + height * start,
      bounds.right,
      bounds.top + height * end,
    );
  }
  final width = bounds.right - bounds.left;
  return _Rect(
    bounds.left + width * start,
    bounds.top,
    bounds.left + width * end,
    bounds.bottom,
  );
}

void _appendGlyphZones(
  List<_Zone> zones,
  List<_CharacterGeometry> glyph,
  bool vertical,
  bool forwardPositive,
) {
  final bounds = glyph[0].bounds;
  final halfCount = glyph.length * 2;
  for (var position = 0; position < glyph.length; position++) {
    final geometry = glyph[position];
    for (final (caret, logicalHalf) in [
      (geometry.character, position * 2),
      (geometry.character + 1, position * 2 + 1),
    ]) {
      final physicalHalf = forwardPositive
          ? logicalHalf
          : halfCount - logicalHalf - 1;
      final logicalBoundary = position + (caret > geometry.character ? 1 : 0);
      final physicalBoundary = forwardPositive
          ? logicalBoundary
          : glyph.length - logicalBoundary;
      final caretX = vertical
          ? (bounds.left + bounds.right) / 2
          : bounds.left +
                (bounds.right - bounds.left) * physicalBoundary / glyph.length;
      final caretY = vertical
          ? bounds.top +
                (bounds.bottom - bounds.top) * physicalBoundary / glyph.length
          : (bounds.top + bounds.bottom) / 2;
      zones.add(
        _Zone(
          bounds: _subdivision(bounds, vertical, physicalHalf, halfCount),
          lineBounds: bounds,
          character: geometry.character,
          caret: caret,
          caretX: caretX,
          caretY: caretY,
          vertical: vertical,
          visualCaret: true,
        ),
      );
    }
  }
}

/// `(leading, trailing)` grapheme boundary for every scalar of [text].
List<(int, int)> _graphemeBoundaryMap(String text) {
  final map = <(int, int)>[];
  var scalar = 0;
  for (final grapheme in text.characters) {
    final count = grapheme.runes.length;
    final end = scalar + count;
    for (var i = 0; i < count; i++) {
      map.add((scalar, end));
    }
    scalar = end;
  }
  return map;
}

void _snapZonesToGraphemes(List<_Zone> zones, String text) {
  final map = _graphemeBoundaryMap(text);
  for (final zone in zones) {
    if (zone.character >= map.length) continue;
    final (leading, trailing) = map[zone.character];
    final originalCaret = zone.caret;
    final isTrailing = originalCaret != zone.character;
    zone.caret = isTrailing ? trailing : leading;
    // Per-character hit zones and persistence geometry stay; only whole
    // grapheme edges are exposed to keyboard traversal. Separate visual edges
    // that share an offset (bidi affinity) stay intact.
    zone.visualCaret = isTrailing
        ? originalCaret == trailing
        : originalCaret == leading;
  }
}

List<_Row> _selectionRows(List<_Zone> zones) {
  final sorted = List.of(zones)
    ..sort((left, right) {
      final byTop = left.bounds.top.compareTo(right.bounds.top);
      return byTop != 0 ? byTop : left.bounds.left.compareTo(right.bounds.left);
    });
  final rows = <_Row>[];
  for (final zone in sorted) {
    final last = rows.isEmpty ? null : rows.last;
    if (last != null &&
        zone.bounds.bottom > last.bounds.top &&
        zone.bounds.top < last.bounds.bottom) {
      last.bounds = _Rect(
        _min(last.bounds.left, zone.bounds.left),
        _min(last.bounds.top, zone.bounds.top),
        _max(last.bounds.right, zone.bounds.right),
        _max(last.bounds.bottom, zone.bounds.bottom),
      );
      last.zones.add(zone);
    } else {
      rows.add(_Row(zone.bounds, [zone]));
    }
  }
  return rows;
}

List<_Row> _keyboardLines(List<_Zone> zones) {
  zones.sort((left, right) {
    if (left.vertical != right.vertical) return left.vertical ? 1 : -1;
    final primary = left.vertical
        ? left.lineBounds.left.compareTo(right.lineBounds.left)
        : left.lineBounds.top.compareTo(right.lineBounds.top);
    if (primary != 0) return primary;
    return left.vertical
        ? left.lineBounds.top.compareTo(right.lineBounds.top)
        : left.lineBounds.left.compareTo(right.lineBounds.left);
  });
  final lines = <_Row>[];
  for (final zone in zones) {
    final last = lines.isEmpty ? null : lines.last;
    final sameLine =
        last != null &&
        last.zones.first.vertical == zone.vertical &&
        (zone.vertical
            ? zone.lineBounds.right > last.bounds.left &&
                  zone.lineBounds.left < last.bounds.right
            : zone.lineBounds.bottom > last.bounds.top &&
                  zone.lineBounds.top < last.bounds.bottom);
    if (sameLine) {
      last.bounds = _Rect(
        _min(last.bounds.left, zone.lineBounds.left),
        _min(last.bounds.top, zone.lineBounds.top),
        _max(last.bounds.right, zone.lineBounds.right),
        _max(last.bounds.bottom, zone.lineBounds.bottom),
      );
      last.zones.add(zone);
    } else {
      lines.add(_Row(zone.lineBounds, [zone]));
    }
  }
  return lines;
}

double _min(double a, double b) => a < b ? a : b;
double _max(double a, double b) => a > b ? a : b;
