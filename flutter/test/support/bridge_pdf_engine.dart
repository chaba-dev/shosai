import 'dart:typed_data';

import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/core/bridge.dart';

/// A fake rendered page: [width] × [height] pixels a fake keeps behind
/// [handle] until `takeBuffer` hands them over.
class FlutterRenderedBuffer {
  const FlutterRenderedBuffer({
    required this.handle,
    required this.width,
    required this.height,
    required this.byteLen,
  });

  final FlutterBufferHandle handle;
  final int width;
  final int height;
  final BigInt byteLen;
}

/// The key of a fake's rendered pixels.
class FlutterBufferHandle {
  const FlutterBufferHandle({required this.registry, required this.id});

  final BigInt registry;
  final BigInt id;

  @override
  int get hashCode => Object.hash(registry, id);

  @override
  bool operator ==(Object other) =>
      other is FlutterBufferHandle &&
      registry == other.registry &&
      id == other.id;
}

/// A [PdfEngine] for a fake bridge: the engine document it opens answers
/// through the fake's [renderPage], [selectionSurface] and `searchDocument`,
/// so a fixture bridge keeps one seam and its counters, completers and
/// recorded layouts stay meaningful for PDFs.
///
/// Mixed into a bridge fake: `class Fake with BridgePdfEngine implements
/// FlutterBridge`. The reader controller uses a bridge that is also an engine
/// as its engine.
mixin BridgePdfEngine implements PdfEngine {
  FlutterBridge get _bridge => this as FlutterBridge;

  /// Page [page] of the fake's document at [scale].
  Future<FlutterRenderedBuffer> renderPage({
    required FlutterDocumentHandle document,
    required BigInt page,
    required double scale,
    required BigInt cancellationId,
  });

  /// The selection surface of page [unit] at [scale].
  Future<FlutterSelectionSurface> selectionSurface({
    required FlutterDocumentHandle document,
    required BigInt unit,
    required double scale,
    required double width,
    required double fontSize,
    required double lineSpacing,
    required BigInt cancellationId,
  });

  /// The pixels behind [handle].
  Uint8List takeBuffer({required FlutterBufferHandle handle});

  bool releaseBuffer({required FlutterBufferHandle handle});

  /// The document handle the engine document passes back to the bridge fakes.
  FlutterDocumentHandle get pdfEngineHandle =>
      FlutterDocumentHandle(registry: BigInt.one, id: BigInt.one);

  /// Pages the engine document reports.
  int get pdfEnginePageCount => 1;

  /// The layout width the engine document asks the bridge's selection fake
  /// for; the reader's default layout width.
  double get pdfEngineSurfaceWidth => 680;

  /// Paths the engine refuses, with the error it throws for each.
  final Map<String, Object> pdfEngineOpenFailures = <String, Object>{};

  /// Every path the engine was asked to open, in order.
  final List<String> pdfEngineOpenedPaths = <String>[];

  /// Engine documents opened and not yet disposed.
  final List<BridgePdfDocument> pdfEngineOpenDocuments = <BridgePdfDocument>[];

  @override
  Future<PdfEngineDocument> open(String path) async {
    pdfEngineOpenedPaths.add(path);
    if (pdfEngineOpenFailures[path] case final failure?) throw failure;
    final document = BridgePdfDocument(this, _bridge);
    pdfEngineOpenDocuments.add(document);
    return document;
  }
}

/// The engine document a [BridgePdfEngine] opens.
final class BridgePdfDocument implements PdfEngineDocument {
  BridgePdfDocument(this._engine, this._bridge);

  final BridgePdfEngine _engine;
  final FlutterBridge _bridge;
  bool disposed = false;

  @override
  int get pageCount => _engine.pdfEnginePageCount;

  @override
  bool get isEncrypted => false;

  @override
  bool get allowsCopying => true;

  @override
  Future<PdfDocumentInfo> info() async => const PdfDocumentInfo();

  @override
  PdfPageSize pageSize(int page) => const PdfPageSize(612, 792);

  @override
  PdfBitmapSize bitmapSize(int page, double scale) =>
      pdfBitmapSizeFor(pageSize(page), scale);

  @override
  Future<PdfRenderedPage> render(int page, double scale) async {
    final rendered = await _engine.renderPage(
      document: _engine.pdfEngineHandle,
      page: BigInt.from(page),
      scale: scale,
      cancellationId: BigInt.zero,
    );
    final Uint8List pixels;
    try {
      pixels = Uint8List.fromList(_engine.takeBuffer(handle: rendered.handle));
    } finally {
      _engine.releaseBuffer(handle: rendered.handle);
    }
    return PdfRenderedPage(
      width: rendered.width,
      height: rendered.height,
      pixels: pixels,
    );
  }

  @override
  Future<FlutterSelectionSurface> selectionSurface(int page, double scale) =>
      _engine.selectionSurface(
        document: _engine.pdfEngineHandle,
        unit: BigInt.from(page),
        scale: scale,
        width: _engine.pdfEngineSurfaceWidth,
        fontSize: 18,
        lineSpacing: 1.5,
        cancellationId: BigInt.zero,
      );

  @override
  Future<String> pageText(int page) async =>
      (await selectionSurface(page, 1)).text;

  @override
  Future<List<FlutterSearchMatch>> search(String query) =>
      _bridge.searchDocument(
        document: _engine.pdfEngineHandle,
        query: query,
        cancellationId: BigInt.zero,
      );

  @override
  Future<List<PdfOutlineEntry>> outline() async => const [];

  @override
  Future<List<PdfPageLink>> links(int page) async => const [];

  @override
  Future<void> dispose() async {
    disposed = true;
    _engine.pdfEngineOpenDocuments.remove(this);
  }
}
