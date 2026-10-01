/// Dart-engine EPUB content: the parsed book for one document generation, the
/// canonical-parity gate, the windowed chapter layout session and page-window
/// extraction.
///
/// The retained Rust bridge still owns storage, search, bookmarks, annotations
/// and reading state. This module only decides what a chapter *looks like*: the
/// canonical stream it renders is compared with the retained one before a
/// chapter is routed, and a chapter whose streams differ (or whose stream the
/// retained implementation cannot produce) stays on the retained renderer.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/src/rust/api.dart';

import 'flow.dart';
import 'font_coverage.dart';
import 'pages.dart';
import 'surface.dart';
import 'text_style.dart';

/// The page margin inside a page window.
const double kEpubPageMargin = 24.0;

/// Maximum images decoded for one chapter.
const int kEpubChapterImageLimit = 32;

/// Maximum bytes of one image resource this renderer decodes.
const int kEpubImageByteLimit = 8 * 1024 * 1024;

/// How long one image decode may take before the layout falls back to the
/// image's alt text.
///
/// A decode is bounded work: a resource whose decoder never completes must not
/// hold the page hostage, so the chapter paints its alt fallback instead.
const Duration kEpubImageDecodeTimeout = Duration(seconds: 5);

/// Maximum decoded image bytes retained for one document.
///
/// Decoded rasters live until the document is replaced, so the budget is what
/// keeps a book whose chapters reference many large images bounded: a chapter
/// whose images would exceed it paints their alt fallback instead (the retained
/// renderer's missing-image fallback) rather than growing without limit.
const int kEpubDecodedImageBudget = 64 * 1024 * 1024;

/// The most text one *indivisible* layout unit may carry.
///
/// The windowed chapter session measures in bounded batches between frames, but
/// a single unit — one paragraph, one list, one table, or one nested container —
/// is measured by one call: a paragraph's `TextPainter.layout`, or a container's
/// whole subtree. A chapter carrying such a unit is left to the retained
/// renderer rather than measured in one unbounded call.
const int kEpubIndivisibleScalarLimit = 32 * 1024;

/// The most nodes one indivisible layout unit may contain.
const int kEpubIndivisibleNodeLimit = 512;

/// Decodes one encoded image resource, or null when it cannot be decoded.
typedef EpubImageDecoder = Future<ui.Image?> Function(Uint8List bytes);

/// Registers one embedded `@font-face` family under [family].
typedef EpubFontRegistrar =
    Future<void> Function(String family, Uint8List bytes);

/// A parsed Dart-engine EPUB document for one reader document generation.
///
/// The source owns the decoded images it has admitted. It is created once per
/// open and released with the document; the per-chapter layout session is
/// owned separately by the controller, because it is replaced on every chapter
/// and layout change.
class EpubContentSource {
  EpubContentSource({
    required this.book,
    required this.embeddedFamilies,
    required this.bytes,
    this.imageDecodeTimeout = kEpubImageDecodeTimeout,
    this.rasterBudgetBytes = kEpubDecodedImageBudget,
  });

  final EpubBook book;

  /// `@font-face` family name → registered Flutter family name.
  final Map<String, String> embeddedFamilies;

  /// The archive bytes the book was parsed from, retained so a later
  /// re-parse (a page-height change does not need one) or diagnostics can
  /// reference the same input.
  final Uint8List bytes;

  /// How long one image decode may take before it is refused.
  ///
  /// A seam for tests; the reader keeps [kEpubImageDecodeTimeout].
  final Duration imageDecodeTimeout;

  /// How many decoded raster bytes this source admits in total.
  ///
  /// A seam for tests; the reader keeps [kEpubDecodedImageBudget].
  final int rasterBudgetBytes;

  /// Decoded images, keyed by canonical resource path.
  final Map<String, ui.Image> images = {};

  /// In-flight decode-and-admit operations, so two chapters (or two attempts)
  /// cannot decode the same resource twice and lose ownership of one result.
  final Map<String, Future<void>> _admissions = {};

  /// Resources this source will not decode again (a failed, timed-out or
  /// over-budget raster), so a relayout does not retry them forever.
  final Set<String> _refusedImages = {};

  bool _disposed = false;

  /// Whether the owner has released this source.
  bool get isDisposed => _disposed;

  final Map<int, bool> _canonicalMatches = {};
  final Map<int, bool> _fontCoverage = {};

  final Map<int, bool> _indivisibleBounded = {};

  /// Whether every indivisible layout unit of [unit] fits the bounded-work
  /// ceilings ([kEpubIndivisibleNodeLimit], [kEpubIndivisibleScalarLimit]).
  ///
  /// The chapter session's window/batch boundary works between top-level
  /// blocks; one container is laid out in one call, so a chapter whose single
  /// blockquote, list, table or paragraph is enormous cannot be measured
  /// incrementally and is refused here (the retained renderer serves it).
  bool indivisibleUnitsBounded(int unit) =>
      _indivisibleBounded.putIfAbsent(unit, () {
        for (final block in book.chapters[unit].blocks) {
          final size = _indivisibleSize(block);
          if (size.nodes > kEpubIndivisibleNodeLimit ||
              size.scalars > kEpubIndivisibleScalarLimit) {
            return false;
          }
        }
        return true;
      });

  /// Whether the chapter's text is covered by the reader's bundled faces.
  ///
  /// Only the bundled faces are consulted. A book's own `@font-face` faces are
  /// admitted for *painting*, but they are not an admission guarantee: whether a
  /// given face is registered (and whether a given span selects it) is decided
  /// after this gate, so routing on embedded coverage alone could promise a
  /// chapter the renderer then cannot draw. Extending the gate to embedded
  /// faces needs the faces' actual selection to be validated first (5C/FM-22).
  bool fontCovered(int unit, EpubFontCoverage? bundled) {
    if (bundled == null) return false;
    return _fontCoverage.putIfAbsent(
      unit,
      () => bundled.coversText(book.chapters[unit].canonicalText),
    );
  }

  /// Whether the canonical stream of [unit] was already compared with the
  /// retained stream.
  bool? canonicalMatch(int unit) => _canonicalMatches[unit];

  /// Records the comparison result for [unit].
  void recordCanonicalMatch(int unit, bool matches) {
    _canonicalMatches[unit] = matches;
  }

  /// Whether [unit] may be served by the Dart engine.
  ///
  /// A chapter is servable only when its canonical stream was verified
  /// identical to the retained one: the reader's durable offsets, search
  /// results and stored annotations live in that stream, and rendering a
  /// different stream would silently write incompatible anchors.
  bool canServe(int unit) =>
      unit >= 0 &&
      unit < book.chapters.length &&
      _canonicalMatches[unit] == true;

  /// Bytes of decoded image rasters currently retained.
  int decodedImageBytes = 0;

  /// Decodes the images [chapter] references, bounded per chapter and per book.
  ///
  /// A resource over [kEpubImageByteLimit], an SVG (Flutter cannot decode it),
  /// a chapter with more than [kEpubChapterImageLimit] images, or a book whose
  /// decoded rasters would exceed [kEpubDecodedImageBudget] is left undecoded;
  /// the layout then paints the image's alt text instead, which is the retained
  /// renderer's missing-image fallback.
  Future<void> ensureImages(
    EpubChapter chapter,
    EpubImageDecoder decode,
  ) async {
    var decoded = 0;
    for (final src in chapterImageSources(chapter)) {
      if (_disposed) return;
      if (images.containsKey(src) || _refusedImages.contains(src)) continue;
      if (decoded >= kEpubChapterImageLimit) break;
      if (decodedImageBytes >= rasterBudgetBytes) break;
      final resource = book.resources[src];
      if (resource == null) continue;
      if (resource.mediaType == 'image/svg+xml' ||
          resource.mediaType.startsWith('image/svg')) {
        continue;
      }
      if (resource.byteLength > kEpubImageByteLimit) continue;
      decoded += 1;
      await _admitImage(src, decode, Uint8List.fromList(resource.bytes));
    }
  }

  /// One shared decode-and-admit operation per resource.
  ///
  /// The *whole* decision — decode, admit, account, release — belongs to one
  /// operation, so concurrent callers (two relayouts, two chapters) cannot each
  /// decide ownership of the same handle. The operation is dropped as soon as
  /// it settles: a settled future awaited from a later zone never completes for
  /// that caller.
  Future<void> _admitImage(
    String src,
    EpubImageDecoder decode,
    Uint8List bytes,
  ) {
    final pending = _admissions[src];
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _decodeAndAdmit(src, decode, bytes).whenComplete(() {
      if (identical(_admissions[src], operation)) _admissions.remove(src);
    });
    _admissions[src] = operation;
    return operation;
  }

  /// Decodes one resource and either adopts it or releases it.
  ///
  /// The decode is bounded by [imageDecodeTimeout]; a raster that lands after
  /// the deadline is released here, and the resource is remembered as refused
  /// so a later relayout does not start a second attempt while the first is
  /// still outstanding.
  Future<void> _decodeAndAdmit(
    String src,
    EpubImageDecoder decode,
    Uint8List bytes,
  ) async {
    ui.Image? image;
    var timedOut = false;
    final settled = Completer<void>();
    final timer = Timer(imageDecodeTimeout, () {
      timedOut = true;
      if (!settled.isCompleted) settled.complete();
    });
    try {
      // `Future.sync` normalizes a decoder that throws before returning: the
      // throw becomes the same refusal as a failed decode, so the resource is
      // remembered and the timer is cancelled on every path.
      unawaited(
        Future<ui.Image?>.sync(() => decode(bytes)).then(
          (decoded) {
            if (timedOut) {
              decoded?.dispose();
              return;
            }
            image = decoded;
            if (!settled.isCompleted) settled.complete();
          },
          onError: (Object _) {
            if (!settled.isCompleted) settled.complete();
          },
        ),
      );
      await settled.future;
    } finally {
      timer.cancel();
    }

    final decoded = image;
    if (decoded == null || _disposed) {
      decoded?.dispose();
      _refusedImages.add(src);
      return;
    }
    final rasterBytes = decoded.width * decoded.height * 4;
    if (decodedImageBytes + rasterBytes > rasterBudgetBytes) {
      // An encoded resource below the byte ceiling can still decode past the
      // chapter's raster budget: release it instead of blowing the budget.
      decoded.dispose();
      _refusedImages.add(src);
      return;
    }
    images[src] = decoded;
    decodedImageBytes += rasterBytes;
  }

  /// Releases every decoded image this source owns.
  void dispose() {
    _disposed = true;
    for (final image in images.values) {
      image.dispose();
    }
    images.clear();
    decodedImageBytes = 0;
  }
}

/// Every image resource path a chapter references, in document order.
/// The work units and canonical scalars of one indivisible layout unit.
///
/// A *work unit* is one thing the layout measures in a single call: a node, a
/// list item, or a table's group/row/cell (the table's structure is placed and
/// sized in one call even though it can paginate between rows). The scalars are
/// the unit's own canonical range, counted once: the range already spans the
/// whole subtree, so summing descendants would double-count nested text.
({int nodes, int scalars}) _indivisibleSize(EpubContentNode root) {
  final canonical = root.canonical;
  final scalars = canonical == null ? 0 : canonical.end - canonical.start;
  var nodes = 0;
  var exceeded = false;
  void count() {
    nodes += 1;
    if (nodes > kEpubIndivisibleNodeLimit) exceeded = true;
  }

  void visit(EpubContentNode node) {
    if (exceeded) return;
    count();
    switch (node) {
      case EpubBlockQuote(:final children):
      case EpubFigure(:final children):
        for (final child in children) {
          if (exceeded) return;
          visit(child);
        }
      case EpubUnorderedList(:final items):
      case EpubOrderedList(:final items):
        for (var index = 0; index < items.length; index += 1) {
          if (exceeded) return;
          count();
        }
      case EpubTable(:final rowGroups):
        for (final group in rowGroups) {
          if (exceeded) return;
          count();
          for (final row in group.rows) {
            if (exceeded) return;
            count();
            for (final cell in row.cells) {
              if (exceeded) return;
              count();
              for (final child in cell.children) {
                if (exceeded) return;
                visit(child);
              }
            }
          }
        }
      case EpubHeading():
      case EpubParagraph():
      case EpubMathNode():
      case EpubCodeBlock():
      case EpubHorizontalRule():
      case EpubImage():
        break;
    }
  }

  visit(root);
  return (nodes: nodes, scalars: scalars);
}

List<String> chapterImageSources(EpubChapter chapter) {
  final sources = <String>[];
  final seen = <String>{};
  void visit(EpubContentNode node) {
    switch (node) {
      case EpubImage(:final src):
        if (seen.add(src)) sources.add(src);
      case EpubBlockQuote(:final children):
      case EpubFigure(:final children):
        for (final child in children) {
          visit(child);
        }
      case EpubTable(:final rowGroups):
        for (final group in rowGroups) {
          for (final row in group.rows) {
            for (final cell in row.cells) {
              for (final child in cell.children) {
                visit(child);
              }
            }
          }
        }
      case EpubHeading():
      case EpubParagraph():
      case EpubMathNode():
      case EpubUnorderedList():
      case EpubOrderedList():
      case EpubCodeBlock():
      case EpubHorizontalRule():
        break;
    }
  }

  for (final node in chapter.blocks) {
    visit(node);
  }
  return sources;
}

/// The bundled document faces' coverage, or null when it cannot be read.
///
/// The composition root loads and parses the reader's bundled faces; the reader
/// gate refuses to route a chapter while the coverage is unknown, because it
/// cannot then promise the chapter will be drawable.
typedef EpubFontCoverageLoader = Future<EpubFontCoverage?> Function();

/// One rendered page window of a Dart-engine EPUB chapter.
///
/// The page window is what stays resident: its slices reference the measured
/// [TextPainter]s of the chapter's layout session, and its surface carries the
/// geometry a pointer, the selection state machine and the highlight painter
/// address.
class ReaderEpubPage {
  ReaderEpubPage({
    required this.unit,
    required this.pageIndex,
    required this.pageCount,
    required this.layoutComplete,
    required this.canGoBackward,
    required this.canGoForward,
    required this.canonicalStart,
    required this.canonicalEnd,
    required this.laidOutNodes,
    required this.totalNodes,
    required this.overflowPages,
    required this.page,
    required this.box,
    required this.surface,
    required this.palette,
  });

  /// Spine ordinal of the chapter this page belongs to.
  final int unit;

  /// 0-based page ordinal inside the laid-out window.
  final int pageIndex;

  /// Pages in the laid-out window (partial while the window is still filling).
  final int pageCount;

  /// Whether the window measured every node of the chapter.
  final bool layoutComplete;

  /// Whether a previous page (or chapter) can be reached.
  final bool canGoBackward;

  /// Whether a following page (or chapter) can be reached.
  final bool canGoForward;

  /// Canonical scalar range this page covers.
  final int canonicalStart;
  final int canonicalEnd;

  /// Measured nodes of the chapter, and the chapter's node count.
  final int laidOutNodes;
  final int totalNodes;

  /// Pages in the window containing a block that could not fit and is painted
  /// clipped. Reported rather than hidden.
  final int overflowPages;

  /// The page's slices, in page coordinates.
  final FlowPage page;

  /// The page box and its content origin.
  final EpubPageBox box;

  /// Hit testing and selection geometry of this page.
  final FlutterSelectionSurface surface;

  /// The palette this page was laid out with.
  final ReaderEpubPalette palette;

  /// Canonical scalar the page starts at; the durable position of a page turn.
  int get readingOffset => canonicalStart;
}

/// The page box of a page window of [windowSize].
EpubPageBox epubPageBoxFor(Size windowSize) => EpubPageBox(
  size: windowSize,
  origin: const Offset(kEpubPageMargin, kEpubPageMargin),
  contentWidth: math.max(40.0, windowSize.width - 2 * kEpubPageMargin),
  contentHeight: math.max(40.0, windowSize.height - 2 * kEpubPageMargin),
);

/// Extracts the page window that contains [scalar].
///
/// [windowSize] is the page window's own size (the reader's content box), and
/// the content is laid out inset by [kEpubPageMargin] on every side. The
/// surface's coordinate space is the whole window, so the retained fit
/// transform is the identity for an un-resized page.
ReaderEpubPage pageWindowFor({
  required ChapterLayoutSession session,
  required int scalar,
  required int unit,
  required int chapterCount,
  required Size windowSize,
}) {
  final box = epubPageBoxFor(windowSize);
  final flow = session.snapshot();
  final paginated = paginateFlow(
    flow: flow,
    pageHeight: box.contentHeight,
    pageWidth: box.contentWidth,
  );
  final index = paginated
      .pageOfCanonical(scalar)
      .clamp(0, paginated.pages.length - 1);
  final page = paginated.pages[index];
  final surface = buildPageSelectionSurface(
    page: page,
    canonicalText: session.chapter.canonicalText,
    resourcePath: session.chapter.resource,
    box: box,
  );
  return ReaderEpubPage(
    unit: unit,
    pageIndex: index,
    pageCount: paginated.pages.length,
    layoutComplete: flow.layoutComplete,
    canGoBackward: index > 0 || flow.firstNodeIndex > 0 || unit > 0,
    canGoForward:
        index + 1 < paginated.pages.length ||
        !flow.layoutComplete ||
        unit + 1 < chapterCount,
    canonicalStart: page.canonicalStart,
    canonicalEnd: page.canonicalEnd,
    laidOutNodes: session.laidOutNodes,
    totalNodes: session.totalNodes,
    overflowPages: paginated.overflowPages,
    page: page,
    box: box,
    surface: surface,
    palette: session.spec.typography.palette,
  );
}

/// Parses [bytes] into an [EpubBook] on a background isolate.
///
/// The archive bytes are moved to the isolate with [TransferableTypedData], so
/// a large book is not copied, and the UI isolate stays responsive while the
/// book is parsed and normalized.
Future<EpubBook> parseEpubBytes(Uint8List bytes) {
  final transferable = TransferableTypedData.fromList([bytes]);
  return Isolate.run(
    () => openEpubBytes(transferable.materialize().asUint8List()),
  );
}
