/// Viewport windows over the original PDF's ordered pieces, never reflow.
library;

import 'dart:math' as math;

import 'columns.dart';
import 'engine.dart';
import 'page_geometry.dart';

// Insets inside the sheet but outside strip coordinates, shared by controller/view.
const pdfStripHeaderHeight = 32.0;
const pdfStripDetailHeaderHeight = 44.0;
const pdfStripSideInset = 16.0;

// Numbered headings can use smaller painted glyphs than their body text.
final _numberedHeading = RegExp(r'^\d+(?:\.\d+)*\.?\s+\p{L}', unicode: true);

/// A stable cursor in the ordered strip. [y] is in original page points.
final class PdfStripPosition implements Comparable<PdfStripPosition> {
  const PdfStripPosition(this.page, {this.region = 0, this.y});
  final int page;
  final int region;
  final double? y;

  @override
  int compareTo(PdfStripPosition other) {
    final pageOrder = page.compareTo(other.page);
    if (pageOrder != 0) return pageOrder;
    final regionOrder = region.compareTo(other.region);
    if (regionOrder != 0) return regionOrder;
    return (y ?? double.negativeInfinity).compareTo(
      other.y ?? double.negativeInfinity,
    );
  }
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
    this.kind = PdfRegionKind.column,
  });
  final int page;
  final int region;
  final PdfRect source;
  final double left;
  final double top;
  final double scale;
  final PdfRegionKind kind;

  bool get zoomable =>
      kind == PdfRegionKind.page || kind == PdfRegionKind.figure;

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
    this.strip,
    this.detailZoom = 1,
    this.continuous = false,
    this.viewportTop = 0,
    this.viewportHeight,
    Map<int, ({double width, double height})> pageSizes = const {},
  }) : pieces = List.unmodifiable(pieces),
       pageSizes = Map.unmodifiable(pageSizes),
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

  /// Detail preserves the strip cursor/history while exposing its own exact
  /// page-space transform. Pinching back to fit returns to this strip screen.
  final PdfStripScreen? strip;
  final double detailZoom;
  final bool continuous;
  final double viewportTop;
  final double? viewportHeight;
  final Map<int, ({double width, double height})> pageSizes;

  /// The same window re-anchored so its viewport starts at [top]. Used when a
  /// passive refill must preserve the reading point it raced against.
  PdfStripScreen withViewportTop(double top) => PdfStripScreen(
    start: start,
    next: next,
    width: width,
    height: height,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
    pieces: pieces,
    separators: separators,
    needsPage: needsPage,
    strip: strip,
    detailZoom: detailZoom,
    continuous: continuous,
    viewportTop: top,
    viewportHeight: viewportHeight,
    pageSizes: pageSizes,
  );
  int get topPage => pieces.first.page;

  /// The page occupying most of the viewport, not the overscan raster.
  int visiblePage(double top, double height) {
    final extents = <int, double>{};
    for (final piece in pieces) {
      final extent = math.max(
        0.0,
        math.min(top + height, piece.top + piece.height) -
            math.max(top, piece.top),
      );
      extents.update(piece.page, (old) => old + extent, ifAbsent: () => extent);
    }
    return extents.keys.reduce((a, b) => extents[a]! >= extents[b]! ? a : b);
  }
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
  double topInset = 0,
  double? columnWidth,
  bool continuous = false,
  PdfStripPosition? stop,
}) {
  final pieces = <PdfStripPiece>[];
  final separators = <PdfStripSeparator>[];
  var cursor = start;
  var top = topInset;
  int? needsPage;
  zoom = zoom.clamp(.5, 1);
  var contentWidth = width;
  columnWidth ??= typicalPdfColumnWidth(pages.values.map((p) => p.columns));
  while (cursor.page < pageCount && top < height - .01) {
    if (stop != null && cursor.compareTo(stop) >= 0) break;
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
    final stopY = cursor.page == stop?.page && cursor.region == stop?.region
        ? stop?.y
        : null;
    if (stopY != null && y >= stopY) {
      cursor = stop!;
      break;
    }
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
    // Body columns share the sampled document scale, not their ink crop's
    // width. An inset abstract or overflowing code line must not resize text.
    final fittedWidth = region.kind == PdfRegionKind.column
        ? columnWidth ?? bounds.width
        : bounds.width;
    var scale = fitWidth / fittedWidth;
    if (!continuous && region.kind == PdfRegionKind.figure) {
      scale = math.min(scale, (height - gap) / bounds.height);
      // A figure/table is one object, not a set of paragraph break promises.
      // Leave it for the next screen rather than shrinking to a leftover tail.
      if (top > 0 && bounds.height * scale > height - top - gap) break;
    }
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
    if (!continuous && tallestLine * scale > height - topInset - gap) {
      scale = (height - topInset - gap) / tallestLine;
    }
    var end = math.min(bounds.bottom, y + (height - top - gap) / scale);
    final atStop = stopY != null && end >= stopY;
    if (atStop) end = stopY;
    if (!continuous &&
        !atStop &&
        end < bounds.bottom &&
        region.kind != PdfRegionKind.figure) {
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
      // Carry a paragraph's first row or a heading with its following text.
      // Numbering supplements geometry when a heading is body-sized. Recheck
      // the exposed row after carrying text, so its heading cannot be orphaned.
      // Never move all rows off an otherwise empty screen.
      final visible = rows
          .where((l) => l.bounds.top >= y && l.bounds.bottom <= end)
          .toList();
      while (visible.length > 1) {
        final last = visible.last;
        final index = rows.indexOf(last);
        if (index + 1 >= rows.length) break;
        final prior = visible[visible.length - 2];
        final next = rows[index + 1];
        final beforeGap = last.bounds.top - prior.bounds.bottom;
        final afterGap = next.bounds.top - last.bounds.bottom;
        if (beforeGap >= 0 &&
            (beforeGap > math.max(last.bounds.height * .3, afterGap * 1.5) ||
                last.bounds.height > next.bounds.height * 1.15 ||
                (beforeGap > last.bounds.height * .3 &&
                    _numberedHeading.hasMatch(last.text.trimLeft())))) {
          // An earlier tall line can span the immediately preceding line.
          // Carrying must not undo the safe physical-row cut established above.
          if (rows.any(
            (line) =>
                line.bounds.top < last.bounds.top &&
                line.bounds.bottom > last.bounds.top,
          )) {
            break;
          }
          end = last.bounds.top;
          visible.removeLast();
        } else {
          break;
        }
      }
      if (pieces.isNotEmpty && cursor.y == null && visible.length == 1) {
        // Also applies when carrying a body row exposed the block's heading.
        break;
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
        // Start wide crops at their leading edge. The raster and scroll extent
        // retain all trailing ink at the same document scale.
        left: math.max(0, (width - bounds.width * scale) / 2),
        top: top,
        scale: scale,
        kind: region.kind,
      ),
    );
    contentWidth = math.max(contentWidth, pieces.last.left + pieces.last.width);
    top += (end - y) * scale;
    if (atStop) {
      // A restored screen already starts at this safe physical-row boundary.
      // Do not carry text across it or repeat any of that screen's rows.
      cursor = stop!;
      break;
    }
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

/// A bounded raster window in the same strip, without screen-break promises.
/// Nearby page geometry is cheap; only the viewport and one viewport on either
/// side are rasterized. Cropping a line at the window edge never inserts space.
PdfStripScreen layoutPdfColumnWindow({
  required Map<int, PdfStripPage> pages,
  required int pageCount,
  required PdfStripPosition position,
  required double width,
  required double height,
  double zoom = 1,
  double topInset = 0,
  double? columnWidth,
  double? overscan,
  double density = 1,
}) {
  final lead = overscan ?? height;
  var firstPage = math.max(0, position.page - 1);
  var endPage = math.min(pageCount, position.page + 2);
  while (endPage < pageCount && pages.containsKey(endPage)) {
    endPage++;
  }
  late PdfStripScreen strip;
  late double anchor;
  while (true) {
    strip = layoutPdfColumnScreen(
      pages: pages,
      pageCount: endPage,
      start: PdfStripPosition(firstPage),
      width: width,
      height: double.infinity,
      zoom: zoom,
      columnWidth: columnWidth,
      continuous: true,
    );
    if (strip.needsPage != null) return strip;
    final target = strip.pieces.firstWhere(
      (p) => p.page == position.page && p.region == position.region,
    );
    anchor = target
        .fromPage(target.source.left, position.y ?? target.source.top)
        .y;
    // One preceding page may be shorter than a step or its overscan. Admit
    // geometry until the requested origin is represented, not a local zero.
    if (firstPage == 0 || anchor - topInset >= lead) break;
    firstPage--;
  }
  final end = strip.pieces.last.top + strip.pieces.last.height;
  if (end < anchor + 2 * height && endPage < pageCount) {
    return PdfStripScreen(
      start: strip.start,
      next: strip.next,
      width: width,
      height: height,
      pageWidth: strip.pageWidth,
      pageHeight: strip.pageHeight,
      pieces: strip.pieces,
      separators: strip.separators,
      needsPage: endPage,
    );
  }
  final viewport = (anchor - topInset).clamp(0.0, math.max(0, end - height));
  final from = math.max(0.0, viewport - lead);
  final to = math.min(end, viewport + height + lead);
  final pieces = <PdfStripPiece>[];
  for (final piece in strip.pieces) {
    final top = math.max(from, piece.top);
    final bottom = math.min(to, piece.top + piece.height);
    if (top >= bottom) continue;
    pieces.add(
      PdfStripPiece(
        page: piece.page,
        region: piece.region,
        source: PdfRect(
          piece.source.left,
          piece.toPage(piece.left, top).y,
          piece.source.right,
          piece.toPage(piece.left, bottom).y,
        ),
        left: piece.left,
        top: top - from,
        scale: piece.scale,
        kind: piece.kind,
      ),
    );
  }
  final contentWidth = pieces.fold(
    width,
    (w, p) => math.max(w, p.left + p.width),
  );
  final rasterHeight =
      math.min(
        pdfMaxBitmapDimension / density,
        pdfMaxBitmapPixels / (contentWidth * density).ceil() / density,
      ) -
      1;
  final admittedLead = math.max(
    0.0,
    math.min(lead, (rasterHeight - height) / 2),
  );
  if (admittedLead < lead) {
    // Overflow keeps its crop and scale; only optional vertical overscan gives
    // way to the actual composed raster's width at this device density.
    return layoutPdfColumnWindow(
      pages: pages,
      pageCount: pageCount,
      position: position,
      width: width,
      height: height,
      zoom: zoom,
      topInset: topInset,
      columnWidth: columnWidth,
      overscan: admittedLead,
      density: density,
    );
  }
  final first = pieces.first;
  final last = pieces.last;
  final lastRegion = pages[last.page]!.columns.regions[last.region];
  final next = last.source.bottom < lastRegion.bounds.bottom - .001
      ? PdfStripPosition(last.page, region: last.region, y: last.source.bottom)
      : last.region + 1 < pages[last.page]!.columns.regions.length
      ? PdfStripPosition(last.page, region: last.region + 1)
      : PdfStripPosition(last.page + 1);
  final page = pages[first.page]!.geometry;
  return PdfStripScreen(
    start: PdfStripPosition(
      first.page,
      region: first.region,
      y: first.source.top,
    ),
    next: next,
    width: contentWidth,
    height: math.max(height, to - from),
    pageWidth: page.width,
    pageHeight: page.height,
    pieces: pieces,
    separators: [
      for (final separator in strip.separators)
        if (separator.top >= from && separator.top < to)
          PdfStripSeparator(separator.top - from, page: separator.page),
    ],
    continuous: true,
    viewportTop: viewport - from,
    viewportHeight: height,
    pageSizes: {
      for (final piece in pieces)
        piece.page: (
          width: pages[piece.page]!.geometry.width,
          height: pages[piece.page]!.geometry.height,
        ),
    },
  );
}
