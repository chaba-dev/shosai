/// Lazy continuous reading of one Dart-engine EPUB chapter.
///
/// A continuous chapter is one scrolled column, but only a *window* of its
/// top-level nodes is laid out: the nodes around the viewport. Every node has
/// an extent in the column — measured once it has been laid out, estimated
/// from the chapter's measured text density until then — so the scroll extent
/// covers the whole chapter while the painters, slices and selection geometry
/// that stay resident cover the window only.
///
/// The window grows toward the viewport one bounded batch at a time
/// ([advanceContinuousWindow]) and releases nodes far from it, so neither the
/// work per frame nor the retained layout grows with the chapter. A node's
/// measured extent outlives its painters, so a node keeps its place in the
/// column after it is released and laid out again.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';

import 'content.dart';
import 'flow.dart';
import 'pages.dart';
import 'surface.dart';

/// How far beyond each edge of the viewport, in viewport heights, the window
/// is laid out, so a scroll reveals measured text rather than an estimate.
const double kContinuousLeadViewports = 1.5;

/// How far beyond each edge of the viewport, in viewport heights, laid-out
/// nodes are kept. Nodes farther away are released.
///
/// Wider than [kContinuousLeadViewports], so a reader scrolling back and forth
/// near a window edge does not release and re-measure the same nodes.
const double kContinuousKeepViewports = 4;

/// The most nodes one window step measures.
const int kContinuousBatchNodes = 8;

/// The layout time after which one window step stops measuring.
///
/// Half the paginated fill's batch: a window step also builds the selection
/// geometry of the nodes it measured, in the same frame.
const int kContinuousBatchMicros = 4000;

/// The column extent of every node of one chapter at one layout: measured
/// where the node has been laid out, estimated elsewhere.
///
/// The estimate is calibrated once, from the first window laid out, and then
/// fixed: only a measurement moves a node, so the column changes exactly where
/// a node was measured, and the view keeps the content it shows in place by
/// the same amount ([ReaderEpubWindow.nodeTops]).
///
/// Extents are plain numbers owned by the controller for one layout key; they
/// hold no native resources and survive a replaced layout session.
class ContinuousExtents {
  ContinuousExtents(this.chapter)
    : _measured = List<double?>.filled(chapter.blocks.length, null);

  final EpubChapter chapter;
  final List<double?> _measured;

  /// Column pixels per canonical scalar, once calibrated.
  double? _density;

  /// The estimated extent of a node without text (an image, a rule).
  double _atomicExtent = 0;

  int get nodeCount => _measured.length;

  /// Whether the estimate has been calibrated.
  bool get calibrated => _density != null;

  /// Whether [node]'s extent has been measured.
  bool isMeasured(int node) => _measured[node] != null;

  /// The measured extent of [node], or its estimate.
  double extent(int node) => _measured[node] ?? _estimate(node);

  double _estimate(int node) {
    final scalars = _scalars(node);
    return scalars == 0 ? _atomicExtent : (_density ?? 0) * scalars;
  }

  int _scalars(int node) {
    final canonical = chapter.blocks[node].canonical;
    return canonical == null ? 0 : canonical.end - canonical.start;
  }

  /// Records [node]'s measured extent.
  void record(int node, double extent) => _measured[node] = extent;

  /// Fixes the estimate from the nodes measured so far.
  void calibrate({required double fallbackDensity}) {
    if (_density != null) return;
    var textExtent = 0.0;
    var textScalars = 0;
    var atomicExtent = 0.0;
    var atomicNodes = 0;
    for (var node = 0; node < _measured.length; node += 1) {
      final extent = _measured[node];
      if (extent == null) continue;
      final scalars = _scalars(node);
      if (scalars == 0) {
        atomicExtent += extent;
        atomicNodes += 1;
      } else {
        textExtent += extent;
        textScalars += scalars;
      }
    }
    _density = textScalars == 0 ? fallbackDensity : textExtent / textScalars;
    _atomicExtent = atomicNodes == 0 ? 0 : atomicExtent / atomicNodes;
  }

  /// The column top of every node, then the column's height: `nodeCount + 1`
  /// entries.
  Float64List tops() {
    final tops = Float64List(_measured.length + 1);
    var cursor = 0.0;
    for (var node = 0; node < _measured.length; node += 1) {
      tops[node] = cursor;
      cursor += extent(node);
    }
    tops[_measured.length] = cursor;
    return tops;
  }
}

/// The node whose column extent contains [y] (clamped to the chapter).
int continuousNodeAt(Float64List tops, double y) {
  final count = tops.length - 1;
  if (count <= 0) return 0;
  var low = 0;
  var high = count - 1;
  while (low < high) {
    final middle = (low + high + 1) >> 1;
    if (tops[middle] <= y) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  return low;
}

/// The node the view keeps in place when the column changes: the first node
/// that starts at or below [y], and is laid out when the window reaches it.
///
/// Not the node under [y]: that node is partly above the view, and when its
/// own extent changes everything after it moves. Not a node above the window
/// either: it paints nothing yet, and measuring it moves it — the laid-out
/// text below it is what the reader sees.
int continuousAnchorNode(
  List<double> tops,
  double y, {
  int firstLaidOut = 0,
  int endLaidOut = 0,
}) {
  final count = tops.length - 1;
  var low = 0;
  var high = count;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (tops[middle] < y) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (low < firstLaidOut && firstLaidOut < endLaidOut) low = firstLaidOut;
  return math.min(low, math.max(0, count - 1));
}

/// One laid-out node's page slices and selection geometry, placed at the
/// node's own top (content x, node-local y).
class _NodeGeometry {
  _NodeGeometry({
    required this.first,
    required this.page,
    required this.endpoints,
    required this.visualLines,
    required this.graphemes,
    required this.words,
  });

  /// The node's first measured block: a node released and laid out again has
  /// new blocks, so a cached entry is only valid while this is still its first.
  final FlowBlock first;
  final FlowPage page;
  final List<FlutterSelectionEndpoint> endpoints;
  final List<FlutterSelectionVisualLine> visualLines;
  final List<int> graphemes;
  final List<int> words;

  double get extent => page.height;
}

/// Per-node geometry of one layout session's window.
///
/// A step lays out a bounded batch of nodes, so building the geometry of only
/// the nodes that are new keeps the step's work bounded; nodes that stay keep
/// theirs. Entries reference the session's blocks, so the cache belongs to
/// exactly one session and drops a node's entry when the node is released.
class ContinuousGeometryCache {
  ContinuousGeometryCache(this.chapter);

  final EpubChapter chapter;
  final Map<int, _NodeGeometry> _nodes = {};
  late final _ScalarIndex _scalars = _ScalarIndex(chapter.canonicalText);

  /// Nodes whose geometry this cache holds.
  int get cachedNodes => _nodes.length;

  _NodeGeometry _geometry(
    int node,
    List<FlowBlock> blocks,
    ChapterLayoutSession session,
    EpubPageBox box,
  ) {
    final cached = _nodes[node];
    if (cached != null && identical(cached.first, blocks.first)) return cached;
    // Pagination with an unbounded height is concatenation, so one node's page
    // is exactly the part of the whole chapter's continuous page it fills.
    final page = paginateFlow(
      flow: ChapterFlow(
        spine: chapter.spine,
        width: session.spec.width,
        height: 0,
        blocks: blocks,
        canonicalScalarCount: chapter.scalarCount,
        overflowClippedBlocks: 0,
        palette: session.spec.typography.palette,
      ),
      pageHeight: double.infinity,
      pageWidth: session.spec.width,
    ).pages.first;
    final geometry = pageSelectionGeometry(page, box);
    final canonical = chapter.blocks[node].canonical;
    final boundaries = canonical == null || page.slices.isEmpty
        ? (graphemes: const <int>[], words: const <int>[])
        : _scalars.boundaries(canonical.start, canonical.end);
    final entry = _NodeGeometry(
      first: blocks.first,
      page: page,
      endpoints: geometry.endpoints,
      visualLines: geometry.visualLines,
      graphemes: boundaries.graphemes,
      words: boundaries.words,
    );
    _nodes[node] = entry;
    return entry;
  }

  void _retainOnly(int first, int end) =>
      _nodes.removeWhere((node, _) => node < first || node >= end);
}

/// Code-unit offsets of the canonical stream at every [_stride] scalars, so
/// a node's boundaries are read without counting from the chapter start.
class _ScalarIndex {
  _ScalarIndex(this.text) {
    var scalar = 0;
    var unit = 0;
    while (unit < text.length) {
      if (scalar % _stride == 0) _checkpoints.add(unit);
      final lead = text.codeUnitAt(unit);
      unit +=
          (lead & 0xFC00) == 0xD800 &&
              unit + 1 < text.length &&
              (text.codeUnitAt(unit + 1) & 0xFC00) == 0xDC00
          ? 2
          : 1;
      scalar += 1;
    }
    _scalarCount = scalar;
  }

  static const _stride = 256;
  final String text;
  final List<int> _checkpoints = [];
  late final int _scalarCount;

  int _codeUnitAt(int scalar) {
    if (scalar <= 0) return 0;
    if (scalar >= _scalarCount) return text.length;
    var unit = _checkpoints[scalar ~/ _stride];
    for (var step = scalar % _stride; step > 0; step -= 1) {
      final lead = text.codeUnitAt(unit);
      unit +=
          (lead & 0xFC00) == 0xD800 &&
              unit + 1 < text.length &&
              (text.codeUnitAt(unit + 1) & 0xFC00) == 0xDC00
          ? 2
          : 1;
    }
    return unit;
  }

  ({List<int> graphemes, List<int> words}) boundaries(int start, int end) {
    final from = start.clamp(0, _scalarCount);
    final to = end.clamp(from, _scalarCount);
    if (to <= from) return (graphemes: <int>[from], words: <int>[from]);
    final boundaries = navigationBoundaries(
      text.substring(_codeUnitAt(from), _codeUnitAt(to)),
    );
    return (
      graphemes: [for (final value in boundaries.graphemes) value + from],
      words: [for (final value in boundaries.words) value + from],
    );
  }
}

/// The continuous page of [session]'s laid-out window.
///
/// The page box is the whole chapter column (never shorter than the window):
/// laid-out nodes sit at their column tops, and the space of nodes outside the
/// window is reserved at their measured or estimated extents. The slices, the
/// selection endpoints, visual lines and boundaries cover the window only,
/// and every geometry is in the column's coordinates, so a pointer, a
/// highlight and a painted glyph agree exactly as on a page.
///
/// Records every laid-out node's measured extent into [extents] first, and
/// calibrates its estimate from the first window.
ReaderEpubPage continuousWindowFor({
  required ChapterLayoutSession session,
  required ContinuousExtents extents,
  required ContinuousGeometryCache cache,
  required int scalar,
  required int unit,
  required int chapterCount,
  required Size windowSize,
}) {
  final chapter = session.chapter;
  final frame = epubPageBoxFor(windowSize);
  // Geometry is built in the page box with a node-local vertical origin: the
  // content's left inset and the top margin, placed at the node's column top.
  final nodeBox = EpubPageBox(
    size: windowSize,
    origin: frame.origin,
    contentWidth: frame.contentWidth,
    contentHeight: double.infinity,
  );
  final nodes = <({int node, _NodeGeometry geometry})>[];
  final blocks = session.blocks;
  var index = 0;
  while (index < blocks.length) {
    final node = blocks[index].nodeIndex;
    var end = index + 1;
    while (end < blocks.length && blocks[end].nodeIndex == node) {
      end += 1;
    }
    final geometry = cache._geometry(
      node,
      blocks.sublist(index, end),
      session,
      nodeBox,
    );
    extents.record(node, geometry.extent);
    nodes.add((node: node, geometry: geometry));
    index = end;
  }
  // A node that laid out no block (an empty paragraph) has no extent.
  if (session.started) {
    for (
      var node = session.firstNodeIndex;
      node <= session.lastNodeIndex;
      node += 1
    ) {
      if (!extents.isMeasured(node)) extents.record(node, 0);
    }
    cache._retainOnly(session.firstNodeIndex, session.lastNodeIndex + 1);
  }
  final typography = session.spec.typography;
  extents.calibrate(
    // One line of body text per line of characters at roughly half an em.
    fallbackDensity:
        typography.fontSize *
        typography.lineHeight /
        math.max(1.0, frame.contentWidth / (typography.fontSize * 0.5)),
  );
  final tops = extents.tops();
  final slices = <PageSlice>[];
  final endpoints = <FlutterSelectionEndpoint>[];
  final visualLines = <FlutterSelectionVisualLine>[];
  final graphemes = <int>[];
  final words = <int>[];
  void addBoundaries(List<int> into, List<int> values) {
    for (final value in values) {
      if (into.isEmpty || into.last < value) into.add(value);
    }
  }

  for (final (:node, :geometry) in nodes) {
    final dy = tops[node];
    for (final slice in geometry.page.slices) {
      slices.add(_shiftedSlice(slice, dy));
    }
    for (final endpoint in geometry.endpoints) {
      final rect = endpoint.rect;
      endpoints.add(
        FlutterSelectionEndpoint(
          offset: endpoint.offset,
          rangeStart: endpoint.rangeStart,
          rangeEnd: endpoint.rangeEnd,
          rect: FlutterSelectionRect(
            left: rect.left,
            top: rect.top + dy,
            right: rect.right,
            bottom: rect.bottom + dy,
          ),
        ),
      );
    }
    for (final line in geometry.visualLines) {
      visualLines.add(
        FlutterSelectionVisualLine(
          carets: [
            for (final caret in line.carets)
              FlutterSelectionCaret(
                offset: caret.offset,
                x: caret.x,
                alongLine: caret.alongLine,
                vertical: caret.vertical,
                top: caret.top + dy,
                bottom: caret.bottom + dy,
              ),
          ],
        ),
      );
    }
    addBoundaries(graphemes, geometry.graphemes);
    addBoundaries(words, geometry.words);
  }
  final height = tops[tops.length - 1];
  final box = EpubPageBox(
    size: Size(
      windowSize.width,
      math.max(windowSize.height, height + 2 * kEpubPageMargin),
    ),
    origin: frame.origin,
    contentWidth: frame.contentWidth,
    contentHeight: math.max(height, frame.contentHeight),
  );
  final page = FlowPage(index: 0, slices: slices, height: height);
  final start = slices.isEmpty ? 0 : page.canonicalStart;
  final end = slices.isEmpty ? 0 : page.canonicalEnd;
  if (graphemes.isEmpty) graphemes.add(start);
  if (words.isEmpty) words.add(start);
  final surface = FlutterSelectionSurface(
    width: box.size.width,
    height: box.size.height,
    text: chapter.canonicalText,
    copyEligible: true,
    resourcePath: chapter.resource,
    endpoints: endpoints,
    graphemeBoundaries: Uint32List.fromList(graphemes),
    wordBoundaries: Uint32List.fromList(words),
    visualLines: visualLines,
  );
  return ReaderEpubPage(
    unit: unit,
    targetScalar: scalar,
    continuous: true,
    pageIndex: 0,
    pageCount: 1,
    layoutComplete: session.complete,
    canGoBackward: unit > 0,
    canGoForward: unit + 1 < chapterCount,
    canonicalStart: start,
    canonicalEnd: end,
    laidOutNodes: session.laidOutNodes,
    totalNodes: session.totalNodes,
    overflowPages: 0,
    page: page,
    box: box,
    surface: surface,
    palette: typography.palette,
    window: ReaderEpubWindow(
      firstNode: session.started ? session.firstNodeIndex : 0,
      endNode: session.started ? session.lastNodeIndex + 1 : 0,
      nodeTops: tops,
    ),
  );
}

PageSlice _shiftedSlice(PageSlice slice, double dy) => switch (slice) {
  TextPageSlice() => TextPageSlice(
    block: slice.block,
    top: slice.top + dy,
    lineStart: slice.lineStart,
    lineEnd: slice.lineEnd,
  ),
  TablePageSlice() => TablePageSlice(
    block: slice.block,
    top: slice.top + dy,
    rowStart: slice.rowStart,
    rowEnd: slice.rowEnd,
  ),
  WholePageSlice() => WholePageSlice(block: slice.block, top: slice.top + dy),
};

/// What one [advanceContinuousWindow] step did.
class ContinuousWindowStep {
  const ContinuousWindowStep({
    required this.released,
    required this.changed,
    required this.pending,
    required this.anchorNode,
    required this.anchorTop,
  });

  /// Blocks the step detached from the session. They are no longer laid out,
  /// but the page installed before the step still paints them: the owner
  /// releases them once a page without them is shown.
  final List<FlowBlock> released;

  /// Whether the laid-out window changed, so a new page must be installed.
  final bool changed;

  /// Whether the window does not cover the viewport's lead yet, so another
  /// step is due.
  final bool pending;

  /// The node under the viewport's top, and its column top before the step.
  ///
  /// Measuring nodes above it moves it in the column; the view keeps it in
  /// place by scrolling by the same amount, which is its top in the next page
  /// minus [anchorTop].
  final int anchorNode;
  final double anchorTop;
}

/// Moves [session]'s window one bounded step toward the viewport
/// [viewportTop]..[viewportBottom] (column coordinates).
///
/// A window that does not reach the viewport at all (a scrollbar drag, a
/// resize) starts again at the node under the viewport's top; otherwise nodes
/// beyond [kContinuousKeepViewports] are released and at most one batch of
/// [kContinuousBatchNodes] nodes or [kContinuousBatchMicros] of layout is
/// measured, before the viewport first, then after it.
ContinuousWindowStep advanceContinuousWindow({
  required ChapterLayoutSession session,
  required ContinuousExtents extents,
  required double viewportTop,
  required double viewportBottom,
}) {
  final count = session.totalNodes;
  if (count == 0) {
    return const ContinuousWindowStep(
      released: [],
      changed: false,
      pending: false,
      anchorNode: 0,
      anchorTop: 0,
    );
  }
  final before = extents.tops();
  final span = math.max(1.0, viewportBottom - viewportTop);
  final visible = continuousNodeAt(before, viewportTop);
  final anchor = continuousAnchorNode(
    before,
    viewportTop,
    firstLaidOut: session.started ? session.firstNodeIndex : 0,
    endLaidOut: session.started ? session.lastNodeIndex + 1 : 0,
  );
  final lead = kContinuousLeadViewports * span;
  final keep = kContinuousKeepViewports * span;
  final first = continuousNodeAt(before, viewportTop - lead);
  final last = continuousNodeAt(before, viewportBottom + lead);
  final released = <FlowBlock>[];
  var changed = false;
  if (!session.started ||
      session.lastNodeIndex < first ||
      session.firstNodeIndex > last) {
    released.addAll(session.releaseAll());
    session.layoutWindowAt(0, node: visible);
    changed = true;
  } else {
    final keepFirst = continuousNodeAt(before, viewportTop - keep);
    if (keepFirst > session.firstNodeIndex) {
      released.addAll(session.releaseBefore(keepFirst));
      changed = true;
    }
    final keepEnd = continuousNodeAt(before, viewportBottom + keep) + 1;
    if (keepEnd <= session.lastNodeIndex) {
      released.addAll(session.releaseFrom(keepEnd));
      changed = true;
    }
    final grown = session.firstNodeIndex > first
        ? session.layoutBackward(
            maxNodes: kContinuousBatchNodes,
            maxMicros: kContinuousBatchMicros,
          )
        : session.lastNodeIndex < last
        ? session.layoutForward(
            maxNodes: kContinuousBatchNodes,
            maxMicros: kContinuousBatchMicros,
          )
        : 0;
    if (grown > 0) changed = true;
  }
  return ContinuousWindowStep(
    released: released,
    changed: changed,
    pending:
        changed &&
        (session.firstNodeIndex > first || session.lastNodeIndex < last),
    anchorNode: anchor,
    anchorTop: before[anchor],
  );
}
