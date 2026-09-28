/// Hit testing and selection projection over a laid-out chapter.
///
/// Every function here reads the same [TextPainter]s the renderer paints, so
/// pixels, hit testing and selection geometry cannot drift apart.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'layout/flow.dart';
import 'layout/pages.dart';

/// A durable hit: canonical scalar plus whether the hit is text-selectable.
class EpubHit {
  const EpubHit({
    required this.scalar,
    required this.selectable,
    this.link,
    this.block,
    this.local,
  });

  final int scalar;
  final bool selectable;
  final String? link;

  /// The block that produced the hit, when there is one.
  final FlowBlock? block;
  final Offset? local;

  @override
  String toString() => 'EpubHit($scalar, selectable=$selectable)';
}

/// Hit test a paginated page.
EpubHit hitTestPage({
  required PaginatedChapter chapter,
  required int pageIndex,
  required Offset local,
}) {
  if (pageIndex < 0 || pageIndex >= chapter.pages.length) {
    return const EpubHit(scalar: 0, selectable: false);
  }
  final page = chapter.pages[pageIndex];
  for (final slice in page.slices.reversed) {
    final hit = _hitSlice(slice, local);
    if (hit != null) return hit;
  }
  // Between blocks: clamp to the page's canonical start.
  return EpubHit(scalar: page.canonicalStart, selectable: true);
}

/// Hit test the continuous flow at a flow-space point.
EpubHit hitTestFlow({required ChapterFlow flow, required Offset local}) {
  for (final block in flow.blocks) {
    if (local.dy < block.top || local.dy > block.top + block.height) continue;
    final blockLocal = Offset(local.dx, local.dy - block.top);
    final hit = _hitBlock(block, blockLocal);
    if (hit != null) return hit;
  }
  // Between blocks (block spacing) or outside the flow: resolve to the nearest
  // block boundary, never to the chapter end.
  if (flow.blocks.isEmpty) {
    return const EpubHit(scalar: 0, selectable: true);
  }
  var nearest = flow.blocks.first;
  var bestDistance = double.infinity;
  for (final block in flow.blocks) {
    final distance = local.dy < block.top
        ? block.top - local.dy
        : (local.dy > block.top + block.height
              ? local.dy - (block.top + block.height)
              : 0.0);
    if (distance < bestDistance) {
      bestDistance = distance;
      nearest = block;
    }
  }
  final scalar = local.dy < nearest.top
      ? nearest.canonicalStart
      : nearest.canonicalEnd;
  return EpubHit(scalar: scalar, selectable: true, block: nearest);
}

EpubHit? _hitSlice(PageSlice slice, Offset local) {
  final top = slice.top;
  final height = switch (slice) {
    TextPageSlice() => slice.height,
    TablePageSlice() =>
      slice.rowEnd <= slice.rowStart
          // Caption-only slice: its height is the caption's, not zero.
          ? (slice.block.table!.caption?.height ?? 0)
          : slice.block.table!.rows
                .sublist(slice.rowStart, slice.rowEnd)
                .fold<double>(0, (sum, row) => sum + row.height),
    WholePageSlice() => slice.block.height,
  };
  if (local.dy < top - 0.5 || local.dy > top + height + 0.5) return null;
  final blockLocal = Offset(local.dx, local.dy - top);
  if (slice is TextPageSlice) {
    final text = slice.block.text!;
    // Map into the block's own coordinate space: the slice starts at the first
    // placed line.
    final blockY = blockLocal.dy + text.lines[slice.lineStart].top;
    final hit = _hitText(
      slice.block,
      text,
      Offset(blockLocal.dx, blockY),
      lineStart: slice.lineStart,
      lineEnd: slice.lineEnd,
    );
    return hit;
  }
  if (slice is TablePageSlice) {
    return _hitTable(slice, blockLocal);
  }
  return _hitBlock(slice.block, blockLocal);
}

EpubHit? _hitBlock(FlowBlock block, Offset local) {
  if (block.text != null) {
    return _hitText(block, block.text!, local);
  }
  if (block.image != null) {
    final image = block.image!;
    if (image.fallbackText != null) {
      return _hitText(block, image.fallbackText!, local);
    }
    if (local.dy <= image.height) {
      // The image's alt text is canonical but not selectable.
      return EpubHit(
        scalar: block.canonicalStart,
        selectable: false,
        block: block,
        local: local,
      );
    }
    if (image.caption != null) {
      return _hitText(
        block,
        image.caption!,
        Offset(local.dx, local.dy - image.height - 0.4 * 16),
      );
    }
    return EpubHit(scalar: block.canonicalStart, selectable: false);
  }
  if (block.table != null) {
    return _hitTableBlock(block, local);
  }
  return EpubHit(scalar: block.canonicalStart, selectable: true, block: block);
}

EpubHit? _hitTable(TablePageSlice slice, Offset local) {
  final table = slice.block.table!;
  final captionHeight = table.caption?.height ?? 0;
  var y = local.dy;
  if (slice.rowStart == 0 && slice.rowEnd == 0) {
    if (table.caption == null) return null;
    return _hitText(slice.block, table.caption!, Offset(local.dx, y));
  }
  for (var index = slice.rowStart; index < slice.rowEnd; index++) {
    final row = table.rows[index];
    if (y < row.height) {
      return _hitTableRow(slice.block, row, local.dx, y);
    }
    y -= row.height;
  }
  if (slice.rowStart > 0 && local.dy < 0) {
    return EpubHit(
      scalar: table.rows[slice.rowStart].canonicalStart,
      selectable: true,
      block: slice.block,
    );
  }
  if (captionHeight > 0) {
    return _hitText(slice.block, table.caption!, Offset(local.dx, local.dy));
  }
  return EpubHit(
    scalar: table.rows.isEmpty
        ? table.canonicalStart
        : table
              .rows[math.min(slice.rowStart, table.rows.length - 1)]
              .canonicalStart,
    selectable: true,
  );
}

EpubHit? _hitTableBlock(FlowBlock block, Offset local) {
  final table = block.table!;
  var y = local.dy;
  if (table.caption != null) {
    if (y <= table.caption!.height) {
      return _hitText(block, table.caption!, Offset(local.dx, y));
    }
    y -= table.caption!.height;
  }
  for (final row in table.rows) {
    if (y < row.height) {
      return _hitTableRow(block, row, local.dx, y);
    }
    y -= row.height;
  }
  return EpubHit(scalar: table.canonicalEnd, selectable: true);
}

EpubHit _hitTableRow(
  FlowBlock block,
  FlowTableRowLayout row,
  double x,
  double y,
) {
  for (final cell in row.cells) {
    if (x < cell.left || x > cell.left + cell.width) continue;
    var cellY = y - 6.0;
    for (final text in cell.blocks) {
      if (cellY <= text.height) {
        final hit = _hitText(block, text, Offset(x - cell.left - 6.0, cellY));
        if (hit != null) return hit;
      }
      cellY -= text.height;
    }
    return EpubHit(scalar: cell.canonicalStart, selectable: true, block: block);
  }
  return EpubHit(scalar: row.canonicalStart, selectable: true, block: block);
}

EpubHit? _hitText(
  FlowBlock block,
  FlowTextBlock text,
  Offset local, {
  int? lineStart,
  int? lineEnd,
}) {
  final clamped = Offset(
    local.dx.clamp(0.0, math.max(0.0, text.width)),
    local.dy.clamp(0.0, math.max(0.0, text.height)),
  );
  final scalar = text.canonicalAtLocal(clamped);
  var selectable = true;
  if (!text.map.rangeSelectable(scalar, scalar + 1)) {
    selectable = false;
  }
  return EpubHit(
    scalar: scalar,
    selectable: selectable,
    link: text.linkAtLocal(clamped),
    block: block,
    local: clamped,
  );
}

/// Selection rectangles for a canonical range on one page.
List<Rect> projectRangePage({
  required PaginatedChapter chapter,
  required int pageIndex,
  required int start,
  required int end,
}) {
  if (pageIndex < 0 || pageIndex >= chapter.pages.length || end <= start) {
    return const [];
  }
  final page = chapter.pages[pageIndex];
  final rects = <Rect>[];
  for (final slice in page.slices) {
    rects.addAll(_projectSlice(slice, start, end));
  }
  return rects;
}

/// Selection rectangles for a canonical range in the continuous flow.
List<Rect> projectRangeFlow({
  required ChapterFlow flow,
  required int start,
  required int end,
}) {
  if (end <= start) return const [];
  final rects = <Rect>[];
  for (final block in flow.blocks) {
    if (block.canonicalEnd <= start || block.canonicalStart >= end) continue;
    rects.addAll(_projectBlock(block, start, end, block.top));
  }
  return rects;
}

List<Rect> _projectSlice(PageSlice slice, int start, int end) {
  if (slice is TextPageSlice) {
    final text = slice.block.text!;
    final from = math.max(start, slice.canonicalStart);
    final to = math.min(end, slice.canonicalEnd);
    if (to <= from) return const [];
    final offsetY = slice.top - text.lines[slice.lineStart].top;
    return [
      for (final box in text.boxesForCanonical(from, to))
        box.translate(0, offsetY),
    ];
  }
  if (slice is TablePageSlice) {
    final table = slice.block.table!;
    var y = slice.top;
    final rects = <Rect>[];
    if (slice.rowEnd <= slice.rowStart) {
      if (table.caption != null) {
        rects.addAll(
          _projectText(table.caption!, start, end, Offset(0, slice.top)),
        );
      }
      return rects;
    }
    for (var index = slice.rowStart; index < slice.rowEnd; index++) {
      final row = table.rows[index];
      rects.addAll(_projectTableRow(table, row, start, end, y));
      y += row.height;
    }
    return rects;
  }
  return _projectBlock(slice.block, start, end, slice.top);
}

List<Rect> _projectBlock(FlowBlock block, int start, int end, double top) {
  if (block.text != null) {
    return _projectText(block.text!, start, end, Offset(0, top));
  }
  if (block.image != null) {
    final image = block.image!;
    final rects = <Rect>[];
    if (image.fallbackText != null) {
      rects.addAll(
        _projectText(image.fallbackText!, start, end, Offset(0, top)),
      );
    } else if (block.canonicalStart >= start && block.canonicalStart < end) {
      rects.add(Rect.fromLTWH(0, top, image.width, image.height));
    }
    if (image.caption != null) {
      rects.addAll(
        _projectText(
          image.caption!,
          start,
          end,
          Offset(0, top + image.height + 0.4 * 16),
        ),
      );
    }
    return rects;
  }
  if (block.table != null) {
    final table = block.table!;
    var y = top;
    final rects = <Rect>[];
    if (table.caption != null) {
      rects.addAll(_projectText(table.caption!, start, end, Offset(0, y)));
      y += table.caption!.height;
    }
    for (final row in table.rows) {
      rects.addAll(_projectTableRow(table, row, start, end, y));
      y += row.height;
    }
    return rects;
  }
  if (block.rule != null &&
      block.canonicalStart >= start &&
      block.canonicalStart < end) {
    return [Rect.fromLTWH(0, top, 120, 1)];
  }
  return const [];
}

List<Rect> _projectTableRow(
  FlowTableBlock table,
  FlowTableRowLayout row,
  int start,
  int end,
  double rowTop,
) {
  final rects = <Rect>[];
  for (final cell in row.cells) {
    var cellY = rowTop + 6.0;
    for (final text in cell.blocks) {
      rects.addAll(
        _projectText(text, start, end, Offset(cell.left + 6.0, cellY)),
      );
      cellY += text.height;
    }
  }
  return rects;
}

List<Rect> _projectText(FlowTextBlock text, int start, int end, Offset origin) {
  final from = math.max(start, text.map.canonicalStart);
  final to = math.min(end, text.map.canonicalEnd);
  if (to <= from) return const [];
  return [
    for (final box in text.boxesForCanonical(from, to)) box.shift(origin),
  ];
}

/// The union rect of projected fragments, for positioning selection actions.
Rect? boundingRect(List<Rect> rects) {
  if (rects.isEmpty) return null;
  var left = rects.first.left;
  var top = rects.first.top;
  var right = rects.first.right;
  var bottom = rects.first.bottom;
  for (final rect in rects.skip(1)) {
    left = math.min(left, rect.left);
    top = math.min(top, rect.top);
    right = math.max(right, rect.right);
    bottom = math.max(bottom, rect.bottom);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Copy text for a canonical range: visible, selectable content only.
///
/// Generated separators (block newlines, table tabs) are included when they
/// fall inside the range; hidden fallbacks (a rendered image's alt text, a
/// rendered math fallback) are excluded, matching the production copy rule.
String copyTextForRange({
  required String canonicalText,
  required int start,
  required int end,
  required List<({int start, int end})> hiddenRanges,
}) {
  final from = math.max(0, start);
  final to = math.min(canonicalText.runes.length, end);
  if (to <= from) return '';
  final scalars = canonicalText.runes.toList(growable: false);
  final buffer = StringBuffer();
  var index = from;
  while (index < to) {
    final hidden = hiddenRanges
        .where((range) => index >= range.start && index < range.end)
        .firstOrNull;
    if (hidden != null) {
      index = math.min(to, hidden.end);
      continue;
    }
    buffer.writeCharCode(scalars[index]);
    index++;
  }
  return buffer.toString();
}

/// Paint a laid-out image scaled into [rect].
void paintDecodedImage(ui.Canvas canvas, ui.Image image, Rect rect) {
  final source = Rect.fromLTWH(
    0,
    0,
    image.width.toDouble(),
    image.height.toDouble(),
  );
  canvas.drawImageRect(
    image,
    source,
    rect,
    Paint()..filterQuality = FilterQuality.medium,
  );
}
