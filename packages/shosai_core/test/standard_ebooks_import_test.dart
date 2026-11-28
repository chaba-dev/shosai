import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../tool/export_catalog_json.dart';
import '../tool/import_standard_ebooks.dart';
import 'support/temp_store.dart';

String _opf({
  required String identifier,
  required String title,
  required List<String> sources,
  String extra = '',
}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">https://standardebooks.org/ebooks/$identifier</dc:identifier>
    <dc:date>2022-01-01T23:35:25Z</dc:date>
    <dc:title id="title">$title</dc:title>
    <dc:language>en-GB</dc:language>
    ${[for (final source in sources) '<dc:source>$source</dc:source>'].join()}
    $extra
  </metadata>
  <manifest/>
</package>''';

void main() {
  test('joins Gutenberg works by their single source; others stand alone', () {
    final directory = tempDataDirectory();
    final path = '${directory.path}/catalog.sqlite';
    final db = sqlite3.open(path);
    addTearDown(db.close);
    db.execute(catalogSchema);
    db.execute(File('test/fixtures/gutenberg_catalog.sql').readAsStringSync());
    final pride = _opf(
      identifier: 'jane-austen/pride-and-prejudice',
      title: 'Pride and Prejudice: An Edited Title',
      sources: [
        'https://www.gutenberg.org/ebooks/1342',
        'https://archive.org/details/prideprejudice00aust',
      ],
      extra: '''
    <dc:creator id="author">Jane Austen</dc:creator>
    <meta property="file-as" refines="#author">Austen, Jane</meta>
    <meta property="schema:abstract">A spirited young woman meets a proud gentleman.</meta>
    <meta property="schema:wordCount">121533</meta>
    <meta property="schema:educationalLevel">63.4</meta>
    <meta property="schema:genre">Fiction</meta>''',
    );
    // A repository name may be truncated; the identifier names the download.
    final simplicissimus = _opf(
      identifier: 'h-j-c-von-grimmelshausen/simplicissimus/alfred-goodrick',
      title: 'The Adventurous Simplicissimus',
      sources: [
        'https://www.gutenberg.org/ebooks/33858',
        'https://www.gutenberg.org/files/33859/33859-h/33859-h.htm',
      ],
      extra: '''
    <dc:creator id="author">Hans Jakob Christoffel von Grimmelshausen</dc:creator>
    <meta property="file-as" refines="#author">Grimmelshausen, Hans Jakob Christoffel von</meta>
    <dc:subject id="subject-1">Picaresque literature</dc:subject>
    <meta property="authority" refines="#subject-1">LCSH</meta>
    <dc:subject id="subject-2">Not authoritative</dc:subject>
    <meta property="schema:genre">Adventure</meta>
    <meta property="schema:genre">Satire</meta>
    <meta property="schema:genre">Fiction</meta>
    <meta id="collection-1" property="belongs-to-collection">Simplicius</meta>
    <meta property="collection-type" refines="#collection-1">series</meta>
    <meta property="group-position" refines="#collection-1">1</meta>
    <meta id="collection-2" property="belongs-to-collection">Great Novels</meta>
    <meta property="collection-type" refines="#collection-2">set</meta>
    <dc:description>
      &lt;p&gt;A boy is swept up in the &lt;i&gt;Thirty&amp;nbsp;Years’
      War&lt;/i&gt;.&lt;/p&gt;
      &lt;p&gt;&lt;a href="https://standardebooks.org/x"&gt;He&lt;/a&gt; survives.&lt;/p&gt;
    </dc:description>''',
    );
    final cover = 'b' * 40;
    final result = importStandardEbooks(db, [
      (
        repository: 'h-j-c-von-grimmelshausen_simplicissimus_alfred-goodr',
        opf: simplicissimus,
        cover: cover,
      ),
      (repository: 'jane-austen_pride-and-prejudice', opf: pride, cover: null),
    ]);
    expect(result, (editions: 2, joined: 1));

    // The Standard Ebooks edition comes first; Gutenberg's keep their order.
    expect(
      db
          .select(
            'SELECT source_edition_id, display_order, language, cover_url '
            "FROM editions WHERE book_id = 'gutenberg:1342' ORDER BY display_order",
          )
          .map((row) => row.values.toList()),
      [
        ['jane-austen/pride-and-prejudice', 0, 'en', null],
        ['1342:z', 1, 'en', null],
        ['1342:a', 2, 'en', null],
      ],
    );
    // A joined work keeps Gutenberg's authors; its title and details are
    // Standard Ebooks'.
    expect(db.select("SELECT title FROM books WHERE id = 'gutenberg:1342'"), [
      {'title': 'Pride and Prejudice: An Edited Title'},
    ]);
    expect(
      db.select("SELECT * FROM book_details WHERE book_id = 'gutenberg:1342'"),
      [
        {
          'book_id': 'gutenberg:1342',
          'summary': 'A spirited young woman meets a proud gentleman.',
          'reading_ease': 63,
          'description': null,
          'word_count': 121533,
          'released': '2022-01-01',
          'released_by': 'standardebooks',
        },
      ],
    );
    expect(
      db.select(
        "SELECT author_id FROM book_authors WHERE book_id = 'gutenberg:1342'",
      ),
      [
        {'author_id': 'gutenberg:68'},
      ],
    );

    const work =
        'standardebooks:h-j-c-von-grimmelshausen/simplicissimus/alfred-goodrick';
    expect(db.select('SELECT * FROM editions WHERE book_id = ?', [work]), [
      {
        'source_id': 'standardebooks',
        'source_edition_id':
            'h-j-c-von-grimmelshausen/simplicissimus/alfred-goodrick',
        'book_id': work,
        'title': 'The Adventurous Simplicissimus',
        'variant_label': 'Standard Ebooks edition',
        'display_order': 0,
        'language': 'en',
        'source_url':
            'https://standardebooks.org/ebooks/h-j-c-von-grimmelshausen/simplicissimus/alfred-goodrick',
        'rights_line': 'Public domain in the USA.',
        'acquisition_url':
            'https://standardebooks.org/ebooks/h-j-c-von-grimmelshausen/simplicissimus/alfred-goodrick'
            '/downloads/h-j-c-von-grimmelshausen_simplicissimus_alfred-goodrick.epub?source=download',
        'acquisition_format': 'epub',
        'size_bytes': null,
        'cover_url': 'thumbnails/$cover.jpg',
      },
    ]);
    expect(
      db
          .select(
            '''SELECT a.name, d.display_name FROM book_authors ba
        JOIN authors a ON a.id = ba.author_id
        JOIN author_details d ON d.author_id = a.id WHERE ba.book_id = ?''',
            [work],
          )
          .map((row) => row.values.toList()),
      [
        [
          'Grimmelshausen, Hans Jakob Christoffel von',
          'Hans Jakob Christoffel von Grimmelshausen',
        ],
      ],
    );
    expect(
      db.select('SELECT description FROM book_details WHERE book_id = ?', [
        work,
      ]).single['description'],
      'A boy is swept up in the Thirty\u00a0Years’ War.\n\nHe survives.',
    );
    expect(
      db
          .select('SELECT subject_id FROM book_subjects WHERE book_id = ?', [
            work,
          ])
          .map((row) => row['subject_id']),
      ['lcsh:Picaresque literature'],
    );
    expect(
      db
          .select(
            '''SELECT c.id, c.label FROM book_categories bc
        JOIN categories c ON c.id = bc.category_id
        WHERE bc.book_id = ? ORDER BY c.id''',
            [work],
          )
          .map((row) => row.values.toList()),
      [
        ['gutenberg:Adventure', 'Adventure'],
        ['gutenberg:Humour', 'Humour'],
      ],
    );
    expect(db.select('SELECT * FROM book_series'), [
      {'book_id': work, 'series': 'Simplicius', 'position': 1},
    ]);
    db.close();

    // The export publishes referenced thumbnails apart from the catalog files.
    final thumbnails = Directory('${directory.path}/thumbnails')..createSync();
    File('${thumbnails.path}/$cover.jpg').writeAsBytesSync([1, 2, 3]);
    final output = '${directory.path}/snapshot';
    exportCatalogJson(path, output, thumbnails: thumbnails.path);
    final manifest = CatalogManifest.parse(
      File('$output/manifest.json').readAsStringSync(),
    );
    expect(manifest.sourceCounts, {'gutenberg': 2, 'standardebooks': 2});
    expect(manifest.thumbnails.keys, ['thumbnails/$cover.jpg']);
    expect(
      manifest.files.keys.where((key) => key.startsWith('thumbnails/')),
      isEmpty,
    );
    expect(File('$output/thumbnails/$cover.jpg').readAsBytesSync(), [1, 2, 3]);
    expect(
      () => exportCatalogJson(path, '${directory.path}/missing'),
      throwsFormatException,
    );
    // Only canonical thumbnail names or absolute HTTP(S) covers export.
    final edit = sqlite3.open(path);
    edit.execute(
      "UPDATE editions SET cover_url = 'http-cover.jpg' WHERE source_id = 'standardebooks' AND cover_url IS NOT NULL",
    );
    edit.close();
    expect(
      () => exportCatalogJson(
        path,
        '${directory.path}/odd',
        thumbnails: thumbnails.path,
      ),
      throwsFormatException,
    );
  });

  test('GraphQL errors fail a listing page even with partial data', () {
    final node = {
      'name': 'a_b',
      'isArchived': false,
      'defaultBranchRef': {
        'target': {'oid': 'c' * 40},
      },
      'opf': {'oid': 'd' * 40},
      'cover': null,
    };
    Map<String, Object?> page({List<Object?>? errors}) => {
      'data': {
        'organization': {
          'repositories': {
            'pageInfo': {'hasNextPage': true, 'endCursor': 'next'},
            'nodes': [node],
          },
        },
      },
      'errors': ?errors,
    };
    final ok = parseRepositoryPage(page());
    expect(ok.next, 'next');
    expect(ok.repositories.single.cover, isNull);
    expect(
      () => parseRepositoryPage(
        page(
          errors: [
            {
              'message': 'timeout',
              'path': ['organization'],
            },
          ],
        ),
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('descriptions keep inline text in order', () {
    expect(
      plainDescription('Before <i>middle</i> after.'),
      'Before middle after.',
    );
    expect(
      plainDescription('<p>One <b>two</b></p> loose <p>three</p>'),
      'One two\n\nloose\n\nthree',
    );
    expect(plainDescription('<p> </p>'), isNull);
  });

  test('sparse records add no details; a shared source joins nothing', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(catalogSchema);
    db.execute(File('test/fixtures/gutenberg_catalog.sql').readAsStringSync());
    String opf(String identifier, String title, String date) => _opf(
      identifier: identifier,
      title: title,
      sources: ['https://www.gutenberg.org/ebooks/1342'],
      extra: '<dc:creator>Jane Austen</dc:creator>',
    ).replaceFirst('2022-01-01T23:35:25Z', date);
    importStandardEbooks(db, [
      (
        repository: 'z',
        opf: opf('jane-austen/z', 'Zed', '2024-19-39'),
        cover: null,
      ),
      (
        repository: 'a',
        opf: opf('jane-austen/a', 'Ay', 'not a date'),
        cover: null,
      ),
    ]);
    // Both name Gutenberg 1342, so it is a collection and neither joins it.
    expect(
      db
          .select('SELECT id, title FROM books ORDER BY id')
          .map((row) => row.values.toList()),
      [
        ['gutenberg:1342', 'Pride and Prejudice'],
        ['standardebooks:jane-austen/a', 'Ay'],
        ['standardebooks:jane-austen/z', 'Zed'],
      ],
    );
    // Neither has a summary, reading ease, description, words or a real date.
    expect(
      db
          .select('SELECT book_id FROM book_details')
          .map((row) => row['book_id']),
      ['gutenberg:1342'],
    );
  });

  test('a source a multi-source book also cites joins nothing', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(catalogSchema);
    db.execute(File('test/fixtures/gutenberg_catalog.sql').readAsStringSync());
    importStandardEbooks(db, [
      (
        repository: 'a',
        opf: _opf(
          identifier: 'jane-austen/a',
          title: 'Ay',
          sources: ['https://www.gutenberg.org/ebooks/1342'],
          extra: '<dc:creator>Jane Austen</dc:creator>',
        ),
        cover: null,
      ),
      (
        repository: 'b',
        opf: _opf(
          identifier: 'jane-austen/b',
          title: 'Bee',
          sources: [
            'https://www.gutenberg.org/ebooks/1342',
            'https://www.gutenberg.org/ebooks/105',
          ],
          extra: '<dc:creator>Jane Austen</dc:creator>',
        ),
        cover: null,
      ),
    ]);
    expect(
      db
          .select('SELECT id, title FROM books ORDER BY id')
          .map((row) => row.values.toList()),
      [
        ['gutenberg:1342', 'Pride and Prejudice'],
        ['standardebooks:jane-austen/a', 'Ay'],
        ['standardebooks:jane-austen/b', 'Bee'],
      ],
    );
  });

  test('a sparse joining book clears Gutenberg details', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(catalogSchema);
    db.execute(File('test/fixtures/gutenberg_catalog.sql').readAsStringSync());
    final result = importStandardEbooks(db, [
      (
        repository: 'a',
        opf: _opf(
          identifier: 'jane-austen/a',
          title: 'Ay',
          sources: ['https://www.gutenberg.org/ebooks/1342'],
          extra: '<dc:creator>Jane Austen</dc:creator>',
        ).replaceFirst('2022-01-01T23:35:25Z', 'undated'),
        cover: null,
      ),
    ]);
    expect(result, (editions: 1, joined: 1));
    expect(db.select('SELECT title FROM books').single['title'], 'Ay');
    expect(db.select('SELECT * FROM book_details'), isEmpty);
  });

  test('a malformed record fails the whole import', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(catalogSchema);
    expect(
      () => importStandardEbooks(db, [
        (
          repository: 'someone_something',
          opf: _opf(
            identifier: '../escape',
            title: 'Something',
            sources: [],
            extra: '<dc:creator>Someone</dc:creator>',
          ),
          cover: null,
        ),
      ]),
      throwsFormatException,
    );
    expect(db.select('SELECT * FROM sources'), isEmpty);
  });

  test('thumbnails are small, deterministic JPEGs without metadata', () {
    final cover = img.Image(width: 1400, height: 2100)
      ..exif.imageIfd['Artist'] = 'Someone';
    img.fill(cover, color: img.ColorRgb8(200, 80, 20));
    final bytes = img.encodeJpg(cover);
    final thumbnail = makeThumbnail(bytes);
    final decoded = img.decodeJpg(thumbnail)!;
    expect((decoded.width, decoded.height), (300, 450));
    expect(decoded.exif.isEmpty, isTrue);
    expect(thumbnail.length, lessThan(bytes.length));
    expect(makeThumbnail(bytes), thumbnail);
  });
}
