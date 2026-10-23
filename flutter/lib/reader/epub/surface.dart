/// Page geometry for the Dart EPUB renderer: the selection surface of one page
/// window and the painting of that page's slices.
///
/// Endpoints, visual lines and boundaries are derived from the same
/// [TextPainter]s the page painter draws, so pixels, hit testing and selection
/// geometry cannot drift apart. Offsets are *chapter-relative canonical
/// scalars*, the same stream the retained Rust renderer, search and the
/// annotation store use.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';

import 'flow.dart';
import 'pages.dart';
import 'text_style.dart';

/// The painted content box of one page inside the page window.
///
/// The flow a page shows is laid out in its own frame: lines run along its x
/// axis and stack down its y axis, from the content's corner. A horizontal
/// page places that frame at [origin]. A [vertical] page turns it a quarter
/// turn clockwise, so lines run down the page and stack from its right edge
/// to its left, as `vertical-rl` text does.
class EpubPageBox {
  const EpubPageBox({
    required this.size,
    required this.origin,
    required this.contentWidth,
    required this.contentHeight,
    this.vertical = false,
  });

  /// The page window's own size; the surface's coordinate space.
  final Size size;

  /// Top-left of the laid-out content inside [size].
  final Offset origin;

  /// The laid-out content extent, on the page.
  final double contentWidth;
  final double contentHeight;

  /// Whether the page shows a vertical flow.
  final bool vertical;

  /// The length of a line: the flow's width.
  double get inlineExtent => vertical ? contentHeight : contentWidth;

  /// The extent lines stack along: the flow's height on one page.
  double get blockExtent => vertical ? contentWidth : contentHeight;

  /// The page point of [flow], a point in the flow's frame.
  Offset toPage(Offset flow) => vertical
      ? Offset(origin.dx + contentWidth - flow.dy, origin.dy + flow.dx)
      : flow + origin;

  /// The flow point under [page], a point on the page.
  Offset toFlow(Offset page) => vertical
      ? Offset(page.dy - origin.dy, origin.dx + contentWidth - page.dx)
      : page - origin;

  /// The page rectangle of [flow], a rectangle in the flow's frame.
  Rect rectToPage(Rect flow) => vertical
      ? Rect.fromLTRB(
          origin.dx + contentWidth - flow.bottom,
          origin.dy + flow.left,
          origin.dx + contentWidth - flow.top,
          origin.dy + flow.right,
        )
      : flow.shift(origin);

  /// Moves [canvas] into the flow's frame.
  void transformToFlow(Canvas canvas) {
    if (!vertical) {
      canvas.translate(origin.dx, origin.dy);
      return;
    }
    canvas.translate(origin.dx + contentWidth, origin.dy);
    canvas.rotate(math.pi / 2);
  }
}

/// Builds the selection surface of one page window.
///
/// The surface's text is the chapter's canonical stream, so a copy, a saved
/// highlight or a durable reading offset is expressed in the same offsets the
/// retained implementation and the annotation store use. [page] only decides
/// which geometry exists in this surface.
FlutterSelectionSurface buildPageSelectionSurface({
  required FlowPage page,
  required String canonicalText,
  required String resourcePath,
  required EpubPageBox box,
  FlowPage? facing,
  EpubPageBox? facingBox,
}) {
  final geometry = pageSelectionGeometry(page, box);
  // A spread's second page continues the first in the chapter's canonical
  // stream, so its geometry follows the first page's in reading order and
  // one surface spans both.
  final facingGeometry = facing == null || facingBox == null
      ? null
      : pageSelectionGeometry(facing, facingBox);
  final start = page.canonicalStart;
  final end = facingGeometry == null ? page.canonicalEnd : facing!.canonicalEnd;
  final boundaries = _boundariesFor(canonicalText, start, end);
  return FlutterSelectionSurface(
    width: box.size.width,
    height: box.size.height,
    text: canonicalText,
    copyEligible: true,
    resourcePath: resourcePath,
    endpoints: [...geometry.endpoints, ...?facingGeometry?.endpoints],
    graphemeBoundaries: Uint32List.fromList(boundaries.graphemes),
    wordBoundaries: Uint32List.fromList(boundaries.words),
    visualLines: [...geometry.visualLines, ...?facingGeometry?.visualLines],
  );
}

/// The endpoints and visual lines of [page]'s text, placed by [box].
///
/// Shared by a page's own surface and by a continuous window, which builds
/// this once per laid-out node and places the result at the node's top.
({
  List<FlutterSelectionEndpoint> endpoints,
  List<FlutterSelectionVisualLine> visualLines,
})
pageSelectionGeometry(FlowPage page, EpubPageBox box) {
  final endpoints = <FlutterSelectionEndpoint>[];
  final visualLines = <FlutterSelectionVisualLine>[];
  for (final slice in page.slices) {
    for (final placed in placedPageText(slice)) {
      // Lines come in text order, so one cursor maps the whole block.
      final cursor = placed.block.map.cursor();
      for (var line = placed.lineStart; line < placed.lineEnd; line++) {
        // Each line carries its own vertical position: the block origin is the
        // painter's top, and the line's `top` is relative to it.
        final lineTop = placed.origin.dy + placed.block.lines[line].top;
        final carets = _lineCarets(
          placed.block,
          placed.block.lines[line],
          lineTop,
          placed.origin.dx,
          endpoints,
          cursor,
          box,
        );
        if (carets.isEmpty) continue;
        carets.sort((left, right) => left.alongLine.compareTo(right.alongLine));
        final deduped = <FlutterSelectionCaret>[];
        for (final caret in carets) {
          if (deduped.isNotEmpty && deduped.last.offset == caret.offset) {
            continue;
          }
          deduped.add(caret);
        }
        visualLines.add(FlutterSelectionVisualLine(carets: deduped));
      }
    }
  }
  return (endpoints: endpoints, visualLines: visualLines);
}

/// The link href at [position] in the page window's coordinates, or null.
///
/// The hit test walks the same [placedPageText] geometry the page painter and
/// the selection surface use, so a link is activated exactly where its glyphs
/// are painted. A text slice is bounded by its own visible line window rather
/// than the whole measured block, so a line that belongs to the next page
/// cannot be hit from this one.
String? pageLinkAt(FlowPage page, EpubPageBox box, Offset position) {
  final flow = box.toFlow(position);
  for (final slice in page.slices) {
    for (final placed in placedPageText(slice)) {
      final block = placed.block;
      final local = flow - placed.origin;
      if (local.dx < 0 ||
          local.dy < 0 ||
          local.dx > block.width ||
          local.dy > block.height) {
        continue;
      }
      if (slice is TextPageSlice) {
        final firstLine = block.lines[placed.lineStart].top;
        final lastLine = block.lines[placed.lineEnd - 1];
        if (local.dy < firstLine || local.dy > lastLine.top + lastLine.height) {
          continue;
        }
      }
      final href = block.linkAtLocal(local);
      if (href != null) return href;
    }
  }
  return null;
}

/// One text block placed on a page, with the page coordinates it paints at.
class PlacedPageText {
  const PlacedPageText({
    required this.block,
    required this.origin,
    required this.lineStart,
    required this.lineEnd,
  });

  final FlowTextBlock block;

  /// Where the block's own top-left corner is in the page's flow frame (see
  /// [EpubPageBox]).
  final Offset origin;

  /// Line window of the block that this page places.
  final int lineStart;
  final int lineEnd;
}

/// Every text block a page slice paints, in painting order.
///
/// This is the single source of a page's text geometry: the selection surface
/// walks it, so a pointer addresses the same glyphs the page painter draws —
/// including table cell text, table captions, image captions and a missing
/// image's visible alt fallback.
List<PlacedPageText> placedPageText(PageSlice slice) {
  if (slice is TextPageSlice) {
    final text = slice.block.text!;
    return [
      PlacedPageText(
        block: text,
        origin: Offset(0, slice.top - text.lines[slice.lineStart].top),
        lineStart: slice.lineStart,
        lineEnd: slice.lineEnd,
      ),
    ];
  }
  final placed = <PlacedPageText>[];
  void addBlock(FlowTextBlock? text, double x, double y) {
    if (text == null || text.lines.isEmpty) return;
    placed.add(
      PlacedPageText(
        block: text,
        origin: Offset(x, y),
        lineStart: 0,
        lineEnd: text.lines.length,
      ),
    );
  }

  void addTableRows(
    FlowTableBlock table,
    int rowStart,
    int rowEnd,
    double top,
  ) {
    var y = top;
    for (var index = rowStart; index < rowEnd; index++) {
      final row = table.rows[index];
      for (final cell in row.cells) {
        var cellY = y + 6.0;
        for (final text in cell.blocks) {
          addBlock(text, cell.left + 6.0, cellY);
          cellY += text.height;
        }
      }
      y += row.height;
    }
  }

  if (slice is TablePageSlice) {
    final table = slice.block.table!;
    if (slice.rowEnd <= slice.rowStart) {
      // Caption-only slice.
      addBlock(table.caption, 0, slice.top);
      return placed;
    }
    addTableRows(table, slice.rowStart, slice.rowEnd, slice.top);
    return placed;
  }
  // Atomic blocks: an image's caption and its visible alt fallback.
  final image = slice.block.image;
  if (image != null) {
    addBlock(image.fallbackText, 0, slice.top);
    addBlock(image.caption, 0, slice.top + image.height + 0.4 * 16);
  }
  final table = slice.block.table;
  if (table != null) {
    addBlock(table.caption, 0, slice.top);
    addTableRows(
      table,
      0,
      table.rows.length,
      slice.top + (table.caption?.height ?? 0),
    );
  }
  return placed;
}

/// One visual line's carets and half-grapheme hit zones, in page coordinates.
///
/// The two half-width endpoints per grapheme cluster are the retained
/// renderer's construction (`crates/shosai-core/src/epub/native_text.rs`): each
/// physical half of the cluster carries the caret at its own edge, so a click
/// resolves to the boundary the user aimed at. A right-to-left run swaps which
/// caret the physical left half carries.
///
/// The geometry is measured in the flow's frame and placed on the page by
/// [box]; on a vertical page the halves are the top and bottom of the
/// character and the carets are vertical.
List<FlutterSelectionCaret> _lineCarets(
  FlowTextBlock text,
  FlowLine line,
  double lineTop,
  double originX,
  List<FlutterSelectionEndpoint> endpoints,
  CanonicalCursor cursor,
  EpubPageBox box,
) {
  FlutterSelectionRect pageRect(double left, double right) {
    final rect = box.rectToPage(
      Rect.fromLTRB(
        left + originX,
        lineTop,
        right + originX,
        lineTop + line.height,
      ),
    );
    return FlutterSelectionRect(
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
    );
  }

  FlutterSelectionCaret caret(int offset, double along) {
    final start = box.toPage(Offset(along + originX, lineTop));
    final end = box.toPage(Offset(along + originX, lineTop + line.height));
    if (box.vertical) {
      return FlutterSelectionCaret(
        offset: BigInt.from(offset),
        x: (start.dx + end.dx) / 2,
        alongLine: start.dy,
        vertical: true,
        top: start.dy,
        bottom: start.dy,
      );
    }
    return FlutterSelectionCaret(
      offset: BigInt.from(offset),
      x: start.dx,
      alongLine: along,
      vertical: false,
      top: start.dy,
      bottom: end.dy,
    );
  }

  final map = text.map;
  final painter = text.painter;
  final markerOffset = map.codeUnitOffset;
  final startUnit = (line.codeUnitStart - markerOffset).clamp(
    0,
    map.text.length,
  );
  final endUnit = (line.codeUnitEnd - markerOffset).clamp(0, map.text.length);
  if (endUnit <= startUnit) return const [];
  final lineText = map.text.substring(startUnit, endUnit);
  final carets = <FlutterSelectionCaret>[];
  // Tate-chū-yoko sets its graphemes side by side across the line, in one
  // em along it: each grapheme's halves are its left and right on the page,
  // and its carets are spread along the em so they keep their order.
  final cells = {
    for (final cell in text.combinedCells(line.codeUnitStart, line.codeUnitEnd))
      cell.start: cell,
  };
  var unit = startUnit;
  for (final grapheme in lineText.characters) {
    final clusterStart = unit;
    final clusterEnd = unit + grapheme.length;
    unit = clusterEnd;
    final cell = cells[clusterStart + markerOffset];
    if (cell != null) {
      final canonicalStart = cursor.at(cell.start);
      final canonicalEnd = cursor.at(cell.end);
      // The cell is in block coordinates; [lineTop] places the line.
      final rect = cell.rect.shift(Offset(0, -line.top));
      // The first grapheme reaches the line's edge on the page's left, and
      // the last its edge on the right, so the line's full width hits.
      final top = cell.index == cell.count - 1 ? 0.0 : rect.top;
      final bottom = cell.index == 0 ? line.height : rect.bottom;
      final mid = (rect.top + rect.bottom) / 2;
      FlutterSelectionRect half(double from, double to) {
        final page = box.rectToPage(
          Rect.fromLTRB(
            rect.left + originX,
            lineTop + from,
            rect.right + originX,
            lineTop + to,
          ),
        );
        return FlutterSelectionRect(
          left: page.left,
          top: page.top,
          right: page.right,
          bottom: page.bottom,
        );
      }

      endpoints.add(
        FlutterSelectionEndpoint(
          offset: BigInt.from(canonicalStart),
          rangeStart: BigInt.from(canonicalStart),
          rangeEnd: BigInt.from(canonicalEnd),
          rect: half(mid, bottom),
        ),
      );
      endpoints.add(
        FlutterSelectionEndpoint(
          offset: BigInt.from(canonicalEnd),
          rangeStart: BigInt.from(canonicalStart),
          rangeEnd: BigInt.from(canonicalEnd),
          rect: half(top, mid),
        ),
      );
      final step = rect.width / cell.count;
      carets.add(caret(canonicalStart, rect.left + step * cell.index));
      carets.add(caret(canonicalEnd, rect.left + step * (cell.index + 1)));
      continue;
    }
    final boxes = painter.getBoxesForSelection(
      TextSelection(
        baseOffset: clusterStart + markerOffset,
        extentOffset: clusterEnd + markerOffset,
      ),
    );
    if (boxes.isEmpty) continue;
    var left = boxes.first.left;
    var right = boxes.first.right;
    for (final entry in boxes.skip(1)) {
      left = math.min(left, entry.left);
      right = math.max(right, entry.right);
    }
    if (right <= left) continue;
    final rtl = boxes.first.direction == ui.TextDirection.rtl;
    final mid = (left + right) / 2;
    final canonicalStart = cursor.at(clusterStart + markerOffset);
    final canonicalEnd = cursor.at(clusterEnd + markerOffset);
    // Physical halves: the left half always carries the caret at its own edge.
    final leftOffset = rtl ? canonicalEnd : canonicalStart;
    final rightOffset = rtl ? canonicalStart : canonicalEnd;
    endpoints.add(
      FlutterSelectionEndpoint(
        offset: BigInt.from(leftOffset),
        rangeStart: BigInt.from(canonicalStart),
        rangeEnd: BigInt.from(canonicalEnd),
        rect: pageRect(left, mid),
      ),
    );
    endpoints.add(
      FlutterSelectionEndpoint(
        offset: BigInt.from(rightOffset),
        rangeStart: BigInt.from(canonicalStart),
        rangeEnd: BigInt.from(canonicalEnd),
        rect: pageRect(mid, right),
      ),
    );
    carets.add(caret(rtl ? canonicalEnd : canonicalStart, rtl ? right : left));
    carets.add(caret(rtl ? canonicalStart : canonicalEnd, rtl ? left : right));
  }
  return carets;
}

/// Grapheme and word boundaries of a page's canonical coverage.
///
/// The page is the unit a pointer or keyboard can address, so its boundaries
/// span the page's coverage rather than the whole chapter. The algorithms are
/// the engine's canonical-stream ports
/// (`flutter/packages/shosai_epub/lib/src/canonical.dart`).
({List<int> graphemes, List<int> words}) _boundariesFor(
  String canonicalText,
  int start,
  int end,
) {
  final scalars = canonicalText.runes.length;
  final from = start.clamp(0, scalars);
  final to = end.clamp(from, scalars);
  if (to <= from) {
    return (graphemes: <int>[from], words: <int>[from]);
  }
  final startUnit = codeUnitAtScalar(canonicalText, from);
  final endUnit = codeUnitAtScalar(canonicalText, to);
  final slice = canonicalText.substring(startUnit, endUnit);
  final boundaries = navigationBoundaries(slice);
  return (
    graphemes: [for (final value in boundaries.graphemes) value + from],
    words: [for (final value in boundaries.words) value + from],
  );
}

/// Paints one page window's slices.
///
/// The painters are the measured ones from the flow: a text slice is clipped to
/// its own line range and translated so its first placed line lands at the
/// slice's page top.
void paintPageSlices(
  Canvas canvas,
  FlowPage page,
  ReaderEpubPalette palette,
  EpubPageBox box,
) {
  canvas.save();
  // The first line's ruby may stand in the margin before the flow: the page's
  // top margin, or its right margin on a vertical page. The margins are even,
  // so the top one measures both.
  final content = Rect.fromLTWH(
    0,
    0,
    box.contentWidth,
    box.contentHeight,
  ).shift(box.origin);
  final margin = box.origin.dy;
  canvas.clipRect(
    box.vertical
        ? Rect.fromLTRB(
            content.left,
            content.top,
            content.right + margin,
            content.bottom,
          )
        : Rect.fromLTRB(
            content.left,
            content.top - margin,
            content.right,
            content.bottom,
          ),
  );
  box.transformToFlow(canvas);
  for (final slice in page.slices) {
    _paintSlice(canvas, slice, palette);
  }
  canvas.restore();
}

void _paintSlice(Canvas canvas, PageSlice slice, ReaderEpubPalette palette) {
  if (slice is TextPageSlice) {
    final text = slice.block.text!;
    final offsetY = slice.top - text.lines[slice.lineStart].top;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, slice.top, text.width, slice.height));
    canvas.translate(0, offsetY);
    text.paint(
      canvas,
      lineStart: slice.lineStart,
      lineEnd: slice.lineEnd,
      ruby: false,
    );
    canvas.restore();
    // Ruby stands above its line's top, outside the slice.
    canvas.save();
    canvas.translate(0, offsetY);
    text.paintRuby(canvas, lineStart: slice.lineStart, lineEnd: slice.lineEnd);
    canvas.restore();
    return;
  }
  if (slice is TablePageSlice) {
    _paintTableSlice(canvas, slice, palette);
    return;
  }
  _paintBlock(canvas, slice.block, slice.top, palette);
}

void _paintTableSlice(
  Canvas canvas,
  TablePageSlice slice,
  ReaderEpubPalette palette,
) {
  final table = slice.block.table!;
  var y = slice.top;
  if (slice.rowEnd <= slice.rowStart) {
    // Caption-only slice: the caption is placed as its own slice so it can
    // precede a page break without repeating on the row slice.
    if (table.caption != null) {
      canvas.save();
      canvas.translate(0, y);
      table.caption!.paint(canvas);
      canvas.restore();
    }
    return;
  }
  for (var index = slice.rowStart; index < slice.rowEnd; index++) {
    final row = table.rows[index];
    _paintTableRow(canvas, row, y, palette);
    y += row.height;
  }
}

void _paintTableRow(
  Canvas canvas,
  FlowTableRowLayout row,
  double top,
  ReaderEpubPalette palette,
) {
  for (final cell in row.cells) {
    final rect = Rect.fromLTWH(cell.left, top, cell.width, row.height);
    if (cell.header) {
      canvas.drawRect(rect, Paint()..color = palette.tableHeaderBackground);
    }
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = palette.tableHeaderBorder,
    );
    var cellY = top + 6.0;
    for (final text in cell.blocks) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(cell.left + 6.0, cellY, cell.width - 12.0, text.height),
      );
      canvas.translate(cell.left + 6.0, cellY);
      text.paint(canvas);
      canvas.restore();
      cellY += text.height;
    }
  }
}

void _paintBlock(
  Canvas canvas,
  FlowBlock block,
  double top,
  ReaderEpubPalette palette,
) {
  if (block.text != null) {
    canvas.save();
    canvas.translate(0, top);
    block.text!.paint(canvas);
    canvas.restore();
    return;
  }
  final image = block.image;
  if (image != null) {
    if (image.image != null) {
      final source = Rect.fromLTWH(
        0,
        0,
        image.image!.width.toDouble(),
        image.image!.height.toDouble(),
      );
      final target = Rect.fromLTWH(0, top, image.width, image.height);
      final paint = Paint()..filterQuality = FilterQuality.medium;
      if (image.quarterTurned) {
        // The flow is turned a quarter turn clockwise; turn the image back.
        canvas.save();
        canvas.translate(target.center.dx, target.center.dy);
        canvas.rotate(-math.pi / 2);
        canvas.drawImageRect(
          image.image!,
          source,
          Rect.fromCenter(
            center: Offset.zero,
            width: target.height,
            height: target.width,
          ),
          paint,
        );
        canvas.restore();
      } else {
        canvas.drawImageRect(image.image!, source, target, paint);
      }
    }
    if (image.fallbackText != null) {
      canvas.save();
      canvas.translate(0, top);
      image.fallbackText!.paint(canvas);
      canvas.restore();
    }
    if (image.caption != null) {
      canvas.save();
      canvas.translate(0, top + image.height + 0.4 * 16);
      image.caption!.paint(canvas);
      canvas.restore();
    }
    return;
  }
  final table = block.table;
  if (table != null) {
    var y = top;
    if (table.caption != null) {
      canvas.save();
      canvas.translate(0, y);
      table.caption!.paint(canvas);
      canvas.restore();
      y += table.caption!.height;
    }
    for (final row in table.rows) {
      _paintTableRow(canvas, row, y, palette);
      y += row.height;
    }
    return;
  }
  if (block.rule != null) {
    canvas.drawRect(
      Rect.fromLTWH(0, top, 120, 1),
      Paint()..color = palette.foreground.withValues(alpha: 0.35),
    );
  }
}
