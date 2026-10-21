/// Book metadata and cover extraction for import.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:shosai_epub/shosai_epub.dart';

import '../cancellation.dart';
import '../errors.dart';

/// Largest cover thumbnail the library stores.
const maxCoverBytes = 512 * 1024;

/// Covers are scaled down to fit this box.
const coverMaxWidth = 300;
const coverMaxHeight = 400;

/// Covers with more source pixels than this are not decoded.
const maxCoverSourcePixels = 16 * 1024 * 1024;

/// What a format engine reports about a book for the library.
final class BookMetadata {
  const BookMetadata({this.title, this.author, this.cover});

  /// The document's own title, or null to use the file name.
  final String? title;
  final String? author;

  /// A PNG thumbnail no larger than [coverMaxWidth] × [coverMaxHeight], or
  /// null when the book has no usable cover.
  final Uint8List? cover;
}

/// Reads a book's metadata for import. One inspector serves each format; the
/// PDF inspector belongs to the PDF engine and is supplied by the host.
abstract interface class BookInspector {
  Future<BookMetadata> inspect(String path, {CancellationToken? cancellation});
}

/// EPUB metadata and cover through the Dart EPUB engine, off the calling
/// isolate.
final class EpubInspector implements BookInspector {
  const EpubInspector({this.limits = const EpubLimits()});

  final EpubLimits limits;

  @override
  Future<BookMetadata> inspect(
    String path, {
    CancellationToken? cancellation,
  }) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException catch (error) {
      throw CoreException(
        CoreErrorKind.inaccessible,
        'Could not read $path: ${error.osError?.message ?? error.message}',
      );
    }
    cancellation.throwIfCancelled();
    final limits = this.limits;
    return Isolate.run(() => _inspectEpub(bytes, limits));
  }
}

BookMetadata _inspectEpub(Uint8List bytes, EpubLimits limits) {
  final EpubInspection inspection;
  try {
    inspection = inspectEpubBytes(bytes, limits: limits);
  } on EpubLimitError catch (error) {
    throw CoreException.limitExceeded('The EPUB exceeds a limit: $error');
  } on EpubFormatError catch (error) {
    throw CoreException.malformed('The EPUB cannot be read: ${error.message}');
  }
  return BookMetadata(
    title: inspection.title,
    author: inspection.author,
    cover: switch (inspection.cover) {
      final cover? => coverThumbnail(cover),
      null => null,
    },
  );
}

/// Decode an encoded cover image and scale it into a PNG thumbnail.
///
/// Returns null for an image that cannot be decoded, has more than
/// [maxCoverSourcePixels] pixels, or encodes larger than [maxCoverBytes].
Uint8List? coverThumbnail(Uint8List encoded) {
  final decoder = image.findDecoderForData(encoded);
  final info = decoder?.startDecode(encoded);
  if (decoder == null ||
      info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > maxCoverSourcePixels) {
    return null;
  }
  final decoded = decoder.decode(encoded);
  if (decoded == null) return null;
  final scale = [
    coverMaxWidth / decoded.width,
    coverMaxHeight / decoded.height,
    1.0,
  ].reduce((a, b) => a < b ? a : b);
  final thumbnail = scale < 1
      ? image.copyResize(
          decoded,
          width: (decoded.width * scale).floor().clamp(1, coverMaxWidth),
          height: (decoded.height * scale).floor().clamp(1, coverMaxHeight),
          interpolation: image.Interpolation.average,
        )
      : decoded;
  final png = image.encodePng(thumbnail);
  return png.length <= maxCoverBytes ? png : null;
}
