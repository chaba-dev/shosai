/// Properties of the CBZ engine, checked over seeded random inputs.
///
/// Each case derives its own seed from [_baseSeed] and the case number, and
/// a failure names it, so `SHOSAI_PROPERTY_SEED=<seed>` replays the run.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:shosai_cbz/shosai_cbz.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

final _baseSeed =
    int.tryParse(Platform.environment['SHOSAI_PROPERTY_SEED'] ?? '') ??
    20261128;

/// Run [body] for [cases] seeded random generators.
Future<void> forCases(
  int cases,
  Future<void> Function(Random random, String seed) body,
) async {
  for (var i = 0; i < cases; i++) {
    final seed = _baseSeed + i;
    await body(Random(seed), 'seed $seed');
  }
}

const _imageExtensions = ['png', 'PNG', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
const _otherExtensions = ['txt', 'xml', 'nfo', ''];
const _segmentChars = 'abcABC0123456789 _-';

String _segment(Random random) => String.fromCharCodes([
  for (var i = 0; i < 1 + random.nextInt(6); i++)
    _segmentChars.codeUnitAt(random.nextInt(_segmentChars.length)),
]);

Uint8List _bytes(Random random, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) random.nextInt(256)]);

Uint8List _zip(Map<String, Uint8List> files, Set<String> stored) {
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

/// Whether the engine's typed failures cover [error].
bool _typed(Object error) =>
    error is CbzFormatError ||
    error is CbzLimitError ||
    error is CbzProtectedError;

/// [text], cut at a random point when [random] says so.
String _cut(Random random, String text) => random.nextBool()
    ? text
    : text.substring(0, random.nextInt(text.length + 1));

void main() {
  test('random archives list exactly their images, in natural order, '
      'and read back byte for byte', () async {
    await forCases(150, (random, seed) async {
      final files = <String, Uint8List>{};
      final stored = <String>{};
      final expected = <String>[];
      for (var i = 0; i < 1 + random.nextInt(24); i++) {
        final folders = [
          for (var d = 0; d < random.nextInt(3); d++) _segment(random),
        ];
        final kind = random.nextInt(10);
        final image = kind < 7;
        final extension = image
            ? _imageExtensions[random.nextInt(_imageExtensions.length)]
            : _otherExtensions[random.nextInt(_otherExtensions.length)];
        var base = _segment(random);
        // Some images are the metadata archivers leave behind.
        final hidden = image && kind == 6;
        if (hidden) base = '.$base';
        if (image && kind == 5) folders.insert(0, '__MACOSX');
        final name = [
          ...folders,
          extension.isEmpty ? base : '$base.$extension',
        ].join('/');
        if (files.containsKey(name)) continue;
        files[name] = _bytes(random, random.nextInt(2000));
        if (random.nextBool()) stored.add(name);
        if (image && !hidden && kind != 5) expected.add(name);
      }
      if (expected.isEmpty) {
        await expectLater(
          CbzArchive.open(CbzBytesSource(_zip(files, stored))),
          throwsA(isA<CbzFormatError>()),
          reason: '$seed: ${files.keys}',
        );
        return;
      }
      expected.sort(compareNatural);
      final archive = await CbzArchive.open(
        CbzBytesSource(_zip(files, stored)),
      );
      expect(
        archive.pages.map((page) => page.path),
        expected,
        reason: '$seed: ${files.keys}',
      );
      for (var i = 0; i < expected.length; i++) {
        expect(
          await archive.pageBytes(i),
          files[expected[i]],
          reason: '$seed: ${expected[i]}',
        );
      }
    });
  });

  test('damaged archives fail only with typed errors', () async {
    final pages = {
      for (var i = 1; i <= 6; i++)
        'Chapter/$i.png': img.encodePng(img.Image(width: 3 * i, height: 2 * i)),
      'ComicInfo.xml': Uint8List.fromList(
        utf8.encode('<ComicInfo><Manga>Yes</Manga></ComicInfo>'),
      ),
    };
    final valid = _zip(pages, {'Chapter/2.png', 'Chapter/4.png'});
    await forCases(400, (random, seed) async {
      final bytes = Uint8List.fromList(valid);
      final Uint8List damaged;
      switch (random.nextInt(3)) {
        case 0:
          for (var i = 0; i < 1 + random.nextInt(8); i++) {
            bytes[random.nextInt(bytes.length)] = random.nextInt(256);
          }
          damaged = bytes;
        case 1:
          damaged = Uint8List.sublistView(
            bytes,
            0,
            random.nextInt(bytes.length),
          );
        default:
          final at = random.nextInt(bytes.length);
          damaged = Uint8List.fromList([
            ...bytes.sublist(0, at),
            ..._bytes(random, 1 + random.nextInt(64)),
            ...bytes.sublist(at),
          ]);
      }
      try {
        final archive = await CbzArchive.open(CbzBytesSource(damaged));
        await archive.comicInfo();
        for (var i = 0; i < archive.pages.length; i++) {
          try {
            await archive.pageSize(i);
            await archive.pageBytes(i);
          } catch (error) {
            expect(_typed(error), isTrue, reason: '$seed page $i: $error');
          }
        }
      } catch (error) {
        expect(_typed(error), isTrue, reason: '$seed: $error');
      }
    });
  });

  test('natural order is a total order that sorts numbers by value', () async {
    await forCases(300, (random, seed) async {
      final names = [
        for (var i = 0; i < 3; i++)
          [
            for (var r = 0; r < 1 + random.nextInt(4); r++)
              random.nextBool()
                  ? '${random.nextInt(3) == 0 ? '0' : ''}${random.nextInt(120)}'
                  : _segment(random),
          ].join(),
      ];
      final [a, b, c] = names;
      int sign(int value) => value.sign;
      expect(
        sign(compareNatural(a, b)),
        -sign(compareNatural(b, a)),
        reason: '$seed: $a, $b',
      );
      expect(compareNatural(a, b) == 0, a == b, reason: '$seed: $a, $b');
      if (compareNatural(a, b) <= 0 && compareNatural(b, c) <= 0) {
        expect(
          compareNatural(a, c),
          lessThanOrEqualTo(0),
          reason: '$seed: $a, $b, $c',
        );
      }
      final x = random.nextInt(1000), y = random.nextInt(1000);
      if (x != y) {
        final padded = 'page${'$x'.padLeft(random.nextInt(5), '0')}';
        expect(
          sign(compareNatural(padded, 'page$y')),
          sign(x - y),
          reason: '$seed: $padded, page$y',
        );
      }
    });
  });

  test('image headers report their real size, or nothing when cut', () async {
    await forCases(120, (random, seed) async {
      final width = 1 + random.nextInt(96), height = 1 + random.nextInt(96);
      final image = img.Image(width: width, height: height);
      final encoded = switch (random.nextInt(4)) {
        0 => img.encodePng(image),
        1 => img.encodeJpg(image),
        2 => img.encodeGif(image),
        _ => img.encodeBmp(image),
      };
      expect(
        imageSizeFromHeader(encoded),
        CbzImageSize(width, height),
        reason: '$seed: ${width}x$height',
      );
      // A cut header is either still whole enough or unknown, never wrong.
      final cut = imageSizeFromHeader(
        Uint8List.sublistView(encoded, 0, random.nextInt(encoded.length)),
      );
      expect(cut, anyOf(isNull, CbzImageSize(width, height)), reason: seed);
    });
  });

  test(
    'ComicInfo parsing never throws, and only Yes values mark manga',
    () async {
      const values = [
        'Yes',
        'yes',
        'YesAndRightToLeft',
        'No',
        'Unknown',
        '',
        ' Yes ',
        'Manga',
      ];
      await forCases(300, (random, seed) async {
        final value = random.nextBool()
            ? values[random.nextInt(values.length)]
            : _segment(random);
        final xml = random.nextInt(4) == 0
            ? _bytes(random, random.nextInt(200))
            : Uint8List.fromList(
                utf8.encode(
                  _cut(
                    random,
                    '<ComicInfo><Title>${_segment(random)}</Title>'
                    '<Manga>$value</Manga></ComicInfo>',
                  ),
                ),
              );
        final CbzComicInfo info;
        try {
          info = parseComicInfo(xml);
        } catch (error) {
          fail('$seed: parsing threw $error');
        }
        // The mark is the trimmed Manga value, Yes or YesAndRightToLeft.
        final text = utf8.decode(xml, allowMalformed: true);
        // A cut document is not well formed and carries no metadata.
        var wellFormed = true;
        try {
          XmlDocument.parse(text);
        } on XmlException {
          wellFormed = false;
        }
        final mark = RegExp(
          r'<Manga>([^<]*)</Manga>',
        ).firstMatch(text)?.group(1)?.trim().toLowerCase();
        expect(
          info.manga.rightToLeft,
          wellFormed && (mark == 'yes' || mark == 'yesandrighttoleft'),
          reason: '$seed: $text',
        );
      });
    },
  );
}
