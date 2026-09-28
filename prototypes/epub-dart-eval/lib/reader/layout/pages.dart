/// Pagination and continuous geometry over a [ChapterFlow].
///
/// Pages and tiles never own pixels: they reference the same [TextPainter]s the
/// flow produced, so selection geometry and hit testing stay tied to the
/// painted layout.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'flow.dart';

/// Where a block slice sits inside a page.
sealed class PageSlice {
  const PageSlice({required this.block, required this.top});

  final FlowBlock block;

  /// Page-local top of the slice.
  final double top;
}

class TextPageSlice extends PageSlice {
  const TextPageSlice({
    required super.block,
    required super.top,
    required this.lineStart,
    required this.lineEnd,
  });

  final int lineStart;
  final int lineEnd;

  int get canonicalStart => block.text!.lines[lineStart].canonicalStart;
  int get canonicalEnd => block.text!.lines[lineEnd - 1].canonicalEnd;

  double get height =>
      block.text!.lines[lineEnd - 1].top +
      block.text!.lines[lineEnd - 1].height -
      block.text!.lines[lineStart].top;
}

class WholePageSlice extends PageSlice {
  const WholePageSlice({required super.block, required super.top});
}

class TablePageSlice extends PageSlice {
  const TablePageSlice({
    required super.block,
    required super.top,
    required this.rowStart,
    required this.rowEnd,
    required this.cellLineStarts,
    required this.cellLineEnds,
  });

  final int rowStart;
  final int rowEnd;

  /// Per-row, per-cell line window placed on this page. Empty lists mean the
  /// whole cell content is placed.
  final List<List<int>> cellLineStarts;
  final List<List<int>> cellLineEnds;
}

/// One paginated page.
class FlowPage {
  FlowPage({required this.index, required this.slices, required this.height});

  final int index;
  final List<PageSlice> slices;

  /// Used height of the page.
  final double height;

  int get canonicalStart => slices.isEmpty
      ? 0
      : slices
            .map(
              (slice) => switch (slice) {
                TextPageSlice() => slice.canonicalStart,
                TablePageSlice() =>
                  slice.rowEnd <= slice.rowStart
                      ? (slice.block.table!.caption?.map.canonicalStart ??
                            slice.block.table!.canonicalStart)
                      : slice.block.table!.rows[slice.rowStart].canonicalStart,
                WholePageSlice() => slice.block.canonicalStart,
              },
            )
            .reduce(math.min);

  int get canonicalEnd => slices.isEmpty
      ? 0
      : slices
            .map(
              (slice) => switch (slice) {
                TextPageSlice() => slice.canonicalEnd,
                TablePageSlice() =>
                  slice.rowEnd <= slice.rowStart
                      ? (slice.block.table!.caption?.map.canonicalEnd ??
                            slice.block.table!.canonicalEnd)
                      : slice.block.table!.rows[slice.rowEnd - 1].canonicalEnd,
                WholePageSlice() => slice.block.canonicalEnd,
              },
            )
            .reduce(math.max);
}

/// A paginated chapter.
class PaginatedChapter {
  PaginatedChapter({
    required this.flow,
    required this.pages,
    required this.pageHeight,
    required this.pageWidth,
    required this.overflowPages,
  });

  final ChapterFlow flow;
  final List<FlowPage> pages;
  final double pageHeight;
  final double pageWidth;

  /// Pages containing a block that could not fit and is painted clipped.
  final int overflowPages;

  /// Page containing a canonical scalar.
  ///
  /// Uses page start ordering rather than exact interval membership: adjacent
  /// slices can share a caret boundary, and a durable scalar that sits on a
  /// boundary belongs to the page that starts at it.
  int pageOfCanonical(int scalar) {
    var result = 0;
    for (final page in pages) {
      if (page.canonicalStart <= scalar) {
        result = page.index;
      } else {
        break;
      }
    }
    return result;
  }
}

/// Compose a flow into pages of [pageHeight].
PaginatedChapter paginateFlow({
  required ChapterFlow flow,
  required double pageHeight,
  required double pageWidth,
}) {
  final pages = <FlowPage>[];
  var slices = <PageSlice>[];
  var used = 0.0;
  var overflowPages = 0;
  var pageHasOverflow = false;

  void startPage() {
    if (pageHasOverflow) overflowPages++;
    if (slices.isNotEmpty) {
      pages.add(FlowPage(index: pages.length, slices: slices, height: used));
    }
    slices = <PageSlice>[];
    used = 0;
    pageHasOverflow = false;
  }

  void place(PageSlice slice, double height) {
    slices.add(slice);
    used += height;
  }

  for (final block in flow.blocks) {
    if (block.text != null) {
      final text = block.text!;
      if (text.lines.isEmpty) continue;
      var line = 0;
      while (line < text.lines.length) {
        final remaining = pageHeight - used;
        var end = line;
        var height = 0.0;
        while (end < text.lines.length) {
          final lineHeight = text.lines[end].height;
          if (height + lineHeight > remaining + 0.5) break;
          height += lineHeight;
          end++;
        }
        if (end == line) {
          if (slices.isEmpty && used == 0) {
            // The line cannot fit even on an empty page: place it clipped.
            end = line + 1;
            height = text.lines[line].height;
            pageHasOverflow = true;
          } else {
            startPage();
            continue;
          }
        }
        place(
          TextPageSlice(block: block, top: used, lineStart: line, lineEnd: end),
          _sliceHeight(text, line, end),
        );
        line = end;
        if (line < text.lines.length) startPage();
      }
      continue;
    }
    if (block.table != null) {
      _paginateTable(
        block,
        pageHeight,
        slices: () => slices,
        used: () => used,
        place: place,
        startPage: startPage,
        markOverflow: () => pageHasOverflow = true,
      );
      continue;
    }
    // Atomic blocks (images, rules).
    final height = block.height;
    if (used + height > pageHeight + 0.5 && slices.isNotEmpty) {
      startPage();
    }
    if (height > pageHeight + 0.5) {
      pageHasOverflow = true;
    }
    place(WholePageSlice(block: block, top: used), height);
    if (used >= pageHeight - 0.5) startPage();
  }
  startPage();
  if (pages.isEmpty) {
    pages.add(FlowPage(index: 0, slices: const [], height: 0));
  }
  return PaginatedChapter(
    flow: flow,
    pages: pages,
    pageHeight: pageHeight,
    pageWidth: pageWidth,
    overflowPages: overflowPages + (pageHasOverflow ? 1 : 0),
  );
}

double _sliceHeight(FlowTextBlock text, int lineStart, int lineEnd) =>
    text.lines[lineEnd - 1].top +
    text.lines[lineEnd - 1].height -
    text.lines[lineStart].top;

void _paginateTable(
  FlowBlock block,
  double pageHeight, {
  required List<PageSlice> Function() slices,
  required double Function() used,
  required void Function(PageSlice, double) place,
  required void Function() startPage,
  required void Function() markOverflow,
}) {
  final table = block.table!;
  final captionHeight = table.caption?.height ?? 0;
  if (captionHeight > 0) {
    final remaining = pageHeight - used();
    if (captionHeight + 0.5 <= remaining) {
      place(
        TablePageSlice(
          block: block,
          top: used(),
          rowStart: 0,
          rowEnd: 0,
          cellLineStarts: const [],
          cellLineEnds: const [],
        ),
        captionHeight,
      );
    } else {
      startPage();
      place(
        TablePageSlice(
          block: block,
          top: used(),
          rowStart: 0,
          rowEnd: 0,
          cellLineStarts: const [],
          cellLineEnds: const [],
        ),
        captionHeight,
      );
    }
  }
  var row = 0;
  while (row < table.rows.length) {
    // Keep a rowspan group together.
    var groupEnd = row + 1;
    while (groupEnd < table.rows.length &&
        table.rows
                .sublist(row, groupEnd)
                .map((entry) => entry.rowSpanGroup)
                .fold<int>(1, math.max) >
            groupEnd - row) {
      groupEnd++;
    }
    var groupHeight = 0.0;
    for (var index = row; index < groupEnd; index++) {
      groupHeight += table.rows[index].height;
    }
    final remaining = pageHeight - used();
    if (groupHeight + 0.5 > remaining && slices().isNotEmpty) {
      startPage();
      continue;
    }
    if (groupHeight + 0.5 > remaining) {
      // The group cannot fit on an empty page. It is placed clipped and the
      // overflow is reported; splitting a rowspan group at line boundaries is
      // not implemented in the prototype.
      markOverflow();
    }
    place(
      TablePageSlice(
        block: block,
        top: used(),
        rowStart: row,
        rowEnd: groupEnd,
        cellLineStarts: const [],
        cellLineEnds: const [],
      ),
      groupHeight,
    );
    row = groupEnd;
    if (used() >= pageHeight - 0.5) startPage();
  }
}

/// Continuous flow geometry: total height plus a visible window.
class ContinuousWindow {
  const ContinuousWindow({
    required this.top,
    required this.bottom,
    required this.blocks,
    required this.totalHeight,
  });

  final double top;
  final double bottom;
  final List<FlowBlock> blocks;
  final double totalHeight;
}

/// Blocks intersecting a viewport window.
ContinuousWindow continuousWindow({
  required ChapterFlow flow,
  required double top,
  required double height,
}) {
  final bottom = top + height;
  final visible = <FlowBlock>[];
  for (final block in flow.blocks) {
    final blockBottom = block.top + block.height;
    if (blockBottom < top) continue;
    if (block.top > bottom) break;
    visible.add(block);
  }
  return ContinuousWindow(
    top: top,
    bottom: bottom,
    blocks: visible,
    totalHeight: flow.height,
  );
}

/// Tile arithmetic ported from the 5B `tile_plan` contract.
class TileSpan {
  const TileSpan({
    required this.index,
    required this.deviceRowStart,
    required this.deviceRowEnd,
    required this.logicalOrigin,
    required this.logicalHeight,
    required this.clippedLogicalHeight,
  });

  final int index;
  final int deviceRowStart;
  final int deviceRowEnd;
  final double logicalOrigin;
  final double logicalHeight;
  final double clippedLogicalHeight;
}

class TilePlan {
  const TilePlan({
    required this.chapterOriginY,
    required this.scale,
    required this.chapterHeight,
    required this.tiles,
  });

  final double chapterOriginY;
  final double scale;
  final double chapterHeight;
  final List<TileSpan> tiles;

  double get nextChapterOrigin => chapterOriginY + chapterHeight + kTileSpacing;

  int get retainedBytes => tiles.length * 48;
}

/// Device-row target per continuous tile (contract `continuous-v1`).
const int kTileTargetDeviceRows = 512;
const double kTileSpacing = 32.0;
const int kMaxTilesPerSpine = 10000;

TilePlan? tilePlan({
  required double chapterOriginY,
  required double chapterHeight,
  required double scale,
}) {
  if (!chapterOriginY.isFinite ||
      !chapterHeight.isFinite ||
      !scale.isFinite ||
      chapterHeight < 0 ||
      scale <= 0 ||
      chapterOriginY < 0) {
    return null;
  }
  final totalRows = (chapterHeight * scale).ceil();
  if (totalRows < 0) return null;
  final tileCount =
      (totalRows + kTileTargetDeviceRows - 1) ~/ kTileTargetDeviceRows;
  if (tileCount > kMaxTilesPerSpine) return null;
  final boundaries = <int>[0];
  while (boundaries.last < totalRows) {
    final next = math.min(boundaries.last + kTileTargetDeviceRows, totalRows);
    if (next <= boundaries.last) return null;
    boundaries.add(next);
  }
  final tiles = <TileSpan>[];
  for (var index = 0; index + 1 < boundaries.length; index++) {
    final start = boundaries[index];
    final end = boundaries[index + 1];
    final logicalOrigin = start / scale;
    final logicalHeight = (end - start) / scale;
    tiles.add(
      TileSpan(
        index: index,
        deviceRowStart: start,
        deviceRowEnd: end,
        logicalOrigin: logicalOrigin,
        logicalHeight: logicalHeight,
        clippedLogicalHeight: math.min(
          logicalHeight,
          math.max(0, chapterHeight - logicalOrigin),
        ),
      ),
    );
  }
  return TilePlan(
    chapterOriginY: chapterOriginY,
    scale: scale,
    chapterHeight: chapterHeight,
    tiles: tiles,
  );
}

/// Paginated spread decision (contract §6): two columns iff `W >= 720` and
/// `C >= max(120, 12 × font_size)` where `C = (W - G)/2 - 40` and `G = 20`.
({int columns, double usableColumnWidth}) spreadDecision({
  required double availableWidth,
  required double fontSize,
}) {
  final usable = (availableWidth - 20.0) / 2.0 - 40.0;
  final minimum = math.max(120.0, 12.0 * fontSize);
  final columns = availableWidth >= 720.0 && usable >= minimum ? 2 : 1;
  return (columns: columns, usableColumnWidth: usable);
}
