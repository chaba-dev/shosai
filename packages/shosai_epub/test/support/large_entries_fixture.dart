import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;

/// Generated, original-content EPUB with both an image and XHTML over 8 MiB.
/// Stored ZIP entries deliberately keep the fixture below the bomb ratio.
/// Generate a copy for manual app checks with:
/// dart run test/support/large_entries_fixture.dart /tmp/large-entries.epub
Uint8List largeEntriesEpub({bool compressImage = false}) {
  final illustration = image.Image(width: 1800, height: 1600);
  image.fill(illustration, color: image.ColorRgb8(194, 220, 227));
  image.fillCircle(
    illustration,
    x: 1320,
    y: 440,
    radius: 180,
    color: image.ColorRgb8(242, 192, 106),
  );
  image.fillRect(
    illustration,
    x1: 0,
    y1: 1000,
    x2: 1799,
    y2: 1599,
    color: image.ColorRgb8(77, 113, 107),
  );
  final png = image.encodePng(illustration, level: 0);
  final chapter =
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
      '<h1>Large entries, readable book</h1>'
      '<p>This chapter and its illustration each exceed 8 MiB.</p>'
      '<!--${'Source markup padding. ' * 420000}-->'
      '<img src="landscape.png" alt="Sun above a quiet landscape"/>'
      '<p id="tail">The end of the large XHTML part is readable too.</p>'
      '</body></html>';
  final archive = Archive()
    ..add(
      ArchiveFile.string('mimetype', 'application/epub+zip')
        ..compression = CompressionType.none,
    )
    ..add(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
      ),
    )
    ..add(
      ArchiveFile.string(
        'book.opf',
        '<package xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<metadata><dc:title>Large entries</dc:title></metadata>'
            '<manifest>'
            '<item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>'
            '<item id="art" href="landscape.png" media-type="image/png" properties="cover-image"/>'
            '</manifest><spine><itemref idref="chapter"/></spine></package>',
      ),
    )
    ..add(
      ArchiveFile.string('chapter.xhtml', chapter)
        ..compression = CompressionType.none,
    )
    ..add(
      ArchiveFile.bytes('landscape.png', png)
        ..compression = compressImage
            ? CompressionType.deflate
            : CompressionType.none,
    );
  for (final file in archive.files) {
    file.lastModTime = 0x00210000; // 1980-01-01, fixed DOS timestamp.
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main(List<String> args) =>
    File(args.single).writeAsBytesSync(largeEntriesEpub());
