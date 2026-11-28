/// A comic archive read in parts: its central directory once, then each
/// page's bytes when that page is needed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

import 'comic_info.dart';
import 'image_size.dart';
import 'limits.dart';
import 'natural_order.dart';

/// Random access to an archive's bytes.
abstract interface class CbzSource {
  /// The archive's size in bytes.
  int get size;

  /// Copy up to [length] bytes at [position] into [buffer] and return how
  /// many were copied: fewer only at the end of the archive.
  Future<int> read(Uint8List buffer, int position, int length);
}

/// An archive held in memory.
final class CbzBytesSource implements CbzSource {
  CbzBytesSource(this._bytes);

  final Uint8List _bytes;

  @override
  int get size => _bytes.length;

  @override
  Future<int> read(Uint8List buffer, int position, int length) async {
    final end = position + length > _bytes.length
        ? _bytes.length
        : position + length;
    if (end <= position) return 0;
    buffer.setRange(0, end - position, _bytes, position);
    return end - position;
  }
}

/// An archive read from an open file, which the caller closes.
final class CbzFileSource implements CbzSource {
  CbzFileSource(this._file, this.size);

  final RandomAccessFile _file;

  @override
  final int size;

  Future<void> _pending = Future.value();

  @override
  Future<int> read(Uint8List buffer, int position, int length) {
    // One file position serves every read, so reads run one at a time.
    final result = _pending.then((_) async {
      await _file.setPosition(position);
      return _file.readInto(buffer, 0, length);
    });
    _pending = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// One image page of an archive.
final class CbzPage {
  const CbzPage._(this.path, this._entry);

  /// The page's path inside the archive.
  final String path;
  final _Entry _entry;

  /// The page's encoded size in bytes.
  int get byteLength => _entry.uncompressedSize;
}

/// An opened comic archive: its pages in reading order and its metadata.
final class CbzArchive {
  CbzArchive._(this._source, this.pages, this._comicInfo, this.limits);

  final CbzSource _source;
  final _Entry? _comicInfo;
  final CbzLimits limits;

  /// The archive's image pages, in natural path order.
  final List<CbzPage> pages;

  final Map<int, CbzImageSize> _sizes = {};

  /// Index [source]'s central directory, checking every limit that can be
  /// checked without decompressing. Reads nothing but the directory.
  static Future<CbzArchive> open(
    CbzSource source, {
    CbzLimits limits = const CbzLimits(),
  }) async {
    if (source.size > limits.maxArchiveBytes) {
      throw CbzLimitError(
        'The comic archive is larger than ${limits.maxArchiveBytes} bytes.',
      );
    }
    final directory = await _readDirectory(source, limits);
    final names = <String>{};
    final images = <(String, _Entry)>[];
    _Entry? comicInfo;
    var comicInfoDepth = 0;
    var total = 0;
    for (final entry in directory) {
      final name = entry.name.replaceAll(r'\', '/');
      if (!names.add(name)) {
        throw CbzFormatError('The archive lists $name twice.');
      }
      if (name.endsWith('/')) continue;
      final segments = name.split('/');
      if (segments.any(
        (segment) =>
            segment == '__MACOSX' || segment.startsWith('.') || segment == '..',
      )) {
        continue;
      }
      final basename = segments.last.toLowerCase();
      final isComicInfo = basename == 'comicinfo.xml';
      final extension = basename.contains('.')
          ? basename.substring(basename.lastIndexOf('.') + 1)
          : '';
      final isImage = _imageExtensions.contains(extension);
      if (!isComicInfo && !isImage) continue;
      _admitEntry(entry, source.size, limits);
      total += entry.uncompressedSize;
      if (total > limits.maxTotalUncompressedBytes) {
        throw CbzLimitError(
          'The comic archive expands past '
          '${limits.maxTotalUncompressedBytes} bytes.',
        );
      }
      if (isComicInfo) {
        // The shallowest ComicInfo.xml describes the archive.
        if (comicInfo == null || segments.length < comicInfoDepth) {
          comicInfo = entry;
          comicInfoDepth = segments.length;
        }
      } else {
        images.add((name, entry));
      }
    }
    if (images.isEmpty) {
      throw const CbzFormatError('The comic archive contains no images.');
    }
    images.sort((a, b) => compareNatural(a.$1, b.$1));
    return CbzArchive._(
      source,
      List.unmodifiable([
        for (final (name, entry) in images) CbzPage._(name, entry),
      ]),
      comicInfo,
      limits,
    );
  }

  /// The archive's ComicInfo.xml, or empty metadata when it has none or it
  /// is too large or unreadable.
  Future<CbzComicInfo> comicInfo() async {
    final entry = _comicInfo;
    if (entry == null || entry.uncompressedSize > limits.maxComicInfoBytes) {
      return const CbzComicInfo();
    }
    try {
      return parseComicInfo(await _readEntry(entry));
    } on CbzFormatError {
      return const CbzComicInfo();
    }
  }

  /// The encoded bytes of page [index].
  Future<Uint8List> pageBytes(int index) => _readEntry(pages[index]._entry);

  /// Page [index]'s size in pixels, read from its image header.
  Future<CbzImageSize> pageSize(int index) async {
    if (_sizes[index] case final size?) return size;
    final entry = pages[index]._entry;
    var size = imageSizeFromHeader(
      await _readEntry(entry, prefix: _probeBytes),
    );
    if (size == null && entry.uncompressedSize > _probeBytes) {
      // A JPEG whose frame header follows large metadata segments.
      size = imageSizeFromHeader(await _readEntry(entry));
    }
    if (size == null) {
      throw CbzFormatError('Page ${index + 1} is not a readable image.');
    }
    return _sizes[index] = size;
  }

  /// Whether page [index] is small enough to decode.
  bool decodable(CbzImageSize size) =>
      size.width <= limits.maxImageDimension &&
      size.height <= limits.maxImageDimension &&
      size.width * size.height <= limits.maxImagePixels;

  Future<Uint8List> _readEntry(_Entry entry, {int? prefix}) async {
    final header = await _readExact(_source, entry.localOffset, 30);
    if (_u32(header, 0) != 0x04034b50) {
      throw CbzFormatError('The archive entry ${entry.name} is damaged.');
    }
    final dataOffset =
        entry.localOffset + 30 + _u16(header, 26) + _u16(header, 28);
    if (dataOffset + entry.compressedSize > _source.size) {
      throw CbzFormatError('The archive entry ${entry.name} is truncated.');
    }
    final wanted = prefix == null || prefix >= entry.uncompressedSize
        ? null
        : prefix;
    if (entry.method == 0) {
      final bytes = await _readExact(
        _source,
        dataOffset,
        wanted ?? entry.compressedSize,
      );
      if (wanted == null) _checkCrc(entry, bytes);
      return bytes;
    }
    return _inflate(entry, dataOffset, wanted);
  }

  /// Inflate [entry]'s data in chunks, stopping once [prefix] bytes are out,
  /// and never holding more than its declared size.
  Future<Uint8List> _inflate(_Entry entry, int dataOffset, int? prefix) async {
    final filter = RawZLibFilter.inflateFilter(raw: true);
    final output = BytesBuilder(copy: false);
    final declared = entry.uncompressedSize;
    void take(List<int>? chunk) {
      if (chunk == null) return;
      output.add(chunk);
      if (output.length > declared) {
        throw CbzFormatError(
          'The archive entry ${entry.name} is larger than it declares.',
        );
      }
    }

    var position = 0;
    try {
      while (position < entry.compressedSize &&
          (prefix == null || output.length < prefix)) {
        final length = entry.compressedSize - position < _chunkBytes
            ? entry.compressedSize - position
            : _chunkBytes;
        final chunk = await _readExact(_source, dataOffset + position, length);
        position += length;
        filter.process(chunk, 0, chunk.length);
        for (List<int>? out; (out = filter.processed(flush: false)) != null;) {
          take(out);
        }
      }
      if (prefix == null) {
        for (List<int>? out; (out = filter.processed(end: true)) != null;) {
          take(out);
        }
      }
    } on FormatException catch (error) {
      throw CbzFormatError(
        'The archive entry ${entry.name} cannot be inflated: ${error.message}',
      );
    } on FileSystemException catch (error) {
      throw CbzFormatError(
        'The archive entry ${entry.name} cannot be inflated: ${error.message}',
      );
    }
    final bytes = output.takeBytes();
    if (prefix != null) return bytes;
    if (bytes.length != declared) {
      throw CbzFormatError(
        'The archive entry ${entry.name} is shorter than it declares.',
      );
    }
    _checkCrc(entry, bytes);
    return bytes;
  }
}

const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
const _probeBytes = 64 * 1024;
const _chunkBytes = 256 * 1024;

final class _Entry {
  const _Entry({
    required this.name,
    required this.flags,
    required this.method,
    required this.crc,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
  });

  final String name;
  final int flags;
  final int method;
  final int crc;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
}

void _admitEntry(_Entry entry, int archiveSize, CbzLimits limits) {
  if (entry.flags & 1 != 0) throw const CbzProtectedError();
  if (entry.method != 0 && entry.method != 8) {
    throw CbzFormatError(
      'The archive entry ${entry.name} uses an unsupported compression '
      'method (${entry.method}).',
    );
  }
  if (entry.uncompressedSize > limits.maxEntryBytes) {
    throw CbzLimitError(
      'The archive entry ${entry.name} is larger than '
      '${limits.maxEntryBytes} bytes.',
    );
  }
  if (entry.method == 0 && entry.compressedSize != entry.uncompressedSize) {
    throw CbzFormatError(
      'The stored archive entry ${entry.name} has inconsistent sizes.',
    );
  }
  if (entry.method == 8 &&
      entry.uncompressedSize >
          (entry.compressedSize < 1 ? 1 : entry.compressedSize) *
              limits.maxCompressionRatio) {
    throw CbzLimitError(
      'The archive entry ${entry.name} exceeds the compression ratio limit.',
    );
  }
  if (entry.localOffset + 30 + entry.compressedSize > archiveSize) {
    throw CbzFormatError('The archive entry ${entry.name} is truncated.');
  }
}

void _checkCrc(_Entry entry, Uint8List bytes) {
  if (getCrc32(bytes) != entry.crc) {
    throw CbzFormatError('The archive entry ${entry.name} is damaged.');
  }
}

Future<Uint8List> _readExact(CbzSource source, int position, int length) async {
  final buffer = Uint8List(length);
  var copied = 0;
  while (copied < length) {
    final view = Uint8List.sublistView(buffer, copied);
    final read = await source.read(view, position + copied, length - copied);
    if (read <= 0) {
      throw const CbzFormatError('The comic archive ends early.');
    }
    copied += read;
  }
  return buffer;
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _u64(Uint8List b, int o) => _u32(b, o) + _u32(b, o + 4) * 0x100000000;

/// The central directory's entries, read from the end of [source].
Future<List<_Entry>> _readDirectory(CbzSource source, CbzLimits limits) async {
  if (source.size < 22) {
    throw const CbzFormatError('The file is not a ZIP archive.');
  }
  final tailLength = source.size < 22 + 0xFFFF + 20
      ? source.size
      : 22 + 0xFFFF + 20;
  final tailStart = source.size - tailLength;
  final tail = await _readExact(source, tailStart, tailLength);
  var eocd = -1;
  for (var offset = tail.length - 22; offset >= 0; offset--) {
    if (_u32(tail, offset) == 0x06054b50) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0) throw const CbzFormatError('The file is not a ZIP archive.');
  var count = _u16(tail, eocd + 10);
  var directorySize = _u32(tail, eocd + 12);
  var directoryOffset = _u32(tail, eocd + 16);
  if (count == 0xFFFF ||
      directorySize == 0xFFFFFFFF ||
      directoryOffset == 0xFFFFFFFF) {
    final locator = eocd - 20;
    if (locator < 0 || _u32(tail, locator) != 0x07064b50) {
      throw const CbzFormatError('The ZIP64 directory has no locator.');
    }
    final recordOffset = _u64(tail, locator + 8);
    if (recordOffset + 56 > source.size) {
      throw const CbzFormatError('The ZIP64 directory is out of range.');
    }
    final record = await _readExact(source, recordOffset, 56);
    if (_u32(record, 0) != 0x06064b50) {
      throw const CbzFormatError('The ZIP64 directory is damaged.');
    }
    count = _u64(record, 32);
    directorySize = _u64(record, 40);
    directoryOffset = _u64(record, 48);
  }
  if (count > limits.maxEntries) {
    throw CbzLimitError(
      'The comic archive has more than ${limits.maxEntries} entries.',
    );
  }
  if (directorySize > limits.maxDirectoryBytes) {
    throw CbzLimitError(
      'The comic archive directory is larger than '
      '${limits.maxDirectoryBytes} bytes.',
    );
  }
  if (directoryOffset + directorySize > source.size) {
    throw const CbzFormatError('The ZIP directory is out of range.');
  }
  final bytes = await _readExact(source, directoryOffset, directorySize);
  final entries = <_Entry>[];
  var offset = 0;
  for (var index = 0; index < count; index++) {
    if (offset + 46 > bytes.length || _u32(bytes, offset) != 0x02014b50) {
      throw const CbzFormatError('The ZIP directory ends early.');
    }
    final flags = _u16(bytes, offset + 8);
    final nameLength = _u16(bytes, offset + 28);
    final extraLength = _u16(bytes, offset + 30);
    final commentLength = _u16(bytes, offset + 32);
    final nameStart = offset + 46;
    final extraStart = nameStart + nameLength;
    final next = extraStart + extraLength + commentLength;
    if (next > bytes.length) {
      throw const CbzFormatError('The ZIP directory ends early.');
    }
    var uncompressed = _u32(bytes, offset + 24);
    var compressed = _u32(bytes, offset + 20);
    var localOffset = _u32(bytes, offset + 42);
    // ZIP64 sizes and offset, in that order, for each field that overflowed.
    var extra = extraStart;
    while (extra + 4 <= extraStart + extraLength) {
      final id = _u16(bytes, extra);
      final size = _u16(bytes, extra + 2);
      if (id == 0x0001) {
        var field = extra + 4;
        int take(int value) {
          if (value != 0xFFFFFFFF) return value;
          if (field + 8 > extra + 4 + size) {
            throw const CbzFormatError('The ZIP64 entry fields are damaged.');
          }
          final wide = _u64(bytes, field);
          field += 8;
          return wide;
        }

        uncompressed = take(uncompressed);
        compressed = take(compressed);
        localOffset = take(localOffset);
      }
      extra += 4 + size;
    }
    entries.add(
      _Entry(
        name: utf8.decode(
          Uint8List.sublistView(bytes, nameStart, extraStart),
          allowMalformed: true,
        ),
        flags: flags,
        method: _u16(bytes, offset + 10),
        crc: _u32(bytes, offset + 16),
        compressedSize: compressed,
        uncompressedSize: uncompressed,
        localOffset: localOffset,
      ),
    );
    offset = next;
  }
  return entries;
}
