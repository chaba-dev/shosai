/// The reader's PDF engine contract.
///
/// The reader controller owns one [PdfEngine] and routes every PDF page
/// operation (render, selection geometry, search, outline, links) through the
/// [PdfEngineDocument] it opens, so the presentation never depends on the
/// engine implementation. Production uses the PDFium-backed engine in
/// `pdfrx_engine.dart`; tests inject a fake.
///
/// Rendering produces the same pixel format and page sizing the retained core
/// did (RGBA, `ceil(points × scale)`), and selection and search use the
/// contract in `selection.dart` and `search.dart`, so the reader's painting,
/// selection and annotation anchors are unchanged by the engine replacement.
library;

import 'dart:typed_data';

import 'package:shosai_flutter/core/bridge.dart';

import 'page_geometry.dart';

/// Maximum PDF input size the engine opens.
const int pdfMaxInputBytes = 512 * 1024 * 1024;

/// Maximum bitmap edge, in pixels, the engine renders.
const int pdfMaxBitmapDimension = 16384;

/// Maximum bitmap area, in pixels, the engine renders.
const int pdfMaxBitmapPixels = 40000000;

/// Opens PDF documents for the reader.
abstract interface class PdfEngine {
  /// Opens the document at [path].
  ///
  /// [path] is the reader's path key: a plain file path, or the core's
  /// encoded key for a path that is not valid UTF-8.
  Future<PdfEngineDocument> open(String path);
}

/// A [PdfEngine] that can also open a document it reads only in parts.
abstract interface class RangedPdfEngine implements PdfEngine {
  /// Opens a [size]-byte document whose bytes come from [read]: it copies up
  /// to `length` bytes at `position` into `buffer` and returns how many it
  /// copied. The engine reads only what it needs, and loads only the first
  /// page, so a document's first page and metadata can be read without the
  /// rest; other pages' sizes are not known. A read that throws fails the
  /// open, or the render that needed it, as an unreadable document.
  Future<PdfEngineDocument> openRanged(
    int size,
    Future<int> Function(Uint8List buffer, int position, int length) read, {
    required String sourceName,
  });
}

/// One open PDF document.
abstract interface class PdfEngineDocument {
  /// Number of pages.
  int get pageCount;

  /// Whether the file is encrypted.
  ///
  /// The engine opens a document whose user password is empty; a document that
  /// needs a password fails to open with [PdfEnginePasswordException].
  bool get isEncrypted;

  /// Whether the document's permissions allow copying text, when it is
  /// encrypted. Always true for an unencrypted document.
  ///
  /// Slice 1 of the Dart core reports the flag and does not enforce it, which
  /// is the retained core's behaviour: copy eligibility is decided by text
  /// mapping alone (RFD 12, M3.0).
  bool get allowsCopying;

  /// Whether the document's viewer preferences read it right to left
  /// (`/Direction /R2L`), as a book in Japanese or Arabic is bound: a spread
  /// puts its first page on the right, and the next page is to the left.
  bool get rightToLeft;

  /// Page size in points, after the page's rotation.
  PdfPageSize pageSize(int page);

  /// Pixel size a page renders at for [scale].
  ///
  /// Throws [PdfEngineLimitException] when the bitmap would exceed the engine's
  /// limits.
  PdfBitmapSize bitmapSize(int page, double scale);

  /// Renders [page] at [scale] as straight (non-premultiplied) RGBA pixels.
  /// With [clip], allocates only that rectangle in rotated page points. The
  /// returned [PdfRenderedPage.source] includes outward pixel rounding.
  Future<PdfRenderedPage> render(int page, double scale, {PdfRect? clip});

  /// Builds the selection surface for [page] rendered at [scale].
  Future<FlutterSelectionSurface> selectionSurface(int page, double scale);

  /// Extracted text of [page], one scalar per PDFium character.
  Future<String> pageText(int page);

  /// Physical lines, images and other painted-object coverage in rotated
  /// visible page points. Unknown coverage is explicit for safe fallback.
  /// Independent of render scale; callers own the returned immutable values.
  Future<PdfPageGeometry> pageGeometry(int page);

  /// Searches the whole document for [query], case-insensitively.
  Future<List<FlutterSearchMatch>> search(String query);

  /// The title and author of the document information dictionary.
  Future<PdfDocumentInfo> info();

  /// The document outline, flattened in document order.
  Future<List<PdfOutlineEntry>> outline();

  /// Link annotations on [page], in page points.
  Future<List<PdfPageLink>> links(int page);

  /// Releases the document. Later calls fail.
  Future<void> dispose();
}

/// What the document information dictionary says about the document.
final class PdfDocumentInfo {
  const PdfDocumentInfo({
    this.title,
    this.author,
    this.isbn,
    this.language,
    this.edition,
    this.volume,
  });

  /// Null when absent or blank.
  final String? title;
  final String? author;
  final String? isbn;
  final String? language;
  final String? edition;
  final String? volume;
}

/// Page size in points.
final class PdfPageSize {
  const PdfPageSize(this.width, this.height);

  final double width;
  final double height;
}

/// Bitmap size in pixels.
final class PdfBitmapSize {
  const PdfBitmapSize(this.width, this.height);

  final int width;
  final int height;
}

/// One rendered page.
final class PdfRenderedPage {
  const PdfRenderedPage({
    required this.width,
    required this.height,
    required this.pixels,
    this.source,
  });

  final int width;
  final int height;

  /// Actual page-point area of a clipped raster, including rounded edge pixels.
  final PdfRect? source;

  /// Straight RGBA pixels, row-major, `width * height * 4` bytes.
  final Uint8List pixels;
}

/// One outline (bookmark) entry.
final class PdfOutlineEntry {
  const PdfOutlineEntry({
    required this.depth,
    required this.title,
    required this.page,
  });

  /// Nesting depth, 0 for a top-level entry.
  final int depth;
  final String title;

  /// Zero-based target page, or null when the entry has no page destination.
  final int? page;
}

/// One link annotation.
final class PdfPageLink {
  const PdfPageLink({
    required this.rects,
    this.url,
    this.page,
    this.destination,
  });

  /// Clickable areas in page points, `(left, bottom, right, top)` with the
  /// PDF's y axis (up), relative to the page's visible box.
  final List<PdfLinkRect> rects;

  /// External target, when the link is a URI action.
  final Uri? url;

  /// Zero-based target page, when the link is an internal destination.
  final int? page;

  /// Optional position within the target's rotated visible page, in points
  /// from its top-left corner. Page-fit destinations have no position.
  final ({double x, double y})? destination;
}

/// A rectangle in page points.
final class PdfLinkRect {
  const PdfLinkRect(this.left, this.bottom, this.right, this.top);

  final double left;
  final double bottom;
  final double right;
  final double top;
}

/// Thrown when a request exceeds one of the engine's resource limits.
final class PdfEngineLimitException implements Exception {
  const PdfEngineLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when a document needs a password the reader cannot supply.
final class PdfEnginePasswordException implements Exception {
  const PdfEnginePasswordException(this.path);

  final String path;

  @override
  String toString() => 'The PDF is password protected';
}

/// Thrown when the engine cannot open or read a document.
final class PdfEngineException implements Exception {
  const PdfEngineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Computes an admitted page/crop bitmap, including PDFium's outward rounding.
/// A crop need not admit the virtual full page, but its native dimensions must
/// still fit signed integers. Callers can preflight without allocating pixels.
PdfBitmapSize pdfBitmapSizeFor(
  PdfPageSize size,
  double scale, {
  PdfRect? clip,
}) {
  if (!scale.isFinite || scale <= 0) {
    throw const PdfEngineException('page scale must be finite and positive');
  }
  var width = (size.width * scale).ceilToDouble();
  var height = (size.height * scale).ceilToDouble();
  if (clip != null) {
    if (!clip.left.isFinite ||
        !clip.top.isFinite ||
        !clip.right.isFinite ||
        !clip.bottom.isFinite ||
        clip.left < 0 ||
        clip.top < 0 ||
        clip.right > size.width ||
        clip.bottom > size.height) {
      throw const PdfEngineException('PDF crop is outside the page');
    }
    if (!width.isFinite ||
        !height.isFinite ||
        width > 0x7fffffff ||
        height > 0x7fffffff) {
      throw const PdfEngineLimitException(
        'PDF render scale exceeds native limits',
      );
    }
    final sx = width / size.width;
    final sy = height / size.height;
    width = (clip.right * sx).ceilToDouble() - (clip.left * sx).floorToDouble();
    height =
        (clip.bottom * sy).ceilToDouble() - (clip.top * sy).floorToDouble();
  }
  if (!width.isFinite ||
      !height.isFinite ||
      width < 1 ||
      height < 1 ||
      width > pdfMaxBitmapDimension ||
      height > pdfMaxBitmapDimension ||
      width * height > pdfMaxBitmapPixels) {
    throw const PdfEngineLimitException(
      'PDF bitmap exceeds decoded image limits',
    );
  }
  return PdfBitmapSize(width.toInt(), height.toInt());
}

/// Decodes the reader's path key into a file path.
///
/// Mirrors the core's `path_from_key`: a key that starts with NUL carries the
/// hex-encoded bytes of a path that is not valid UTF-8. Dart strings cannot
/// hold such a path losslessly, so the bytes are decoded as UTF-8 with
/// replacement and the engine opens what it can.
String pdfPathFromKey(String key) {
  const unix = '\u0000unix-path-v1:';
  if (key.startsWith(unix)) {
    final bytes = _decodeHex(key.substring(unix.length));
    if (bytes != null) return String.fromCharCodes(bytes);
  }
  return key;
}

List<int>? _decodeHex(String encoded) {
  if (encoded.length.isOdd) return null;
  final bytes = <int>[];
  for (var i = 0; i < encoded.length; i += 2) {
    final value = int.tryParse(encoded.substring(i, i + 2), radix: 16);
    if (value == null) return null;
    bytes.add(value);
  }
  return bytes;
}
