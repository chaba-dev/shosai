import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_flutter/main.dart';
import 'package:shosai_flutter/src/rust/api.dart';

/// Test support for rendering and inspecting the production shell.
///
/// The harness renders [ShosaiShell], the composition `main.dart` uses, and
/// substitutes only the Rust bridge beneath it. It provides deterministic
/// fonts, library data and reader rasters, geometry-based render detectors and
/// artifact capture so that renders can be inspected and reproduced.
///
/// The detectors deliberately do not rely on Flutter's own overflow reporting:
/// [findRenderDefects] measures the laid-out tree, so text that is silently
/// clipped without a `RenderFlex` exception is still reported.

/// Key of the capture boundary that wraps every harness render.
const harnessBoundaryKey = ValueKey<String>('shosai-render-harness-boundary');

/// Environment variable that selects where render artifacts are written.
const harnessArtifactDirVariable = 'SHOSAI_HARNESS_ARTIFACTS';

/// Environment variable that records the revision under test in artifacts.
const harnessRevisionVariable = 'SHOSAI_HARNESS_REVISION';

// ---------------------------------------------------------------------------
// Deterministic fonts
// ---------------------------------------------------------------------------

/// Loads the bundled interface and icon fonts into the test engine.
///
/// Renders then depend on the repository's own font binaries instead of
/// whichever fonts the host provides.
Future<void> loadHarnessFonts() async {
  final loaders = <FontLoader>[
    FontLoader('Inter')
      ..addFont(rootBundle.load('../assets/fonts/InterVariable.ttf')),
    FontLoader('Noto Sans JP')
      ..addFont(rootBundle.load('../assets/fonts/NotoSansJP-Variable.ttf')),
    FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')),
    FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
      rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
    ),
  ];
  for (final loader in loaders) {
    await loader.load();
  }
}

// ---------------------------------------------------------------------------
// Deterministic viewports
// ---------------------------------------------------------------------------

/// A deterministic viewport for harness renders.
class HarnessView {
  const HarnessView({
    required this.size,
    this.devicePixelRatio = 1,
    this.textScale = 1,
  });

  /// Physical size in pixels; with the default ratio this is the logical size.
  final Size size;
  final double devicePixelRatio;

  /// Platform text scale, equivalent to a 200% accessibility setting at `2`.
  final double textScale;

  /// Applies the viewport to [tester] and restores it when the test ends.
  void apply(WidgetTester tester) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// Metadata recorded next to captured artifacts.
  Map<String, Object?> toMetadata() => <String, Object?>{
    'width': size.width,
    'height': size.height,
    'devicePixelRatio': devicePixelRatio,
    'textScale': textScale,
  };
}

// ---------------------------------------------------------------------------
// Production composition
// ---------------------------------------------------------------------------

/// The production shell around [home], inside a capture boundary.
///
/// [ShosaiShell] is the same widget `ShosaiApp` builds, so a render here shows
/// the production `ShadApp.custom` + `MaterialApp` + `ShadAppBuilder` stack.
Widget productionShell({required Widget home}) => RepaintBoundary(
  key: harnessBoundaryKey,
  child: ShosaiShell(home: home),
);

/// The complete production application for a library bridge, including the
/// production reader builder.
Widget productionApp({required FlutterBridge Function() bridgeFactory}) =>
    RepaintBoundary(
      key: harnessBoundaryKey,
      child: ShosaiApp(productBridgeFactory: bridgeFactory),
    );

// ---------------------------------------------------------------------------
// Deterministic fixtures
// ---------------------------------------------------------------------------

/// The library used by harness renders.
///
/// The data is asymmetric on purpose: English, Japanese and mixed-script
/// metadata, long unbreakable tokens, missing covers and mixed formats all
/// appear so that compact, multilingual and large-text renders exercise the
/// historical failure shapes rather than a uniform grid.
List<FlutterLibraryBook> harnessLibraryBooks() => const [
  FlutterLibraryBook(
    bookId: 1,
    title: 'The Quiet Cartographer',
    author: 'Ada Lovelace',
    format: FlutterBookFormat.epub,
    pathKey: '/books/quiet-cartographer.epub',
    managed: true,
    progress: 0.42,
    dateAdded: '2026-09-10',
    lastRead: '2026-09-19T08:12:00Z',
  ),
  FlutterLibraryBook(
    bookId: 2,
    title: '海辺の図書館 — 失われた書架をめぐる長い旅路',
    author: '紫式部',
    format: FlutterBookFormat.epub,
    pathKey: '/books/umibe.epub',
    managed: true,
    progress: 0.07,
    dateAdded: '2026-09-11',
    lastRead: '2026-09-18T21:40:00Z',
  ),
  FlutterLibraryBook(
    bookId: 3,
    title: 'Donaudampfschifffahrtsgesellschaftskapitaenskajuettenfenster',
    author: 'Übersetzungswerkstatt für mehrsprachige Ausgaben',
    format: FlutterBookFormat.pdf,
    pathKey: '/books/donau.pdf',
    managed: false,
    progress: 0.99,
    dateAdded: '2026-09-12',
  ),
  FlutterLibraryBook(
    bookId: 4,
    title: 'Mixed Script Atlas: 東京・Wien・São Paulo',
    author: 'Léa Dubois and 田中 陽子',
    format: FlutterBookFormat.cbz,
    pathKey: '/books/atlas.cbz',
    managed: true,
    progress: 0.31,
    dateAdded: '2026-09-13',
  ),
  FlutterLibraryBook(
    bookId: 5,
    title: 'A Book With No Cover At All',
    author: 'Anonymous',
    format: FlutterBookFormat.pdf,
    pathKey: '/books/no-cover.pdf',
    managed: true,
    progress: 0.0,
    dateAdded: '2026-09-14',
  ),
  FlutterLibraryBook(
    bookId: 6,
    title: '短い',
    author: '芥川龍之介',
    format: FlutterBookFormat.epub,
    pathKey: '/books/mijikai.epub',
    managed: true,
    progress: 0.5,
    dateAdded: '2026-09-15',
  ),
];

/// Covers for the first [count] books, generated deterministically.
Map<int, Uint8List> harnessCovers({int count = 6}) => {
  for (var index = 1; index <= count; index += 1)
    index: deterministicPng(width: 24, height: 32, seed: index),
};

/// A deterministic 8-bit RGB PNG, encoded in-process.
///
/// Covers must not depend on the engine's image encoder or on any host file,
/// so this writes the PNG container directly.
Uint8List deterministicPng({
  required int width,
  required int height,
  required int seed,
}) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y += 1) {
    raw.addByte(0); // Filter type: none.
    for (var x = 0; x < width; x += 1) {
      raw
        ..addByte((seed * 37 + x * 7) % 256)
        ..addByte((seed * 53 + y * 11) % 256)
        ..addByte((seed * 71 + x * y) % 256);
    }
  }
  final compressed = Uint8List.fromList(
    ZLibCodec(level: 6).encode(raw.takeBytes()),
  );

  final output = BytesBuilder(copy: false);
  output.add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final header = BytesBuilder(copy: false)
    ..add(_uint32(width))
    ..add(_uint32(height))
    ..add(const [8, 2, 0, 0, 0]); // 8-bit RGB, no interlace.
  output.add(_chunk('IHDR', header.takeBytes()));
  output.add(_chunk('IDAT', compressed));
  output.add(_chunk('IEND', Uint8List(0)));
  return output.takeBytes();
}

/// A deterministic premultiplied RGBA page raster for [page].
///
/// Alpha is opaque, so the bytes are valid premultiplied input for the reader's
/// decoder without depending on a renderer.
Uint8List deterministicPageRgba({
  required int width,
  required int height,
  required int page,
}) {
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final index = (y * width + x) * 4;
      final checker = ((x ~/ 24) + (y ~/ 24)) % 2 == 0;
      final margin = x < 12 || y < 12 || x >= width - 12 || y >= height - 12;
      final band = (y + page * 17) % 64 < 4;
      bytes[index] = margin
          ? 0x1f
          : checker
          ? 0xf4
          : 0xe6;
      bytes[index + 1] = margin
          ? 0x33
          : band
          ? 0x4d
          : 0xe8;
      bytes[index + 2] = margin
          ? 0x55
          : checker
          ? 0xd8
          : 0xef;
      bytes[index + 3] = 0xff;
    }
  }
  return bytes;
}

// ---------------------------------------------------------------------------
// Deterministic bridge
// ---------------------------------------------------------------------------

/// A deterministic product bridge covering the library and reader surfaces.
///
/// Every method returns fixed data derived from the constructor arguments, so
/// repeated renders of the same state produce identical pixels.
class HarnessBridge implements FlutterBridge {
  HarnessBridge({
    List<FlutterLibraryBook>? books,
    Map<int, Uint8List>? covers,
    this.settings = const FlutterReaderSettings(
      continuous: false,
      theme: 'light',
      epubFontSize: 18,
      epubLineSpacing: 1.6,
      pdfZoom: 0,
    ),
    this.pageWidth = 420,
    this.pageHeight = 560,
    this.unitCount = 3,
  }) : books = books ?? const [],
       covers = covers ?? const {};

  final List<FlutterLibraryBook> books;
  final Map<int, Uint8List> covers;
  final FlutterReaderSettings settings;
  final int pageWidth;
  final int pageHeight;
  final int unitCount;

  int pageCalls = 0;
  int surfaceCalls = 0;
  int coverCalls = 0;
  int importCalls = 0;
  int removeCalls = 0;
  int settingsWrites = 0;
  FlutterReaderSettings? savedSettings;
  final List<String> events = <String>[];
  final Map<BigInt, Uint8List> _buffers = <BigInt, Uint8List>{};
  final Map<BigInt, FlutterBookFormat> _documentFormats =
      <BigInt, FlutterBookFormat>{};
  BigInt _nextCancellation = BigInt.one;
  BigInt _nextBuffer = BigInt.one;
  bool _disposed = false;

  @override
  bool get isDisposed => _disposed;

  @override
  Future<FlutterLibraryPage> libraryPage({
    String? query,
    FlutterBookFormat? format,
    required int limit,
    required int offset,
    required BigInt cancellationId,
  }) async {
    final filtered = books
        .where(
          (book) =>
              (query == null ||
                  query.isEmpty ||
                  book.title.contains(query) ||
                  (book.author?.contains(query) ?? false)) &&
              (format == null || book.format == format),
        )
        .toList();
    final end = (offset + limit).clamp(0, filtered.length);
    return FlutterLibraryPage(
      books: filtered.sublist(offset.clamp(0, end), end),
      hasMore: end < filtered.length,
    );
  }

  @override
  Future<Uint8List?> libraryCover({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    coverCalls += 1;
    return covers[bookId];
  }

  @override
  Future<FlutterReaderSettings> loadReaderSettings({
    required BigInt cancellationId,
  }) async => settings;

  @override
  Future<void> saveReaderSettings({
    required FlutterReaderSettings value,
  }) async {
    settingsWrites += 1;
    savedSettings = value;
  }

  @override
  Future<FlutterImportReport> importPaths({
    required List<String> pathKeys,
    required bool managed,
    required BigInt cancellationId,
  }) async {
    importCalls += 1;
    return _emptyImportReport;
  }

  @override
  Future<FlutterImportReport> importDirectory({
    required String pathKey,
    required bool managed,
    required BigInt cancellationId,
  }) async {
    importCalls += 1;
    return _emptyImportReport;
  }

  @override
  Future<FlutterLibraryRemoveOutcome> removeLibraryBook({
    required int bookId,
  }) async {
    removeCalls += 1;
    return const FlutterLibraryRemoveOutcome(
      removed: true,
      managedFileDeletionPending: false,
    );
  }

  @override
  BigInt createCancellation() {
    final value = _nextCancellation;
    _nextCancellation += BigInt.one;
    return value;
  }

  @override
  bool cancel({required BigInt id}) {
    events.add('cancel');
    return true;
  }

  @override
  bool releaseCancellation({required BigInt id}) {
    events.add('release');
    return true;
  }

  @override
  Future<FlutterDocumentSummary> openDocument({
    required FlutterOpenRequest request,
    required BigInt cancellationId,
  }) async => _summaryFor(
    path: request.pathKey,
    format: request.formatHint ?? _formatForPath(request.pathKey),
    bookId: null,
  );

  @override
  Future<FlutterDocumentSummary> openLibraryBook({
    required int bookId,
    required BigInt cancellationId,
  }) async {
    final book = _firstOrNull(books.where((book) => book.bookId == bookId));
    return _summaryFor(
      path: book?.pathKey ?? '/books/$bookId.pdf',
      format: book?.format ?? FlutterBookFormat.pdf,
      bookId: bookId,
    );
  }

  @override
  Future<FlutterReadingState?> loadReadingState({
    required int bookId,
    required BigInt cancellationId,
  }) async => null;

  @override
  Future<List<FlutterBookmark>> listBookmarks({
    required int bookId,
    required BigInt cancellationId,
  }) async => const [];

  @override
  Future<List<FlutterAnnotation>> listAnnotations({
    required FlutterDocumentHandle document,
    required double scale,
    required BigInt cancellationId,
  }) async => const [];

  @override
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  }) async {
    surfaceCalls += 1;
    final format = _documentFormats[document.id] ?? FlutterBookFormat.pdf;
    return FlutterSelectionSurface(
      handle: FlutterSelectionHandle(registry: BigInt.one, id: unit),
      width: width,
      height: pageHeight.toDouble(),
      text: 'Page ${unit + BigInt.one} of the deterministic harness document.',
      copyEligible: true,
      raster: format == FlutterBookFormat.epub
          ? _rasterFor(unit.toInt())
          : null,
      endpoints: const [],
      graphemeBoundaries: Uint32List(0),
      wordBoundaries: Uint32List(0),
      visualLines: const [],
    );
  }

  @override
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  }) async {
    pageCalls += 1;
    return _rasterFor(page.toInt());
  }

  @override
  Uint8List takeBuffer({required FlutterBufferHandle handle}) =>
      _buffers[handle.id] ?? Uint8List(0);

  @override
  bool releaseBuffer({required FlutterBufferHandle handle}) {
    _buffers.remove(handle.id);
    return true;
  }

  @override
  bool releaseDocument({required FlutterDocumentHandle handle}) => true;

  @override
  bool releaseSelection({required FlutterSelectionHandle handle}) => true;

  @override
  Future<void> saveReadingState({
    required int bookId,
    required FlutterReadingState value,
    required BigInt unitCount,
  }) async {}

  @override
  Future<List<FlutterSearchMatch>> searchDocument({
    required FlutterDocumentHandle document,
    required String query,
    required BigInt cancellationId,
  }) async => const [];

  @override
  Future<String> exportBookmarks({required int bookId}) async => '';

  @override
  Future<FlutterBookmark?> toggleBookmark({
    required int bookId,
    required BigInt unit,
    BigInt? offset,
    String? title,
    String? note,
  }) async => null;

  @override
  Future<void> updateBookmark({
    required int id,
    String? title,
    String? note,
  }) async {}

  @override
  Future<void> updateBookmarkNote({required int id, String? note}) async {}

  @override
  Future<void> deleteBookmark({required int id}) async {}

  @override
  Future<FlutterAnnotation> createAnnotation({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required BigInt start,
    required BigInt end,
    required double displayScale,
    required FlutterHighlightColor color,
    String? body,
    required BigInt cancellationId,
  }) async => FlutterAnnotation(
    id: 'harness',
    unit: unit,
    resolution: FlutterAnnotationResolution.exact,
    color: color,
    body: body,
  );

  @override
  Future<bool> updateAnnotation({
    required FlutterDocumentHandle document,
    required String id,
    required FlutterHighlightColor color,
    String? body,
  }) async => true;

  @override
  Future<bool> deleteAnnotation({
    required FlutterDocumentHandle document,
    required String id,
  }) async => true;

  @override
  Future<FlutterAnnotationAssociationSourcePage>
  listAnnotationAssociationSources({
    required FlutterDocumentHandle target,
    String? cursor,
    required BigInt limit,
    required BigInt cancellationId,
  }) async => const FlutterAnnotationAssociationSourcePage(sources: []);

  @override
  Future<FlutterAnnotationAssociationOutcome> associateAnnotationVersion({
    required String sourceVersionId,
    required FlutterDocumentHandle target,
    required BigInt cancellationId,
  }) async => FlutterAnnotationAssociationOutcome.associated;

  @override
  FlutterSelectionSurface roundTripVisibleScene({
    required FlutterSelectionSurface scene,
  }) => scene;

  @override
  void dispose() {
    _disposed = true;
    events.add('dispose');
  }

  FlutterDocumentSummary _summaryFor({
    required String path,
    required FlutterBookFormat format,
    required int? bookId,
  }) {
    final handle = FlutterDocumentHandle(
      registry: BigInt.one,
      id: BigInt.from(bookId ?? 1),
    );
    _documentFormats[handle.id] = format;
    return FlutterDocumentSummary(
      handle: handle,
      bookId: bookId,
      format: format,
      title: path.split('/').last,
      logicalUnitCount: BigInt.from(unitCount),
    );
  }

  FlutterRenderedBuffer _rasterFor(int page) {
    final bytes = deterministicPageRgba(
      width: pageWidth,
      height: pageHeight,
      page: page,
    );
    final handle = FlutterBufferHandle(registry: BigInt.one, id: _nextBuffer);
    _nextBuffer += BigInt.one;
    _buffers[handle.id] = bytes;
    return FlutterRenderedBuffer(
      handle: handle,
      width: pageWidth,
      height: pageHeight,
      byteLen: BigInt.from(bytes.length),
    );
  }
}

final FlutterImportReport _emptyImportReport = FlutterImportReport(
  imported: BigInt.zero,
  failed: BigInt.zero,
  cancelled: false,
  items: const [],
);

T? _firstOrNull<T>(Iterable<T> values) => values.isEmpty ? null : values.first;

FlutterBookFormat _formatForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.epub')) return FlutterBookFormat.epub;
  if (lower.endsWith('.cbz')) return FlutterBookFormat.cbz;
  return FlutterBookFormat.pdf;
}

// ---------------------------------------------------------------------------
// Render detectors
// ---------------------------------------------------------------------------

/// The kind of render defect a detector reports.
enum RenderDefectKind {
  /// Children exceed the bounds of a flex layout.
  layoutOverflow,

  /// Text is laid out larger than its box and is cut off without an ellipsis.
  clippedText,

  /// Text is cut off by an ancestor clip rectangle.
  clippedByAncestor,

  /// Text is ellipsized or limited by `maxLines`.
  truncatedText,
}

/// A single detected render defect.
class RenderDefect {
  const RenderDefect({
    required this.kind,
    required this.source,
    required this.label,
    required this.target,
    required this.detail,
  });

  final RenderDefectKind kind;

  /// `framework` for Flutter's own error report, otherwise the measurement.
  final String source;

  /// Short, stable identity of the offending content.
  final String label;

  /// Detailed creator chain of the offending render object.
  final String target;

  /// Human-readable measurement that produced the report.
  final String detail;

  /// Stable identity used for known-defect comparisons.
  String get id => '${kind.name}|$label';

  @override
  String toString() => '$id ($source): $detail\n      at $target';
}

/// Records framework errors reported while a render is pumped.
///
/// Flutter reports a `RenderFlex` overflow through `FlutterError.onError`, so
/// recording those reports keeps the framework signal available next to the
/// geometry-based detectors. The previous handler still runs, so
/// `tester.takeException` keeps working.
class RenderErrorRecorder {
  RenderErrorRecorder._(this._previous);

  final FlutterExceptionHandler? _previous;
  final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];

  static RenderErrorRecorder install() {
    final recorder = RenderErrorRecorder._(FlutterError.onError);
    FlutterError.onError = (details) {
      recorder.errors.add(details);
      recorder._previous?.call(details);
    };
    return recorder;
  }

  void dispose() {
    FlutterError.onError = _previous;
  }

  /// Errors that describe a layout overflow.
  List<FlutterErrorDetails> get overflowErrors =>
      errors.where((details) => isOverflowReport(details.exception)).toList();

  static bool isOverflowReport(Object? exception) {
    final text = exception?.toString() ?? '';
    return text.contains('overflowed by') ||
        text.contains('overflowed the constraints');
  }

  /// Framework overflow reports as defects, for comparison with the geometry
  /// detector.
  List<RenderDefect> overflowDefects() => overflowErrors
      .map(
        (details) => RenderDefect(
          kind: RenderDefectKind.layoutOverflow,
          source: 'framework',
          label: 'RenderFlex overflow',
          target: _firstLine(details.exception.toString()),
          detail: _firstLine(details.exception.toString()),
        ),
      )
      .toList();
}

/// Reports layout overflows and clipped text in the rendered tree.
///
/// The walk starts at the capture boundary, or at [within] when given, and
/// measures the laid-out render objects: flex children against their parent's
/// bounds, and paragraph text against the box that paints it. A paragraph that
/// is only cut by a scroll viewport is not reported, because scrolling is
/// expected to clip.
///
/// Text is measured from its painted ink, not from its line boxes: a line box
/// can exceed its paragraph box while every glyph still paints inside it, so
/// only a rasterized ink measurement can prove that a glyph is cut. The ink
/// rasterization needs the real event loop and runs in [WidgetTester.runAsync].
Future<List<RenderDefect>> findRenderDefects(
  WidgetTester tester, {
  Finder? within,
  double tolerance = 0.5,
  bool includeTruncation = false,
}) async {
  final finder = within ?? find.byKey(harnessBoundaryKey);
  final roots = finder
      .evaluate()
      .map((element) => element.renderObject)
      .whereType<RenderObject>()
      .toList();
  final defects = <RenderDefect>[];
  final candidates = <_ParagraphCandidate>[];
  for (final root in roots) {
    _inspect(root, const _ClipContext(), tolerance, defects, candidates);
  }
  if (candidates.isNotEmpty) {
    await tester.runAsync(() async {
      for (final candidate in candidates) {
        defects.addAll(await _inspectParagraphInk(candidate, tolerance));
      }
    });
  }
  return includeTruncation
      ? defects
      : defects
            .where((defect) => defect.kind != RenderDefectKind.truncatedText)
            .toList();
}

/// Reports ellipsized or `maxLines`-limited text, which is visible truncation
/// rather than a hidden cut.
Future<List<RenderDefect>> findTruncationDefects(
  WidgetTester tester, {
  Finder? within,
  double tolerance = 0.5,
}) async => (await findRenderDefects(
  tester,
  within: within,
  tolerance: tolerance,
  includeTruncation: true,
)).where((defect) => defect.kind == RenderDefectKind.truncatedText).toList();

/// Reports only the clipping defects, which have no framework counterpart.
Future<List<RenderDefect>> findClippingDefects(
  WidgetTester tester, {
  Finder? within,
  double tolerance = 0.5,
}) async => (await findRenderDefects(
  tester,
  within: within,
  tolerance: tolerance,
)).where((defect) => defect.kind != RenderDefectKind.layoutOverflow).toList();

/// Clips along the path to a paragraph.
///
/// A scroll viewport clips its content by design, and so does any clip above
/// it: scrolling moves content through those clips. Clips below the nearest
/// viewport cut content wherever it is scrolled to, so they are tracked
/// separately and reported when they cut painted ink.
///
/// Rectangles approximate the clip: rounded-corner, path and rotated clips are
/// only bounded, because this walk measures axis-aligned paint geometry.
class _ClipContext {
  const _ClipContext({this.viewport, this.outer, this.inner});

  /// The nearest scroll viewport's own clip rectangle.
  final Rect? viewport;

  /// Clips above the nearest viewport.
  final Rect? outer;

  /// Clips below the nearest viewport.
  final Rect? inner;

  _ClipContext withClip(Rect clip, {required bool isViewport}) {
    if (isViewport) {
      // A nested viewport scrolls its content relative to every clip above it,
      // so clips collected below the previous viewport become outer clips. The
      // effective viewport visibility stays the intersection of every viewport
      // clip on the path, because an outer viewport still bounds what can be
      // seen.
      final innerClip = inner;
      final folded = innerClip == null ? outer : _intersect(outer, innerClip);
      return _ClipContext(viewport: _intersect(viewport, clip), outer: folded);
    }
    if (viewport == null) {
      return _ClipContext(outer: _intersect(outer, clip));
    }
    return _ClipContext(
      viewport: viewport,
      outer: outer,
      inner: _intersect(inner, clip),
    );
  }
}

/// A paragraph that may be clipped, awaiting an ink measurement.
class _ParagraphCandidate {
  const _ParagraphCandidate(this.paragraph, this.clip);

  final RenderParagraph paragraph;
  final _ClipContext clip;
}

void _inspect(
  RenderObject node,
  _ClipContext clip,
  double tolerance,
  List<RenderDefect> defects,
  List<_ParagraphCandidate> candidates,
) {
  switch (node) {
    case RenderParagraph paragraph:
      // A paragraph needs an ink measurement when its line box overflows, and
      // also when any clip on the path could cut it.
      if (_overflowsLineBox(paragraph, tolerance) ||
          clip.inner != null ||
          clip.outer != null) {
        candidates.add(_ParagraphCandidate(paragraph, clip));
      }
    case RenderFlex flex:
      _inspectFlex(flex, tolerance, defects);
  }

  node.visitChildren((child) {
    final childClip = node.describeApproximatePaintClip(child);
    final nextClip = childClip == null
        ? clip
        : clip.withClip(
            _globalRectOfLocal(node, childClip),
            isViewport: node is RenderAbstractViewport,
          );
    _inspect(child, nextClip, tolerance, defects, candidates);
  });
}

bool _overflowsLineBox(RenderParagraph paragraph, double tolerance) =>
    paragraph.textSize.width > paragraph.size.width + tolerance ||
    paragraph.textSize.height > paragraph.size.height + tolerance ||
    paragraph.didExceedMaxLines;

/// Classifies one paragraph from its painted ink.
Future<List<RenderDefect>> _inspectParagraphInk(
  _ParagraphCandidate candidate,
  double tolerance,
) async {
  final paragraph = candidate.paragraph;
  final box = Offset.zero & paragraph.size;
  final label = _label(paragraph);
  final target = _identity(paragraph);
  final defects = <RenderDefect>[];
  // `TextOverflow.fade` attenuates the glyphs at the clipped edge, which is a
  // visible indication like an ellipsis rather than a hidden cut. That is a
  // product decision recorded here so it is not made silently. Flutter enables
  // the fade shader for width overflow, height overflow or a `maxLines` limit,
  // so the debug shader flag is part of the signal.
  final fadeActive =
      paragraph.overflow == TextOverflow.fade &&
      (paragraph.didExceedMaxLines || paragraph.debugHasOverflowShader);
  final visiblyTruncated =
      (paragraph.overflow == TextOverflow.ellipsis &&
          paragraph.didExceedMaxLines) ||
      fadeActive;

  if (_hasInlineWidgets(paragraph.text)) {
    defects.add(
      RenderDefect(
        kind: RenderDefectKind.clippedText,
        source: 'paragraph',
        label: label,
        target: target,
        detail:
            'paragraph contains inline widgets, so its painted ink is not '
            'measurable',
      ),
    );
    return defects;
  }

  final lineBoxExceeds = _overflowsLineBox(paragraph, tolerance);
  if (!lineBoxExceeds && visiblyTruncated) {
    defects.add(_truncatedDefect(paragraph, label, target));
  }
  if (!lineBoxExceeds &&
      candidate.clip.inner == null &&
      candidate.clip.outer == null) {
    return defects;
  }

  // What the paragraph paints under its own limits, and what the content would
  // need without them: a dropped line is content loss even when the remaining
  // ink fits.
  final visible = await _measureInk(paragraph, respectLimits: true);
  final content = await _measureInk(paragraph, respectLimits: false);
  final visibleInk = visible.bounds;
  final visibleExceeds =
      visibleInk != null && !_within(visibleInk, box, tolerance);
  final contentInk = content.bounds;
  final contentExceeds =
      contentInk != null && !_within(contentInk, box, tolerance);
  final measurable = !visible.unmeasured && !content.unmeasured;
  // Flutter clips a paragraph only when its line metrics overflow and the
  // overflow policy is not `visible` (`RenderParagraph._needsClipping`). Glyph
  // overhang can paint outside a box whose line metrics fit, so this exact
  // condition decides both the self-clip report and whether ancestor analysis
  // may treat ink outside the box as unreachable.
  final paragraphClips =
      paragraph.overflow != TextOverflow.visible &&
      (paragraph.textSize.width > paragraph.size.width ||
          paragraph.textSize.height > paragraph.size.height ||
          paragraph.didExceedMaxLines);

  if (!measurable) {
    // An unmeasured raster is reported under every overflow policy, including
    // `TextOverflow.visible`: the harness cannot prove that nothing is cut.
    defects.add(_clippedDefect(paragraph, label, target, visible, content));
  } else if (fadeActive) {
    // The faded edge is the visible indication, so the paragraph itself is not
    // reported as a hidden cut.
    defects.add(_truncatedDefect(paragraph, label, target));
  } else if (visiblyTruncated) {
    defects.add(_truncatedDefect(paragraph, label, target));
    // Truncation does not excuse a cut: the painted line itself can still be
    // clipped, for example vertically.
    if (visibleExceeds) {
      defects.add(_clippedDefect(paragraph, label, target, visible, content));
    }
  } else if (paragraph.didExceedMaxLines &&
      paragraph.overflow != TextOverflow.ellipsis &&
      paragraph.overflow != TextOverflow.fade) {
    // `maxLines` removes laid-out content during layout, independently of
    // whether the remaining ink fits the box, and `clip` and `visible` show no
    // indication of it. That is a hidden cut like any other, and it is reported
    // separately from geometric self-clipping below.
    defects.add(_droppedLinesDefect(paragraph, label, target));
    if (paragraphClips && (visibleExceeds || contentExceeds)) {
      defects.add(_clippedDefect(paragraph, label, target, visible, content));
    }
  } else if (paragraphClips && (visibleExceeds || contentExceeds)) {
    // The paragraph cuts its own ink: Flutter activates its clip and the
    // measured ink confirms that something visible is removed. A fitting line
    // box never reports here, even when glyph overhang paints outside the box;
    // that overhang is judged by the ancestor check instead.
    defects.add(_clippedDefect(paragraph, label, target, visible, content));
  }

  // An ancestor clip is independent of the paragraph's own overflow policy, so
  // it is checked even for truncated text.
  if (visibleInk != null) {
    // A clipping paragraph paints clipped ink; a paragraph that does not clip
    // paints all of its ink, including glyph overhang outside its box, so
    // ancestor analysis must consider the full ink for it.
    final paintedInk = paragraphClips ? visibleInk.intersect(box) : visibleInk;
    // An empty intersection means this paragraph contributes no ink at all
    // here. Transforming an empty rect would normalize its negative extent and
    // invent a phantom rect that an ancestor could appear to cut.
    if (paintedInk.isEmpty) {
      return defects;
    }
    final paintedGlobal = _globalRectOfLocal(paragraph, paintedInk);
    final inner = candidate.clip.inner;
    final outer = candidate.clip.outer;
    final viewport = candidate.clip.viewport;
    // A clip below a viewport moves with the content, so it is compared with
    // the painted ink directly. A clip above a viewport can only remove ink the
    // viewports actually show, so that check uses the visible intersection.
    final shown = viewport == null
        ? paintedGlobal
        : paintedGlobal.intersect(viewport);
    if (inner != null && !_within(paintedGlobal, inner, tolerance)) {
      defects.add(
        _ancestorClipDefect(
          label,
          target,
          paintedGlobal,
          inner,
          'inside the nearest viewport',
        ),
      );
    } else if (outer != null &&
        !shown.isEmpty &&
        !_within(shown, outer, tolerance)) {
      defects.add(
        _ancestorClipDefect(
          label,
          target,
          shown,
          outer,
          viewport == null ? 'in the tree' : 'above the nearest viewport',
        ),
      );
    }
  }
  return defects;
}

RenderDefect _clippedDefect(
  RenderParagraph paragraph,
  String label,
  String target,
  _InkMeasurement visible,
  _InkMeasurement content,
) => RenderDefect(
  kind: RenderDefectKind.clippedText,
  source: 'paragraph',
  label: label,
  target: target,
  detail:
      'ink ${visible.bounds == null ? 'unmeasured' : _rect(visible.bounds!)} '
      '(content ${content.bounds == null ? 'unmeasured' : _rect(content.bounds!)}) '
      'in box ${_size(paragraph.size)} '
      '(line ${_size(paragraph.textSize)}, '
      'overflow: ${paragraph.overflow.name}, '
      'maxLines: ${paragraph.maxLines ?? 'unlimited'})',
);

RenderDefect _droppedLinesDefect(
  RenderParagraph paragraph,
  String label,
  String target,
) => RenderDefect(
  kind: RenderDefectKind.clippedText,
  source: 'paragraph',
  label: label,
  target: target,
  detail:
      'maxLines: ${paragraph.maxLines} dropped laid-out content with no '
      'ellipsis or fade to show it (overflow: ${paragraph.overflow.name}, '
      'line ${_size(paragraph.textSize)} in box ${_size(paragraph.size)})',
);

RenderDefect _ancestorClipDefect(
  String label,
  String target,
  Rect ink,
  Rect clip,
  String description,
) => RenderDefect(
  kind: RenderDefectKind.clippedByAncestor,
  source: 'ancestor-clip',
  label: label,
  target: target,
  detail:
      'painted ink ${_rect(ink)} is cut by a clip $description '
      '${_rect(clip)}',
);

RenderDefect _truncatedDefect(
  RenderParagraph paragraph,
  String label,
  String target,
) => RenderDefect(
  kind: RenderDefectKind.truncatedText,
  source: 'paragraph',
  label: label,
  target: target,
  detail:
      'text truncated in box ${_size(paragraph.size)} '
      '(line ${_size(paragraph.textSize)}, overflow: ${paragraph.overflow.name})',
);

bool _hasInlineWidgets(InlineSpan span) {
  var found = false;
  span.visitChildren((child) {
    if (child is PlaceholderSpan) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Result of measuring a paragraph's painted ink.
///
/// An empty result is not a failed measurement: whitespace-only text paints no
/// ink, which is different from ink that cannot be measured at all.
class _InkMeasurement {
  const _InkMeasurement.measured(this.bounds) : unmeasured = false;
  const _InkMeasurement.unmeasured() : bounds = null, unmeasured = true;

  final Rect? bounds;
  final bool unmeasured;
}

/// Measures the painted ink of a paragraph, in paragraph-local coordinates.
///
/// The measurement re-paints the paragraph's own text with the same layout
/// parameters Flutter used, including `softWrap`, the minimum width and the
/// overflow policy, so it reflects glyphs instead of font metrics. Inline
/// widgets are not painted by a [TextPainter], so they are reported as
/// unmeasured rather than guessed.
Future<_InkMeasurement> _measureInk(
  RenderParagraph paragraph, {
  required bool respectLimits,
}) async {
  final text = paragraph.text;
  if (text.toPlainText().isEmpty) return const _InkMeasurement.measured(null);
  if (_hasInlineWidgets(text)) return const _InkMeasurement.unmeasured();
  final ellipsis = respectLimits && paragraph.overflow == TextOverflow.ellipsis
      ? '…'
      : null;
  final painter = TextPainter(
    text: text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    textHeightBehavior: paragraph.textHeightBehavior,
    textWidthBasis: paragraph.textWidthBasis,
    strutStyle: paragraph.strutStyle,
    locale: paragraph.locale,
    maxLines: respectLimits ? paragraph.maxLines : null,
    ellipsis: ellipsis,
  );
  try {
    // Mirrors `RenderParagraph._adjustMaxWidth`: without wrapping and without
    // an ellipsis the paragraph lays out at its intrinsic width.
    final constraints = paragraph.constraints;
    final maxWidth = paragraph.softWrap || ellipsis != null
        ? constraints.maxWidth
        : double.infinity;
    painter.layout(minWidth: constraints.minWidth, maxWidth: maxWidth);
    final size = painter.size;
    if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) {
      return const _InkMeasurement.measured(null);
    }
    const padding = 4;
    final width = size.width.ceil() + padding * 2;
    final height = size.height.ceil() + padding * 2;
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
      return const _InkMeasurement.unmeasured();
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paint(canvas, Offset(padding.toDouble(), padding.toDouble()));
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) return const _InkMeasurement.unmeasured();
        final bytes = data.buffer.asUint8List();
        return _InkMeasurement.measured(
          _inkBounds(bytes, width, height, padding),
        );
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  } finally {
    painter.dispose();
  }
}

Rect? _inkBounds(Uint8List rgba, int width, int height, int padding) {
  var minX = width;
  var minY = height;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < height; y += 1) {
    for (var x = 0; x < width; x += 1) {
      final alpha = rgba[(y * width + x) * 4 + 3];
      if (alpha <= 8) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < minX || maxY < minY) return null;
  return Rect.fromLTRB(
    (minX - padding).toDouble(),
    (minY - padding).toDouble(),
    (maxX + 1 - padding).toDouble(),
    (maxY + 1 - padding).toDouble(),
  );
}

void _inspectFlex(
  RenderFlex flex,
  double tolerance,
  List<RenderDefect> defects,
) {
  final bounds = Offset.zero & flex.size;
  Rect? childrenBounds;
  flex.visitChildren((child) {
    if (child is! RenderBox || !child.hasSize) return;
    final parentData = child.parentData;
    final offset = parentData is FlexParentData
        ? parentData.offset
        : Offset.zero;
    final rect = offset & child.size;
    childrenBounds = childrenBounds == null
        ? rect
        : childrenBounds!.expandToInclude(rect);
  });
  final union = childrenBounds;
  if (union == null || _within(union, bounds, tolerance)) return;
  defects.add(
    RenderDefect(
      kind: RenderDefectKind.layoutOverflow,
      source: 'geometry',
      label: _label(flex),
      target: _identity(flex),
      detail:
          'children ${_rect(union)} exceed ${_rect(bounds)} '
          '(${flex.direction.name})',
    ),
  );
}

Rect _intersect(Rect? clip, Rect bounds) =>
    clip == null ? bounds : clip.intersect(bounds);

Rect _globalRectOfLocal(RenderObject node, Rect local) =>
    MatrixUtils.transformRect(node.getTransformTo(null), local);

bool _within(Rect inner, Rect outer, double tolerance) =>
    inner.left >= outer.left - tolerance &&
    inner.top >= outer.top - tolerance &&
    inner.right <= outer.right + tolerance &&
    inner.bottom <= outer.bottom + tolerance;

String _identity(RenderObject node) {
  final creator = node.debugCreator?.toString() ?? node.runtimeType.toString();
  final bounded = creator.length > 120 ? creator.substring(0, 120) : creator;
  if (node is RenderParagraph) {
    return '${_label(node)} <- $bounded';
  }
  return '${node.runtimeType} <- $bounded';
}

/// Short, stable identity of a render object's content.
String _label(RenderObject node) {
  if (node is RenderParagraph) {
    final text = node.text.toPlainText().replaceAll('\n', ' ');
    final clipped = text.length > 48 ? '${text.substring(0, 48)}…' : text;
    return 'paragraph("$clipped")';
  }
  if (node is RenderFlex) return 'flex(${node.direction.name})';
  return node.runtimeType.toString();
}

String _rect(Rect rect) =>
    '(${rect.left.toStringAsFixed(1)}, ${rect.top.toStringAsFixed(1)}) '
    '${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)}';

String _size(Size size) =>
    '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}';

String _firstLine(String value) {
  final end = value.indexOf('\n');
  return end == -1 ? value : value.substring(0, end);
}

// ---------------------------------------------------------------------------
// Capture and artifacts
// ---------------------------------------------------------------------------

/// Renders the harness boundary to PNG bytes at the harness pixel ratio.
Future<Uint8List> captureHarnessPng(
  WidgetTester tester, {
  double pixelRatio = 1,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(harnessBoundaryKey),
  );
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      bytes = data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  return bytes;
}

/// Renders the harness boundary to raw RGBA bytes.
///
/// Raw pixels isolate pixel determinism from PNG encoder differences, so a
/// repeat-render check can compare two captures of the same state directly.
Future<Uint8List> captureHarnessRgba(
  WidgetTester tester, {
  double pixelRatio = 1,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(harnessBoundaryKey),
  );
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      bytes = data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  return bytes;
}

/// Advances a bounded number of frames.
///
/// `pumpAndSettle` cannot be used for surfaces that animate continuously (the
/// reader), so harness renders advance a fixed number of frames instead.
Future<void> pumpHarnessFrames(WidgetTester tester, {int frames = 12}) async {
  for (var frame = 0; frame < frames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// True when the tree contains at least one decoded image and no undecoded one.
///
/// The library covers are painted through [RawImage], so this is the readiness
/// signal for a library render. A state that legitimately renders no image
/// needs its own predicate, because an empty tree is not evidence of a finished
/// decode.
bool harnessImagesReady(WidgetTester tester) {
  final images = tester.widgetList<RawImage>(find.byType(RawImage)).toList();
  return images.isNotEmpty && images.every((image) => image.image != null);
}

/// True when a reader page painter has a decoded page raster.
///
/// An open document paints its page through [PagePainter] rather than
/// [RawImage], and shows a progress indicator until the raster arrives.
bool harnessReaderPageReady(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .whereType<PagePainter>()
    .any((painter) => painter.image != null);

/// Thrown when a harness render never became ready.
class HarnessNotReadyException implements Exception {
  const HarnessNotReadyException(this.message);

  final String message;

  @override
  String toString() => 'HarnessNotReadyException: $message';
}

/// Renders [widget] into a settled, deterministic harness frame.
///
/// Engine work (image decoding for covers and page rasters) only completes on
/// the real event loop, so the render alternates real-async windows with frame
/// pumps until [ready] holds, then advances a fixed animation interval before
/// the capture. Exhausting [maxRounds] without readiness throws instead of
/// capturing a partial frame. The image cache is cleared first, so a state
/// renders the same whether it is the first or the tenth render in the process.
Future<void> renderHarnessState(
  WidgetTester tester,
  Widget widget, {
  required bool Function() ready,
  int maxRounds = 8,
}) async {
  imageCache.clear();
  imageCache.clearLiveImages();
  await tester.runAsync(() async {
    await tester.pumpWidget(widget);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });
  var isReady = false;
  for (var round = 0; round < maxRounds; round += 1) {
    await pumpHarnessFrames(tester, frames: 4);
    if (ready()) {
      isReady = true;
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
  }
  if (!isReady) {
    throw HarnessNotReadyException(
      'the render did not become ready after $maxRounds rounds; '
      'the state would have been captured before its content loaded',
    );
  }
  await pumpHarnessFrames(tester, frames: 8);
}

/// Describes where two raw RGBA captures differ, for failure messages.
String describePixelDifference(
  Uint8List expected,
  Uint8List actual, {
  required int width,
}) {
  if (expected.length != actual.length) {
    return 'capture sizes differ: ${expected.length} vs ${actual.length}';
  }
  var count = 0;
  var minX = width;
  var maxX = -1;
  var minY = 1 << 30;
  var maxY = -1;
  for (var offset = 0; offset + 3 < expected.length; offset += 4) {
    if (expected[offset] == actual[offset] &&
        expected[offset + 1] == actual[offset + 1] &&
        expected[offset + 2] == actual[offset + 2] &&
        expected[offset + 3] == actual[offset + 3]) {
      continue;
    }
    count += 1;
    final pixel = offset ~/ 4;
    final x = pixel % width;
    final y = pixel ~/ width;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  if (count == 0) return 'captures are identical';
  return 'differing pixels: $count in x $minX..$maxX, y $minY..$maxY';
}

/// Captures the harness boundary and records it as an inspectable artifact.
///
/// Rendering happens before any detector or golden assertion so a failing state
/// still leaves a screenshot and its metadata behind.
Future<Uint8List> captureHarnessArtifact(
  WidgetTester tester,
  String name, {
  Map<String, Object?> metadata = const {},
}) async {
  final bytes = await captureHarnessPng(tester);
  writeHarnessArtifact(name, bytes, metadata: metadata);
  return bytes;
}

/// Compares the harness boundary against its committed golden.
///
/// Goldens live in `test/goldens/`, next to the product-shell goldens, so the
/// path is relative to the calling test file in `test/visual/`.
Future<void> expectHarnessGolden(WidgetTester tester, String name) async {
  await expectLater(
    find.byKey(harnessBoundaryKey),
    matchesGoldenFile('../goldens/$name.png'),
  );
}

/// The directory render artifacts are written to.
///
/// Defaults to the repository's `target/` directory so artifacts are never
/// committed; set [harnessArtifactDirVariable] to relocate them.
Directory harnessArtifactDirectory() => Directory(
  Platform.environment[harnessArtifactDirVariable] ??
      '../target/flutter-render-harness',
);

/// Writes one captured render plus its metadata, and returns the PNG path.
///
/// Artifact writing is best-effort: a render check must not fail because the
/// artifact directory is unavailable, but the returned path is `null` then.
File? writeHarnessArtifact(
  String name,
  Uint8List bytes, {
  Map<String, Object?> metadata = const {},
}) {
  try {
    final directory = harnessArtifactDirectory()..createSync(recursive: true);
    final png = File('${directory.path}/$name.png')..writeAsBytesSync(bytes);
    File('${directory.path}/$name.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'name': name,
        'revision': Platform.environment[harnessRevisionVariable] ?? 'unknown',
        'bytes': bytes.length,
        ...metadata,
      }),
    );
    return png;
  } catch (error) {
    debugPrint('harness artifact $name was not written: $error');
    return null;
  }
}

// ---------------------------------------------------------------------------
// Known production defects
// ---------------------------------------------------------------------------

/// A reviewed production defect that the harness reports but does not fix.
///
/// An entry is an explicit exception with an owning follow-up package. New
/// defects that are not listed fail the check.
class KnownRenderDefect {
  const KnownRenderDefect({
    required this.id,
    required this.owner,
    required this.note,
  });

  /// [RenderDefect.id] of the accepted defect.
  final String id;

  /// Package expected to resolve it.
  final String owner;
  final String note;
}

/// Asserts that [defects] contain exactly the reviewed [known] defects.
///
/// Every detected defect is reported in the failure message so a new
/// regression is visible with its measurement rather than as a diff.
void expectOnlyKnownDefects(
  List<RenderDefect> defects,
  List<KnownRenderDefect> known,
) {
  final knownIds = known.map((defect) => defect.id).toSet();
  final unexpected = defects
      .where((defect) => !knownIds.contains(defect.id))
      .toList();
  final observed = defects.map((defect) => defect.id).toSet();
  final missing = knownIds.where((id) => !observed.contains(id)).toList();
  if (unexpected.isEmpty && missing.isEmpty) return;

  final buffer = StringBuffer('render defects changed');
  if (unexpected.isNotEmpty) {
    buffer.writeln('\nnew or unlisted defects:');
    for (final defect in unexpected) {
      buffer.writeln('  - $defect');
    }
  }
  if (missing.isNotEmpty) {
    buffer.writeln('\nreviewed defects that are no longer detected:');
    for (final id in missing) {
      final entry = known.firstWhere((defect) => defect.id == id);
      buffer.writeln('  - $id (owner: ${entry.owner})');
    }
  }
  buffer.writeln('\nall detected defects:');
  for (final defect in defects) {
    buffer.writeln('  - $defect');
  }
  fail(buffer.toString());
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

Uint8List _chunk(String type, Uint8List data) {
  final payload = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(type.codeUnits))
    ..add(data);
  final bytes = payload.takeBytes();
  return Uint8List.fromList([
    ..._uint32(data.length),
    ...bytes,
    ..._uint32(_crc32(bytes)),
  ]);
}

final List<int> _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit += 1) {
    value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
