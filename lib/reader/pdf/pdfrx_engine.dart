/// The PDFium-backed [PdfEngine], built on pdfrx.
///
/// pdfrx owns the PDFium library, the document and form lifecycle, rendering,
/// outlines, links and permissions, and serialises every PDFium call on its
/// background worker isolate. Selection geometry needs PDFium text calls that
/// pdfrx's object model does not expose (loose character boxes, text matrices,
/// generated-character flags, page-to-device mapping), so those run as raw
/// `pdfium_dart` calls submitted to the same worker through
/// [PdfrxEntryFunctions.compute]: PDFium is not thread-safe, and one worker
/// keeps every call on one thread.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:shosai_flutter/core/bridge.dart';

import 'engine.dart';
import 'page_geometry.dart';
import 'search.dart';
import 'selection.dart';

/// PDFium renders text with LCD subpixel smoothing, as the retained core did.
const int _lcdText = pdfrx.PdfPageRenderFlags.lcdText;

/// PDFium writes RGBA instead of its native BGRA byte order.
const int _reverseByteOrder = 0x10;

/// The production [PdfEngine].
final class PdfrxPdfEngine implements RangedPdfEngine {
  PdfrxPdfEngine();

  static Future<void>? _initialized;

  /// Initialises pdfrx once per process.
  ///
  /// An application bundle carries PDFium as pdfrx's native asset. `flutter
  /// test` does not link native assets, so a test run names the library to
  /// load through `PDFIUM_PATH` (pdfrx's own variable) or
  /// `SHOSAI_PDFIUM_LIBRARY` (the repository's Nix shell).
  static Future<void> ensureInitialized() => _initialized ??= _initialize();

  static Future<void> _initialize() async {
    for (final variable in const ['PDFIUM_PATH', 'SHOSAI_PDFIUM_LIBRARY']) {
      final override = Platform.environment[variable];
      if (override != null && override.isNotEmpty) {
        pdfrx.Pdfrx.pdfiumModulePath ??= override;
        break;
      }
    }
    // pdfrx asks path_provider for a cache directory it uses only for
    // documents fetched over HTTP, which the reader never opens; the system
    // temporary directory keeps initialisation free of a plugin channel.
    pdfrx.Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path;
    await pdfrx.pdfrxFlutterInitialize();
  }

  @override
  Future<PdfEngineDocument> open(String path) async {
    await ensureInitialized();
    final filePath = pdfPathFromKey(path);
    final file = File(filePath);
    final int length;
    try {
      length = await file.length();
    } on FileSystemException catch (error) {
      throw PdfEngineException(
        'Cannot open PDF: ${error.osError?.message ?? error.message}',
      );
    }
    if (length > pdfMaxInputBytes) {
      throw const PdfEngineLimitException(
        'PDF exceeds the $pdfMaxInputBytes-byte input limit',
      );
    }
    return _adopt(() => pdfrx.PdfDocument.openFile(filePath), filePath);
  }

  @override
  Future<PdfEngineDocument> openRanged(
    int size,
    Future<int> Function(Uint8List buffer, int position, int length) read, {
    required String sourceName,
  }) async {
    await ensureInitialized();
    if (size > pdfMaxInputBytes) {
      throw const PdfEngineLimitException(
        'PDF exceeds the $pdfMaxInputBytes-byte input limit',
      );
    }
    return _adopt(
      () => pdfrx.PdfDocument.openCustom(
        read: read,
        fileSize: size,
        sourceName: sourceName,
        // Only the first page is loaded: loading every page would read every
        // page object of the file.
        useProgressiveLoading: true,
        // A small document is read whole, in one range, and opened from
        // memory; a larger one is read block by block as PDFium asks.
        maxSizeToCacheOnMemory: 256 * 1024,
      ),
      sourceName,
    );
  }

  Future<PdfEngineDocument> _adopt(
    Future<pdfrx.PdfDocument> Function() opening,
    String name,
  ) async {
    final pdfrx.PdfDocument document;
    try {
      document = await opening();
    } on pdfrx.PdfPasswordException {
      throw PdfEnginePasswordException(name);
    } on pdfrx.PdfException catch (error) {
      throw PdfEngineException('Cannot open PDF: ${error.message}');
    }
    if (document.pages.isEmpty) {
      await document.dispose();
      throw const PdfEngineException('PDF has no pages');
    }
    final opened = _PdfrxDocument(document);
    try {
      opened._rightToLeft = await pdfrx.PdfrxEntryFunctions.instance.compute(
        _rightToLeftOnWorker,
        opened._handle.address,
      );
    } catch (_) {
      // Unreadable viewer preferences leave the document left to right.
    }
    return opened;
  }
}

final class _PdfrxDocument implements PdfEngineDocument {
  _PdfrxDocument(this._document);

  final pdfrx.PdfDocument _document;
  bool _disposed = false;
  bool _rightToLeft = false;

  @override
  int get pageCount => _document.pages.length;

  @override
  bool get isEncrypted => _document.isEncrypted;

  @override
  bool get allowsCopying => _document.permissions?.allowsCopying ?? true;

  @override
  bool get rightToLeft => _rightToLeft;

  pdfrx.PdfPage _page(int page) {
    if (_disposed) throw const PdfEngineException('PDF document is closed');
    if (page < 0 || page >= pageCount) {
      throw PdfEngineException(
        'page index $page out of range (total: $pageCount)',
      );
    }
    return _document.pages[page];
  }

  @override
  PdfPageSize pageSize(int page) {
    final loaded = _page(page);
    return PdfPageSize(loaded.width, loaded.height);
  }

  @override
  PdfBitmapSize bitmapSize(int page, double scale) =>
      pdfBitmapSizeFor(pageSize(page), scale);

  @override
  Future<PdfRenderedPage> render(
    int page,
    double scale, {
    PdfRect? clip,
  }) async {
    final loaded = _page(page);
    // Validate the allocation, not the virtual full page: a high-zoom screen
    // crop must not allocate (or reject) an enormous offscreen page bitmap.
    final requested = pdfBitmapSizeFor(pageSize(page), scale, clip: clip);
    final fullWidth = (loaded.width * scale).ceil();
    final fullHeight = (loaded.height * scale).ceil();
    final sx = fullWidth / loaded.width;
    final sy = fullHeight / loaded.height;
    final x = clip == null ? 0 : (clip.left * sx).floor();
    final y = clip == null ? 0 : (clip.top * sy).floor();
    final width = requested.width;
    final height = requested.height;
    final image = await loaded.render(
      x: x,
      y: y,
      width: width,
      height: height,
      fullWidth: fullWidth.toDouble(),
      fullHeight: fullHeight.toDouble(),
      flags: _lcdText | _reverseByteOrder,
    );
    if (image == null) {
      throw PdfEngineException('failed to render page $page');
    }
    try {
      return PdfRenderedPage(
        width: image.width,
        height: image.height,
        pixels: Uint8List.fromList(image.pixels),
        source: clip == null
            ? null
            : PdfRect(x / sx, y / sy, (x + width) / sx, (y + height) / sy),
      );
    } finally {
      image.dispose();
    }
  }

  @override
  Future<FlutterSelectionSurface> selectionSurface(
    int page,
    double scale,
  ) async {
    _page(page);
    final size = bitmapSize(page, scale);
    final samples = await _sample(page, size, geometry: true);
    return buildPdfPageSelection(
      bitmapWidth: size.width,
      bitmapHeight: size.height,
      samples: samples,
    ).surface;
  }

  @override
  Future<String> pageText(int page) async {
    _page(page);
    final samples = await _sample(
      page,
      const PdfBitmapSize(1, 1),
      geometry: false,
    );
    return pdfPageText(samples).text;
  }

  @override
  Future<PdfPageGeometry> pageGeometry(int page) async {
    final size = pageSize(page);
    // Sampling only: no bitmap is allocated. Preserve millipoint geometry
    // despite PDFium's integer page-to-device API.
    final width = (size.width * 1000).round();
    final height = (size.height * 1000).round();
    final samples = await _sample(
      page,
      PdfBitmapSize(width, height),
      geometry: true,
      inkGeometry: true,
    );
    final objects = await pdfrx.PdfrxEntryFunctions.instance.compute(
      _pageObjectsOnWorker,
      (document: _handle.address, page: page, width: width, height: height),
    );
    return PdfPageGeometry(
      width: size.width,
      height: size.height,
      lines: buildPdfTextLines(
        samples,
        scale: 1000,
        width: size.width,
        height: size.height,
      ),
      images: objects.images,
      graphics: objects.graphics,
      hasUnboundedGraphics: objects.unbounded,
    );
  }

  @override
  Future<List<FlutterSearchMatch>> search(String query) async {
    final search = PdfSearch(query);
    if (search.isEmpty) return const [];
    for (var page = 0; page < pageCount; page++) {
      search.addPage(page, await pageText(page));
    }
    return search.results;
  }

  @override
  Future<PdfDocumentInfo> info() async {
    if (_disposed) throw const PdfEngineException('PDF document is closed');
    final info = await pdfrx.PdfrxEntryFunctions.instance.compute(
      _infoOnWorker,
      _handle.address,
    );
    return info;
  }

  @override
  Future<List<PdfOutlineEntry>> outline() async {
    if (_disposed) throw const PdfEngineException('PDF document is closed');
    final nodes = await _document.loadOutline();
    final entries = <PdfOutlineEntry>[];
    void visit(List<pdfrx.PdfOutlineNode> nodes, int depth) {
      for (final node in nodes) {
        final target = node.dest?.pageNumber;
        entries.add(
          PdfOutlineEntry(
            depth: depth,
            title: node.title,
            page: target == null || target < 1 || target > pageCount
                ? null
                : target - 1,
          ),
        );
        visit(node.children, depth + 1);
      }
    }

    visit(nodes, 0);
    return entries;
  }

  @override
  Future<List<PdfPageLink>> links(int page) async {
    final loaded = _page(page);
    final links = await loaded.loadLinks(enableAutoLinkDetection: false);
    return [
      for (final link in links)
        PdfPageLink(
          rects: [
            for (final rect in link.rects.map(
              (rect) => rect.rotate(loaded.rotation.index, loaded),
            ))
              PdfLinkRect(rect.left, rect.bottom, rect.right, rect.top),
          ],
          url: link.url,
          page: switch (link.dest?.pageNumber) {
            final target? when target >= 1 && target <= pageCount => target - 1,
            _ => null,
          },
          destination: await _linkDestination(link.dest),
        ),
    ];
  }

  Future<({double x, double y})?> _linkDestination(pdfrx.PdfDest? dest) async {
    if (dest == null || dest.pageNumber < 1 || dest.pageNumber > pageCount) {
      return null;
    }
    final params = dest.params;
    double? at(int index) =>
        params != null && index < params.length ? params[index] : null;
    final (x, y) = switch (dest.command) {
      pdfrx.PdfDestCommand.xyz => (at(0), at(1)),
      pdfrx.PdfDestCommand.fitH || pdfrx.PdfDestCommand.fitBH => (null, at(0)),
      pdfrx.PdfDestCommand.fitV || pdfrx.PdfDestCommand.fitBV => (at(0), null),
      pdfrx.PdfDestCommand.fitR => (at(0), at(3)),
      _ => (null, null),
    };
    if (x == null && y == null) return null;
    final size = pageSize(dest.pageNumber - 1);
    return pdfrx.PdfrxEntryFunctions.instance.compute(_destinationOnWorker, (
      document: _handle.address,
      page: dest.pageNumber - 1,
      width: (size.width * 1000).ceil(),
      height: (size.height * 1000).ceil(),
      x: x,
      y: y,
    ));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _document.dispose();
  }

  // pdfrx keeps the FPDF_DOCUMENT handle on its (private) document class as
  // a public `document` field; the raw calls below need it. This is the one
  // place the engine reaches past pdfrx's object model, and the engine tests
  // fail loudly if a pdfrx upgrade moves it.
  Pointer<NativeType> get _handle =>
      (_document as dynamic).document as Pointer<NativeType>;

  /// Samples every character of [page] on pdfrx's PDFium worker.
  Future<List<PdfCharacterSample>> _sample(
    int page,
    PdfBitmapSize size, {
    required bool geometry,
    bool inkGeometry = false,
  }) {
    final handle = _handle;
    return pdfrx.PdfrxEntryFunctions.instance.compute(
      _sampleOnWorker,
      _SampleRequest(
        document: handle.address,
        page: page,
        bitmapWidth: size.width,
        bitmapHeight: size.height,
        geometry: geometry,
        inkGeometry: inkGeometry,
      ),
    );
  }
}

final class _SampleRequest {
  const _SampleRequest({
    required this.document,
    required this.page,
    required this.bitmapWidth,
    required this.bitmapHeight,
    required this.geometry,
    required this.inkGeometry,
  });

  final int document;
  final int page;
  final int bitmapWidth;
  final int bitmapHeight;
  final bool geometry;
  final bool inkGeometry;
}

/// PDFium bindings loaded in the worker isolate (top-level state is
/// per-isolate, so this does not race the main isolate's copy).
pdfium_bindings.PDFium? _workerPdfium;

pdfium_bindings.PDFium get _pdfium => _workerPdfium ??= pdfium_bindings
    .getPdfium(modulePath: pdfrx.Pdfrx.pdfiumModulePath);

/// PDFium applies the CropBox origin and rotation, just as for painted text.
({double x, double y})? _destinationOnWorker(
  ({int document, int page, int width, int height, double? x, double? y})
  request,
) => using((arena) {
  final pdfium = _pdfium;
  final page = pdfium.FPDF_LoadPage(
    pdfium_bindings.FPDF_DOCUMENT.fromAddress(request.document),
    request.page,
  );
  if (page == nullptr) return null;
  try {
    final box = arena<pdfium_bindings.FS_RECTF>();
    if (pdfium.FPDF_GetPageBoundingBox(page, box) == 0) return null;
    final x = arena<Int>();
    final y = arena<Int>();
    final ok = pdfium.FPDF_PageToDevice(
      page,
      0,
      0,
      request.width,
      request.height,
      0,
      request.x ?? box.ref.left,
      request.y ?? box.ref.top,
      x,
      y,
    );
    return ok == 0 ? null : (x: x.value / 1000, y: y.value / 1000);
  } finally {
    pdfium.FPDF_ClosePage(page);
  }
});

/// Runs on pdfrx's worker isolate: explicit document information, not ISBNs
/// in page text (which could describe a bibliography or another edition).
PdfDocumentInfo _infoOnWorker(int address) {
  final pdfium = _pdfium;
  final document = pdfium_bindings.FPDF_DOCUMENT.fromAddress(address);
  String? text(String tag) => using((arena) {
    final key = tag.toNativeUtf8(allocator: arena).cast<Char>();
    final length = pdfium.FPDF_GetMetaText(document, key, nullptr, 0);
    // UTF-16LE with a terminator; 2 bytes is an empty value.
    if (length <= 2 || length > 64 * 1024) return null;
    final buffer = arena<Uint16>(length ~/ 2);
    pdfium.FPDF_GetMetaText(document, key, buffer.cast(), length);
    final value = String.fromCharCodes(
      buffer.asTypedList(length ~/ 2 - 1),
    ).trim();
    return value.isEmpty ? null : value;
  });
  return PdfDocumentInfo(
    title: text('Title'),
    author: text('Author'),
    isbn: text('ISBN'),
    language: text('Language'),
    edition: text('Edition'),
    volume: text('Volume'),
  );
}

/// Runs on pdfrx's worker isolate: whether the viewer preferences'
/// `/Direction` is `/R2L`.
bool _rightToLeftOnWorker(int address) {
  final pdfium = _pdfium;
  final document = pdfium_bindings.FPDF_DOCUMENT.fromAddress(address);
  return using((arena) {
    final key = 'Direction'.toNativeUtf8(allocator: arena).cast<Char>();
    // The value's bytes and a terminator; 0 when there is no such name.
    const capacity = 8;
    final buffer = arena<Uint8>(capacity);
    final length = pdfium.FPDF_VIEWERREF_GetName(
      document,
      key,
      buffer.cast(),
      capacity,
    );
    if (length < 1 || length > capacity) return false;
    return String.fromCharCodes(buffer.asTypedList(length - 1)) == 'R2L';
  });
}

/// Object bounds include the object's matrix; nested forms additionally need
/// every ancestor matrix. Apply those before the page's CropBox/rotation.
({List<PdfRect> images, List<PdfRect> graphics, bool unbounded})
_pageObjectsOnWorker(
  ({int document, int page, int width, int height}) request,
) => using((arena) {
  final pdfium = _pdfium;
  final page = pdfium.FPDF_LoadPage(
    pdfium_bindings.FPDF_DOCUMENT.fromAddress(request.document),
    request.page,
  );
  if (page == nullptr) {
    throw PdfEngineException('failed to load page ${request.page}');
  }
  try {
    final images = <PdfRect>[];
    final graphics = <PdfRect>[];
    var unbounded = false;
    final left = arena<Float>();
    final bottom = arena<Float>();
    final right = arena<Float>();
    final top = arena<Float>();
    final matrix = arena<pdfium_bindings.FS_MATRIX>();
    final dx = arena<Int>();
    final dy = arena<Int>();
    var objects = 0;
    void visit(
      pdfium_bindings.FPDF_PAGEOBJECT object,
      List<({double a, double b, double c, double d, double e, double f})>
      parents,
    ) {
      if (++objects > 65536 || parents.length > 64) {
        throw const PdfEngineLimitException('PDF page object limit exceeded');
      }
      final type = pdfium.FPDFPageObj_GetType(object);
      if (type == pdfium_bindings.FPDF_PAGEOBJ_FORM) {
        if (pdfium.FPDFPageObj_GetMatrix(object, matrix) == 0) {
          unbounded = true;
          return;
        }
        final m = matrix.ref;
        if (![m.a, m.b, m.c, m.d, m.e, m.f].every((v) => v.isFinite)) {
          unbounded = true;
          return;
        }
        final chain = [
          (a: m.a, b: m.b, c: m.c, d: m.d, e: m.e, f: m.f),
          ...parents,
        ];
        final count = pdfium.FPDFFormObj_CountObjects(object);
        if (count < 0) unbounded = true;
        for (var i = 0; i < count; i++) {
          visit(pdfium.FPDFFormObj_GetObject(object, i), chain);
        }
      } else if (type != pdfium_bindings.FPDF_PAGEOBJ_TEXT) {
        if ((type != pdfium_bindings.FPDF_PAGEOBJ_IMAGE &&
                type != pdfium_bindings.FPDF_PAGEOBJ_PATH &&
                type != pdfium_bindings.FPDF_PAGEOBJ_SHADING) ||
            pdfium.FPDFPageObj_GetBounds(object, left, bottom, right, top) ==
                0) {
          unbounded = true;
          return;
        }
        if (![
          left.value,
          bottom.value,
          right.value,
          top.value,
        ].every((v) => v.isFinite)) {
          unbounded = true;
          return;
        }
        final points = <({double x, double y})>[];
        for (var x in [left.value, right.value]) {
          for (var y in [bottom.value, top.value]) {
            var px = x;
            var py = y;
            for (final m in parents) {
              final nx = m.a * px + m.c * py + m.e;
              py = m.b * px + m.d * py + m.f;
              px = nx;
            }
            if (pdfium.FPDF_PageToDevice(
                  page,
                  0,
                  0,
                  request.width,
                  request.height,
                  0,
                  px,
                  py,
                  dx,
                  dy,
                ) !=
                0) {
              points.add((x: dx.value / 1000, y: dy.value / 1000));
            }
          }
        }
        if (points.length != 4) {
          unbounded = true;
          return;
        }
        final rect = PdfRect(
          points
              .map((p) => p.x)
              .reduce(math.min)
              .clamp(0, request.width / 1000),
          points
              .map((p) => p.y)
              .reduce(math.min)
              .clamp(0, request.height / 1000),
          points
              .map((p) => p.x)
              .reduce(math.max)
              .clamp(0, request.width / 1000),
          points
              .map((p) => p.y)
              .reduce(math.max)
              .clamp(0, request.height / 1000),
        );
        if (rect.width > 0 && rect.height > 0) {
          (type == pdfium_bindings.FPDF_PAGEOBJ_IMAGE ? images : graphics).add(
            rect,
          );
        } else {
          // Zero-area path bounds do not prove no ink: hairline strokes can
          // still paint device pixels. Prefer the full page over discarding it.
          unbounded = true;
        }
      }
    }

    final count = pdfium.FPDFPage_CountObjects(page);
    if (count < 0) unbounded = true;
    for (var i = 0; i < count; i++) {
      visit(pdfium.FPDFPage_GetObject(page, i), const []);
    }
    return (images: images, graphics: graphics, unbounded: unbounded);
  } finally {
    pdfium.FPDF_ClosePage(page);
  }
});

/// Runs on pdfrx's worker isolate: samples every character of one page.
List<PdfCharacterSample> _sampleOnWorker(_SampleRequest request) {
  final pdfium = _pdfium;
  final document = pdfium_bindings.FPDF_DOCUMENT.fromAddress(request.document);
  final page = pdfium.FPDF_LoadPage(document, request.page);
  if (page == nullptr) {
    throw PdfEngineException('failed to load page ${request.page}');
  }
  try {
    final textPage = pdfium.FPDFText_LoadPage(page);
    if (textPage == nullptr) {
      throw PdfEngineException('failed to load text for page ${request.page}');
    }
    try {
      return using((arena) {
        final count = pdfium.FPDFText_CountChars(textPage);
        if (count < 0) {
          throw PdfEngineException(
            'failed to count characters on page ${request.page}',
          );
        }
        if (count * 2 > pdfSelectionMaxEndpoints) {
          throw const PdfSelectionLimitException(
            'PDF page exceeds the $pdfSelectionMaxEndpoints-endpoint '
            'selection ceiling',
          );
        }
        final box = arena<pdfium_bindings.FS_RECTF>();
        final pageBox = arena<pdfium_bindings.FS_RECTF>();
        final matrix = arena<pdfium_bindings.FS_MATRIX>();
        final tight = arena<Double>(4);
        final deviceX = arena<Int>();
        final deviceY = arena<Int>();
        final hasPageBox = pdfium.FPDF_GetPageBoundingBox(page, pageBox) != 0;
        final samples = <PdfCharacterSample>[];
        for (var index = 0; index < count; index++) {
          final codePoint = pdfium.FPDFText_GetUnicode(textPage, index);
          final generated = pdfium.FPDFText_IsGenerated(textPage, index) == 1;
          final hasLoose =
              pdfium.FPDFText_GetLooseCharBox(textPage, index, box) != 0;
          PdfPageBounds? pageBounds;
          var visible = false;
          if (hasLoose) {
            pageBounds = PdfPageBounds(
              box.ref.left,
              box.ref.bottom,
              box.ref.right,
              box.ref.top,
            );
            visible =
                hasPageBox &&
                pageBounds.left < pageBox.ref.right &&
                pageBounds.right > pageBox.ref.left &&
                pageBounds.bottom < pageBox.ref.top &&
                pageBounds.top > pageBox.ref.bottom;
          }
          PdfDeviceBounds? deviceBounds;
          PdfDeviceBounds? inkBounds;
          PdfBaselineProbe? baseline;
          if (request.geometry && pageBounds != null) {
            (int, int)? toDevice(double x, double y) {
              final ok = pdfium.FPDF_PageToDevice(
                page,
                0,
                0,
                request.bitmapWidth,
                request.bitmapHeight,
                0,
                x,
                y,
                deviceX,
                deviceY,
              );
              return ok == 0 ? null : (deviceX.value, deviceY.value);
            }

            final corners = [
              toDevice(pageBounds.left, pageBounds.bottom),
              toDevice(pageBounds.left, pageBounds.top),
              toDevice(pageBounds.right, pageBounds.bottom),
              toDevice(pageBounds.right, pageBounds.top),
            ];
            if (!corners.contains(null)) {
              final xs = [for (final corner in corners) corner!.$1];
              final ys = [for (final corner in corners) corner!.$2];
              deviceBounds = PdfDeviceBounds(
                xs.reduce(math.min),
                ys.reduce(math.min),
                xs.reduce(math.max),
                ys.reduce(math.max),
              );
            }
            if (request.inkGeometry &&
                pdfium.FPDFText_GetCharBox(
                      textPage,
                      index,
                      tight,
                      tight + 1,
                      tight + 2,
                      tight + 3,
                    ) !=
                    0) {
              final corners = [
                toDevice(tight[0], tight[2]),
                toDevice(tight[0], tight[3]),
                toDevice(tight[1], tight[2]),
                toDevice(tight[1], tight[3]),
              ];
              if (!corners.contains(null)) {
                inkBounds = PdfDeviceBounds(
                  corners.map((p) => p!.$1).reduce(math.min),
                  corners.map((p) => p!.$2).reduce(math.min),
                  corners.map((p) => p!.$1).reduce(math.max),
                  corners.map((p) => p!.$2).reduce(math.max),
                );
              }
            }
            if (pdfium.FPDFText_GetMatrix(textPage, index, matrix) != 0) {
              final a = matrix.ref.a;
              final b = matrix.ref.b;
              final baselineLength = math.sqrt(a * a + b * b);
              if (baselineLength.isFinite && baselineLength > 1e-7) {
                // PDFium exposes integer device coordinates; extend the probe
                // so a valid subpixel text matrix cannot quantise to zero.
                final probeScale = 1024 / baselineLength;
                final pageX = (pageBounds.left + pageBounds.right) / 2;
                final pageY = (pageBounds.bottom + pageBounds.top) / 2;
                final origin = toDevice(pageX, pageY);
                final probe = toDevice(
                  pageX + a * probeScale,
                  pageY + b * probeScale,
                );
                if (origin != null && probe != null) {
                  baseline = PdfBaselineProbe(
                    probe.$1 - origin.$1,
                    probe.$2 - origin.$2,
                  );
                }
              }
            }
          }
          samples.add(
            PdfCharacterSample(
              index: index,
              codePoint: codePoint,
              generated: generated,
              visible: visible,
              pageBounds: pageBounds,
              deviceBounds: deviceBounds,
              inkBounds: inkBounds,
              baseline: baseline,
            ),
          );
        }
        return samples;
      });
    } finally {
      pdfium.FPDFText_ClosePage(textPage);
    }
  } finally {
    pdfium.FPDF_ClosePage(page);
  }
}
