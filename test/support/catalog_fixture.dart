import 'dart:io';

import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:shosai_core/src/catalog/catalog_database.dart'
    show importCatalog;

import '../../packages/shosai_core/tool/export_catalog_json.dart';
import 'production_shell_harness.dart';

/// Real local catalog, with enough asymmetric content to exercise paging,
/// author selection, alternate editions, filters and offline failure.
CatalogClient createCatalogFixture(
  Directory root, {
  int editionCount = 2,
  String? supportUrl = 'https://www.gutenberg.org/donate/',
}) {
  root.createSync(recursive: true);
  final db = sqlite3.open('${root.path}/upstream.sqlite3');
  try {
    db.execute(catalogSchema);
    db.execute(
      "INSERT INTO sources VALUES ('gutenberg', 'Project Gutenberg', 'https://www.gutenberg.org', 'Catalog from Project Gutenberg', ?)",
      [supportUrl],
    );
    db.execute(
      "INSERT INTO authors VALUES ('austen', 'Jane Austen', 'Austen', NULL), ('soseki', '夏目漱石', '夏目', 'なつめ')",
    );
    db.execute(
      "INSERT INTO subjects VALUES ('love', 'Love stories'); INSERT INTO categories VALUES ('fiction', 'Fiction'), ('history', 'History')",
    );
    db.execute(
      "INSERT INTO author_details VALUES ('austen', 'Jane Austen', 1775, 1817)",
    );
    for (var i = 0; i < 37; i++) {
      final id = i.toString();
      final title = i == 0
          ? 'Pride and Prejudice'
          : i == 1
          ? '吾輩は猫である'
          : 'A study of stories — Volume $i';
      db.execute('INSERT INTO books VALUES (?, ?)', [id, title]);
      db.execute('INSERT INTO book_authors VALUES (?, ?, 0)', [
        id,
        i == 1 ? 'soseki' : 'austen',
      ]);
      db.execute("INSERT INTO book_categories VALUES (?, 'fiction')", [id]);
      db.execute("INSERT INTO book_subjects VALUES (?, 'love')", [id]);
      if (i == 0) {
        // Project Gutenberg's published summary for ebook 1342.
        db.execute('INSERT INTO book_details VALUES (?, ?, ?)', [
          id,
          '"Pride and Prejudice" by Jane Austen is a novel published in 1813. '
              'It follows Elizabeth Bennet, who must learn to see past first '
              'impressions and hasty judgments. When wealthy Mr. Darcy arrives '
              "in their countryside neighborhood, his pride and Elizabeth's "
              'prejudice set the stage for misunderstandings, hidden truths, '
              'and unexpected revelations about character and love. (This is '
              'an automatically generated summary.)',
          69,
        ]);
      }
      for (var e = 0; e < editionCount; e++) {
        db.execute(
          'INSERT INTO editions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [
            'gutenberg',
            '$id:$e',
            id,
            title,
            switch (e) {
              0 => 'With images',
              1 => 'Without images',
              _ => 'Additional variant ${e + 1}',
            },
            e,
            i == 1 ? 'ja' : 'en',
            'https://www.gutenberg.org/ebooks/$id',
            e == 0
                ? 'Public domain in the USA. Check the law where you live.'
                : 'Alternate edition rights — check the source.',
            'https://www.gutenberg.org/ebooks/$id.epub',
            'epub',
            e == 0 ? 123456 : null,
            null,
          ],
        );
      }
    }
  } finally {
    db.close();
  }
  final stage = '${root.path}/snapshot';
  exportCatalogJson('${root.path}/upstream.sqlite3', stage);
  importCatalog(stage, File('$stage/manifest.json').readAsStringSync());
  File('$stage/catalog.sqlite3').copySync('${root.path}/catalog.sqlite3');
  return CatalogClient(
    root.path,
    userAgent: 'Shosai-test',
    snapshot: Uri.parse('http://127.0.0.1:1/'),
  );
}

class CatalogHarnessBridge extends HarnessBridge
    implements CatalogHost, CatalogAcquisitionHost {
  CatalogHarnessBridge(this.catalog, {List<FlutterLibraryBook>? books})
    : super(books: books ?? harnessLibraryBooks());
  @override
  final CatalogClient catalog;

  List<String> recentSearches = [];
  @override
  Future<List<String>> recentCatalogSearches() async =>
      List.unmodifiable(recentSearches);
  @override
  Future<void> saveRecentCatalogSearches(List<String> queries) async {
    recentSearches = List.of(queries);
  }

  @override
  Future<CatalogSaveOptions> catalogSaveOptions() async => (
    locations: [
      (
        id: 'drive',
        label: 'Google Drive · Books',
        generation: 1,
        directory: 'books',
      ),
    ],
    selected: null,
  );
  @override
  Future<void> selectCatalogSaveLocation(String? id) async {}
  @override
  Future<CatalogAddedBook> addCatalogBook({
    required String bookId,
    required String sourceId,
    required String editionId,
    required String? locationId,
    required ({int generation, String? directory})? destination,
    required BigInt cancellationId,
    void Function(int, int?)? progress,
  }) async =>
      throw UnsupportedError('This browsing fixture does not download books.');
}
