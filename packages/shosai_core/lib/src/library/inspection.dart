/// Book metadata and cover extraction for import.
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:shosai_epub/shosai_epub.dart';

import '../cancellation.dart';
import '../errors.dart';
import 'files.dart';
import 'location.dart';

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
    final bytes = await readBookBytes(path, cancellation: cancellation);
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
  } on EpubPathError catch (error) {
    throw CoreException.malformed('The EPUB cannot be read: $error');
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

/// Reads an unopened book's metadata through its location's byte ranges,
/// without downloading it. One previewer serves each format; the PDF one
/// belongs to the PDF engine and is supplied by the host.
abstract interface class BookPreviewer {
  Future<BookMetadata> preview(
    LibraryLocation location,
    LocationEntry entry, {
    CancellationToken? cancellation,
  });
}

/// [previewEpub] as a [BookPreviewer].
final class EpubPreviewer implements BookPreviewer {
  const EpubPreviewer();

  @override
  Future<BookMetadata> preview(
    LibraryLocation location,
    LocationEntry entry, {
    CancellationToken? cancellation,
  }) => previewEpub(location, entry, cancellation: cancellation);
}

/// The most a PDF preview reads from one file. A PDF whose first page needs
/// more (a file without a nearby cross-reference table, or a heavy first
/// page) is not previewed rather than downloaded.
const maxPreviewPdfReadBytes = 4 * 1024 * 1024;

/// The size of each ranged read [PreviewRanges] makes.
const previewBlockBytes = 64 * 1024;

/// Serves a document engine's small, random reads of an unopened file from
/// a few larger ranged reads of its location, within a byte budget.
///
/// Reads are aligned [blockBytes] blocks, fetched once and kept, with
/// neighbouring missing blocks fetched in one range. A read that would take
/// the file past [budget] bytes fails and sets [exceeded]; a read the
/// location fails, or one after [cancellation], fails and keeps the error in
/// [failure]. An engine that reports failed reads only as a failure to open
/// lets its caller tell these apart.
final class PreviewRanges {
  PreviewRanges(
    this._location,
    this._key,
    this.size, {
    this.budget = maxPreviewPdfReadBytes,
    this.blockBytes = previewBlockBytes,
    CancellationToken? cancellation,
  }) : _cancellation = cancellation;

  final LibraryLocation _location;
  final String _key;
  final CancellationToken? _cancellation;

  /// The file's size in bytes.
  final int size;
  final int budget;
  final int blockBytes;
  final Map<int, Uint8List> _blocks = {};

  /// The bytes fetched from the location so far.
  int fetched = 0;

  /// Whether a read was refused because it would exceed [budget].
  bool exceeded = false;

  /// The first error a fetch failed with, other than the budget.
  Object? failure;

  /// Copy up to [length] bytes at [position] into [buffer] and return how
  /// many were copied: fewer only at the end of the file.
  Future<int> read(Uint8List buffer, int position, int length) async {
    if (position < 0 || length < 0) {
      throw const CoreException.invalidRequest('Invalid byte range.');
    }
    final end = position + length > size ? size : position + length;
    if (end <= position) return 0;
    final first = position ~/ blockBytes;
    final last = (end - 1) ~/ blockBytes;
    var index = first;
    while (index <= last) {
      if (_blocks.containsKey(index)) {
        index++;
        continue;
      }
      var stop = index;
      while (stop < last && !_blocks.containsKey(stop + 1)) {
        stop++;
      }
      await _fetch(index, stop);
      index = stop + 1;
    }
    var copied = 0;
    for (var block = first; block <= last; block++) {
      final bytes = _blocks[block]!;
      final blockStart = block * blockBytes;
      final from = (position > blockStart ? position : blockStart) - blockStart;
      final to =
          (end < blockStart + bytes.length ? end : blockStart + bytes.length) -
          blockStart;
      buffer.setRange(copied, copied + to - from, bytes, from);
      copied += to - from;
    }
    return copied;
  }

  Future<void> _fetch(int first, int last) async {
    try {
      _cancellation.throwIfCancelled();
      final start = first * blockBytes;
      final end = (last + 1) * blockBytes > size
          ? size
          : (last + 1) * blockBytes;
      if (fetched + end - start > budget) {
        exceeded = true;
        throw CoreException.limitExceeded(
          'The preview would read more than $budget bytes.',
        );
      }
      fetched += end - start;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in _location.read(
        _key,
        start: start,
        end: end,
        cancellation: _cancellation,
      )) {
        _cancellation.throwIfCancelled();
        bytes.add(chunk);
        if (bytes.length > end - start) {
          throw const CoreException.malformed(
            'The source returned more than the requested range.',
          );
        }
      }
      final data = bytes.takeBytes();
      if (data.length != end - start) {
        throw const CoreException.malformed(
          'The source ended before its listed size.',
        );
      }
      for (var block = first; block <= last; block++) {
        final from = (block - first) * blockBytes;
        final to = from + blockBytes > data.length
            ? data.length
            : from + blockBytes;
        _blocks[block] = Uint8List.sublistView(data, from, to);
      }
    } catch (error) {
      if (!exceeded) failure ??= error;
      rethrow;
    }
  }
}

/// The limits for reading a book before it is opened: an import's, with a
/// smaller cover image, so a preview costs at most a few megabytes to fetch.
const previewEpubLimits = EpubLimits(maxImageBytes: 8 * 1024 * 1024);

/// The most a preview reads from one file, in all.
const maxPreviewReadBytes = 16 * 1024 * 1024;

/// An unopened EPUB's title, author and cover, read through [location]'s
/// byte ranges without downloading [entry]: the end of the archive, its
/// central directory, the container, the package document and the cover
/// image. The cover is scaled off the calling isolate, as an import's is.
Future<BookMetadata> previewEpub(
  LibraryLocation location,
  LocationEntry entry, {
  CancellationToken? cancellation,
}) async {
  cancellation.throwIfCancelled();
  final size =
      entry.size ??
      (await location.stat(entry.key, cancellation: cancellation)).size;
  if (size == null) {
    throw const CoreException(
      CoreErrorKind.unsupported,
      'The file has no known size.',
    );
  }
  Future<Uint8List> read(int start, int end) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in location.read(
      entry.key,
      start: start,
      end: end,
      cancellation: cancellation,
    )) {
      cancellation.throwIfCancelled();
      bytes.add(chunk);
      if (bytes.length > end - start) {
        throw const CoreException.malformed(
          'The source returned more than the requested range.',
        );
      }
    }
    return bytes.takeBytes();
  }

  final EpubInspection inspection;
  try {
    inspection = await inspectEpubRanges(
      read,
      size,
      limits: previewEpubLimits,
      maxReadBytes: maxPreviewReadBytes,
    );
  } on EpubLimitError catch (error) {
    throw CoreException.limitExceeded('The EPUB exceeds a limit: $error');
  } on EpubFormatError catch (error) {
    throw CoreException.malformed('The EPUB cannot be read: ${error.message}');
  } on EpubPathError catch (error) {
    throw CoreException.malformed('The EPUB cannot be read: $error');
  }
  cancellation.throwIfCancelled();
  final cover = inspection.cover;
  return BookMetadata(
    title: inspection.title,
    author: inspection.author,
    cover: cover == null ? null : await _thumbnailOffIsolate(cover),
  );
}

/// [coverThumbnail] on another isolate. A closure sends its whole context,
/// so this one is made where nothing else is in scope.
Future<Uint8List?> _thumbnailOffIsolate(Uint8List cover) =>
    Isolate.run(() => coverThumbnail(cover));

/// Scale a straight RGBA rendering ([width] × [height]) into a PNG
/// thumbnail, as [coverThumbnail] does for an encoded image.
Uint8List? coverThumbnailFromRgba(int width, int height, Uint8List pixels) {
  if (width <= 0 ||
      height <= 0 ||
      width * height > maxCoverSourcePixels ||
      pixels.length != width * height * 4) {
    return null;
  }
  return _thumbnail(
    image.Image.fromBytes(
      width: width,
      height: height,
      bytes: pixels.buffer,
      bytesOffset: pixels.offsetInBytes,
      numChannels: 4,
    ),
  );
}

/// Decode an encoded cover image and scale it into a PNG thumbnail.
///
/// Returns null for an image that cannot be decoded (including one whose
/// decoder throws), has more than [maxCoverSourcePixels] pixels, or encodes
/// larger than [maxCoverBytes]. A cover is optional, so a bad one never fails
/// the import.
Uint8List? coverThumbnail(Uint8List encoded) {
  final image.Image? decoded;
  try {
    final decoder = image.findDecoderForData(encoded);
    final info = decoder?.startDecode(encoded);
    if (decoder == null ||
        info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > maxCoverSourcePixels) {
      return null;
    }
    decoded = decoder.decode(encoded);
  } on image.ImageException {
    return null;
  } on RangeError {
    // Truncated image data indexes past its buffer.
    return null;
  }
  if (decoded == null) return null;
  return _thumbnail(decoded);
}

Uint8List? _thumbnail(image.Image decoded) {
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
