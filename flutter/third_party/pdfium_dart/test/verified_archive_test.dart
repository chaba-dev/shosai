import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../hook/verified_archive.dart';

const _libraryPath = 'lib/libpdfium.so';
final _source = Uri.parse('https://example.invalid/pdfium-linux-x64.tgz');

void main() {
  late Directory directory;
  late File archive;
  late File library;
  late List<int> archiveBytes;
  late String archiveSha256;
  late int downloads;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('verified-archive-');
    archive = File('${directory.path}/cache/pdfium.tgz');
    library = File('${directory.path}/cache/libpdfium.so');
    archiveBytes = _tgz({
      _libraryPath: 'the real library',
      'LICENSE': 'license',
    });
    archiveSha256 = sha256.convert(archiveBytes).toString();
    downloads = 0;
  });

  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> extract({List<int>? served}) => extractVerifiedPdfium(
    archive: archive,
    library: library,
    expectedSha256: archiveSha256,
    libraryPath: _libraryPath,
    source: _source,
    download: () async {
      downloads++;
      return served ?? archiveBytes;
    },
  );

  test('extracts the library from a download that matches the pin', () async {
    await extract();

    expect(library.readAsStringSync(), 'the real library');
    expect(archive.readAsBytesSync(), archiveBytes);
    expect(downloads, 1);
    expect(
      directory.listSync(recursive: true).map((e) => e.path),
      isNot(contains(contains('.partial-'))),
    );
  });

  test('refuses a download whose SHA-256 differs from the pin', () async {
    final tampered = _tgz({_libraryPath: 'a tampered library'});

    await expectLater(
      extract(served: tampered),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'message',
          contains('expected $archiveSha256'),
        ),
      ),
    );
    expect(library.existsSync(), isFalse);
    expect(archive.existsSync(), isFalse);
  });

  test('replaces a library left without a verified archive', () async {
    // A truncated write, or a library that never came from a verified
    // archive: its presence alone must not be trusted.
    library
      ..createSync(recursive: true)
      ..writeAsStringSync('the real lib');

    await extract();

    expect(library.readAsStringSync(), 'the real library');
    expect(downloads, 1);
  });

  test('rebuilds a changed library from the cached archive', () async {
    await extract();
    library.writeAsStringSync('a changed library');

    await extract();

    expect(library.readAsStringSync(), 'the real library');
    expect(downloads, 1, reason: 'the cached archive still matches the pin');
  });

  test('downloads again when the cached archive no longer matches', () async {
    archive
      ..createSync(recursive: true)
      ..writeAsBytesSync(_tgz({_libraryPath: 'a tampered library'}));

    await extract();

    expect(library.readAsStringSync(), 'the real library');
    expect(archive.readAsBytesSync(), archiveBytes);
    expect(downloads, 1);
  });

  test('keeps a library that already matches the archive', () async {
    await extract();
    final modified = library.lastModifiedSync();
    library.setLastModifiedSync(modified.subtract(const Duration(hours: 1)));

    await extract();

    expect(
      library.lastModifiedSync(),
      modified.subtract(const Duration(hours: 1)),
    );
    expect(downloads, 1);
  });
}

List<int> _tgz(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    final bytes = utf8.encode(value);
    archive.addFile(ArchiveFile(key, bytes.length, bytes));
  }
  return GZipEncoder().encode(TarEncoder().encode(archive));
}
