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
const double kContinuousKeepViewports = 3;

/// The most nodes one window step measures.
const int kContinuousBatchNodes = 8;

/// The layout time after which one window step stops measuring.
///
/// Half the paginated fill's batch: a window step also places the nodes it
/// measured and builds selection geometry, in the same frame.
const int kContinuousBatchMicros = 3000;

/// The time after which one window step stops building selection geometry;
/// the remaining nodes paint without it until the next step.
const int kContinuousSelectionMicros = 2500;

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

  /// The atomic estimate when no atomic node was measured yet: never zero, so
  /// a run of unmeasured images still reserves space and a window step
  /// measuring them is not hidden behind a column that does not move.

  int _scalars(int node) {
    final canonical = chapter.blocks[node].canonical;
    return canonical == null ? 0 : canonical.end - canonical.start;
  }

  /// Records [node]'s measured extent.
  void record(int node, double extent) => _measured[node] = extent;

  /// Fixes the estimate from the nodes measured so far.
  void calibrate({
    required double fallbackDensity,
    required double fallbackAtomicExtent,
  }) {
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
    _atomicExtent = atomicNodes == 0
        ? fallbackAtomicExtent
        : math.max(1.0, atomicExtent / atomicNodes);
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
int continuousNodeAt(List<double> tops, double y) {
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

/// [y] in the column of [from], placed at the same point of the same node in
/// the column of [to]: what was under [y] is under the result once [to] is
/// installed. Within a node, the offset is clamped to the node's new extent.
double continuousMapToColumn(List<double> from, List<double> to, double y) {
  if (identical(from, to) || from.length != to.length || from.length < 2) {
    return y;
  }
  final node = continuousNodeAt(from, y);
  final within = y - from[node];
  return to[node] + math.min(within, math.max(0.0, to[node + 1] - to[node]));
}

/// Where the view's top [y], in [before]'s column, is once [after] is
/// installed: the rule the view corrects its scroll offset by, and the one
/// the controller maps a report against an older window with.
///
/// A restarted window keeps the view's place in the node under [y]
/// ([continuousMapToColumn]); otherwise the laid-out node the view keeps in
/// place ([continuousAnchorNode]) moves the view by its own shift, and with
/// no such node nothing moves.
double continuousCorrectedTop(
  ReaderEpubWindow before,
  ReaderEpubWindow after,
  double y,
) {
  if (identical(before, after) ||
      before.nodeTops.length != after.nodeTops.length) {
    return y;
  }
  if (after.restartedAt != null) {
    return continuousMapToColumn(before.nodeTops, after.nodeTops, y);
  }
  final node = continuousAnchorNode(
    before.nodeTops,
    y,
    firstLaidOut: before.firstNode,
    endLaidOut: before.endNode,
  );
  return node == null ? y : y + after.nodeTops[node] - before.nodeTops[node];
}

/// The node the view keeps in place when the column changes, or null when
/// nothing laid out can be: the first laid-out node that starts at or below
/// [y], within [firstLaidOut]..[endLaidOut], or else the laid-out node under
/// [y] (a node taller than the rest of the view, the window's last).
///
/// The node under [y] only as the fallback: it is partly above the view, and
/// a node starting in the view is what the reader reads next. Never a node
/// outside the window: it paints nothing, and keeping an estimated node in
/// place would move the view along with every measurement in front of it. A
/// laid-out node's extent is measured, so keeping it in place is exact.
int? continuousAnchorNode(
  List<double> tops,
  double y, {
  required int firstLaidOut,
  required int endLaidOut,
}) {
  if (endLaidOut <= firstLaidOut) return null;
  var low = 0;
  var high = tops.length - 1;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (tops[middle] < y) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final node = math.max(low, firstLaidOut);
  if (node < endLaidOut) return node;
  final under = low - 1;
  return under >= firstLaidOut && under < endLaidOut ? under : null;
}

/// One laid-out node's page slices and selection geometry, placed at the
/// node's own top (content x, node-local y).
class _NodeGeometry {
  _NodeGeometry({required this.first, required this.page});

  /// The node's first measured block: a node released and laid out again has
  /// new blocks, so a cached entry is only valid while this is still its first.
  final FlowBlock first;

  /// The node's slices, node-local: what paints it. Cheap, so it is built as
  /// soon as the node is laid out.
  final FlowPage page;

  /// The node's selection geometry, node-local, once built.
  ///
  /// Building it costs one shaped-box query per grapheme, the most expensive
  /// part of a step, so it has its own per-step budget: a node paints from
  /// [page] before its selection geometry exists.
  ({
    List<FlutterSelectionEndpoint> endpoints,
    List<FlutterSelectionVisualLine> visualLines,
    List<int> graphemes,
    List<int> words,
  })?
  selection;

  double get extent => page.height;

  /// This node's geometry placed at column top [_placedAt], kept until the
  /// node moves (or gains its selection geometry): a window step re-places
  /// only the nodes that are new or moved.
  double? _placedAt;
  bool _placedSelection = false;
  List<PageSlice> _slices = const [];
  List<FlutterSelectionEndpoint> _endpoints = const [];
  List<FlutterSelectionVisualLine> _visualLines = const [];

  void _place(double dy) {
    final selection = this.selection;
    if (_placedAt != dy) {
      _slices = [for (final slice in page.slices) _shiftedSlice(slice, dy)];
    } else if (_placedSelection == (selection != null)) {
      return;
    }
    _placedAt = dy;
    _placedSelection = selection != null;
    if (selection == null) return;
    _endpoints = [
      for (final endpoint in selection.endpoints)
        FlutterSelectionEndpoint(
          offset: endpoint.offset,
          rangeStart: endpoint.rangeStart,
          rangeEnd: endpoint.rangeEnd,
          rect: FlutterSelectionRect(
            left: endpoint.rect.left,
            top: endpoint.rect.top + dy,
            right: endpoint.rect.right,
            bottom: endpoint.rect.bottom + dy,
          ),
        ),
    ];
    _visualLines = [
      for (final line in selection.visualLines)
        FlutterSelectionVisualLine(
          carets: List.unmodifiable([
            for (final caret in line.carets)
              FlutterSelectionCaret(
                offset: caret.offset,
                x: caret.x,
                alongLine: caret.alongLine,
                vertical: caret.vertical,
                top: caret.top + dy,
                bottom: caret.bottom + dy,
              ),
          ]),
        ),
    ];
  }
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

  /// Whether a laid-out node of the last window still lacks its selection
  /// geometry, so another step is due to build it.
  bool get selectionPending => _selectionPending;
  bool _selectionPending = false;

  _NodeGeometry _geometry(
    int node,
    List<FlowBlock> blocks,
    ChapterLayoutSession session,
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
    final entry = _NodeGeometry(first: blocks.first, page: page);
    _nodes[node] = entry;
    return entry;
  }

  void _buildSelection(int node, _NodeGeometry entry, EpubPageBox box) {
    final geometry = pageSelectionGeometry(entry.page, box);
    final canonical = chapter.blocks[node].canonical;
    final boundaries = canonical == null || entry.page.slices.isEmpty
        ? (graphemes: const <int>[], words: const <int>[])
        : _scalars.boundaries(canonical.start, canonical.end);
    entry.selection = (
      endpoints: geometry.endpoints,
      visualLines: geometry.visualLines,
      graphemes: boundaries.graphemes,
      words: boundaries.words,
    );
  }

  /// Grapheme and word boundaries of the nodes around [scalar]: the node
  /// holding it and one node either side.
  ///
  /// Keyboard selection moves by these, so a focus outside the laid-out window
  /// still moves by one grapheme or word, and crosses into the next node.
  ({List<int> graphemes, List<int> words}) boundariesAround(int scalar) {
    final blocks = chapter.blocks;
    var node = 0;
    for (var index = 0; index < blocks.length; index += 1) {
      final canonical = blocks[index].canonical;
      if (canonical == null) continue;
      if (canonical.start > scalar) break;
      node = index;
    }
    int? start;
    int? end;
    for (
      var index = math.max(0, node - 1);
      index <= math.min(blocks.length - 1, node + 1);
      index += 1
    ) {
      final canonical = blocks[index].canonical;
      if (canonical == null) continue;
      start = start == null
          ? canonical.start
          : math.min(start, canonical.start);
      end = end == null ? canonical.end : math.max(end, canonical.end);
    }
    if (start == null || end == null) {
      return (graphemes: <int>[scalar], words: <int>[scalar]);
    }
    return _scalars.boundaries(start, end);
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
///
/// With [selectionBudgetMicros], selection geometry is built for the nodes
/// nearest [priorityTop] (column coordinates) until the budget is spent; the
/// others paint without it until a later call
/// ([ContinuousGeometryCache.selectionPending]).
ReaderEpubPage continuousWindowFor({
  required ChapterLayoutSession session,
  required ContinuousExtents extents,
  required ContinuousGeometryCache cache,
  required int scalar,
  required int unit,
  required int chapterCount,
  required Size windowSize,
  double priorityTop = 0,
  int? selectionBudgetMicros,
  int? restartedAt,
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
    final geometry = cache._geometry(node, blocks.sublist(index, end), session);
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
  // Selection geometry is built as one run of consecutive nodes, grown
  // toward [priorityTop] within the budget (and started at the node nearest
  // it). A node is always built, so every step makes progress. Never two runs
  // with a node still pending between them: the surface's visual lines then
  // hold no gap a keyboard movement could step across.
  if (nodes.any((entry) => entry.geometry.selection == null)) {
    final before = extents.tops();
    double distance(int index) {
      final node = nodes[index].node;
      return math.max(
        0.0,
        math.max(before[node] - priorityTop, priorityTop - before[node + 1]),
      );
    }

    final watch = Stopwatch()..start();
    var built = 0;
    bool spent() =>
        selectionBudgetMicros != null &&
        built > 0 &&
        watch.elapsedMicroseconds >= selectionBudgetMicros;
    void build(int index) {
      final (:node, :geometry) = nodes[index];
      cache._buildSelection(node, geometry, nodeBox);
      built += 1;
    }

    var low = nodes.indexWhere((entry) => entry.geometry.selection != null);
    var high = nodes.lastIndexWhere(
      (entry) => entry.geometry.selection != null,
    );
    if (low < 0) {
      var nearest = 0;
      for (var index = 1; index < nodes.length; index += 1) {
        if (distance(index) < distance(nearest)) nearest = index;
      }
      build(nearest);
      low = high = nearest;
    }
    for (var index = low; index <= high && !spent(); index += 1) {
      if (nodes[index].geometry.selection == null) build(index);
    }
    while (!spent() && (low > 0 || high < nodes.length - 1)) {
      final above = low > 0 ? distance(low - 1) : double.infinity;
      final below = high < nodes.length - 1
          ? distance(high + 1)
          : double.infinity;
      if (above <= below) {
        build(low -= 1);
      } else {
        build(high += 1);
      }
    }
  }
  cache._selectionPending = nodes.any(
    (entry) => entry.geometry.selection == null,
  );
  final typography = session.spec.typography;
  extents.calibrate(
    // One line of body text per line of characters at roughly half an em.
    fallbackDensity:
        typography.fontSize *
        typography.lineHeight /
        math.max(1.0, frame.contentWidth / (typography.fontSize * 0.5)),
    // An image is commonly a good part of a page tall.
    fallbackAtomicExtent: frame.contentHeight / 3,
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
    geometry._place(tops[node]);
    slices.addAll(geometry._slices);
    endpoints.addAll(geometry._endpoints);
    visualLines.addAll(geometry._visualLines);
    final selection = geometry.selection;
    if (selection != null) {
      addBoundaries(graphemes, selection.graphemes);
      addBoundaries(words, selection.words);
    }
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
    // Built unmodifiable, so the owner adopts it without copying it again
    // ([continuousSurfaceFrozen]).
    endpoints: List.unmodifiable(endpoints),
    graphemeBoundaries: Uint32List.fromList(graphemes).asUnmodifiableView(),
    wordBoundaries: Uint32List.fromList(words).asUnmodifiableView(),
    visualLines: List.unmodifiable(visualLines),
  );
  _frozen[surface] = true;
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
      restartedAt: restartedAt,
      targetNode: scalar <= 0 ? null : session.nodeIndexForScalar(scalar),
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

final Expando<bool> _frozen = Expando();

/// Whether [surface] is a continuous window's surface, whose lists are
/// already unmodifiable.
bool continuousSurfaceFrozen(FlutterSelectionSurface surface) =>
    _frozen[surface] ?? false;

/// What one [advanceContinuousWindow] step did.
class ContinuousWindowStep {
  const ContinuousWindowStep({
    required this.changed,
    required this.pending,
    this.restartedAt,
  });

  /// The node the window was started again at, when the viewport did not
  /// intersect it: the view then places that node at its top.
  final int? restartedAt;

  /// Whether the laid-out window changed, so a new page must be installed.
  final bool changed;

  /// Whether the window does not cover the viewport's lead yet, so another
  /// step is due.
  final bool pending;
}

/// Moves [session]'s window one bounded step toward the viewport
/// [viewportTop]..[viewportBottom] (column coordinates).
///
/// A window the viewport does not intersect (a scrollbar drag, a fast fling,
/// a resize) starts again at the node under the viewport's top; otherwise
/// nodes beyond [kContinuousKeepViewports] are released. Either way at most
/// one batch of [kContinuousBatchNodes] nodes or [kContinuousBatchMicros] of
/// layout is measured, before the viewport first, then after it.
///
/// Every block the step detaches is added to [released] as soon as it is
/// detached, so the caller owns it even when a later part of the step throws:
/// the page installed before the step may still paint it, and the caller
/// releases it once a page without it is shown.
ContinuousWindowStep advanceContinuousWindow({
  required ChapterLayoutSession session,
  required ContinuousExtents extents,
  required double viewportTop,
  required double viewportBottom,
  required List<FlowBlock> released,
}) {
  final count = session.totalNodes;
  if (count == 0) {
    return const ContinuousWindowStep(changed: false, pending: false);
  }
  final before = extents.tops();
  final span = math.max(1.0, viewportBottom - viewportTop);
  final visible = continuousNodeAt(before, viewportTop);
  final bottom = continuousNodeAt(before, viewportBottom);
  final lead = kContinuousLeadViewports * span;
  final keep = kContinuousKeepViewports * span;
  final first = continuousNodeAt(before, viewportTop - lead);
  final last = continuousNodeAt(before, viewportBottom + lead);
  var changed = false;
  int? restartedAt;
  if (!session.started ||
      session.lastNodeIndex < visible ||
      session.firstNodeIndex > bottom) {
    released.addAll(session.releaseAll());
    changed = true;
    restartedAt = visible;
    session.layoutWindowAt(
      0,
      node: visible,
      maxNodes: kContinuousBatchNodes,
      maxMicros: kContinuousBatchMicros,
    );
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
    // The viewport itself first, then the lead above it, then below.
    final grown = session.lastNodeIndex < bottom
        ? session.layoutForward(
            maxNodes: kContinuousBatchNodes,
            maxMicros: kContinuousBatchMicros,
          )
        : session.firstNodeIndex > first
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
    changed: changed,
    pending:
        changed &&
        (session.firstNodeIndex > first || session.lastNodeIndex < last),
    restartedAt: restartedAt,
  );
}
