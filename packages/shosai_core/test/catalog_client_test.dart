import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shosai_core/catalog.dart';
import 'package:shosai_core/shosai_core.dart' show CoreException;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../tool/export_catalog_json.dart';
import 'support/temp_store.dart';

void main() {
  late Directory root;
  late Directory snapshot;
  late HttpServer server;
  late DateTime now;
  late CatalogClient client;
  late List<String> requests;
  late List<String?> agents;
  Future<void> Function(HttpRequest)? respond;

  setUp(() async {
    root = tempDataDirectory();
    snapshot = Directory('${root.path}/snapshot');
    _fixture(root, snapshot);
    now = DateTime.utc(2026, 11, 21);
    requests = [];
    agents = [];
    respond = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request.uri.path);
      agents.add(request.headers.value(HttpHeaders.userAgentHeader));
      if (respond != null) return respond!(request);
      final file = File('${snapshot.path}${request.uri.path}');
      if (file.existsSync()) {
        await request.response.addStream(file.openRead());
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    client = CatalogClient(
      '${root.path}/device/catalog',
      userAgent: 'Shosai-test (+https://github.com/chaba-dev/shosai/issues)',
      snapshot: Uri.parse('http://127.0.0.1:${server.port}/'),
      clock: () => now,
    );
  });

  test(
    'installs published JSON; searches locally, pages and preserves edition sources',
    () async {
      expect(await client.search(query: '猫'), isEmpty);
      expect(await client.book('cat'), isNull);
      expect(await client.isInstalled, isFalse);
      expect(await client.refresh(), CatalogRefresh.installed);
      expect(await client.isInstalled, isTrue);
      expect(requests.length, 25);
      expect(agents.toSet(), {client.userAgent});
      final before = requests.length;
      for (final query in ['猫', '吾輩', '吾輩は']) {
        expect((await client.search(query: query)).map((b) => b.id), ['cat']);
      }
      expect((await client.search(query: 'AUSTEN')).map((b) => b.id), [
        'pride',
      ]);
      expect((await client.search(query: 'STRASSE')).map((b) => b.id), [
        'symbols',
      ]);
      for (final query in ['%', '_', '"or"', '100%_', 'OR NOT']) {
        expect(
          (await client.search(query: query)).map((b) => b.id),
          query == 'OR NOT' ? isEmpty : ['symbols'],
        );
      }
      expect(
        (await client.search(
          category: 'fiction',
          language: 'ja',
          source: 'aozora',
        )).map((b) => b.id),
        ['pride', 'cat'],
      );
      // Language and source must match the same edition, not two independent ones.
      expect(
        await client.search(
          query: 'Pride',
          language: 'ja',
          source: 'gutenberg',
        ),
        isEmpty,
      );
      expect((await client.search(limit: 1)).single.id, 'symbols');
      expect((await client.search(limit: 1, offset: 1)).single.id, 'pride');
      expect((await client.search(limit: 1, offset: 2)).single.id, 'cat');
      expect(await client.search(offset: 3), isEmpty);
      expect(await client.categories(), [
        (id: 'fiction', label: 'Fiction', books: 2),
      ]);
      expect(await client.authors(query: 'AUSTEN'), [
        (id: 'austen', name: 'Austen, Jane', books: 1),
      ]);
      expect(await client.authors(query: '漱石'), [
        (id: 'soseki', name: '夏目漱石', books: 1),
      ]);
      expect(await client.authors(query: '%'), isEmpty);
      expect((await client.authors(limit: 1, offset: 1)).single.id, 'soseki');
      expect((await client.search(author: 'soseki')).map((b) => b.id), ['cat']);
      expect(await client.search(author: 'austen', language: 'de'), isEmpty);
      final filters = await client.filters();
      expect(filters.languages, ['de', 'en', 'ja']);
      expect(filters.sources, [
        (id: 'gutenberg', name: 'Project Gutenberg'),
        (id: 'aozora', name: '青空文庫'),
      ]);
      final book = (await client.book('pride'))!;
      expect(book.book.id, 'pride');
      expect(book.book.title, 'Pride and Prejudice');
      expect(book.book.authors, ['Austen, Jane']);
      expect(book.book.sources, ['Project Gutenberg', '青空文庫']);
      expect(book.book.coverUrl, isNull);
      expect(book.subjects, ['Love stories']);
      expect(
        book.editions.map(
          (e) => (e.sourceId, e.sourceName, e.variant, e.rights, e.sizeBytes),
        ),
        [
          (
            'gutenberg',
            'Project Gutenberg',
            'With images',
            'Public domain in the USA',
            12345,
          ),
          (
            'aozora',
            '青空文庫',
            'Japanese translation',
            'Public domain in Japan',
            null,
          ),
        ],
      );
      expect(
        book.editions.first.acquisitionUrl,
        'https://www.gutenberg.org/ebooks/1342.epub3.images',
      );
      expect(book.editions.last.catalogCredit, 'Aozora catalog CC BY 4.0');
      expect(book.editions.last.supportUrl, 'https://example.org/support');
      expect(
        requests.length,
        before,
        reason: 'Local queries must never send search terms',
      );
    },
  );

  test(
    'coalesces refreshes, persists daily throttle across restart; dates are not changes',
    () async {
      final results = await Future.wait([
        client.refresh(),
        client.refresh(),
        client.refresh(),
      ]);
      expect(results, everyElement(CatalogRefresh.installed));
      expect(requests.length, 25);
      final restarted = CatalogClient(
        client.directory,
        userAgent: client.userAgent,
        snapshot: client.snapshot,
        clock: () => now,
      );
      now = now.add(const Duration(hours: 23, minutes: 59));
      expect(await restarted.refresh(), CatalogRefresh.notDue);
      expect(requests.length, 25);
      now = now.add(const Duration(minutes: 1));
      final manifest = _manifest(snapshot)
        ..['builtAt'] = '2027-01-01T00:00:00.000Z';
      _writeManifest(snapshot, manifest);
      final bytes = File(
        '${client.directory}/catalog.sqlite3',
      ).readAsBytesSync();
      expect(await restarted.refresh(), CatalogRefresh.unchanged);
      expect(requests.length, 26);
      expect(
        File('${client.directory}/catalog.sqlite3').readAsBytesSync(),
        bytes,
      );
    },
  );

  test(
    'a changed snapshot swaps only after validation; old catalog survives failed refreshes',
    () async {
      await client.refresh();
      final original = File(
        '${client.directory}/catalog.sqlite3',
      ).readAsBytesSync();
      final books = File('${snapshot.path}/books/0.json');
      final oldBytes = books.readAsBytesSync();
      books.writeAsStringSync(
        books.readAsStringSync().replaceAll(
          'Pride and Prejudice',
          'A changed title',
        ),
      );
      _reinventory(snapshot, 'books/0.json');
      books.writeAsStringSync(
        books.readAsStringSync().replaceAll('changed', 'damaged'),
      );
      now = now.add(const Duration(days: 1));
      // Same size is not sufficient; hashes are verified independently.
      await expectLater(client.refresh(), throwsA(isA<FormatException>()));
      expect(
        File('${client.directory}/catalog.sqlite3').readAsBytesSync(),
        original,
      );
      expect((await client.search(query: 'Pride')).single.id, 'pride');
      expect(await client.refresh(), CatalogRefresh.notDue);
      books.writeAsStringSync(
        books.readAsStringSync().replaceAll('damaged', 'changed'),
      );
      now = now.add(const Duration(days: 1));
      expect(await client.refresh(), CatalogRefresh.installed);
      expect(await client.search(query: 'Pride'), isEmpty);
      expect((await client.search(query: 'changed')).single.id, 'pride');
      expect(
        Directory(client.directory).listSync().whereType<Directory>(),
        isEmpty,
      );
      books.writeAsBytesSync(oldBytes);
    },
  );

  test(
    'unsupported formats and HTTP failures retain offline data and throttle failures',
    () async {
      await client.refresh();
      final original = File(
        '${client.directory}/catalog.sqlite3',
      ).readAsBytesSync();
      now = now.add(const Duration(days: 1));
      _writeManifest(snapshot, _manifest(snapshot)..['formatVersion'] = 999);
      final before = requests.length;
      await expectLater(client.refresh(), throwsA(isA<FormatException>()));
      expect(requests.length, before + 1);
      expect(
        File('${client.directory}/catalog.sqlite3').readAsBytesSync(),
        original,
      );
      now = now.add(const Duration(days: 1));
      respond = (request) async {
        request.response.statusCode = 503;
        await request.response.close();
      };
      await expectLater(client.refresh(), throwsA(isA<FormatException>()));
      expect((await client.search(query: '吾輩')).single.id, 'cat');
      final restarted = CatalogClient(
        client.directory,
        userAgent: client.userAgent,
        snapshot: client.snapshot,
        clock: () => now,
      );
      expect(await restarted.refresh(), CatalogRefresh.notDue);
    },
  );

  test(
    'refresh repairs a corrupt or incompatible public cache using a validated replacement',
    () async {
      await client.refresh();
      final file = File('${client.directory}/catalog.sqlite3');
      for (final damage in ['bytes', 'version', 'metadata', 'search-page']) {
        now = now.add(const Duration(days: 1));
        if (damage == 'bytes') {
          file.writeAsBytesSync([1, 2, 3, 4]);
        } else {
          final db = sqlite3.open(file.path);
          int? searchPage;
          final pageSize =
              db.select('PRAGMA page_size').single.values.single as int;
          try {
            if (damage == 'search-page') {
              searchPage =
                  db
                          .select(
                            "SELECT rootpage FROM sqlite_schema WHERE name='catalog_search_data'",
                          )
                          .single['rootpage']
                      as int;
            } else {
              db.execute(
                damage == 'version'
                    ? 'PRAGMA user_version = 999'
                    : 'DELETE FROM catalog_metadata',
              );
            }
          } finally {
            db.close();
          }
          if (searchPage != null) {
            final bytes = file.readAsBytesSync();
            bytes[(searchPage - 1) * pageSize] = 0;
            file.writeAsBytesSync(bytes);
            await expectLater(
              client.search(query: 'Pride'),
              throwsA(isA<SqliteException>()),
            );
          }
        }
        final damaged = file.readAsBytesSync();
        final partition = File('${snapshot.path}/books/0.json');
        final valid = partition.readAsBytesSync();
        partition.writeAsStringSync('invalid');
        await expectLater(client.refresh(), throwsA(isA<FormatException>()));
        expect(file.readAsBytesSync(), damaged);
        partition.writeAsBytesSync(valid);
        now = now.add(const Duration(days: 1));
        final before = requests.length;
        expect(await client.refresh(), CatalogRefresh.installed);
        expect(requests.length - before, 25);
        expect((await client.search(query: 'Pride')).single.id, 'pride');
      }
    },
  );

  test(
    'verified bytes with invalid relationships or inventory counts cannot replace installed data',
    () async {
      await client.refresh();
      final original = File(
        '${client.directory}/catalog.sqlite3',
      ).readAsBytesSync();
      final authors = File('${snapshot.path}/authors/0.json');
      final before = authors.readAsBytesSync();
      authors.writeAsStringSync('[]');
      _reinventory(snapshot, 'authors/0.json');
      now = now.add(const Duration(days: 1));
      await expectLater(client.refresh(), throwsA(isA<SqliteException>()));
      expect(
        File('${client.directory}/catalog.sqlite3').readAsBytesSync(),
        original,
      );
      authors.writeAsBytesSync(before);
      _reinventory(snapshot, 'authors/0.json');
      final manifest = _manifest(snapshot);
      (manifest['sourceCounts'] as Map)['gutenberg'] = 100;
      _writeManifest(snapshot, manifest);
      now = now.add(const Duration(days: 1));
      await expectLater(client.refresh(), throwsA(isA<FormatException>()));
      expect(
        File('${client.directory}/catalog.sqlite3').readAsBytesSync(),
        original,
      );
    },
  );

  test(
    'shutdown cancels a blocked download and leaves personal and catalog data alone',
    () async {
      await client.refresh();
      final original = File(
        '${client.directory}/catalog.sqlite3',
      ).readAsBytesSync();
      final personal = File('${root.path}/device/library.sqlite3')
        ..writeAsStringSync('personal data');
      now = now.add(const Duration(days: 1));
      final started = Completer<void>();
      final release = Completer<void>();
      respond = (request) async {
        started.complete();
        await release.future;
        await request.response.close();
      };
      final refreshing = client.refresh();
      final failed = expectLater(refreshing, throwsA(isA<CoreException>()));
      await started.future;
      final competing = CatalogClient(
        '${client.directory}/.',
        userAgent: client.userAgent,
        snapshot: client.snapshot,
        clock: () => now,
      );
      // A second owner in the same process must not sweep the active staging
      // directory (POSIX permits that process to take its own lock again).
      await expectLater(competing.refresh(), throwsStateError);
      expect(
        Directory(client.directory).listSync().whereType<Directory>(),
        hasLength(1),
      );
      expect((await competing.search(query: 'Austen')).single.id, 'pride');
      await competing.close();
      await client.close();
      await failed;
      release.complete();
      expect(() => client.search(), throwsStateError);
      expect(
        File('${client.directory}/catalog.sqlite3').readAsBytesSync(),
        original,
      );
      expect(personal.readAsStringSync(), 'personal data');
      expect(
        Directory(client.directory).listSync().whereType<Directory>(),
        isEmpty,
      );
    },
  );

  test(
    'next use cleans interrupted staging without discarding the installed catalog',
    () async {
      await client.refresh();
      final interrupted = Directory('${client.directory}/.staging-interrupted')
        ..createSync();
      File(
        '${interrupted.path}/incomplete.sqlite3',
      ).writeAsStringSync('partial data');
      expect(await client.refresh(), CatalogRefresh.notDue);
      expect(interrupted.existsSync(), isFalse);
      expect((await client.search(query: 'Austen')).single.id, 'pride');
    },
  );
}

void _fixture(Directory root, Directory snapshot) {
  final db = sqlite3.open('${root.path}/upstream.sqlite3');
  try {
    db.execute(catalogSchema);
    db.execute(
      '''INSERT INTO sources VALUES
      ('gutenberg', 'Project Gutenberg', 'https://www.gutenberg.org', NULL, NULL),
      ('aozora', '青空文庫', 'https://www.aozora.gr.jp', 'Aozora catalog CC BY 4.0', 'https://example.org/support');
      INSERT INTO books VALUES ('pride', 'Pride and Prejudice'), ('cat', '吾輩は猫である'),
        ('symbols', '100%_ "or" Straße');
      INSERT INTO authors VALUES ('austen', 'Austen, Jane', 'Austen', NULL),
        ('soseki', '夏目漱石', '夏目', 'なつめ');
      INSERT INTO book_authors VALUES ('pride', 'austen', 0), ('cat', 'soseki', 0);
      INSERT INTO subjects VALUES ('love', 'Love stories');
      INSERT INTO book_subjects VALUES ('pride', 'love');
      INSERT INTO categories VALUES ('fiction', 'Fiction');
      INSERT INTO book_categories VALUES ('pride', 'fiction'), ('cat', 'fiction');
      INSERT INTO editions VALUES
        ('gutenberg', '1342', 'pride', 'Pride and Prejudice', 'With images', 0, 'en',
         'https://www.gutenberg.org/ebooks/1342', 'Public domain in the USA',
         'https://www.gutenberg.org/ebooks/1342.epub3.images', 'epub', 12345, NULL),
        ('aozora', 'translation', 'pride', 'Pride and Prejudice', 'Japanese translation', 1, 'ja',
         'https://www.aozora.gr.jp/translation', 'Public domain in Japan',
         'https://www.aozora.gr.jp/translation.html', 'xhtml', NULL, NULL),
        ('aozora', 'cat', 'cat', '吾輩は猫である', '新字新仮名', 0, 'ja',
         'https://www.aozora.gr.jp/cat', 'Public domain in Japan',
         'https://www.aozora.gr.jp/cat.html', 'xhtml', NULL, NULL),
        ('gutenberg', 'symbols', 'symbols', 'Symbols', 'With images', 0, 'de',
         'https://www.gutenberg.org/ebooks/1', 'Public domain in the USA',
         'https://www.gutenberg.org/ebooks/1.epub3.images', 'epub', NULL, NULL);''',
    );
  } finally {
    db.close();
  }
  exportCatalogJson('${root.path}/upstream.sqlite3', snapshot.path);
}

Map<String, dynamic> _manifest(Directory snapshot) =>
    jsonDecode(File('${snapshot.path}/manifest.json').readAsStringSync())
        as Map<String, dynamic>;

void _writeManifest(Directory snapshot, Map<String, dynamic> manifest) => File(
  '${snapshot.path}/manifest.json',
).writeAsStringSync(jsonEncode(manifest));

void _reinventory(Directory snapshot, String path) {
  final manifest = _manifest(snapshot);
  final bytes = File('${snapshot.path}/$path').readAsBytesSync();
  (manifest['files'] as Map)[path] = {
    'sizeBytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  _writeManifest(snapshot, manifest);
}
