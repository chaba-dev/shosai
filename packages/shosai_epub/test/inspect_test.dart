import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:test/test.dart';

import 'support/large_entries_fixture.dart';

void main() {
  test('opens and inspects a book with image and XHTML entries over 8 MiB', () {
    final bytes = largeEntriesEpub(compressImage: true);
    final entries = ZipDecoder().decodeBytes(bytes);
    expect(entries.find('chapter.xhtml')!.size, greaterThan(8 * 1024 * 1024));
    expect(entries.find('landscape.png')!.size, greaterThan(8 * 1024 * 1024));

    final book = openEpubBytes(bytes);
    expect(
      book.chapters.single.canonicalText,
      startsWith('Large entries, readable book\n'),
    );
    expect(
      book.chapters.single.canonicalText,
      endsWith('The end of the large XHTML part is readable too.\n'),
    );
    final art = book.chapters.single.blocks.whereType<EpubImage>().single;
    expect(art.intrinsicSize?.width, 1800);
    expect(art.intrinsicSize?.height, 1600);
    final inspection = inspectEpubBytes(bytes);
    expect(inspection.title, 'Large entries');
    expect(inspection.cover, book.resources['landscape.png']!.bytes);
  });

  test(
    'resource byte ceilings depend on manifest type, not just the ZIP cap',
    () {
      for (final (path, mediaType, limits, kind) in [
        ('art', 'image/png', const EpubLimits(maxImageBytes: 8), 'image bytes'),
        (
          'face.ttf',
          'application/octet-stream',
          const EpubLimits(maxFontBytes: 8),
          'font bytes',
        ),
        (
          'style',
          'text/css',
          const EpubLimits(maxStyleSheetBytes: 8),
          'stylesheet bytes',
        ),
        (
          'vector',
          'image/svg+xml',
          const EpubLimits(maxMetadataBytes: 1024),
          'metadata bytes',
        ),
      ]) {
        final ceiling = mediaType == 'image/svg+xml' ? 1024 : 8;
        Uint8List book(int size) => _epub(
          manifest: '<item id="r" href="$path" media-type="$mediaType"/>',
          files: {'OEBPS/$path': Uint8List(size)..fillRange(0, size, 32)},
        );
        expect(
          () => openEpubBytes(book(ceiling), limits: limits),
          returnsNormally,
        );
        expect(
          () => openEpubBytes(book(ceiling + 1), limits: limits),
          throwsA(isA<EpubLimitError>().having((e) => e.kind, 'kind', kind)),
        );
      }
    },
  );

  test(
    'chapter, metadata and aggregate limits include their exact boundary',
    () {
      final bytes = _epub();
      final archive = ZipDecoder().decodeBytes(bytes);
      final chapterSize = archive.find('OEBPS/ch1.xhtml')!.size;
      final metadataSize = archive.find('OEBPS/content.opf')!.size;
      final total = archive.files.fold<int>(0, (sum, file) => sum + file.size);
      for (final (accepted, rejected, kind) in [
        (
          EpubLimits(maxChapterBytes: chapterSize),
          EpubLimits(maxChapterBytes: chapterSize - 1),
          'chapter bytes',
        ),
        (
          EpubLimits(maxMetadataBytes: metadataSize),
          EpubLimits(maxMetadataBytes: metadataSize - 1),
          'metadata bytes',
        ),
        (
          EpubLimits(maxTotalUncompressedBytes: total),
          EpubLimits(maxTotalUncompressedBytes: total - 1),
          'archive uncompressed bytes',
        ),
        (
          EpubLimits(maxEntryBytes: metadataSize),
          EpubLimits(maxEntryBytes: metadataSize - 1),
          'archive entry bytes',
        ),
      ]) {
        expect(() => openEpubBytes(bytes, limits: accepted), returnsNormally);
        expect(
          () => openEpubBytes(bytes, limits: rejected),
          throwsA(isA<EpubLimitError>().having((e) => e.kind, 'kind', kind)),
        );
      }
      expect(
        () => inspectEpubBytes(
          bytes,
          limits: EpubLimits(maxTotalUncompressedBytes: total - 1),
        ),
        throwsA(isA<EpubLimitError>()),
      );
    },
  );

  test('high aggregate expansion is refused even below the byte budget', () {
    final bytes = _epub(files: {'padding': Uint8List(4 * 1024 * 1024)});
    for (final read in [openEpubBytes, inspectEpubBytes]) {
      expect(
        () => read(bytes),
        throwsA(
          isA<EpubLimitError>().having(
            (e) => e.kind,
            'kind',
            'archive compression ratio',
          ),
        ),
      );
    }
  });

  test('inflation cannot exceed forged ZIP sizes, stored or deflated', () {
    for (final compression in [CompressionType.none, CompressionType.deflate]) {
      final bytes = _epub(
        compression: compression,
        manifest:
            '<item id="r" href="art" media-type="image/png" properties="cover-image"/>',
        files: {'OEBPS/art': Uint8List(64 * 1024)},
      );
      _declareEntrySize(bytes, 'OEBPS/art', 8);
      for (final read in [openEpubBytes, inspectEpubBytes]) {
        expect(() => read(bytes), throwsA(isA<EpubFormatError>()));
      }
    }
  });

  test('an entry shorter than its declared size is not silently accepted', () {
    final bytes = _epub();
    final size = ZipDecoder().decodeBytes(bytes).find('OEBPS/ch1.xhtml')!.size;
    _declareEntrySize(bytes, 'OEBPS/ch1.xhtml', size + 1);
    expect(() => openEpubBytes(bytes), throwsA(isA<EpubFormatError>()));
  });

  test('reads title, author and the EPUB 3 cover-image item', () {
    final inspection = inspectEpubBytes(
      _epub(
        metadata:
            '<dc:title> Sample Book </dc:title><dc:creator>Test Author</dc:creator>',
        manifest:
            '<item id="c" href="images/cover.png" media-type="image/png" properties="cover-image"/>',
        files: {'OEBPS/images/cover.png': _png},
      ),
    );

    expect(inspection.title, 'Sample Book');
    expect(inspection.author, 'Test Author');
    expect(inspection.coverPath, 'OEBPS/images/cover.png');
    expect(inspection.coverMediaType, 'image/png');
    expect(inspection.cover, _png);
  });

  test('falls back to the EPUB 2 cover meta', () {
    final inspection = inspectEpubBytes(
      _epub(
        metadata: '<meta name="cover" content="art"/>',
        manifest: '<item id="art" href="art.jpg" media-type="image/jpeg"/>',
        files: {'OEBPS/art.jpg': _png},
      ),
    );

    expect(inspection.title, isNull);
    expect(inspection.author, isNull);
    expect(inspection.coverPath, 'OEBPS/art.jpg');
  });

  test('ignores a cover that is not an image or exceeds the image limit', () {
    final notImage = inspectEpubBytes(
      _epub(
        metadata: '<meta name="cover" content="c"/>',
        manifest:
            '<item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>',
        files: {'OEBPS/c.xhtml': Uint8List.fromList('<html/>'.codeUnits)},
      ),
    );
    final tooLarge = inspectEpubBytes(
      _epub(
        metadata: '<meta name="cover" content="c"/>',
        manifest: '<item id="c" href="c.png" media-type="image/png"/>',
        files: {'OEBPS/c.png': _png},
      ),
      limits: const EpubLimits(maxImageBytes: 4),
    );
    final tooLargeSvg = inspectEpubBytes(
      _epub(
        manifest:
            '<item id="c" href="art.svg" media-type="image/svg+xml" properties="cover-image"/>',
        files: {'OEBPS/art.svg': Uint8List(1025)},
      ),
      limits: const EpubLimits(maxMetadataBytes: 1024),
    );

    expect(notImage.cover, isNull);
    expect(tooLarge.cover, isNull);
    expect(tooLargeSvg.cover, isNull);
  });

  test('reads the spine page progression, left to right by default', () {
    EpubDirection progression(String attributes) =>
        openEpubBytes(_epub(spineAttributes: attributes)).pageProgression;
    expect(progression(''), EpubDirection.ltr);
    expect(
      progression(' page-progression-direction="default"'),
      EpubDirection.ltr,
    );
    expect(progression(' page-progression-direction="ltr"'), EpubDirection.ltr);
    expect(progression(' page-progression-direction="rtl"'), EpubDirection.rtl);
  });

  test('applies archive admission before reading metadata', () {
    expect(
      () => inspectEpubBytes(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<EpubFormatError>()),
    );
    expect(
      () => inspectEpubBytes(
        _epub(),
        limits: const EpubLimits(maxArchiveEntries: 1),
      ),
      throwsA(isA<EpubLimitError>()),
    );
  });
}

final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

Uint8List _epub({
  String metadata = '',
  String manifest = '',
  String spineAttributes = '',
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
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0"><metadata>$metadata</metadata><manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>$manifest</manifest><spine$spineAttributes><itemref idref="ch1"/></spine></package>'
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
