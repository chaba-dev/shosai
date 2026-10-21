/// Dart-engine EPUB content: the parsed book for one document generation, the
/// windowed chapter layout session and page-window extraction.
///
/// This module only decides what a chapter *looks like*; the application core
/// keeps the records, and its anchors and search index the same canonical
/// stream the pages are laid out from.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:shosai_flutter/core/bridge.dart';

import 'flow.dart';
import 'pages.dart';
import 'surface.dart';
import 'text_style.dart';

/// How a rendered link's href is handled.
enum EpubLinkKind {
  /// A same-book reference: resolved against the document's parsed source and
  /// navigated through the guarded layout path.
  internal,

  /// An allowed external scheme (`http`, `https`, `mailto`): handed to the
  /// injected platform opener, never fetched by the reader.
  external,

  /// Anything else (`file`, `data`, `javascript`, an unknown scheme): refused.
  /// The reader never launches it and never fetches it.
  unsupported,
}

/// Classifies [href] with the retained reader's link policy.
///
/// A reference without a scheme is internal; the allowed external schemes are
/// exactly `http`, `https` and `mailto` (case-insensitive); everything else is
/// unsupported. The scheme detection mirrors the retained `link_scheme`: a
/// colon only starts a scheme when the text before it contains no `/`, `?` or
/// `#`, so `Text/foo:bar.xhtml` stays an internal path.
EpubLinkKind classifyEpubLink(String href) {
  final colon = href.indexOf(':');
  if (colon < 0) return EpubLinkKind.internal;
  final prefix = href.substring(0, colon);
  if (prefix.isEmpty ||
      prefix.contains('/') ||
      prefix.contains('?') ||
      prefix.contains('#')) {
    return EpubLinkKind.internal;
  }
  // Text before the colon that is not a valid scheme is a path character to
  // the retained classifier (`Text/foo:bar.xhtml` and `1abc:foo` both stay
  // internal); reference resolution then refuses the colon, so neither is
  // ever launched or fetched.
  if (!_isScheme(prefix)) return EpubLinkKind.internal;
  return switch (prefix.toLowerCase()) {
    'http' || 'https' || 'mailto' => EpubLinkKind.external,
    _ => EpubLinkKind.unsupported,
  };
}

/// The retained `link_scheme` syntax: a leading ASCII letter followed by
/// letters, digits, `+`, `-` or `.`.
bool _isScheme(String prefix) {
  if (prefix.isEmpty) return false;
  if (!_isSchemeCharacter(prefix.codeUnitAt(0), first: true)) return false;
  for (var index = 1; index < prefix.length; index += 1) {
    if (!_isSchemeCharacter(prefix.codeUnitAt(index), first: false)) {
      return false;
    }
  }
  return true;
}

bool _isSchemeCharacter(int unit, {required bool first}) {
  final isAsciiAlpha =
      (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
  if (isAsciiAlpha) return true;
  if (first) return false;
  final isAsciiDigit = unit >= 0x30 && unit <= 0x39;
  return isAsciiDigit || unit == 0x2B || unit == 0x2D || unit == 0x2E;
}

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
    this.imageDecodeTimeout = kEpubImageDecodeTimeout,
    this.rasterBudgetBytes = kEpubDecodedImageBudget,
  });

  final EpubBook book;

  /// `@font-face` family name → registered Flutter family name.
  final Map<String, String> embeddedFamilies;

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

/// One rendered page window of a Dart-engine EPUB chapter.
///
/// The page window is what stays resident: its slices reference the measured
/// [TextPainter]s of the chapter's layout session, and its surface carries the
/// geometry a pointer, the selection state machine and the highlight painter
/// address.
class ReaderEpubPage {
  ReaderEpubPage({
    required this.unit,
    required this.targetScalar,
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

  /// Canonical scalar the window was requested for. A continuous page holds
  /// the whole chapter, so this is the location the view scrolls to.
  final int targetScalar;

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

/// Paginates [flow] for a page window of [windowSize]; a [continuous] chapter
/// is one page of unbounded height.
PaginatedChapter paginateWindow(
  ChapterFlow flow,
  Size windowSize, {
  required bool continuous,
}) {
  final box = epubPageBoxFor(windowSize);
  return paginateFlow(
    flow: flow,
    pageHeight: continuous ? double.infinity : box.contentHeight,
    pageWidth: box.contentWidth,
  );
}

/// Extracts the page window that contains [scalar].
///
/// [windowSize] is the page window's own size (the reader's content box), and
/// the content is laid out inset by [kEpubPageMargin] on every side. The
/// surface's coordinate space is the whole window, so the retained fit
/// transform is the identity for an un-resized page.
///
/// A [continuous] window is the whole laid-out chapter as one page: its box
/// keeps the window's width and grows to the chapter's height (never shorter
/// than the window), and the view scrolls it.
ReaderEpubPage pageWindowFor({
  required ChapterLayoutSession session,
  required int scalar,
  required int unit,
  required int chapterCount,
  required Size windowSize,
  bool continuous = false,
}) {
  final flow = session.snapshot();
  final paginated = paginateWindow(flow, windowSize, continuous: continuous);
  final index = paginated
      .pageOfCanonical(scalar)
      .clamp(0, paginated.pages.length - 1);
  final page = paginated.pages[index];
  final box = epubPageBoxFor(
    continuous
        ? Size(
            windowSize.width,
            math.max(windowSize.height, page.height + 2 * kEpubPageMargin),
          )
        : windowSize,
  );
  final surface = buildPageSelectionSurface(
    page: page,
    canonicalText: session.chapter.canonicalText,
    resourcePath: session.chapter.resource,
    box: box,
  );
  return ReaderEpubPage(
    unit: unit,
    targetScalar: scalar,
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
