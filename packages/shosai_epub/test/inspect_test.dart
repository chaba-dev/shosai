import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shosai_epub/shosai_epub.dart';
import 'package:test/test.dart';

void main() {
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

    expect(notImage.cover, isNull);
    expect(tooLarge.cover, isNull);
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
}) {
  final archive = Archive();
  void add(String name, List<int> bytes) =>
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
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
