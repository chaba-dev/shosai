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
  /// mapping alone (RFD 4, M3.0).
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
  Future<PdfRenderedPage> render(int page, double scale);

  /// Builds the selection surface for [page] rendered at [scale].
  Future<FlutterSelectionSurface> selectionSurface(int page, double scale);

  /// Extracted text of [page], one scalar per PDFium character.
  Future<String> pageText(int page);

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
  const PdfDocumentInfo({this.title, this.author});

  /// Null when absent or blank.
  final String? title;
  final String? author;
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
  });

  final int width;
  final int height;

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
  const PdfPageLink({required this.rects, this.url, this.page});

  /// Clickable areas in page points, `(left, bottom, right, top)` with the
  /// PDF's y axis (up), relative to the page's visible box.
  final List<PdfLinkRect> rects;

  /// External target, when the link is a URI action.
  final Uri? url;

  /// Zero-based target page, when the link is an internal destination.
  final int? page;
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

/// Computes the bitmap size for a page, with the retained core's limits.
PdfBitmapSize pdfBitmapSizeFor(PdfPageSize size, double scale) {
  if (!scale.isFinite || scale <= 0) {
    throw const PdfEngineException('page scale must be finite and positive');
  }
  final width = (size.width * scale).ceilToDouble();
  final height = (size.height * scale).ceilToDouble();
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
