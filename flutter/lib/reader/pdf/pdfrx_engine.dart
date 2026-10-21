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
import 'package:shosai_flutter/src/rust/api.dart';

import 'engine.dart';
import 'search.dart';
import 'selection.dart';

/// PDFium renders text with LCD subpixel smoothing, as the retained core did.
const int _lcdText = pdfrx.PdfPageRenderFlags.lcdText;

/// PDFium writes RGBA instead of its native BGRA byte order.
const int _reverseByteOrder = 0x10;

/// The production [PdfEngine].
final class PdfrxPdfEngine implements PdfEngine {
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
    final pdfrx.PdfDocument document;
    try {
      document = await pdfrx.PdfDocument.openFile(filePath);
    } on pdfrx.PdfPasswordException {
      throw PdfEnginePasswordException(filePath);
    } on pdfrx.PdfException catch (error) {
      throw PdfEngineException('Cannot open PDF: ${error.message}');
    }
    if (document.pages.isEmpty) {
      await document.dispose();
      throw const PdfEngineException('PDF has no pages');
    }
    return _PdfrxDocument(document);
  }
}

final class _PdfrxDocument implements PdfEngineDocument {
  _PdfrxDocument(this._document);

  final pdfrx.PdfDocument _document;
  bool _disposed = false;

  @override
  int get pageCount => _document.pages.length;

  @override
  bool get isEncrypted => _document.isEncrypted;

  @override
  bool get allowsCopying => _document.permissions?.allowsCopying ?? true;

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
  Future<PdfRenderedPage> render(int page, double scale) async {
    final loaded = _page(page);
    final size = bitmapSize(page, scale);
    final image = await loaded.render(
      width: size.width,
      height: size.height,
      fullWidth: size.width.toDouble(),
      fullHeight: size.height.toDouble(),
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
  Future<List<FlutterSearchMatch>> search(String query) async {
    final search = PdfSearch(query);
    if (search.isEmpty) return const [];
    for (var page = 0; page < pageCount; page++) {
      search.addPage(page, await pageText(page));
    }
    return search.results;
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
            for (final rect in link.rects)
              PdfLinkRect(rect.left, rect.bottom, rect.right, rect.top),
          ],
          url: link.url,
          page: switch (link.dest?.pageNumber) {
            final target? when target >= 1 && target <= pageCount => target - 1,
            _ => null,
          },
        ),
    ];
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _document.dispose();
  }

  /// Samples every character of [page] on pdfrx's PDFium worker.
  Future<List<PdfCharacterSample>> _sample(
    int page,
    PdfBitmapSize size, {
    required bool geometry,
  }) {
    // pdfrx keeps the FPDF_DOCUMENT handle on its (private) document class as
    // a public `document` field; the raw text calls below need it. This is the
    // one place the engine reaches past pdfrx's object model, and the engine
    // tests fail loudly if a pdfrx upgrade moves it.
    final handle = (_document as dynamic).document as Pointer<NativeType>;
    return pdfrx.PdfrxEntryFunctions.instance.compute(
      _sampleOnWorker,
      _SampleRequest(
        document: handle.address,
        page: page,
        bitmapWidth: size.width,
        bitmapHeight: size.height,
        geometry: geometry,
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
  });

  final int document;
  final int page;
  final int bitmapWidth;
  final int bitmapHeight;
  final bool geometry;
}

/// PDFium bindings loaded in the worker isolate (top-level state is
/// per-isolate, so this does not race the main isolate's copy).
pdfium_bindings.PDFium? _workerPdfium;

pdfium_bindings.PDFium get _pdfium => _workerPdfium ??= pdfium_bindings
    .getPdfium(modulePath: pdfrx.Pdfrx.pdfiumModulePath);

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
