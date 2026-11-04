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
/// The output has one entry per input page, in the same order. A fallback is
/// one complete page: a scan or an uncertain layout must never lose content.
///
/// Gutters need at least three lines on either side, simultaneous vertical
/// extent, and a gap of at least 12pt or 1.2 line heights. Up to 20% spanning
/// lines may cross a gutter (titles, equations, etc.); those become bands.
/// This deliberately conservative geometric heuristic is not OCR or semantic
/// figure/table recognition. [rightToLeft] comes from `/Direction /R2L`, not
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
  final gutters = _gutters(lines);
  if (gutters.isEmpty) {
    return PdfColumnPage(
      columnCount: 0,
      regions: [
        PdfReadingRegion(
          kind: PdfRegionKind.page,
          bounds: PdfRect(0, 0, page.width, page.height),
          lines: lines,
        ),
      ],
    );
  }
  bool spans(PdfRect r) => gutters.any((x) => r.left < x && r.right > x);
  final bands = <PdfReadingRegion>[
    for (final line in lines.where((line) => spans(line.bounds)))
      PdfReadingRegion(
        kind: PdfRegionKind.band,
        bounds: line.bounds,
        lines: [line],
      ),
    for (final image in page.images.where(spans))
      PdfReadingRegion(kind: PdfRegionKind.figure, bounds: image),
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
            math.max(last.lines.last.bounds.height, band.bounds.height) * 1.5) {
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
  final remaining = lines.where((line) => !spans(line.bounds)).toList();
  final images = page.images.where((r) => !spans(r)).toList();
  void flush(double before) {
    final slabLines = remaining.where((l) => l.bounds.top < before).toList();
    final slabImages = images.where((r) => r.top < before).toList();
    remaining.removeWhere(slabLines.contains);
    images.removeWhere(slabImages.contains);
    final order = List.generate(gutters.length + 1, (i) => i);
    if (rtl) order.sort((a, b) => b.compareTo(a));
    for (final column in order) {
      bool belongs(PdfRect r) =>
          (column == 0 || r.left >= gutters[column - 1]) &&
          (column == gutters.length || r.right <= gutters[column]);
      regions.addAll(
        _columnRegions(
          slabLines.where((l) => belongs(l.bounds)).toList(),
          slabImages.where(belongs).toList(),
        ),
      );
    }
  }

  for (final band in merged) {
    // A full-width band owns the complete horizontal slice, including author
    // affiliations or figure labels that do not themselves cross the gutter.
    final inside = remaining
        .where(
          (l) =>
              l.bounds.top < band.bounds.bottom &&
              l.bounds.bottom > band.bounds.top,
        )
        .toList();
    remaining.removeWhere(inside.contains);
    final bandLines = [...band.lines, ...inside]
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final bounds = inside.fold(band.bounds, (r, l) => r.union(l.bounds));
    flush(bounds.top);
    regions.add(
      PdfReadingRegion(kind: band.kind, bounds: bounds, lines: bandLines),
    );
  }
  flush(double.infinity);
  return PdfColumnPage(columnCount: gutters.length + 1, regions: regions);
}

List<PdfReadingRegion> _columnRegions(
  List<PdfTextLine> lines,
  List<PdfRect> images,
) {
  lines.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  images.sort((a, b) => a.top.compareTo(b.top));
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

  for (final image in images) {
    textBefore(image.top);
    regions.add(PdfReadingRegion(kind: PdfRegionKind.figure, bounds: image));
  }
  textBefore(double.infinity);
  return regions;
}

/// Sweep x edges, admitting only whitespace with substantial text on both
/// sides. Spanning lines cost votes but do not hide a page's body gutter.
List<double> _gutters(List<PdfTextLine> lines) {
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
  // Marginal vertical arXiv stamps and side labels are not body columns.
  final minColumnWidth = (maxX - minX) * .2;
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
