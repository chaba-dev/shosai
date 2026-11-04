/// Viewport windows over the original PDF's ordered pieces, never reflow.
library;

import 'dart:math' as math;

import 'columns.dart';
import 'page_geometry.dart';

// Furniture outside the strip's coordinate space, shared by controller/view.
const pdfStripHeaderHeight = 32.0;
const pdfStripSideInset = 14.0;

/// A stable cursor in the ordered strip. [y] is in original page points.
final class PdfStripPosition {
  const PdfStripPosition(this.page, {this.region = 0, this.y});
  final int page;
  final int region;
  final double? y;
}

final class PdfStripPage {
  const PdfStripPage(this.geometry, this.columns);
  final PdfPageGeometry geometry;
  final PdfColumnPage columns;
}

/// One visible crop and its affine mapping into the screen's logical pixels.
/// PR3 uses the same mapping for page-space selection, marks and links.
final class PdfStripPiece {
  const PdfStripPiece({
    required this.page,
    required this.region,
    required this.source,
    required this.left,
    required this.top,
    required this.scale,
  });
  final int page;
  final int region;
  final PdfRect source;
  final double left;
  final double top;
  final double scale;

  double get width => source.width * scale;
  double get height => source.height * scale;
  ({double x, double y}) toPage(double x, double y) =>
      (x: source.left + (x - left) / scale, y: source.top + (y - top) / scale);
  ({double x, double y}) fromPage(double x, double y) =>
      (x: left + (x - source.left) * scale, y: top + (y - source.top) * scale);
}

/// Null [page] is a short column rule; otherwise this is a new-page band.
final class PdfStripSeparator {
  const PdfStripSeparator(this.top, {this.page});
  final double top;
  final int? page;
}

final class PdfStripScreen {
  PdfStripScreen({
    required this.start,
    required this.next,
    required this.width,
    required this.height,
    required this.pageWidth,
    required this.pageHeight,
    required List<PdfStripPiece> pieces,
    required List<PdfStripSeparator> separators,
    this.needsPage,
  }) : pieces = List.unmodifiable(pieces),
       separators = List.unmodifiable(separators);

  final PdfStripPosition start;
  final PdfStripPosition next;
  final double width;
  final double height;
  final double pageWidth;
  final double pageHeight;
  final List<PdfStripPiece> pieces;
  final List<PdfStripSeparator> separators;

  /// Geometry to load before this screen can be rendered completely.
  final int? needsPage;
  int get topPage => pieces.first.page;
}

/// Fills one screen across columns and PDF pages. The caller supplies only
/// nearby geometry and retries after loading [PdfStripScreen.needsPage].
/// Text breaks use gaps between physical lines, including overlapping rows.
PdfStripScreen layoutPdfColumnScreen({
  required Map<int, PdfStripPage> pages,
  required int pageCount,
  required PdfStripPosition start,
  required double width,
  required double height,
  double zoom = 1,
}) {
  final pieces = <PdfStripPiece>[];
  final separators = <PdfStripSeparator>[];
  var cursor = start;
  var top = 0.0;
  int? needsPage;
  final contentWidth = width * math.max(1, zoom);
  while (cursor.page < pageCount && top < height - .01) {
    final page = pages[cursor.page];
    if (page == null) {
      needsPage = cursor.page;
      break;
    }
    final regions = page.columns.regions;
    if (cursor.region >= regions.length) {
      cursor = PdfStripPosition(cursor.page + 1);
      continue;
    }
    final region = regions[cursor.region];
    final bounds = region.bounds;
    final y = cursor.y ?? bounds.top;
    final newPage = cursor.region == 0 && cursor.y == null && cursor.page > 0;
    final previous = cursor.region > 0 ? regions[cursor.region - 1] : null;
    final newColumn =
        cursor.y == null &&
        previous != null &&
        // A figure can end a column. Indentation within a column is not a
        // column change: the horizontal intervals still overlap.
        (previous.bounds.right <= bounds.left ||
            previous.bounds.left >= bounds.right);
    final gap = newPage
        ? 28.0
        : newColumn
        ? 16.0
        : pieces.isEmpty
        ? 0.0
        : 12.0;
    if (height - top <= gap) break;
    // Wide bands/figures and fallback pages never need horizontal panning.
    final fitWidth = switch (region.kind) {
      PdfRegionKind.page => width,
      PdfRegionKind.column => width * zoom,
      _ => width * math.min(1, zoom),
    };
    var scale = fitWidth / bounds.width;
    // Overlapping physical lines form an indivisible row (superscripts,
    // equations, etc.). Even a tall row must fit without being cut in two.
    final rows = region.lines.toList()
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    var rowTop = double.negativeInfinity;
    var rowBottom = double.negativeInfinity;
    var tallestLine = 0.0;
    for (final line in rows) {
      if (line.bounds.top >= rowBottom) rowTop = line.bounds.top;
      rowBottom = math.max(rowBottom, line.bounds.bottom);
      tallestLine = math.max(tallestLine, rowBottom - rowTop);
    }
    if (tallestLine * scale > height - gap) {
      scale = (height - gap) / tallestLine;
    }
    var end = math.min(bounds.bottom, y + (height - top - gap) / scale);
    if (end < bounds.bottom) {
      // Moving the cut upward repeatedly handles overlapping line boxes.
      var moved = true;
      while (moved) {
        moved = false;
        for (final line in region.lines) {
          if (line.bounds.top < end && line.bounds.bottom > end) {
            end = line.bounds.top;
            moved = true;
          }
        }
      }
      final before = region.lines.where((line) => line.bounds.bottom <= end);
      if (before.isNotEmpty) {
        final bottom = before.map((l) => l.bounds.bottom).reduce(math.max);
        if (bottom > y) end = (bottom + end) / 2;
      }
    }
    if (end <= y + .001) break;
    if (newPage || newColumn) {
      separators.add(
        PdfStripSeparator(top, page: newPage ? cursor.page : null),
      );
    }
    top += gap;
    pieces.add(
      PdfStripPiece(
        page: cursor.page,
        region: cursor.region,
        source: PdfRect(bounds.left, y, bounds.right, end),
        left:
            ((region.kind == PdfRegionKind.column ? contentWidth : width) -
                bounds.width * scale) /
            2,
        top: top,
        scale: scale,
      ),
    );
    top += (end - y) * scale;
    cursor = end < bounds.bottom
        ? PdfStripPosition(cursor.page, region: cursor.region, y: end)
        : cursor.region + 1 < regions.length
        ? PdfStripPosition(cursor.page, region: cursor.region + 1)
        : PdfStripPosition(cursor.page + 1);
    // A partial piece filled this screen. Its next physical line starts the
    // next screen rather than being squeezed into the remaining whitespace.
    if (end < bounds.bottom) break;
  }
  return PdfStripScreen(
    start: start,
    next: cursor,
    width: contentWidth,
    height: height,
    pageWidth: pieces.isEmpty ? 1 : pages[pieces.first.page]!.geometry.width,
    pageHeight: pieces.isEmpty ? 1 : pages[pieces.first.page]!.geometry.height,
    pieces: pieces,
    separators: separators,
    needsPage: needsPage,
  );
}
