/// Two PDF pages shown side by side as one page.
///
/// A spread pairs pages the way a printed book opens: the cover is shown
/// alone, then (2, 3), (4, 5) and so on, so left pages are even and right
/// pages odd. A last page without a partner is shown alone too. The reader
/// keeps one surface and one raster for what it shows, so a spread is built as
/// a single page: the second page's raster sits beside the first's (to its
/// right, or to its left in a right-to-left document), and its text follows
/// the first page's, its offsets moved past the first page's text. Saved highlights and new ones convert between the spread's offsets
/// and each page's own with [ReaderPdfSpread].
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shosai_flutter/core/bridge.dart';

import 'engine.dart';

/// The first page of the spread [page] belongs to: the cover is a spread of
/// its own, and every later spread starts on an odd unit.
int pdfSpreadStart(int page) => page <= 0 ? 0 : page - (page - 1) % 2;

/// The page shown beside the spread starting at [start] in a document of
/// [pageCount] pages, or null when [start] is shown alone.
int? pdfSpreadFacing(int start, int pageCount) =>
    start > 0 && start == pdfSpreadStart(start) && start + 1 < pageCount
    ? start + 1
    : null;

/// The first page of the spread [delta] (±1) spreads away from the one
/// holding [page]; past either end of the document when there is none.
int pdfSpreadStep(int page, int delta) {
  final start = pdfSpreadStart(page);
  if (delta > 0) return start == 0 ? 1 : start + 2;
  return start <= 1 ? start - 1 : start - 2;
}

/// Where the second page of a spread lives in the spread's surface.
final class ReaderPdfSpread {
  const ReaderPdfSpread({
    required this.facingUnit,
    required this.textShift,
    this.firstLeft = 0,
    this.facingLeft = 0,
  });

  /// The second page's unit; the first is the reader's unit.
  final int facingUnit;

  /// The second page's offset 0 in the spread's text: the first page's text
  /// and a line break come before it.
  final int textShift;

  /// Where the first page's left edge lies in the spread's surface.
  final double firstLeft;

  /// Where the second page's left edge lies in the spread's surface.
  final double facingLeft;

  /// Where [unit]'s left edge lies in the spread's surface, given the
  /// spread's first unit: page geometry such as an area highlight moves
  /// right by it.
  double leftOf(int unit, int firstUnit) => unit == facingUnit
      ? facingLeft
      : unit == firstUnit
      ? firstLeft
      : 0;

  /// The unit that [offset] in the spread's surface belongs to, given the
  /// spread's first unit.
  int unitOf(int offset, int firstUnit) =>
      offset >= textShift ? facingUnit : firstUnit;

  /// [offset] in the spread's surface as an offset in its own page.
  int pageOffset(int offset) =>
      offset >= textShift ? offset - textShift : offset;

  @override
  bool operator ==(Object other) =>
      other is ReaderPdfSpread &&
      other.facingUnit == facingUnit &&
      other.textShift == textShift &&
      other.firstLeft == firstLeft &&
      other.facingLeft == facingLeft;

  @override
  int get hashCode => Object.hash(facingUnit, textShift, firstLeft, facingLeft);
}

/// One surface for two pages laid side by side, [first] on the left, or on
/// the right when [rightToLeft]. [first]'s text comes first either way.
({FlutterSelectionSurface surface, ReaderPdfSpread spread})
mergePdfSpreadSurfaces(
  FlutterSelectionSurface first,
  FlutterSelectionSurface second, {
  required int facingUnit,
  bool rightToLeft = false,
}) {
  final firstLength = first.text.runes.length;
  final shift = firstLength + 1;
  final firstLeft = rightToLeft ? second.width : 0.0;
  final dx = rightToLeft ? 0.0 : first.width;
  final big = BigInt.from(shift);
  FlutterSelectionRect moved(FlutterSelectionRect rect, double dx) =>
      FlutterSelectionRect(
        left: rect.left + dx,
        top: rect.top,
        right: rect.right + dx,
        bottom: rect.bottom,
      );
  Uint32List boundaries(Uint32List left, Uint32List right) {
    final values = <int>{
      ...left,
      firstLength,
      shift,
      for (final b in right) b + shift,
    };
    return Uint32List.fromList(values.toList()..sort());
  }

  return (
    surface: FlutterSelectionSurface(
      width: first.width + second.width,
      height: math.max(first.height, second.height),
      text: '${first.text}\n${second.text}',
      copyEligible: first.copyEligible && second.copyEligible,
      resourcePath: first.resourcePath,
      endpoints: [
        for (final endpoint in first.endpoints)
          firstLeft == 0
              ? endpoint
              : FlutterSelectionEndpoint(
                  offset: endpoint.offset,
                  rangeStart: endpoint.rangeStart,
                  rangeEnd: endpoint.rangeEnd,
                  rect: moved(endpoint.rect, firstLeft),
                ),
        for (final endpoint in second.endpoints)
          FlutterSelectionEndpoint(
            offset: endpoint.offset + big,
            rangeStart: endpoint.rangeStart + big,
            rangeEnd: endpoint.rangeEnd + big,
            rect: moved(endpoint.rect, dx),
          ),
      ],
      graphemeBoundaries: boundaries(
        first.graphemeBoundaries,
        second.graphemeBoundaries,
      ),
      wordBoundaries: boundaries(first.wordBoundaries, second.wordBoundaries),
      visualLines: [
        for (final line in first.visualLines)
          firstLeft == 0 ? line : _movedLine(line, BigInt.zero, firstLeft),
        for (final line in second.visualLines) _movedLine(line, big, dx),
      ],
    ),
    spread: ReaderPdfSpread(
      facingUnit: facingUnit,
      textShift: shift,
      firstLeft: firstLeft,
      facingLeft: dx,
    ),
  );
}

/// [line] with its offsets moved by [shift] and its carets right by [dx].
FlutterSelectionVisualLine _movedLine(
  FlutterSelectionVisualLine line,
  BigInt shift,
  double dx,
) => FlutterSelectionVisualLine(
  carets: [
    for (final caret in line.carets)
      FlutterSelectionCaret(
        offset: caret.offset + shift,
        x: caret.x + dx,
        alongLine: caret.vertical ? caret.alongLine : caret.alongLine + dx,
        vertical: caret.vertical,
        top: caret.top,
        bottom: caret.bottom,
      ),
  ],
);

/// The bitmap size of a spread of two pages of [first] and [second] pixels,
/// side by side.
///
/// Throws [PdfEngineLimitException] when the spread exceeds the engine's
/// limits, though each page alone is within them: two admissible pages can
/// make a raster too wide or too large to decode.
PdfBitmapSize pdfSpreadBitmapSize(PdfBitmapSize first, PdfBitmapSize second) {
  final width = first.width + second.width;
  final height = math.max(first.height, second.height);
  if (width > pdfMaxBitmapDimension ||
      height > pdfMaxBitmapDimension ||
      width * height > pdfMaxBitmapPixels) {
    throw const PdfEngineLimitException(
      'PDF spread bitmap exceeds decoded image limits',
    );
  }
  return PdfBitmapSize(width, height);
}

/// One raster for two pages rendered at the same scale, [first] on the left
/// and both top-aligned; a shorter page leaves transparent pixels below it.
///
/// Throws [PdfEngineLimitException] before allocating a spread larger than
/// the engine's limits.
PdfRenderedPage composePdfSpread(
  PdfRenderedPage first,
  PdfRenderedPage second,
) {
  final size = pdfSpreadBitmapSize(
    PdfBitmapSize(first.width, first.height),
    PdfBitmapSize(second.width, second.height),
  );
  final width = size.width;
  final height = size.height;
  final pixels = Uint8List(width * height * 4);
  for (var row = 0; row < height; row += 1) {
    final target = row * width * 4;
    if (row < first.height) {
      pixels.setRange(
        target,
        target + first.width * 4,
        first.pixels,
        row * first.width * 4,
      );
    }
    if (row < second.height) {
      pixels.setRange(
        target + first.width * 4,
        target + width * 4,
        second.pixels,
        row * second.width * 4,
      );
    }
  }
  return PdfRenderedPage(width: width, height: height, pixels: pixels);
}
