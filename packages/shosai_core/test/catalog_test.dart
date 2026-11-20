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
final _files = {
  for (final entry in catalogTables.entries)
    for (final part in entry.value.parts.split(''))
      '${entry.key}/$part.json': _file,
};

Map<String, String> _snapshot(Directory directory) => {
  for (final file in directory.listSync(recursive: true).whereType<File>())
    file.path.substring(directory.path.length + 1): file.readAsStringSync(),
};

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
      for (final part in catalogTables[table]!.parts.split('')) {
        final path = '$table/$part.json';
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

  test(
    'unchanged regeneration has no diff; a new book stays in its partition',
    () {
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

      final old = Directory('${directory.path}/old');
      exportCatalogJson(snapshot.path, old.path);
      // Use an earlier date so the test cannot pass just because runs share a clock tick.
      final manifestFile = File('${old.path}/manifest.json');
      final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
      manifest['builtAt'] = '2026-01-01T00:00:00.000Z';
      manifestFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      );
      final before = _snapshot(old);

      final same = Directory('${directory.path}/same');
      exportCatalogJson(snapshot.path, same.path, previous: old.path);
      expect(_snapshot(same), before);

      final updated = sqlite3.open(snapshot.path);
      const title = '猫の本\n"A new book"';
      try {
        updated.execute('INSERT INTO books VALUES (?, ?)', [
          'gutenberg:0',
          title,
        ]);
        updated.execute(
          '''
        INSERT INTO editions
        SELECT source_id, '0:a', 'gutenberg:0', ?, variant_label, display_order,
               language, source_url, rights_line, acquisition_url,
               acquisition_format, size_bytes, cover_url
        FROM editions WHERE source_edition_id = '1342:z'
      ''',
          [title],
        );
      } finally {
        updated.close();
      }
      final changed = Directory('${directory.path}/changed');
      exportCatalogJson(snapshot.path, changed.path, previous: old.path);
      final after = _snapshot(changed);
      expect(after.keys.toSet(), before.keys.toSet());
      expect(after.keys.where((path) => after[path] != before[path]).toSet(), {
        'books/0.json',
        'editions/b.json',
        'manifest.json',
      });
      // SHA-256 of gutenberg:1342 starts with 7, and gutenberg:0 with b.
      expect((jsonDecode(after['editions/7.json']!) as List).length, 2);
      final lines = after['editions/b.json']!.split('\n');
      expect(lines.length, 4);
      expect((jsonDecode(lines[1].trim()) as Map)['title'], title);
      final nextManifest = CatalogManifest.parse(after['manifest.json']!);
      expect(nextManifest.sourceCounts, {'gutenberg': 3});
      expect(nextManifest.builtAt, isNot(DateTime.utc(2026)));
    },
  );

  test('existing output is never replaced', () {
    final directory = tempDataDirectory();
    final output = File('${directory.path}/out')..writeAsStringSync('keep me');
    expect(
      () => exportCatalogJson('missing.sqlite', output.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(output.readAsStringSync(), 'keep me');
  });

  test('an empty source ID fails without leaving output', () {
    final directory = tempDataDirectory();
    final snapshot = File('${directory.path}/catalog.sqlite');
    final db = sqlite3.open(snapshot.path);
    try {
      db.execute(catalogSchema);
      db.execute(
        File(
          'test/fixtures/gutenberg_catalog.sql',
        ).readAsStringSync().replaceAll("'gutenberg'", "''"),
      );
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      db.close();
    }
    expect(
      () => exportCatalogJson(snapshot.path, '${directory.path}/out'),
      throwsA(isA<FormatException>()),
    );
    expect(directory.listSync().map((entry) => entry.path), [snapshot.path]);
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
      db.execute('UPDATE books SET title = ?', ['猫' * 8400000]);
    } finally {
      db.close();
    }
    expect(
      () => exportCatalogJson(snapshot.path, '${directory.path}/out'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('exceeds the partition limit'),
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
      _manifest(files: {..._files}..remove('editions/f.json')),
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
