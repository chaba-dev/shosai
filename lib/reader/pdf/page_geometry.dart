/// Owned, renderer-independent geometry in the rotated visible page's points.
/// The origin is the top-left, x increases rightward and y downward. This is
/// also the coordinate system used to crop the engine's rendered page.
library;

import 'dart:math' as math;

final class PdfRect {
  const PdfRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  PdfRect union(PdfRect other) => PdfRect(
    math.min(left, other.left),
    math.min(top, other.top),
    math.max(right, other.right),
    math.max(bottom, other.bottom),
  );
}

/// A physical line, not a row joining text on opposite sides of a gutter.
final class PdfTextLine {
  const PdfTextLine({
    required this.bounds,
    required this.text,
    required this.start,
    required this.end,
  });

  final PdfRect bounds;
  final String text;

  /// Half-open PDFium character indices, identical to selection/search offsets.
  final int start;
  final int end;
}

final class PdfPageGeometry {
  PdfPageGeometry({
    required this.width,
    required this.height,
    required List<PdfTextLine> lines,
    required List<PdfRect> images,
  }) : lines = List.unmodifiable(lines),
       images = List.unmodifiable(images);

  final double width;
  final double height;
  final List<PdfTextLine> lines;

  /// Image objects, including images inside transformed Form XObjects.
  /// Vector drawings are not image objects and remain in the page raster.
  final List<PdfRect> images;
}
