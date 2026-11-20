import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../tool/export_catalog_json.dart';
import 'support/temp_store.dart';

Map<String, Object> _manifest({Map<String, Object>? files}) => {
  'formatVersion': 2,
  'builtAt': '2026-10-24T12:00:00.000Z',
  'sourceCounts': {'gutenberg': 2},
  'files': files ?? _files,
};

final _file = {'sizeBytes': 4096, 'sha256': 'a' * 64};
final _files = {for (final table in catalogTables.keys) '$table/0.json': _file};

void main() {
  test('exports verified JSON that restores the Gutenberg catalog', () {
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
    final output = Directory('${directory.path}/catalog');
    exportCatalogJson(snapshot.path, output.path);
    final manifest = CatalogManifest.parse(
      File('${output.path}/manifest.json').readAsStringSync(),
    );
    final catalog = sqlite3.openInMemory();
    addTearDown(catalog.close);
    catalog.execute(catalogSchema);
    for (final table in catalogTables.keys) {
      final path = '$table/0.json';
      final bytes = File('${output.path}/$path').readAsBytesSync();
      expect(manifest.files[path], (
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ));
      for (final raw in jsonDecode(utf8.decode(bytes)) as List) {
        final row = raw as Map<String, dynamic>;
        final columns = row.keys.join(', ');
        final placeholders = List.filled(row.length, '?').join(', ');
        catalog.execute(
          'INSERT INTO $table ($columns) VALUES ($placeholders)',
          row.values.toList(),
        );
      }
    }
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

  test('splits catalog rows at the UTF-8 size limit', () {
    final directory = tempDataDirectory();
    final snapshot = File('${directory.path}/catalog.sqlite');
    final db = sqlite3.open(snapshot.path);
    final title = '猫' * 750000;
    try {
      db.execute(catalogSchema);
      db.execute(
        File('test/fixtures/gutenberg_catalog.sql').readAsStringSync(),
      );
      db.execute('UPDATE books SET title = ?', [title]);
      db.execute("INSERT INTO books VALUES ('gutenberg:2', ?)", [title]);
    } finally {
      db.close();
    }

    final output = Directory('${directory.path}/catalog');
    exportCatalogJson(snapshot.path, output.path);
    final manifest = CatalogManifest.parse(
      File('${output.path}/manifest.json').readAsStringSync(),
    );
    final parts = manifest.files.keys.where(
      (path) => path.startsWith('books/'),
    );
    expect(parts, ['books/0.json', 'books/1.json']);
    for (final (index, path) in parts.indexed) {
      final bytes = File('${output.path}/$path').readAsBytesSync();
      expect(bytes.length, lessThanOrEqualTo(4 * 1024 * 1024));
      expect(jsonDecode(utf8.decode(bytes)), [
        {
          'id': ['gutenberg:1342', 'gutenberg:2'][index],
          'title': title,
        },
      ]);
    }
  });

  test('a failed export leaves no partial catalog', () {
    final directory = tempDataDirectory();
    final snapshot = File('${directory.path}/catalog.sqlite');
    final db = sqlite3.open(snapshot.path);
    try {
      db.execute(catalogSchema);
      db.execute(
        File('test/fixtures/gutenberg_catalog.sql').readAsStringSync(),
      );
      db.execute('UPDATE books SET title = ?', ['猫' * 1500000]);
    } finally {
      db.close();
    }
    expect(
      () => exportCatalogJson(snapshot.path, '${directory.path}/out'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('exceeds the shard limit'),
        ),
      ),
    );
    expect(directory.listSync().map((entry) => entry.path), [snapshot.path]);
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
      _manifest()..['formatVersion'] = 1,
      _manifest()..['builtAt'] = '2026-02-30T12:00:00.000Z',
      _manifest()..['sourceCounts'] = {'gutenberg': -1},
      _manifest(files: {}),
      _manifest(
        files: {
          ..._files,
          'books/0.json': {..._file, 'sha256': 'oops'},
        },
      ),
      _manifest(
        files: {
          ..._files,
          'books/0.json': {..._file, 'sizeBytes': 0},
        },
      ),
      _manifest(files: {..._files, '../cover.jpg': _file}),
      _manifest(files: {..._files, 'https://example.com': _file}),
    ];
    for (final input in invalid) {
      expect(
        () => CatalogManifest.parse(jsonEncode(input)),
        throwsFormatException,
      );
    }
  });
}
