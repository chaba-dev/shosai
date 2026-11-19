import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

Map<String, Object> _manifest({Map<String, Object>? files}) => {
  'formatVersion': 1,
  'builtAt': '2026-10-24T12:00:00.000Z',
  'sourceCounts': {'gutenberg': 2},
  'files': files ?? {'catalog.sqlite.gz': _file},
};

final _file = {'sizeBytes': 4096, 'sha256': 'a' * 64};

void main() {
  test('reads the manifest for a compressed Gutenberg SQLite snapshot', () {
    final directory = tempDataDirectory();
    final snapshot = File('${directory.path}/catalog.sqlite');
    final db = sqlite3.open(snapshot.path);
    try {
      db.execute(catalogSchema);
      db.execute(
        File('test/fixtures/gutenberg_catalog.sql').readAsStringSync(),
      );
    } finally {
      db.close();
    }
    final compressed = gzip.encode(snapshot.readAsBytesSync());
    final digest = sha256.convert(compressed).toString();
    final manifest = CatalogManifest.parse(
      jsonEncode(
        _manifest(
          files: {
            'catalog.sqlite.gz': {
              'sizeBytes': compressed.length,
              'sha256': digest,
            },
          },
        ),
      ),
    );
    expect(manifest.builtAt, DateTime.utc(2026, 10, 24, 12));
    expect(manifest.files[catalogDatabaseFile], (
      sizeBytes: compressed.length,
      sha256: digest,
    ));

    final unpacked = File('${directory.path}/unpacked.sqlite')
      ..writeAsBytesSync(gzip.decode(compressed));
    final catalog = sqlite3.open(unpacked.path, mode: OpenMode.readOnly);
    addTearDown(catalog.close);
    expect(catalog.userVersion, 1);
    expect(catalog.select('PRAGMA foreign_key_check'), isEmpty);
    final counts = catalog.select('''
      SELECT source_id, COUNT(*) AS edition_count FROM editions GROUP BY source_id
    ''');
    expect(manifest.sourceCounts, {
      for (final row in counts) row['source_id']: row['edition_count'],
    });
    final editions = catalog.select('''
      SELECT b.title, a.name, e.source_edition_id, e.variant_label,
             e.rights_line, e.size_bytes
      FROM book_categories AS bc
      JOIN books AS b ON b.id = bc.book_id
      JOIN book_authors AS ba ON ba.book_id = b.id
      JOIN authors AS a ON a.id = ba.author_id
      JOIN editions AS e ON e.book_id = b.id
      WHERE bc.category_id = 'classics' AND e.source_id = 'gutenberg'
      ORDER BY e.display_order
    ''');
    expect(editions.map((row) => row.values.toList()), [
      [
        'Pride and Prejudice',
        'Jane Austen',
        '1342:z',
        'With images',
        'Public domain in the USA',
        123456,
      ],
      [
        'Pride and Prejudice',
        'Jane Austen',
        '1342:a',
        'Without images',
        'Public domain in the USA',
        null,
      ],
    ]);
  });

  test('publisher connection rejects editions for a missing work', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(catalogSchema);
    db.execute(File('test/fixtures/gutenberg_catalog.sql').readAsStringSync());
    expect(
      () => db.execute('''
        INSERT INTO editions (
          source_id, source_edition_id, book_id, title, variant_label,
          display_order, language, source_url, rights_line, acquisition_url,
          acquisition_format
        )
        SELECT source_id, 'orphan', 'missing', title, variant_label,
               display_order, language, source_url, rights_line, acquisition_url,
               acquisition_format
        FROM editions WHERE source_edition_id = '1342:z'
      '''),
      throwsA(
        isA<SqliteException>().having(
          (error) => error.extendedResultCode,
          'extended result code',
          787, // SQLITE_CONSTRAINT_FOREIGNKEY
        ),
      ),
    );
  });

  test('rejects incompatible versions and invalid snapshot metadata', () {
    final invalid = [
      _manifest()..['formatVersion'] = 2,
      _manifest()..['builtAt'] = '2026-02-30T12:00:00.000Z',
      _manifest()..['sourceCounts'] = {'gutenberg': -1},
      _manifest(files: {}),
      _manifest(
        files: {
          'catalog.sqlite.gz': {..._file, 'sha256': 'oops'},
        },
      ),
      _manifest(
        files: {
          'catalog.sqlite.gz': {..._file, 'sizeBytes': 0},
        },
      ),
      _manifest(files: {'catalog.sqlite.gz': _file, '../cover.jpg': _file}),
      _manifest(
        files: {'catalog.sqlite.gz': _file, 'https://example.com': _file},
      ),
    ];
    for (final input in invalid) {
      expect(
        () => CatalogManifest.parse(jsonEncode(input)),
        throwsFormatException,
      );
    }
  });
}
