/// Pagination over a [ChapterFlow].
///
/// Pages never own pixels: they reference the same [TextPainter]s the flow
/// produced, so selection geometry and hit testing stay tied to the painted
/// layout.
///
/// This is the reader's production port of the evaluated prototype's
/// `layout/pages.dart` pagination half
/// (`prototypes/epub-dart-eval/lib/reader/layout/pages.dart`). The prototype's
/// continuous tiles, tile plan and spread decision are not part of this slice:
/// continuous mode is still served by the retained Rust renderer, and spreads
/// are 5G work.
library;

import 'dart:math' as math;

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
  });

  final int rowStart;
  final int rowEnd;
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
    if (captionHeight + 0.5 > remaining) {
      startPage();
    }
    place(
      TablePageSlice(block: block, top: used(), rowStart: 0, rowEnd: 0),
      captionHeight,
    );
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
      // not implemented.
      markOverflow();
    }
    place(
      TablePageSlice(
        block: block,
        top: used(),
        rowStart: row,
        rowEnd: groupEnd,
      ),
      groupHeight,
    );
    row = groupEnd;
    if (used() >= pageHeight - 0.5) startPage();
  }
}
