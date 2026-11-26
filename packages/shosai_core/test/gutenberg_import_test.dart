import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import '../tool/export_catalog_json.dart';
import '../tool/import_gutenberg.dart';
import 'support/temp_store.dart';

// The excerpt contains four records from Project Gutenberg's public-domain
// offline CSV (mirror.cs.odu.edu/gutenberg-epub/feeds/pg_catalog.csv.gz,
// retrieved 2026-11-19), with line endings normalized to LF.
final _excerpt = File('test/fixtures/pg_catalog_excerpt.csv');
final _rdf = File('test/fixtures/pg_catalog_excerpt.rdf');

void main() {
  test('only personal-name inversions are reordered', () {
    // Real Gutenberg agents that are not personal-name inversions, the first
    // five from ebooks 32155, 2811, 53979, 69367 and 47147.
    const kept = [
      'Henry VIII, King of England',
      'Pliny, the Younger',
      'Alfred A. Knopf, Inc.',
      'Anti-slavery Society of Meriden, Conn.',
      'British Museum (Natural History). Department of Mineralogy',
      'Chrétien, de Troyes',
    ];
    expect(
      [
        'Austen, Jane',
        'Wells, H. G. (Herbert George)',
        'Beethoven, Ludwig van',
        'Tolkien, J.R.R.',
        ...kept,
      ].map(readingOrder),
      [
        'Jane Austen',
        'H. G. Wells',
        'Ludwig van Beethoven',
        'J.R.R. Tolkien',
        ...kept,
      ],
    );
  });

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
      final document = XmlDocument.parse(
        _rdf.readAsStringSync().replaceFirst(
          '<d:rights>Public domain in the USA.</d:rights>',
          '<d:rights>Public domain in the USA.</d:rights>'
              '<d:rights>Check rights outside the USA.</d:rights>'
              '<d:rights> Public domain in the USA. </d:rights>'
              '<d:rights> </d:rights>',
        ),
      );
      if (index == 1) {
        final children = document.rootElement.children.reversed
            .map((node) => node.copy())
            .toList();
        document.rootElement.children
          ..clear()
          ..addAll(children);
        for (final ebook in document.rootElement.childElements) {
          final formats = ebook.children.reversed
              .map((node) => node.copy())
              .toList();
          ebook.children
            ..clear()
            ..addAll(formats);
        }
      }
      final rdf = File('${dir.path}/$index.rdf')
        ..writeAsStringSync(document.toXmlString());
      await importGutenbergFile(input, db, rdf: rdf);
      final imported = sqlite3.open(db.path, mode: OpenMode.readOnly);
      try {
        expect(
          imported
              .select(
                "SELECT DISTINCT rights_line FROM editions WHERE book_id = 'gutenberg:417'",
              )
              .single['rights_line'],
          'Check rights outside the USA.\nPublic domain in the USA.',
        );
      } finally {
        imported.close();
      }
      exportCatalogJson(
        db.path,
        '${dir.path}/export$index',
        previous: index == 0 ? null : '${dir.path}/export0',
      );
    }
    expect(contents('${dir.path}/export1'), contents('${dir.path}/export0'));
  });

  test(
    'imports search metadata and only RDF-listed EPUBs with their sizes and rights',
    () async {
      final dir = tempDataDirectory();
      final input = File('${dir.path}/pg_catalog.csv.gz')
        ..writeAsBytesSync(gzip.encode(_excerpt.readAsBytesSync()));
      final output = File('${dir.path}/catalog.sqlite');
      expect(await importGutenbergFile(input, output, rdf: _rdf), (
        works: 3,
        editions: 5,
        skipped: 1,
      ));
      final db = sqlite3.open(output.path, mode: OpenMode.readOnly);
      addTearDown(db.close);
      expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      expect(
        db
            .select("SELECT support_url FROM sources WHERE id = 'gutenberg'")
            .single['support_url'],
        'https://www.gutenberg.org/donate/',
      );
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
      expect(db.select('SELECT * FROM author_details ORDER BY author_id'), [
        {
          'author_id':
              'gutenberg:Allen, Nathan H. (Nathan Hale), 1848-1925 [Editor]',
          'display_name': 'Nathan H. Allen',
          'birth_year': 1848,
          'death_year': null,
        },
        {
          'author_id': 'gutenberg:Austen, Jane, 1775-1817',
          'display_name': 'Jane Austen',
          'birth_year': 1775,
          'death_year': 1817,
        },
        {
          'author_id': 'gutenberg:Luther, Martin, 1483-1546',
          'display_name': 'Martin Luther',
          'birth_year': 1483,
          'death_year': 1546,
        },
      ]);
      expect(db.select('SELECT * FROM book_details ORDER BY book_id'), [
        {
          'book_id': 'gutenberg:1342',
          'summary':
              'A novel of manners. (This is an automatically generated summary.)',
          'reading_ease': 69,
        },
        {'book_id': 'gutenberg:417', 'summary': null, 'reading_ease': -13},
      ]);
      expect(
        db.select('SELECT support_url FROM sources').single['support_url'],
        'https://www.gutenberg.org/donate/',
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
        'EPUB3 with images',
        'EPUB2 with images',
        'EPUB2 without images',
      ]);
      expect(editions.map((row) => row['acquisition_url']), [
        'https://www.gutenberg.org/ebooks/417.epub3.images',
        'https://www.gutenberg.org/ebooks/417.epub.images',
        'https://www.gutenberg.org/ebooks/417.epub.noimages',
      ]);
      expect(editions.map((row) => row['size_bytes']), [875432, 887654, 41234]);
      for (final row in editions) {
        expect(row['language'], 'de; en');
        expect(row['rights_line'], 'Public domain in the USA.');
      }
      for (final (id, variant, size) in [
        ('1342', 'EPUB3 with images', 24836548),
        ('42671', 'EPUB2 without images', null),
      ]) {
        final row = db.select('SELECT * FROM editions WHERE book_id = ?', [
          'gutenberg:$id',
        ]).single;
        expect(row['variant_label'], variant);
        expect(row['size_bytes'], size);
        expect(row['display_order'], 0);
      }
      expect(
        db
            .select(
              "SELECT rights_line FROM editions WHERE book_id = 'gutenberg:42671'",
            )
            .single['rights_line'],
        'Rights not listed in the offline catalog. Check Project Gutenberg.',
      );
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
        importGutenbergFile(input, output, rdf: _rdf),
        throwsFormatException,
      );
      expect(output.existsSync(), isFalse);

      output.writeAsStringSync('existing output');
      await expectLater(
        importGutenbergFile(_excerpt, output, rdf: _rdf),
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
        importGutenbergFile(input, output, rdf: _rdf),
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
      importGutenbergFile(input, output, rdf: _rdf),
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
    final rdf = File('${dir.path}/quoted.rdf')
      ..writeAsStringSync(
        _rdf
            .readAsStringSync()
            .replaceAll('1342', '1')
            .replaceAll('42671', '2'),
      );
    await importGutenbergFile(input, output, rdf: rdf);
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
      importGutenbergFile(_excerpt, output, rdf: _rdf),
      throwsA(isA<FileSystemException>()),
    );
    expect(output.existsSync(), isFalse);
    expect(journal.readAsStringSync(), 'unrelated');
  });

  test('does not invent EPUBs for missing RDF or a non-EPUB MIME type', () async {
    final dir = tempDataDirectory();
    final input = File('${dir.path}/catalog.csv')
      ..writeAsStringSync(
        '${_excerpt.readAsStringSync()}99,Text,,HTML only,en,,,,\n100,Text,,Missing RDF,en,,,,\n',
      );
    final output = File('${dir.path}/catalog.sqlite');
    expect(await importGutenbergFile(input, output, rdf: _rdf), (
      works: 3,
      editions: 5,
      skipped: 3,
    ));
    final db = sqlite3.open(output.path, mode: OpenMode.readOnly);
    addTearDown(db.close);
    expect(
      db.select(
        "SELECT id FROM books WHERE id IN ('gutenberg:99', 'gutenberg:100')",
      ),
      isEmpty,
    );
  });

  test(
    'lists standard EPUBs only for a release whose RDF has just its uploads',
    () async {
      final dir = tempDataDirectory();
      final input = File('${dir.path}/catalog.csv')
        ..writeAsStringSync(
          '${_excerpt.readAsStringSync()}'
          '79882,Text,2026-10-30,Gallipoli memories,en,,,,\n'
          '59248,Text,2019-04-11,The Mathematical Theory of Relativity,en,,,,\n'
          '70427,Text,2022-04-01,Generated HTML only,en,,,,\n',
        );
      final output = File('${dir.path}/catalog.sqlite');
      expect(await importGutenbergFile(input, output, rdf: _rdf), (
        works: 4,
        editions: 7,
        skipped: 3,
      ));
      final db = sqlite3.open(output.path, mode: OpenMode.readOnly);
      addTearDown(db.close);
      expect(
        db
            .select('''
      SELECT book_id, variant_label, display_order, acquisition_url,
        size_bytes, rights_line
      FROM editions WHERE book_id IN
        ('gutenberg:79882', 'gutenberg:59248', 'gutenberg:70427')
      ORDER BY book_id, display_order
    ''')
            .map((row) => row.values),
        [
          [
            'gutenberg:79882',
            'EPUB3 with images',
            0,
            'https://www.gutenberg.org/ebooks/79882.epub3.images',
            null,
            'Public domain in the USA.',
          ],
          [
            'gutenberg:79882',
            'EPUB2 without images',
            1,
            'https://www.gutenberg.org/ebooks/79882.epub.noimages',
            null,
            'Public domain in the USA.',
          ],
        ],
      );
    },
  );

  test(
    'streams independent RDF documents from an archive without extracting files',
    () async {
      final dir = tempDataDirectory();
      final rdf = File('${dir.path}/one.rdf')
        ..writeAsStringSync(_rdf.readAsStringSync());
      final extra = File('${dir.path}/two.rdf')
        ..writeAsStringSync('''
<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>
''');
      final archive = File('${dir.path}/rdf-files.tar.bz2');
      final tar = await Process.run('tar', [
        '-cjf',
        archive.path,
        '-C',
        dir.path,
        'two.rdf',
        'one.rdf',
      ]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');
      rdf.deleteSync();
      extra.deleteSync();
      final output = File('${dir.path}/catalog.sqlite');
      expect(await importGutenbergFile(_excerpt, output, rdf: archive), (
        works: 3,
        editions: 5,
        skipped: 1,
      ));
      expect(rdf.existsSync(), isFalse);
      expect(extra.existsSync(), isFalse);

      // Complete XML is not sufficient when the compressed archive is truncated.
      final bytes = archive.readAsBytesSync();
      archive.writeAsBytesSync(bytes.sublist(0, bytes.length - 8));
      final broken = File('${dir.path}/broken.sqlite');
      await expectLater(
        importGutenbergFile(_excerpt, broken, rdf: archive),
        throwsFormatException,
      );
      expect(broken.existsSync(), isFalse);
    },
  );

  test(
    'rejects invalid RDF archive members without a partial output',
    () async {
      final dir = tempDataDirectory();
      final valid = _rdf.readAsStringSync();
      for (final (first, second) in [
        (valid, 'temporarily unavailable'),
        (valid, ''),
        (valid.replaceFirst('</rdf:RDF>', ''), '</rdf:RDF>'),
      ]) {
        File('${dir.path}/one.rdf').writeAsStringSync(first);
        File('${dir.path}/two.rdf').writeAsStringSync(second);
        final archive = File('${dir.path}/rdf-files.tar.bz2');
        final tar = await Process.run('tar', [
          '-cjf',
          archive.path,
          '-C',
          dir.path,
          'one.rdf',
          'two.rdf',
        ]);
        expect(tar.exitCode, 0, reason: '${tar.stderr}');
        final output = File('${dir.path}/catalog.sqlite');
        await expectLater(
          importGutenbergFile(_excerpt, output, rdf: archive),
          throwsA(isA<Exception>()),
          reason: 'Every archive member must be a complete RDF document',
        );
        expect(output.existsSync(), isFalse);
      }
    },
  );

  test(
    'decodes rights entities identically across plain and archived read boundaries',
    () async {
      final dir = tempDataDirectory();
      final text = _rdf.readAsStringSync().replaceFirst(
        'Public domain in the USA.',
        'Terms &amp; conditions',
      );
      final padding = 65534 - text.indexOf('&amp;') - 7;
      final rdf = File('${dir.path}/boundary.rdf')
        ..writeAsStringSync(
          text.replaceFirst('<p:ebook', '<!--${'x' * padding}--><p:ebook'),
        );
      expect(rdf.readAsStringSync().indexOf('&amp;'), 65534);
      final archive = File('${dir.path}/boundary.tar.bz2');
      final tar = await Process.run('tar', [
        '-cjf',
        archive.path,
        '-C',
        dir.path,
        'boundary.rdf',
      ]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');
      for (final (index, input) in [rdf, archive].indexed) {
        final output = File('${dir.path}/$index.sqlite');
        await importGutenbergFile(_excerpt, output, rdf: input);
        final db = sqlite3.open(output.path, mode: OpenMode.readOnly);
        try {
          expect(
            db
                .select(
                  "SELECT DISTINCT rights_line FROM editions WHERE book_id = 'gutenberg:417'",
                )
                .single['rights_line'],
            'Terms & conditions',
          );
        } finally {
          db.close();
        }
      }
    },
  );

  test(
    'rejects malformed RDF, invalid sizes and unsafe EPUB URLs without output',
    () async {
      final dir = tempDataDirectory();
      for (final text in [
        '',
        'temporarily unavailable',
        '${_rdf.readAsStringSync()}temporarily unavailable',
        'temporarily unavailable${_rdf.readAsStringSync()}',
        '${_rdf.readAsStringSync()}<![CDATA[outside root]]>',
        '${_rdf.readAsStringSync()}${_rdf.readAsStringSync()}',
        _rdf.readAsStringSync().replaceFirst(
          '<p:file rdf:about=',
          '<p:file rdf:about="https://www.gutenberg.org/ebooks/1342.epub3.images" rdf:about=',
        ),
        _rdf.readAsStringSync().replaceFirst(
          '<p:file rdf:about=',
          '<p:file xmlns:alias="http://www.w3.org/1999/02/22-rdf-syntax-ns#" '
              'alias:about="https://www.gutenberg.org/ebooks/1342.epub3.images" rdf:about=',
        ),
        _rdf.readAsStringSync().replaceFirst('</rdf:RDF>', ''),
        _rdf.readAsStringSync().replaceFirst('<d:extent>41234', '<d:extent>0'),
        _rdf.readAsStringSync().replaceFirst(
          'https://www.gutenberg.org/ebooks/417.epub.noimages',
          'https://untrusted.example/417.epub',
        ),
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>',
      ]) {
        final input = File('${dir.path}/bad.rdf')..writeAsStringSync(text);
        final output = File('${dir.path}/catalog.sqlite');
        await expectLater(
          importGutenbergFile(_excerpt, output, rdf: input),
          throwsA(isA<Exception>()),
        );
        expect(output.existsSync(), isFalse);
      }
    },
  );
}
