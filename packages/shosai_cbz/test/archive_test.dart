import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:shosai_cbz/shosai_cbz.dart';
import 'package:test/test.dart';

/// A ZIP of [files], each stored or deflated as [stored] says.
Uint8List zip(Map<String, List<int>> files, {Set<String> stored = const {}}) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    archive.add(
      stored.contains(key)
          ? ArchiveFile.noCompress(key, value.length, value)
          : ArchiveFile.bytes(key, value),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List png(int width, int height) =>
    img.encodePng(img.Image(width: width, height: height));

/// The central-directory header offsets of [bytes].
List<int> directoryHeaders(Uint8List bytes) => [
  for (var i = 0; i + 4 <= bytes.length; i++)
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x01 &&
        bytes[i + 3] == 0x02)
      i,
];

Future<CbzArchive> open(Uint8List bytes, {CbzLimits? limits}) =>
    CbzArchive.open(CbzBytesSource(bytes), limits: limits ?? const CbzLimits());

void main() {
  test(
    'pages are the images in natural order, without metadata files',
    () async {
      final page = png(2, 3);
      final archive = await open(
        zip({
          'Vol 1/page10.png': page,
          'Vol 1/page2.png': page,
          'Vol 1/Page1.PNG': page,
          'Vol 10/page1.png': page,
          'Vol 2/page1.png': page,
          '__MACOSX/Vol 1/._page2.png': page,
          'Vol 1/.hidden.png': page,
          'Vol 1/notes.txt': utf8.encode('not a page'),
          'ComicInfo.xml': utf8.encode('<ComicInfo/>'),
        }),
      );
      expect(archive.pages.map((p) => p.path), [
        'Vol 1/Page1.PNG',
        'Vol 1/page2.png',
        'Vol 1/page10.png',
        'Vol 2/page1.png',
        'Vol 10/page1.png',
      ]);
    },
  );

  test(
    'stored and deflated pages read back exactly, with header sizes',
    () async {
      final wide = png(300, 120);
      final jpeg = img.encodeJpg(img.Image(width: 17, height: 9));
      final gif = img.encodeGif(img.Image(width: 5, height: 7));
      final bmp = img.encodeBmp(img.Image(width: 11, height: 4));
      final archive = await open(
        zip(
          {'1.png': wide, '2.jpg': jpeg, '3.gif': gif, '4.bmp': bmp},
          stored: {'2.jpg', '4.bmp'},
        ),
      );
      expect(await archive.pageBytes(0), wide);
      expect(await archive.pageBytes(1), jpeg);
      expect(await archive.pageBytes(3), bmp);
      expect(
        [for (var i = 0; i < 4; i++) await archive.pageSize(i)],
        const [
          CbzImageSize(300, 120),
          CbzImageSize(17, 9),
          CbzImageSize(5, 7),
          CbzImageSize(11, 4),
        ],
      );
    },
  );

  test('a JPEG frame header past the probe window is still measured', () async {
    final jpeg = img.encodeJpg(img.Image(width: 33, height: 21));
    // An APP15 segment of 65 000 bytes and another, before the frame header.
    final padding = <int>[
      for (var segment = 0; segment < 2; segment++) ...[
        0xFF,
        0xEF,
        0xFD,
        0xEA,
        ...List.filled(65000, 0),
      ],
    ];
    final padded = [...jpeg.sublist(0, 2), ...padding, ...jpeg.sublist(2)];
    final archive = await open(zip({'1.jpg': padded}));
    expect(await archive.pageSize(0), const CbzImageSize(33, 21));
  });

  test('WebP headers report their canvas sizes', () {
    Uint8List riff(String chunk, List<int> body) => Uint8List.fromList([
      ...ascii.encode('RIFF'),
      0,
      0,
      0,
      0,
      ...ascii.encode('WEBP'),
      ...ascii.encode(chunk),
      0,
      0,
      0,
      0,
      ...body,
    ]);
    // VP8X: 24-bit width-1 and height-1 at bytes 24 and 27.
    expect(
      imageSizeFromHeader(
        riff('VP8X', [0, 0, 0, 0, 0xFF, 0x03, 0x00, 0x57, 0x02, 0x00]),
      ),
      const CbzImageSize(1024, 600),
    );
    // VP8L: 14-bit width-1 and height-1 packed after the 0x2F signature.
    final w = 799, h = 1199;
    final bits = w | (h << 14);
    expect(
      imageSizeFromHeader(
        riff('VP8L', [
          0x2F,
          bits & 0xFF,
          (bits >> 8) & 0xFF,
          (bits >> 16) & 0xFF,
          (bits >> 24) & 0xFF,
          0,
          0,
          0,
          0,
        ]),
      ),
      const CbzImageSize(800, 1200),
    );
  });

  test('ComicInfo supplies the title, writers and manga mark', () async {
    final archive = await open(
      zip({
        '1.png': png(1, 1),
        'extras/ComicInfo.xml': utf8.encode(
          '<ComicInfo><Title>Wrong</Title></ComicInfo>',
        ),
        'ComicInfo.xml': utf8.encode('''<?xml version="1.0"?>
<ComicInfo>
  <Series>Comet Courier</Series><Number>2</Number>
  <Writer>A. Writer, B. Writer</Writer>
  <LanguageISO>ja</LanguageISO>
  <Manga>YesAndRightToLeft</Manga>
</ComicInfo>'''),
      }),
    );
    final info = await archive.comicInfo();
    expect(info.displayTitle, 'Comet Courier 2');
    expect(info.writers, ['A. Writer', 'B. Writer']);
    expect(info.language, 'ja');
    expect(info.manga.rightToLeft, isTrue);
  });

  test('the manga mark is Yes or YesAndRightToLeft only', () {
    CbzManga manga(String value) => parseComicInfo(
      utf8.encode('<ComicInfo><Manga>$value</Manga></ComicInfo>'),
    ).manga;
    expect(manga('Yes').rightToLeft, isTrue);
    expect(manga('No').rightToLeft, isFalse);
    expect(manga('Unknown').rightToLeft, isFalse);
    expect(parseComicInfo(utf8.encode('<ComicInfo>')).manga, CbzManga.unknown);
  });

  test('an archive without images, or not a ZIP, is malformed', () async {
    await expectLater(
      open(zip({'readme.txt': utf8.encode('x')})),
      throwsA(isA<CbzFormatError>()),
    );
    await expectLater(
      open(Uint8List.fromList(utf8.encode('%PDF-1.7 not a zip at all'))),
      throwsA(isA<CbzFormatError>()),
    );
  });

  test('an encrypted page makes the archive protected', () async {
    final bytes = zip({'1.png': png(1, 1)});
    for (final header in directoryHeaders(bytes)) {
      bytes[header + 8] |= 1;
    }
    await expectLater(open(bytes), throwsA(isA<CbzProtectedError>()));
  });

  test('a name listed twice is malformed', () async {
    final bytes = zip({'a.png': png(1, 1), 'b.png': png(1, 1)});
    final second = directoryHeaders(bytes)[1];
    bytes[second + 46] = 0x61; // b.png → a.png
    await expectLater(open(bytes), throwsA(isA<CbzFormatError>()));
  });

  test('a damaged page fails its own read, not the archive', () async {
    final page = png(4, 4);
    final bytes = zip({'1.png': page, '2.png': png(2, 2)}, stored: {'1.png'});
    // Flip a byte inside the first page's stored data, past its header.
    final data = 30 + '1.png'.length + 20;
    bytes[data] ^= 0xFF;
    final archive = await open(bytes);
    await expectLater(archive.pageBytes(0), throwsA(isA<CbzFormatError>()));
    expect(await archive.pageSize(1), const CbzImageSize(2, 2));
  });

  test('a truncated archive is malformed', () async {
    final bytes = zip({'1.png': png(8, 8), '2.png': png(8, 8)});
    await expectLater(
      open(Uint8List.sublistView(bytes, 0, bytes.length - 30)),
      throwsA(isA<CbzFormatError>()),
    );
  });

  test('limits are checked before anything is inflated', () async {
    final bomb = zip({'1.png': List.filled(4 * 1024 * 1024, 0)});
    await expectLater(
      open(bomb, limits: const CbzLimits(maxCompressionRatio: 100)),
      throwsA(isA<CbzLimitError>()),
    );
    await expectLater(
      open(
        zip({'1.png': png(1, 1), '2.png': png(1, 1)}),
        limits: const CbzLimits(maxEntries: 1),
      ),
      throwsA(isA<CbzLimitError>()),
    );
    await expectLater(
      open(
        zip({'1.png': png(64, 64)}),
        limits: const CbzLimits(maxEntryBytes: 10),
      ),
      throwsA(isA<CbzLimitError>()),
    );
  });

  test('a file source reads pages without loading the archive', () async {
    final directory = await Directory.systemTemp.createTemp('cbz-test');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/book.cbz');
    final pages = {for (var i = 1; i <= 12; i++) '$i.png': png(i, 2 * i)};
    await file.writeAsBytes(zip(pages));
    final handle = await file.open();
    addTearDown(handle.close);
    final archive = await CbzArchive.open(
      CbzFileSource(handle, await file.length()),
    );
    // Concurrent reads share one file position.
    final sizes = await Future.wait([
      for (var i = 0; i < 12; i++) archive.pageSize(i),
    ]);
    expect(sizes, [for (var i = 1; i <= 12; i++) CbzImageSize(i, 2 * i)]);
  });

  test('natural order compares numbers by value and ignores case', () {
    final names = ['b10', 'B2', 'a', '010', '9', 'b2'];
    names.sort(compareNatural);
    expect(names, ['9', '010', 'a', 'B2', 'b2', 'b10']);
  });
}
