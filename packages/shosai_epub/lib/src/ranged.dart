/// EPUB package metadata and cover read through byte ranges, for a file that
/// is not downloaded.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'archive.dart';
import 'limits.dart';

/// Returns the bytes of a file from [start] up to [end] (exclusive): the
/// whole range, or fewer only where the file ends first.
typedef EpubRangeReader = Future<Uint8List> Function(int start, int end);

/// What [inspectEpubRanges] reads from one file, in all, unless told
/// otherwise.
const defaultEpubRangeReadBytes = 16 * 1024 * 1024;

/// The bytes a ZIP local header may carry beyond its name, read with the
/// header so a typical entry costs one range.
const _localExtraAllowance = 1024;

/// Read an EPUB's title, author and cover as [inspectEpubBytes] does, from a
/// [size]-byte file that only [read] can reach.
///
/// Only the end of the archive, its central directory, the container, the
/// package document and the cover image are read, and never more than
/// [maxReadBytes] in all. The entries read pass the same rules as an
/// imported archive's: entry count, duplicate names, declared sizes,
/// compression ratio and encoding. A cover that would exceed the limits or
/// the read budget is left out rather than failing the inspection. ZIP64
/// archives are not read through ranges.
Future<EpubInspection> inspectEpubRanges(
  EpubRangeReader read,
  int size, {
  EpubLimits limits = const EpubLimits(),
  int maxReadBytes = defaultEpubRangeReadBytes,
}) async {
  var budget = maxReadBytes;
  // The end of the archive is read first; whatever lies in it is not read
  // again.
  Uint8List? tail;
  var tailStart = size;
  Future<Uint8List> fetch(int start, int end) async {
    if (tail case final tail? when start >= tailStart && end <= size) {
      return Uint8List.sublistView(tail, start - tailStart, end - tailStart);
    }
    final length = end - start;
    if (length > budget) {
      throw EpubLimitError('range read bytes', maxReadBytes, length);
    }
    budget -= length;
    final bytes = await read(start, end);
    if (bytes.length != length) {
      throw const EpubFormatError('EPUB archive ended early');
    }
    return bytes;
  }

  if (size < 22) throw const EpubFormatError('EPUB archive is too short');
  final start = size - 22 - 0xFFFF < 0 ? 0 : size - 22 - 0xFFFF;
  final ending = tail = await fetch(start, size);
  tailStart = start;
  final eocd = _endOfCentralDirectory(ending);
  if (eocd < 0) {
    throw const EpubFormatError('ZIP end-of-central-directory not found');
  }
  final entryCount = _u16(ending, eocd + 10);
  final directorySize = _u32(ending, eocd + 12);
  final directoryOffset = _u32(ending, eocd + 16);
  if (entryCount == 0xFFFF ||
      directorySize == 0xFFFFFFFF ||
      directoryOffset == 0xFFFFFFFF) {
    throw const EpubFormatError('ZIP64 archives are not read through ranges');
  }
  if (entryCount > limits.maxArchiveEntries) {
    throw EpubLimitError(
      'archive entries',
      limits.maxArchiveEntries,
      entryCount,
    );
  }
  if (directoryOffset + directorySize > tailStart + eocd) {
    throw const EpubFormatError('ZIP central directory is out of range');
  }
  final directory = await fetch(
    directoryOffset,
    directoryOffset + directorySize,
  );
  final entries = _centralDirectory(directory, entryCount);

  Future<Uint8List> entry(String name, int limit, String kind) async {
    final header = entries[name];
    if (header == null) {
      throw EpubFormatError('EPUB archive has no $name');
    }
    header.admit(limits, limit, kind);
    final localStart = header.localOffset;
    final guess =
        localStart +
        30 +
        header.name.length +
        _localExtraAllowance +
        header.compressedSize;
    var local = await fetch(localStart, guess > size ? size : guess);
    if (local.length < 30 || _u32(local, 0) != 0x04034B50) {
      throw EpubFormatError('ZIP local header is missing: $name');
    }
    final dataStart = 30 + _u16(local, 26) + _u16(local, 28);
    final dataEnd = dataStart + header.compressedSize;
    if (localStart + dataEnd > size) {
      throw EpubFormatError('ZIP entry is out of range: $name');
    }
    if (dataEnd > local.length) {
      local = Uint8List.fromList([
        ...local,
        ...await fetch(localStart + local.length, localStart + dataEnd),
      ]);
    }
    return header.inflate(Uint8List.sublistView(local, dataStart, dataEnd));
  }

  final opfPath = epubPackagePath(
    await entry(
      'META-INF/container.xml',
      limits.maxMetadataBytes,
      'metadata bytes',
    ),
  );
  final package = inspectEpubPackage(
    await entry(opfPath, limits.maxMetadataBytes, 'metadata bytes'),
    opfPath,
  );
  Uint8List? cover;
  final coverHeader = switch (package.coverPath) {
    final path? => entries[path],
    null => null,
  };
  if (coverHeader != null &&
      coverHeader.compressedSize +
              coverHeader.name.length +
              30 +
              _localExtraAllowance <=
          budget &&
      (package.coverMediaType != 'image/svg+xml' ||
          coverHeader.uncompressedSize <= limits.maxMetadataBytes)) {
    try {
      cover = await entry(
        package.coverPath!,
        limits.maxImageBytes,
        'image bytes',
      );
    } on EpubLimitError {
      cover = null;
    }
  }
  return EpubInspection(
    title: package.title,
    author: package.author,
    contributors: package.contributors,
    identifiers: package.identifiers,
    language: package.language,
    edition: package.edition,
    volume: package.volume,
    coverPath: cover == null ? null : package.coverPath,
    coverMediaType: cover == null ? null : package.coverMediaType,
    cover: cover,
  );
}

/// One central-directory record: what is needed to fetch and inflate its
/// entry alone.
final class _Header {
  _Header(this.record, this.name);

  /// The record's fixed 46 bytes.
  final Uint8List record;

  /// The entry name's raw bytes.
  final Uint8List name;

  int get flags => _u16(record, 8);
  int get method => _u16(record, 10);
  int get compressedSize => _u32(record, 20);
  int get uncompressedSize => _u32(record, 24);
  int get localOffset => _u32(record, 42);

  void admit(EpubLimits limits, int limit, String kind) {
    final label = utf8.decode(name, allowMalformed: true);
    if (method != 0 && method != 8 || flags & 1 != 0) {
      throw EpubFormatError('unsupported EPUB ZIP encoding: $label');
    }
    if (uncompressedSize > limits.maxEntryBytes) {
      throw EpubLimitError(
        'archive entry bytes',
        limits.maxEntryBytes,
        uncompressedSize,
      );
    }
    if (uncompressedSize > limit) {
      throw EpubLimitError(kind, limit, uncompressedSize);
    }
    if (compressedSize > 0 &&
        uncompressedSize / compressedSize > limits.maxCompressionRatio) {
      throw EpubLimitError(
        'compression ratio',
        limits.maxCompressionRatio,
        uncompressedSize ~/ compressedSize,
      );
    }
  }

  /// Inflate [data] through the same ZIP reader an imported archive uses,
  /// by wrapping it in a one-entry archive: its output is bounded by the
  /// declared size, and its checksum is verified.
  Uint8List inflate(Uint8List data) {
    final archive = BytesBuilder(copy: false)
      ..add(_local())
      ..add(data);
    final directoryOffset = archive.length;
    archive
      ..add(_central())
      ..add(_end(46 + name.length, directoryOffset));
    final zip = ZipDirectory();
    try {
      zip.read(InputMemoryStream(archive.takeBytes()));
      final file = zip.fileHeaders.single.file!;
      final output = OutputMemoryStream(size: uncompressedSize);
      file.decompress(output);
      if (output.length != uncompressedSize) {
        throw const EpubFormatError('incorrect EPUB ZIP entry size');
      }
      return output.getBytes();
    } on EpubFormatError {
      rethrow;
    } catch (error) {
      throw EpubFormatError('failed to read EPUB entry: $error');
    }
  }

  /// A local header from this record's values, without a data descriptor.
  Uint8List _local() {
    final bytes = Uint8List(30 + name.length);
    final view = ByteData.sublistView(bytes);
    view
      ..setUint32(0, 0x04034B50, Endian.little)
      ..setUint16(4, _u16(record, 6), Endian.little)
      ..setUint16(6, flags & ~0x8, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint32(10, _u32(record, 12), Endian.little)
      ..setUint32(14, _u32(record, 16), Endian.little)
      ..setUint32(18, compressedSize, Endian.little)
      ..setUint32(22, uncompressedSize, Endian.little)
      ..setUint16(26, name.length, Endian.little)
      ..setUint16(28, 0, Endian.little);
    bytes.setRange(30, bytes.length, name);
    return bytes;
  }

  /// This record pointing at offset zero, without extra fields or comment.
  Uint8List _central() {
    final bytes = Uint8List(46 + name.length)..setRange(0, 46, record);
    final view = ByteData.sublistView(bytes);
    view
      ..setUint16(8, flags & ~0x8, Endian.little)
      ..setUint16(30, 0, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint32(42, 0, Endian.little);
    bytes.setRange(46, bytes.length, name);
    return bytes;
  }

  static Uint8List _end(int directorySize, int directoryOffset) {
    final bytes = Uint8List(22);
    ByteData.sublistView(bytes)
      ..setUint32(0, 0x06054B50, Endian.little)
      ..setUint16(8, 1, Endian.little)
      ..setUint16(10, 1, Endian.little)
      ..setUint32(12, directorySize, Endian.little)
      ..setUint32(16, directoryOffset, Endian.little);
    return bytes;
  }
}

/// The directory's records by name; a repeated name fails, as it does for an
/// imported archive.
Map<String, _Header> _centralDirectory(Uint8List bytes, int count) {
  final entries = <String, _Header>{};
  var offset = 0;
  for (var index = 0; index < count; index++) {
    if (offset + 46 > bytes.length || _u32(bytes, offset) != 0x02014B50) {
      throw const EpubFormatError('ZIP central directory ended early');
    }
    final nameLength = _u16(bytes, offset + 28);
    final next =
        offset +
        46 +
        nameLength +
        _u16(bytes, offset + 30) +
        _u16(bytes, offset + 32);
    if (next > bytes.length) {
      throw const EpubFormatError('ZIP central directory is out of range');
    }
    final name = Uint8List.fromList(
      bytes.sublist(offset + 46, offset + 46 + nameLength),
    );
    final key = utf8.decode(name, allowMalformed: true);
    if (entries.containsKey(key)) {
      throw EpubFormatError('duplicate EPUB archive entry: $key');
    }
    entries[key] = _Header(
      Uint8List.fromList(bytes.sublist(offset, offset + 46)),
      name,
    );
    offset = next;
  }
  return entries;
}

int _endOfCentralDirectory(Uint8List bytes) {
  for (var offset = bytes.length - 22; offset >= 0; offset--) {
    if (_u32(bytes, offset) == 0x06054B50) return offset;
  }
  return -1;
}

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);
