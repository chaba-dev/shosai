import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../tool/export_catalog_json.dart';
import '../tool/import_gutenberg.dart';
import 'support/temp_store.dart';

// The excerpt contains four records from Project Gutenberg's public-domain
// offline CSV (mirror.cs.odu.edu/gutenberg-epub/feeds/pg_catalog.csv.gz,
// retrieved 2026-11-19), with line endings normalized to LF.
final _excerpt = File('test/fixtures/pg_catalog_excerpt.csv');

void main() {
  test('reordered feed records export byte-identical catalog files', () async {
    final dir = tempDataDirectory();
    const header = 'Text#,Type,Title,Language,Authors,Subjects,Bookshelves\n';
    const rows = [
      '1342,Text,Pride and Prejudice,en,Austen,Love stories,Category: Novels',
      '417,Text,"A title\nwith two lines",de,Luther,Poetry,Category: Poetry',
      '3002,Sound,Audio,en,Performer,,',
      '42671,Text,Another edition,en,Austen,Love stories,Category: Novels',
    ];
    Map<String, String> contents(String path) => {
      for (final file in Directory(
        path,
      ).listSync(recursive: true).whereType<File>())
        file.path.substring(path.length): file.readAsStringSync(),
    };
    for (var index = 0; index < 2; index++) {
      final input = File('${dir.path}/$index.csv')
        ..writeAsStringSync(
          '$header${(index == 0 ? rows : rows.reversed).join('\n')}\n',
        );
      final db = File('${dir.path}/$index.sqlite');
      await importGutenbergFile(input, db);
      exportCatalogJson(
        db.path,
        '${dir.path}/export$index',
        previous: index == 0 ? null : '${dir.path}/export0',
      );
    }
    expect(contents('${dir.path}/export1'), contents('${dir.path}/export0'));
  });

  test(
    'imports an upstream CSV excerpt without guessing work identity or rights',
    () async {
      final dir = tempDataDirectory();
      final input = File('${dir.path}/pg_catalog.csv.gz')
        ..writeAsBytesSync(gzip.encode(_excerpt.readAsBytesSync()));
      final output = File('${dir.path}/catalog.sqlite');
      expect(await importGutenbergFile(input, output), (
        works: 3,
        editions: 6,
        skipped: 1,
      ));
      final db = sqlite3.open(output.path, mode: OpenMode.readOnly);
      addTearDown(db.close);
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      expect(
        db
            .select(
              "SELECT id FROM books WHERE title = 'Pride and Prejudice' ORDER BY id",
            )
            .map((row) => row['id']),
        ['gutenberg:1342', 'gutenberg:42671'],
      );
      expect(
        db
            .select("SELECT title FROM books WHERE id = 'gutenberg:417'")
            .single['title'],
        "Dr. Martin Luther's Deutsche Geistliche Lieder\n"
        'The Hymns of Martin Luther Set to Their Original Melodies, With an English Version',
      );
      expect(
        db
            .select('''
      SELECT a.name FROM book_authors AS ba JOIN authors AS a ON a.id = ba.author_id
      WHERE ba.book_id = 'gutenberg:417' ORDER BY ba.position
    ''')
            .map((row) => row['name']),
        [
          'Luther, Martin, 1483-1546',
          'Allen, Nathan H. (Nathan Hale), 1848-1925 [Editor]',
          'Bacon, Leonard Woolsey, 1830-1907 [Editor]',
        ],
      );
      expect(
        db
            .select('''
      SELECT c.label FROM book_categories AS bc JOIN categories AS c ON c.id = bc.category_id
      WHERE bc.book_id = 'gutenberg:1342' ORDER BY c.label
    ''')
            .map((row) => row['label']),
        ['British Literature', 'Classics of Literature', 'Novels', 'Romance'],
      );
      final editions = db.select('''
      SELECT variant_label, language, acquisition_url, rights_line, size_bytes
      FROM editions WHERE book_id = 'gutenberg:417' ORDER BY display_order
    ''');
      expect(editions.map((row) => row['variant_label']), [
        'With images',
        'Without images',
      ]);
      expect(editions.map((row) => row['acquisition_url']), [
        'https://www.gutenberg.org/ebooks/417.epub3.images',
        'https://www.gutenberg.org/ebooks/417.epub.noimages',
      ]);
      for (final row in editions) {
        expect(row['language'], 'de; en');
        expect(row['size_bytes'], isNull);
        expect(
          row['rights_line'],
          'Rights not listed in the offline catalog. Check Project Gutenberg.',
        );
      }
    },
  );

  test(
    'a bad record leaves no output and an existing output is not replaced',
    () async {
      final dir = tempDataDirectory();
      final input = File('${dir.path}/bad.csv')
        ..writeAsStringSync('${_excerpt.readAsStringSync()}1,Text,invalid\n');
      final output = File('${dir.path}/catalog.sqlite');
      await expectLater(
        importGutenbergFile(input, output),
        throwsFormatException,
      );
      expect(output.existsSync(), isFalse);

      output.writeAsStringSync('existing output');
      await expectLater(
        importGutenbergFile(_excerpt, output),
        throwsA(isA<FileSystemException>()),
      );
      expect(output.readAsStringSync(), 'existing output');
    },
  );

  test(
    'rejects a missing gzip trailer even after the last complete row',
    () async {
      final dir = tempDataDirectory();
      final compressed = gzip.encode(_excerpt.readAsBytesSync());
      final input = File('${dir.path}/truncated.csv.gz')
        ..writeAsBytesSync(compressed.sublist(0, compressed.length - 8));
      final output = File('${dir.path}/catalog.sqlite');
      await expectLater(
        importGutenbergFile(input, output),
        throwsFormatException,
      );
      expect(output.existsSync(), isFalse);
    },
  );

  test('rejects an unclosed quote that would absorb the next record', () async {
    final dir = tempDataDirectory();
    final input = File('${dir.path}/unclosed.csv')
      ..writeAsStringSync('''
Text#,Type,Issued,Title,Language,Authors,Subjects,LoCC,Bookshelves
1,Text,,First,en,,,,"Category: Novels
2,Text,,Second,en,,,,
''');
    final output = File('${dir.path}/catalog.sqlite');
    await expectLater(
      importGutenbergFile(input, output),
      throwsFormatException,
    );
    expect(output.existsSync(), isFalse);
  });

  test('preserves escaped quotes split across file reads', () async {
    final dir = tempDataDirectory();
    const header =
        'Text#,Type,Issued,Title,Language,Authors,Subjects,LoCC,Bookshelves\r\n';
    const beforePadding = '${header}1,Text,,';
    const beforeQuote = ',en,,,,\r\n2,Text,,';
    // Place the opening quote and the first escaped quote in one 64 KiB read,
    // and the second escaped quote in the next one.
    final padding = 'x' * (65534 - beforePadding.length - beforeQuote.length);
    final input = File('${dir.path}/quoted.csv')
      ..writeAsStringSync(
        '$beforePadding$padding$beforeQuote"""The Raven""",en,,,,\r\n',
      );
    final output = File('${dir.path}/catalog.sqlite');
    await importGutenbergFile(input, output);
    final db = sqlite3.open(output.path, mode: OpenMode.readOnly);
    addTearDown(db.close);
    expect(
      db
          .select("SELECT title FROM books WHERE id = 'gutenberg:2'")
          .single['title'],
      '"The Raven"',
    );
  });

  test('preserves a journal beside the requested output', () async {
    final dir = tempDataDirectory();
    final output = File('${dir.path}/catalog.sqlite');
    final journal = File('${output.path}-journal')
      ..writeAsStringSync('unrelated');
    await expectLater(
      importGutenbergFile(_excerpt, output),
      throwsA(isA<FileSystemException>()),
    );
    expect(output.existsSync(), isFalse);
    expect(journal.readAsStringSync(), 'unrelated');
  });
}
