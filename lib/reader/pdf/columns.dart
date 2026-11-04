/// Pure Dart Columns analysis (RFD 12, Papers on phones, rules 1, 2 and 10).
/// No rendering, I/O, viewport state or text reflow belongs here.
library;

import 'dart:math' as math;

import 'page_geometry.dart';

enum PdfRegionKind { page, band, column, figure }

final class PdfReadingRegion {
  PdfReadingRegion({
    required this.kind,
    required this.bounds,
    List<PdfTextLine> lines = const [],
  }) : lines = List.unmodifiable(lines);

  final PdfRegionKind kind;
  final PdfRect bounds;

  /// Original page-space lines and character offsets, for screen breaks and
  /// selection. They are never rewritten or renumbered by region ordering.
  final List<PdfTextLine> lines;
}

final class PdfColumnPage {
  PdfColumnPage({
    required this.columnCount,
    required List<PdfReadingRegion> regions,
  }) : regions = List.unmodifiable(regions);

  /// Zero means fit-width fallback, not a detected one-column layout.
  final int columnCount;
  final List<PdfReadingRegion> regions;
}

/// Analyzes a document (or a representative page sample) without mutating it.
/// The output has one entry per input page, in the same order. Fallback bounds
/// trim only proven empty margins; unknown painted coverage keeps the page.
///
/// Gutters need at least three lines on either side, simultaneous vertical
/// extent, and a gap of at least 12pt or 1.2 line heights. Up to 20% spanning
/// lines may cross a gutter (titles, equations, etc.); those become bands.
/// Connected painted objects and their labels are indivisible figures/tables,
/// not OCR or semantic recognition. [rightToLeft] comes from `/Direction /R2L`, not
/// from guessing the script of the page's text.
List<PdfColumnPage> analyzePdfColumns(
  List<PdfPageGeometry> pages, {
  bool rightToLeft = false,
}) {
  final recurring = _recurringMargins(pages);
  return List.unmodifiable([
    for (var p = 0; p < pages.length; p++)
      _analyzePage(
        pages[p],
        pages[p].lines.where((line) => !recurring[p].contains(line)).toList(),
        rightToLeft,
      ),
  ]);
}

List<Set<PdfTextLine>> _recurringMargins(List<PdfPageGeometry> pages) {
  final removed = [for (final _ in pages) <PdfTextLine>{}];
  if (pages.length < 2) return removed;
  final groups = <String, List<({int page, PdfTextLine line})>>{};
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    for (final line in page.lines) {
      if (line.bounds.bottom > page.height * .1 &&
          line.bounds.top < page.height * .9) {
        continue;
      }
      var text = line.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (RegExp(
        r'^(?:\d+|[ivxlcdm]+|(?:Page )?\d+(?: of \d+)?)$',
        caseSensitive: false,
      ).hasMatch(text)) {
        text = '#page';
      }
      if (text.isEmpty) continue;
      groups.putIfAbsent(text, () => []).add((page: p, line: line));
    }
  }
  // Compare actual positions rather than quantizing into bins: two heads on
  // opposite sides of a rounding boundary still recur. Normalize page sizes.
  for (final group in groups.values) {
    for (final item in group) {
      final a = item.line.bounds;
      final page = pages[item.page];
      final matches = group.where((other) {
        final b = other.line.bounds;
        final size = pages[other.page];
        return (a.left / page.width - b.left / size.width).abs() < .01 &&
            (a.top / page.height - b.top / size.height).abs() < .004;
      }).toList();
      if (matches.map((m) => m.page).toSet().length >= 2) {
        for (final match in matches) {
          removed[match.page].add(match.line);
        }
      }
    }
  }
  return removed;
}

PdfColumnPage _analyzePage(
  PdfPageGeometry page,
  List<PdfTextLine> lines,
  bool rtl,
) {
  final ink = [
    ...lines.map((line) => line.bounds),
    ...page.images,
    ...page.graphics,
  ];
  PdfColumnPage fallback() => PdfColumnPage(
    columnCount: 0,
    regions: [
      PdfReadingRegion(
        kind: PdfRegionKind.page,
        bounds: page.hasUnboundedGraphics || ink.isEmpty
            ? PdfRect(0, 0, page.width, page.height)
            : _padded(ink.reduce((a, b) => a.union(b)), page),
        lines: lines,
      ),
    ],
  );
  if (page.hasUnboundedGraphics) return fallback();
  final textGutters = _gutters(lines);
  final figures = _figures(lines, [
    ...page.images,
    ...page.graphics,
  ], textGutters);
  final owned = figures.expand((r) => r.lines).toSet();
  final body = lines.where((line) => !owned.contains(line)).toList();
  final bodyGutters = _gutters(body);
  final gutters = bodyGutters.isEmpty ? textGutters : bodyGutters;
  if (gutters.isEmpty) return fallback();
  bool spans(PdfRect r) => gutters.any((x) => r.left < x && r.right > x);
  final bands = <PdfReadingRegion>[
    for (final line in body.where((line) => spans(line.bounds)))
      PdfReadingRegion(
        kind: PdfRegionKind.band,
        bounds: line.bounds,
        lines: [line],
      ),
    ...figures.where((r) => spans(r.bounds)),
  ]..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  // Adjacent spanning lines are one title/equation band; an image always owns
  // its own region, even when it touches a title or caption.
  final merged = <PdfReadingRegion>[];
  for (final band in bands) {
    final last = merged.lastOrNull;
    if (last != null &&
        last.kind == PdfRegionKind.band &&
        band.kind == PdfRegionKind.band &&
        band.bounds.top - last.bounds.bottom <=
            math.max(last.lines.last.bounds.height, band.bounds.height) * 2) {
      merged[merged.length - 1] = PdfReadingRegion(
        kind: PdfRegionKind.band,
        bounds: last.bounds.union(band.bounds),
        lines: [...last.lines, ...band.lines],
      );
    } else {
      merged.add(band);
    }
  }
  final regions = <PdfReadingRegion>[];
  final remaining = body.where((line) => !spans(line.bounds)).toList();
  final localFigures = figures.where((r) => !spans(r.bounds)).toList();
  void flush(double before) {
    final slabLines = remaining.where((l) => l.bounds.top < before).toList();
    final slabFigures = localFigures
        .where((r) => r.bounds.top < before)
        .toList();
    remaining.removeWhere(slabLines.contains);
    localFigures.removeWhere(slabFigures.contains);
    final order = List.generate(gutters.length + 1, (i) => i);
    if (rtl) order.sort((a, b) => b.compareTo(a));
    for (final column in order) {
      bool belongs(PdfRect r) =>
          (column == 0 || r.left >= gutters[column - 1]) &&
          (column == gutters.length || r.right <= gutters[column]);
      regions.addAll(
        _columnRegions(
          slabLines.where((l) => belongs(l.bounds)).toList(),
          slabFigures.where((r) => belongs(r.bounds)).toList(),
        ),
      );
    }
  }

  for (final band in merged) {
    // A full-width band owns the complete horizontal slice, including author
    // rows and short caption tails that do not themselves cross the gutter.
    var bounds = band.bounds;
    final inside = <PdfTextLine>[];
    while (true) {
      final adjacent = remaining.where((l) {
        final gap = l.bounds.height * .75;
        return l.bounds.height <= l.bounds.width &&
            l.bounds.top < bounds.bottom + gap &&
            l.bounds.bottom > bounds.top - gap;
      }).toList();
      if (adjacent.isEmpty) break;
      remaining.removeWhere(adjacent.contains);
      inside.addAll(adjacent);
      bounds = adjacent.fold(bounds, (r, l) => r.union(l.bounds));
    }
    final bandLines = [...band.lines, ...inside]
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    flush(bounds.top);
    regions.add(
      PdfReadingRegion(kind: band.kind, bounds: bounds, lines: bandLines),
    );
  }
  flush(double.infinity);
  final padded = _padRegions(regions, page);
  // Keep the coverage guard independent of figure detection: every retained
  // painted object and physical line must belong to exactly one final crop.
  for (final rect in ink) {
    final owners = padded.where((r) => r.bounds.overlaps(rect)).toList();
    if (owners.length != 1 || !owners.single.bounds.contains(rect)) {
      return fallback();
    }
  }
  return PdfColumnPage(columnCount: gutters.length + 1, regions: padded);
}

// Keep raster antialiasing at crop edges without widening the physical line
// boxes used for screen cuts. Neighboring crops meet at whitespace midpoints.
PdfRect _padded(PdfRect r, PdfPageGeometry page) => PdfRect(
  math.max(0, r.left - 1),
  math.max(0, r.top - 1),
  math.min(page.width, r.right + 1),
  math.min(page.height, r.bottom + 1),
);

List<PdfReadingRegion> _padRegions(
  List<PdfReadingRegion> regions,
  PdfPageGeometry page,
) {
  final paddedRegions = <PdfReadingRegion>[];
  for (final region in regions) {
    final r = region.bounds;
    final padded = _padded(r, page);
    var left = padded.left;
    var top = padded.top;
    var right = padded.right;
    var bottom = padded.bottom;
    for (final other in regions) {
      if (identical(region, other)) continue;
      final b = other.bounds;
      if (r.left - 1 < b.right + 1 && r.right + 1 > b.left - 1) {
        if (r.bottom <= b.top) {
          bottom = math.min(bottom, (r.bottom + b.top) / 2);
        }
        if (r.top >= b.bottom) top = math.max(top, (r.top + b.bottom) / 2);
      }
      if (r.top - 1 < b.bottom + 1 && r.bottom + 1 > b.top - 1) {
        if (r.right <= b.left) right = math.min(right, (r.right + b.left) / 2);
        if (r.left >= b.right) left = math.max(left, (r.left + b.right) / 2);
      }
    }
    paddedRegions.add(
      PdfReadingRegion(
        kind: region.kind,
        bounds: PdfRect(left, top, right, bottom),
        lines: region.lines,
      ),
    );
  }
  return paddedRegions;
}

List<PdfReadingRegion> _columnRegions(
  List<PdfTextLine> lines,
  List<PdfReadingRegion> figures,
) {
  lines.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  figures.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  final regions = <PdfReadingRegion>[];
  void textBefore(double y) {
    final block = lines.where((l) => l.bounds.top < y).toList();
    lines.removeWhere(block.contains);
    if (block.isEmpty) return;
    regions.add(
      PdfReadingRegion(
        kind: PdfRegionKind.column,
        bounds: block.map((l) => l.bounds).reduce((a, b) => a.union(b)),
        lines: block,
      ),
    );
  }

  for (final figure in figures) {
    textBefore(figure.bounds.top);
    regions.add(figure);
  }
  textBefore(double.infinity);
  return regions;
}

/// Tiny raster hyphens and vector underlines within a line are inline ink.
/// Other painted components own intersecting labels/cells, before gutters are
/// inferred. Repeating to closure prevents partial labels and overlapping
/// subfigures from appearing in multiple crops. Lines themselves stay physical.
List<PdfReadingRegion> _figures(
  List<PdfTextLine> lines,
  List<PdfRect> objects,
  List<double> gutters,
) {
  final width = lines.isEmpty
      ? 0.0
      : lines.map((l) => l.bounds).reduce((a, b) => a.union(b)).width;
  final heights =
      lines
          .where((l) => l.bounds.width >= width * .2)
          .map((l) => l.bounds.height)
          .toList()
        ..sort();
  final height = heights.isEmpty ? 10.0 : heights[heights.length ~/ 2];
  final gap = height * .7;
  final figures = <PdfReadingRegion>[
    for (final object in objects)
      if (!lines.any(
        (line) =>
            line.bounds.contains(object) &&
            object.height < line.bounds.height * .5,
      ))
        PdfReadingRegion(kind: PdfRegionKind.figure, bounds: object),
  ];
  bool near(PdfRect a, PdfRect b, double distance) =>
      a.left <= b.right + distance &&
      a.right + distance >= b.left &&
      a.top <= b.bottom + distance &&
      a.bottom + distance >= b.top;
  bool parallel(PdfRect a, PdfRect b) =>
      gutters.isNotEmpty &&
      !gutters.any(
        (x) => math.min(a.left, b.left) < x && math.max(a.right, b.right) > x,
      ) &&
      a.top < b.bottom &&
      a.bottom > b.top;
  var changed = true;
  while (changed) {
    changed = false;
    for (var i = 0; i < figures.length; i++) {
      var bounds = figures[i].bounds;
      final labels = figures[i].lines.toSet();
      for (final line in lines) {
        final small =
            math.min(line.bounds.width, line.bounds.height) < height * .9;
        if (near(bounds, line.bounds, small ? gap : 0) && labels.add(line)) {
          bounds = bounds.union(line.bounds);
          changed = true;
        }
      }
      for (var j = figures.length - 1; j > i; j--) {
        if (near(bounds, figures[j].bounds, gap) ||
            parallel(bounds, figures[j].bounds)) {
          bounds = bounds.union(figures[j].bounds);
          labels.addAll(figures.removeAt(j).lines);
          changed = true;
        }
      }
      figures[i] = PdfReadingRegion(
        kind: PdfRegionKind.figure,
        bounds: bounds,
        lines: labels.toList()
          ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top)),
      );
    }
  }
  return figures;
}

/// Sweep x edges, admitting only whitespace with substantial text on both
/// sides. Spanning lines cost votes but do not hide a page's body gutter.
List<double> _gutters(List<PdfTextLine> input) {
  if (input.length < 6) return [];
  final extent = input.map((l) => l.bounds).reduce((a, b) => a.union(b));
  // Short author names, plot labels and marginal stamps must not fragment an
  // otherwise clear body gutter into intervals narrower than the threshold.
  final minColumnWidth = extent.width * .2;
  final lines = input.where((l) => l.bounds.width >= minColumnWidth).toList();
  if (lines.length < 6) return [];
  final heights = lines.map((l) => l.bounds.height).toList()..sort();
  final minGap = math.max(12.0, heights[heights.length ~/ 2] * 1.2);
  final edges = <({double x, bool start})>[
    for (final l in lines) ...[
      (x: l.bounds.left, start: true),
      (x: l.bounds.right, start: false),
    ],
  ]..sort((a, b) => a.x.compareTo(b.x));
  var left = 0;
  var right = lines.length;
  var crossing = 0;
  final minX = edges.first.x;
  final maxX = edges.last.x;
  ({double from, double to, int crossing, int support})? best;
  double? from;
  int? previousCrossing;
  for (var i = 0; i < edges.length;) {
    final x = edges[i].x;
    while (i < edges.length && edges[i].x == x) {
      if (edges[i].start) {
        right--;
        crossing++;
      } else {
        left++;
        crossing--;
      }
      i++;
    }
    if (i == edges.length) break;
    final to = edges[i].x;
    final eligible =
        left >= 3 &&
        right >= 3 &&
        crossing <= lines.length * .2 &&
        to >= minX + minColumnWidth &&
        x <= maxX - minColumnWidth;
    if (!eligible) {
      from = null;
      previousCrossing = null;
      continue;
    }
    // Keep a contiguous interval only while it has the same crossing count.
    if (previousCrossing != crossing) from = x;
    previousCrossing = crossing;
    from ??= x;
    final support = math.min(left, right);
    if (to - from >= minGap &&
        (best == null ||
            crossing < best.crossing ||
            (crossing == best.crossing &&
                (support > best.support || to - from > best.to - best.from)))) {
      best = (from: from, to: to, crossing: crossing, support: support);
    }
  }
  if (best == null) return [];
  final x = (best.from + best.to) / 2;
  final a = lines.where((l) => l.bounds.right <= x).toList();
  final b = lines.where((l) => l.bounds.left >= x).toList();
  final ar = a.map((l) => l.bounds).reduce((a, b) => a.union(b));
  final br = b.map((l) => l.bounds).reduce((a, b) => a.union(b));
  if (ar.width < minColumnWidth || br.width < minColumnWidth) return [];
  if (math.min(ar.bottom, br.bottom) - math.max(ar.top, br.top) < minGap * 2) {
    return [];
  }
  return [..._gutters(a), x, ..._gutters(b)];
}
