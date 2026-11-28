/// Comic archives behind the reader's fixed-page document contract.
///
/// A comic is a sequence of images, so it serves the same paged, spread,
/// continuous and zoom presentation a PDF does through [PdfEngineDocument].
/// The archive and its metadata come from `shosai_cbz`; Flutter's image codec
/// decodes the pixels. A page's size in points is its size in pixels. Pages
/// have no text: selection surfaces are empty and search finds nothing.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:shosai_cbz/shosai_cbz.dart';
import 'package:shosai_flutter/core/bridge.dart';

import '../pdf/engine.dart';
import '../pdf/page_geometry.dart';

/// An open comic archive read as fixed pages.
final class CbzPageDocument implements PdfEngineDocument {
  CbzPageDocument._(this._file, this._archive, this._sizes, this.comicInfo);

  final RandomAccessFile _file;
  final CbzArchive _archive;
  final List<CbzImageSize> _sizes;

  /// The archive's ComicInfo.xml metadata, empty when it has none.
  final CbzComicInfo comicInfo;

  /// The last decoded page, kept so a re-render at the same size, as a spread
  /// partner or after a relayout, does not decode it again.
  ({int page, int width, int height, Uint8List pixels})? _last;
  var _disposed = false;

  /// Open the archive at [path] and measure every page from its image
  /// header. A page whose header cannot be read takes its neighbour's size
  /// and fails only when it is rendered.
  static Future<CbzPageDocument> open(String path) async {
    final RandomAccessFile file;
    try {
      file = await File(path).open();
    } on FileSystemException catch (error) {
      throw PdfEngineException(
        'The comic cannot be read: ${error.osError?.message ?? error.message}',
      );
    }
    try {
      final archive = await CbzArchive.open(
        CbzFileSource(file, await file.length()),
      );
      final sizes = <CbzImageSize?>[];
      for (var page = 0; page < archive.pages.length; page++) {
        try {
          sizes.add(await archive.pageSize(page));
        } on CbzFormatError {
          sizes.add(null);
        }
      }
      final known = sizes.whereType<CbzImageSize>().firstOrNull;
      if (known == null) {
        throw const PdfEngineException('The comic has no readable pages.');
      }
      var previous = known;
      final measured = [for (final size in sizes) previous = size ?? previous];
      return CbzPageDocument._(
        file,
        archive,
        measured,
        await archive.comicInfo(),
      );
    } on CbzProtectedError {
      await file.close();
      throw const PdfEngineProtectedException();
    } on CbzLimitError catch (error) {
      await file.close();
      throw PdfEngineLimitException(error.message);
    } on CbzFormatError catch (error) {
      await file.close();
      throw PdfEngineException(error.message);
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  @override
  int get pageCount => _sizes.length;

  @override
  bool get isEncrypted => false;

  @override
  bool get allowsCopying => false;

  /// The comic's own direction, its manga mark. The reader decides the
  /// direction it shows from this, the reader settings and the book's saved
  /// choice, and sets it here so spreads are laid out that way.
  bool get markedRightToLeft => comicInfo.manga.rightToLeft;

  @override
  bool rightToLeft = false;

  @override
  PdfPageSize pageSize(int page) {
    final size = _sizes[page];
    return PdfPageSize(size.width.toDouble(), size.height.toDouble());
  }

  @override
  PdfBitmapSize bitmapSize(int page, double scale) =>
      pdfBitmapSizeFor(pageSize(page), _decodeScale(page, scale));

  /// [scale], or less when the page would decode larger than its own pixels
  /// or than the engine's bitmap limits: a page never renders past its
  /// source, and the painter scales the raster up to the page's box.
  double _decodeScale(int page, double scale) {
    final size = _sizes[page];
    final pixels = size.width * size.height;
    var limit = math.min(
      1.0,
      math.min(
        pdfMaxBitmapDimension / size.width,
        pdfMaxBitmapDimension / size.height,
      ),
    );
    if (pixels * limit * limit > pdfMaxBitmapPixels) {
      limit = math.sqrt(pdfMaxBitmapPixels / pixels);
    }
    return math.min(scale, limit);
  }

  @override
  Future<PdfRenderedPage> render(
    int page,
    double scale, {
    PdfRect? clip,
  }) async {
    if (_disposed) throw const PdfEngineException('The comic is closed.');
    if (clip != null) {
      throw const PdfEngineException('Comic pages render whole.');
    }
    final target = bitmapSize(page, scale);
    if (_last case final last?
        when last.page == page &&
            last.width == target.width &&
            last.height == target.height) {
      return PdfRenderedPage(
        width: last.width,
        height: last.height,
        pixels: last.pixels,
      );
    }
    final source = _sizes[page];
    if (!_archive.decodable(source)) {
      throw PdfEngineLimitException(
        'Page ${page + 1} is larger than the reader decodes.',
      );
    }
    final Uint8List bytes;
    try {
      bytes = await _archive.pageBytes(page);
    } on CbzFormatError catch (error) {
      throw PdfEngineException(error.message);
    } on CbzLimitError catch (error) {
      throw PdfEngineLimitException(error.message);
    }
    final ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: target.width,
        targetHeight: target.height,
      );
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } on Exception catch (error) {
      throw PdfEngineException('Page ${page + 1} cannot be decoded: $error');
    }
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) {
        throw PdfEngineException('Page ${page + 1} cannot be decoded.');
      }
      final pixels = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      _last = (
        page: page,
        width: image.width,
        height: image.height,
        pixels: pixels,
      );
      return PdfRenderedPage(
        width: image.width,
        height: image.height,
        pixels: pixels,
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
    final size = pageSize(page);
    return FlutterSelectionSurface(
      width: size.width * scale,
      height: size.height * scale,
      text: '',
      copyEligible: false,
      endpoints: const [],
      graphemeBoundaries: Uint32List(0),
      wordBoundaries: Uint32List(0),
      visualLines: const [],
    );
  }

  @override
  Future<String> pageText(int page) async => '';

  @override
  Future<PdfPageGeometry> pageGeometry(int page) async {
    final size = pageSize(page);
    return PdfPageGeometry(
      width: size.width,
      height: size.height,
      lines: const [],
      images: [PdfRect(0, 0, size.width, size.height)],
    );
  }

  @override
  Future<List<FlutterSearchMatch>> search(String query) async => const [];

  @override
  Future<PdfDocumentInfo> info() async => PdfDocumentInfo(
    title: comicInfo.displayTitle,
    author: comicInfo.writers.isEmpty ? null : comicInfo.writers.join(', '),
    language: comicInfo.language,
    volume: comicInfo.volume,
  );

  @override
  Future<List<PdfOutlineEntry>> outline() async => const [];

  @override
  Future<List<PdfPageLink>> links(int page) async => const [];

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _last = null;
    await _file.close();
  }
}
