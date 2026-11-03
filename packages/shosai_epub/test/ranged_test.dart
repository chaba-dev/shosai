import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:test/test.dart';

import 'support/large_entries_fixture.dart';

/// A range reader over [bytes] that records what it was asked for.
final class _Ranges {
  _Ranges(this.bytes);

  final Uint8List bytes;
  final List<(int, int)> reads = [];

  int get bytesRead => reads.fold(0, (sum, read) => sum + read.$2 - read.$1);

  Future<Uint8List> call(int start, int end) async {
    reads.add((start, end));
    return Uint8List.sublistView(
      bytes,
      start,
      end > bytes.length ? bytes.length : end,
    );
  }
}

void main() {
  test('reads what an imported archive reports, from a few ranges', () async {
    for (final path in [
      '../../fixtures/sample.epub',
      '../../fixtures/epub-layout/rich-chapter.epub',
      '../../fixtures/epub-conformance/conformance.epub',
      '../../fixtures/epub-conformance/fonts.epub',
    ]) {
      final bytes = File(path).readAsBytesSync();
      final whole = inspectEpubBytes(bytes);
      final ranges = _Ranges(bytes);
      final ranged = await inspectEpubRanges(ranges.call, bytes.length);
      expect(ranged.title, whole.title, reason: path);
      expect(ranged.author, whole.author, reason: path);
      expect(ranged.coverPath, whole.coverPath, reason: path);
      expect(ranged.coverMediaType, whole.coverMediaType, reason: path);
      expect(ranged.cover, whole.cover, reason: path);
      // A small book is read once, from its end.
      expect(ranges.reads, hasLength(1), reason: path);
    }
  });

  test('a large book is not downloaded to read its cover', () async {
    final bytes = largeEntriesEpub(compressImage: true);
    final ranges = _Ranges(bytes);
    final inspection = await inspectEpubRanges(ranges.call, bytes.length);
    expect(inspection.title, 'Large entries');
    expect(inspection.cover, inspectEpubBytes(bytes).cover);
    // The 8 MiB chapter is never read.
    expect(ranges.bytesRead, lessThan(bytes.length - 8 * 1024 * 1024));
  });

  test('a cover over the image limit or the read budget is left out', () async {
    final cover = Uint8List(200 * 1024)..fillRange(0, 200 * 1024, 7);
    final bytes = _epub(
      manifest:
          '<item id="c" href="c.png" media-type="image/png" properties="cover-image"/>',
      files: {'OEBPS/c.png': cover},
      compression: CompressionType.none,
    );
    final full = await inspectEpubRanges(_Ranges(bytes).call, bytes.length);
    expect(full.cover, cover);

    final limited = await inspectEpubRanges(
      _Ranges(bytes).call,
      bytes.length,
      limits: const EpubLimits(maxImageBytes: 100 * 1024),
    );
    expect(limited.title, 'Ranged');
    expect(limited.cover, isNull);
    expect(limited.coverPath, isNull);

    final ranges = _Ranges(bytes);
    final budgeted = await inspectEpubRanges(
      ranges.call,
      bytes.length,
      maxReadBytes: 100 * 1024,
    );
    expect(budgeted.title, 'Ranged');
    expect(budgeted.cover, isNull);
    expect(ranges.bytesRead, lessThanOrEqualTo(100 * 1024));
  });

  test('the archive admission rules still apply', () async {
    // A declared size the payload does not inflate to.
    final bytes = _epub();
    _declareEntrySize(bytes, 'OEBPS/content.opf', 9000);
    await expectLater(
      inspectEpubRanges(_Ranges(bytes).call, bytes.length),
      throwsA(isA<EpubFormatError>()),
    );

    // More entries than the limit allows.
    await expectLater(
      inspectEpubRanges(
        _Ranges(_epub()).call,
        _epub().length,
        limits: const EpubLimits(maxArchiveEntries: 2),
      ),
      throwsA(
        isA<EpubLimitError>().having((e) => e.kind, 'kind', 'archive entries'),
      ),
    );

    // A package document over the metadata limit.
    await expectLater(
      inspectEpubRanges(
        _Ranges(_epub()).call,
        _epub().length,
        limits: const EpubLimits(maxMetadataBytes: 64),
      ),
      throwsA(
        isA<EpubLimitError>().having((e) => e.kind, 'kind', 'metadata bytes'),
      ),
    );

    // A directory that is not a ZIP's.
    final junk = Uint8List(4096);
    await expectLater(
      inspectEpubRanges(_Ranges(junk).call, junk.length),
      throwsA(isA<EpubFormatError>()),
    );
  });

  test('a file shorter than it was listed fails instead of guessing', () async {
    final bytes = _epub();
    await expectLater(
      inspectEpubRanges(_Ranges(bytes).call, bytes.length + 100),
      throwsA(isA<EpubFormatError>()),
    );
  });
}

Uint8List _epub({
  String manifest = '',
  Map<String, Uint8List> files = const {},
  CompressionType compression = CompressionType.deflate,
}) {
  final archive = Archive();
  void add(String name, List<int> bytes) => archive.addFile(
    ArchiveFile(name, bytes.length, bytes)..compression = compression,
  );
  add('mimetype', 'application/epub+zip'.codeUnits);
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
        .codeUnits,
  );
  add(
    'OEBPS/content.opf',
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0"><metadata><dc:title>Ranged</dc:title><dc:creator>A. Writer</dc:creator></metadata><manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>$manifest</manifest><spine><itemref idref="ch1"/></spine></package>'
        .codeUnits,
  );
  add(
    'OEBPS/ch1.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Hi</p></body></html>'
        .codeUnits,
  );
  files.forEach(add);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Change both size declarations, leaving compressed payload and CRC intact.
void _declareEntrySize(Uint8List bytes, String name, int size) {
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  final data = ByteData.sublistView(bytes);
  var offset = directory.centralDirectoryOffset;
  for (final header in directory.fileHeaders) {
    if (header.filename == name) {
      data.setUint32(offset + 24, size, Endian.little);
      data.setUint32(header.localHeaderOffset + 22, size, Endian.little);
      return;
    }
    offset +=
        46 +
        data.getUint16(offset + 28, Endian.little) +
        data.getUint16(offset + 30, Endian.little) +
        data.getUint16(offset + 32, Endian.little);
  }
  throw StateError('fixture entry not found: $name');
}
