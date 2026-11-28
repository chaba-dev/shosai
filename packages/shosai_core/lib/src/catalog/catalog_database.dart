/// Worker-isolate catalog import and reads. No library database is opened here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../catalog.dart';
import '../search/case_fold.dart';

typedef CatalogBook = ({
  String id,
  String title,
  List<String> authors,
  String? coverUrl,
  List<String> sources,
});
typedef CatalogAuthor = ({String id, String name, int books});
typedef CatalogFilters = ({
  List<String> languages,
  List<({String id, String name})> sources,
});
typedef CatalogCategory = ({String id, String label, int books});
typedef CatalogEdition = ({
  String sourceId,
  String editionId,
  String sourceName,
  String sourceWebsite,
  String? catalogCredit,
  String? supportUrl,
  String variant,
  String language,
  String sourceUrl,
  String rights,
  String acquisitionUrl,
  String format,
  int? sizeBytes,
  String? coverUrl,
});

/// A work's author as the details page names them: the reading-order name
/// when the catalog supplies one, life years when known, and their book count.
typedef CatalogBookAuthor = ({
  String id,
  String name,
  int? birthYear,
  int? deathYear,
  int books,
});
typedef CatalogBookDetails = ({
  CatalogBook book,
  List<CatalogEdition> editions,
  List<String> subjects,
  List<CatalogBookAuthor> authors,
  String? summary,
  int? readingEase,

  /// The long description, as plain paragraphs separated by blank lines.
  String? description,
  int? wordCount,

  /// The calendar date (`YYYY-MM-DD`) a source released its edition: never a
  /// publication year.
  String? released,

  /// The name of the source that released the edition on [released].
  String? releasedBy,

  /// The series the book belongs to, with its position when numbered.
  List<({String name, int? position})> series,

  /// Up to [catalogMoreByAuthorLimit] other books by the first author.
  List<CatalogBook> moreByAuthor,
});

const catalogMoreByAuthorLimit = 12;

bool catalogMatches(String path, CatalogManifest candidate) {
  if (!File(path).existsSync()) return false;
  try {
    return _read(path, (db) {
      // An older catalog is never current, whatever its manifest says.
      if (db.userVersion != catalogDatabaseVersion) return false;
      // An intact manifest does not establish that the search pages survived.
      // This runs only on an eligible refresh, off the UI isolate.
      if (db
          .select('PRAGMA integrity_check')
          .any((row) => row.values.single != 'ok')) {
        return false;
      }
      final rows = db.select('SELECT manifest FROM catalog_metadata');
      if (rows.length != 1 || rows.single['manifest'] is! String) return false;
      final installed = CatalogManifest.parse(
        rows.single['manifest'] as String,
      );
      return installed.files.length == candidate.files.length &&
          installed.files.entries.every(
            (e) => candidate.files[e.key] == e.value,
          ) &&
          installed.sourceCounts.length == candidate.sourceCounts.length &&
          installed.sourceCounts.entries.every(
            (e) => candidate.sourceCounts[e.key] == e.value,
          );
    });
  } on SqliteException {
    return false;
  } on FormatException {
    return false;
  }
}

/// Loads a verified snapshot that [stage] holds. Relative edition cover URLs
/// name inventoried thumbnails and are resolved against [root], the snapshot
/// URL the files came from.
void importCatalog(String stage, String manifestText, Uri root) {
  final manifest = CatalogManifest.parse(manifestText);
  // Verify even inventory entries that this version does not interpret.
  for (final entry in manifest.files.entries) {
    final bytes = File('$stage/${entry.key}').readAsBytesSync();
    if (bytes.length != entry.value.sizeBytes ||
        sha256.convert(bytes).toString() != entry.value.sha256) {
      throw FormatException('Catalog checksum mismatch: ${entry.key}');
    }
  }
  final db = sqlite3.open('$stage/catalog.sqlite3');
  try {
    db.execute(catalogSchema);
    db.execute('BEGIN');
    for (final entry in {
      ...catalogTables,
      // Earlier snapshots omit the descriptive tables; they then stay empty.
      for (final optional in optionalCatalogTables.entries)
        if (manifest.files.containsKey('${optional.key}/0.json'))
          optional.key: optional.value,
    }.entries) {
      final table = entry.key;
      final fields = db.select('PRAGMA table_info($table)');
      final columns = fields.map((row) => row['name'] as String).toList();
      final cover = table == 'editions' ? columns.indexOf('cover_url') : -1;
      final stmt = db.prepare(
        'INSERT INTO $table VALUES (${List.filled(columns.length, '?').join(',')})',
      );
      try {
        for (final part in entry.value.parts.split('')) {
          final rows = jsonDecode(
            File('$stage/$table/$part.json').readAsStringSync(),
          );
          if (rows is! List) {
            throw const FormatException('Expected catalog rows');
          }
          for (final row in rows) {
            // Newer snapshots may add columns; unknown ones are ignored and
            // absent ones are null, which NOT NULL columns then reject.
            if (row is! Map) {
              throw const FormatException('Invalid catalog columns');
            }
            for (final field in fields) {
              final value = row[field['name']];
              if ((value == null && field['notnull'] == 1) ||
                  (value != null &&
                      (field['type'] == 'TEXT'
                          ? value is! String
                          : value is! int))) {
                throw const FormatException('Invalid catalog column type');
              }
            }
            final values = [for (final column in columns) row[column]];
            if (cover >= 0) {
              values[cover] = _coverUrl(
                values[cover] as String?,
                manifest,
                root,
              );
            }
            stmt.execute(values);
          }
        }
      } finally {
        stmt.close();
      }
    }
    db.execute('CREATE INDEX catalog_editions_book ON editions(book_id)');
    db.execute(
      'CREATE INDEX catalog_book_authors_author ON book_authors(author_id)',
    );
    final counts = {
      for (final row in db.select(
        'SELECT source_id, COUNT(*) AS n FROM editions GROUP BY source_id',
      ))
        row['source_id'] as String: row['n'] as int,
    };
    if (counts.isEmpty ||
        counts.length != manifest.sourceCounts.length ||
        !counts.entries.every((e) => manifest.sourceCounts[e.key] == e.value) ||
        db.select('PRAGMA foreign_key_check').isNotEmpty ||
        db.select(
          '''SELECT 1 FROM books b WHERE NOT EXISTS
          (SELECT 1 FROM editions e WHERE e.book_id=b.id) LIMIT 1''',
        ).isNotEmpty) {
      throw const FormatException('Incomplete catalog relationships');
    }
    db.execute('''CREATE VIRTUAL TABLE catalog_search USING fts5(
      title, authors, tokenize='trigram case_sensitive 1')''');
    final insert = db.prepare(
      'INSERT INTO catalog_search(rowid, title, authors) VALUES (?, ?, ?)',
    );
    try {
      for (final row in db.select('''SELECT b.rowid, b.title,
        (SELECT group_concat(name, char(10)) FROM
          (SELECT a.name FROM book_authors ba JOIN authors a ON a.id=ba.author_id
           WHERE ba.book_id=b.id
           UNION ALL
           SELECT d.display_name FROM book_authors ba
           JOIN author_details d ON d.author_id=ba.author_id
           WHERE ba.book_id=b.id)) AS authors FROM books b''')) {
        insert.execute([
          row['rowid'],
          caseFold(row['title'] as String),
          caseFold(row['authors'] as String? ?? ''),
        ]);
      }
    } finally {
      insert.close();
    }
    db.execute(
      "INSERT INTO catalog_search(catalog_search) VALUES ('optimize')",
    );
    db.execute(
      "INSERT INTO catalog_search(catalog_search) VALUES ('integrity-check')",
    );
    db.execute('CREATE TABLE catalog_metadata(manifest TEXT NOT NULL) STRICT');
    db.execute('INSERT INTO catalog_metadata VALUES (?)', [manifestText]);
    db.execute('COMMIT');
    if (db.select('PRAGMA integrity_check').single.values.single != 'ok') {
      throw const FormatException('Invalid catalog database');
    }
  } finally {
    db.close();
  }
}

/// An absolute HTTP(S) cover stays as published; any other must name an
/// inventoried thumbnail, which is resolved against the snapshot.
String? _coverUrl(String? url, CatalogManifest manifest, Uri root) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty) {
    return url;
  }
  if (manifest.thumbnails.containsKey(url)) return root.resolve(url).toString();
  throw FormatException('Catalog cover is not inventoried: $url');
}

T _read<T>(String path, T Function(Database) body) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    switch (db.userVersion) {
      case catalogDatabaseVersion:
        break;
      case 1:
        // A catalog installed before the details tables stays searchable until
        // a refresh replaces it. Empty temporary tables (private to this
        // read-only connection) stand in for the details it does not have.
        db.execute('''CREATE TEMP TABLE author_details(author_id TEXT,
          display_name TEXT, birth_year INTEGER, death_year INTEGER);
          CREATE TEMP TABLE book_details(book_id TEXT, summary TEXT,
          reading_ease INTEGER)''');
      default:
        throw const FormatException('Unsupported installed catalog');
    }
    return body(db);
  } finally {
    db.close();
  }
}

CatalogBook _book(Database db, Row row) => (
  id: row['id'] as String,
  title: row['title'] as String,
  coverUrl:
      db.select(
            'SELECT cover_url FROM editions WHERE book_id=? ORDER BY display_order LIMIT 1',
            [row['id']],
          ).single['cover_url']
          as String?,
  sources: List.unmodifiable(
    db
        .select(
          'SELECT DISTINCT s.name FROM editions e JOIN sources s ON s.id=e.source_id WHERE e.book_id=? ORDER BY s.name',
          [row['id']],
        )
        .map((r) => r['name'] as String),
  ),
  authors: List.unmodifiable(
    db
        .select(
          '''SELECT COALESCE(d.display_name, a.name) AS name FROM book_authors ba
    JOIN authors a ON a.id=ba.author_id
    LEFT JOIN author_details d ON d.author_id=a.id
    WHERE ba.book_id=? ORDER BY ba.position''',
          [row['id']],
        )
        .map((row) => row['name'] as String),
  ),
);

List<CatalogBook> searchCatalog(
  String path,
  String query,
  String? category,
  String? language,
  String? source,
  String? author,
  int limit,
  int offset,
) {
  if (!File(path).existsSync()) return const [];
  return _read(path, (db) {
    final folded = caseFold(query.trim());
    final where = <String>[];
    final values = <Object?>[];
    if (folded.isNotEmpty) {
      if (folded.runes.length >= 3) {
        where.add('catalog_search MATCH ?');
        values.add('"${folded.replaceAll('"', '""')}"');
      } else {
        where.add(
          '(instr(catalog_search.title, ?) > 0 OR instr(catalog_search.authors, ?) > 0)',
        );
        values.addAll([folded, folded]);
      }
    }
    if (category != null) {
      where.add(
        'EXISTS (SELECT 1 FROM book_categories bc WHERE bc.book_id=b.id AND bc.category_id=?)',
      );
      values.add(category);
    }
    if (author != null) {
      where.add(
        'EXISTS (SELECT 1 FROM book_authors ba WHERE ba.book_id=b.id AND ba.author_id=?)',
      );
      values.add(author);
    }
    if (language != null || source != null) {
      where.add('''EXISTS (SELECT 1 FROM editions e WHERE e.book_id=b.id
        ${language == null ? '' : 'AND e.language=?'}
        ${source == null ? '' : 'AND e.source_id=?'})''');
      if (language != null) values.add(language);
      if (source != null) values.add(source);
    }
    final rows = db.select(
      '''SELECT b.id, b.title FROM books b
      JOIN catalog_search ON catalog_search.rowid=b.rowid
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY b.title COLLATE NOCASE, b.id LIMIT ? OFFSET ?''',
      [...values, limit, offset],
    );
    return List.unmodifiable(rows.map((row) => _book(db, row)));
  });
}

List<CatalogCategory> catalogCategories(String path) {
  if (!File(path).existsSync()) return const [];
  return _read(
    path,
    (db) => List.unmodifiable(
      db
          .select('''SELECT c.id, c.label, COUNT(*) AS n
    FROM categories c JOIN book_categories bc ON bc.category_id=c.id
    GROUP BY c.id ORDER BY c.label COLLATE NOCASE, c.id''')
          .map(
            (row) => (
              id: row['id'] as String,
              label: row['label'] as String,
              books: row['n'] as int,
            ),
          ),
    ),
  );
}

/// Two real members of each requested category. Limit on the membership index
/// before joining books; bundled artwork needs no member lookup at all.
Map<String, List<CatalogBook>> catalogCategoryPreviews(
  String path,
  List<String> categoryIds,
) {
  if (!File(path).existsSync()) return const {};
  return _read(path, (db) {
    final previews = <String, List<CatalogBook>>{};
    for (final id in categoryIds.toSet()) {
      final rows = db.select(
        '''SELECT b.id, b.title FROM (
        SELECT book_id FROM book_categories WHERE category_id=?
        ORDER BY book_id LIMIT 2
      ) bc JOIN books b ON b.id=bc.book_id ORDER BY b.id''',
        [id],
      );
      if (rows.isNotEmpty) {
        previews[id] = [for (final row in rows) _book(db, row)];
      }
    }
    return Map.unmodifiable({
      for (final entry in previews.entries)
        entry.key: List<CatalogBook>.unmodifiable(entry.value),
    });
  });
}

List<CatalogAuthor> catalogAuthors(
  String path,
  String query,
  int limit,
  int offset,
) {
  if (!File(path).existsSync()) return const [];
  return _read(path, (db) {
    // Author names are small enough to filter outside FTS, using the same
    // Unicode case folding as title search rather than SQLite's ASCII lower().
    final folded = caseFold(query.trim());
    // Either the catalog heading or the display name shown on book cards
    // finds an author; the list keeps the heading, whose dates disambiguate.
    final rows = db.select('''SELECT a.id, a.name, d.display_name,
      COUNT(*) AS n FROM authors a
      JOIN book_authors ba ON ba.author_id=a.id
      LEFT JOIN author_details d ON d.author_id=a.id GROUP BY a.id
      ORDER BY a.sort_name COLLATE NOCASE, a.id''');
    return List.unmodifiable(
      rows
          .where(
            (r) =>
                caseFold(r['name'] as String).contains(folded) ||
                caseFold(r['display_name'] as String? ?? '').contains(folded),
          )
          .skip(offset)
          .take(limit)
          .map(
            (r) => (
              id: r['id'] as String,
              name: r['name'] as String,
              books: r['n'] as int,
            ),
          ),
    );
  });
}

CatalogFilters catalogFilters(String path) {
  if (!File(path).existsSync()) return (languages: const [], sources: const []);
  return _read(
    path,
    (db) => (
      languages: List.unmodifiable(
        db
            .select('SELECT DISTINCT language FROM editions ORDER BY language')
            .map((r) => r['language'] as String),
      ),
      sources: List.unmodifiable(
        db
            .select('SELECT id, name FROM sources ORDER BY name')
            .map((r) => (id: r['id'] as String, name: r['name'] as String)),
      ),
    ),
  );
}

CatalogBookDetails? catalogBook(String path, String id) {
  if (!File(path).existsSync()) return null;
  return _read(path, (db) {
    final rows = db.select('SELECT id, title FROM books WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final authors = db.select(
      '''SELECT a.id, a.name, d.display_name, d.birth_year, d.death_year,
      (SELECT COUNT(*) FROM book_authors x WHERE x.author_id=a.id) AS n
      FROM book_authors ba JOIN authors a ON a.id=ba.author_id
      LEFT JOIN author_details d ON d.author_id=a.id
      WHERE ba.book_id=? ORDER BY ba.position''',
      [id],
    );
    // A version 2 catalog installed before these details existed lacks their
    // columns and the series table; it reads as having none of them.
    final columns = {
      for (final row in db.select('PRAGMA table_info(book_details)'))
        row['name'] as String,
    };
    final described = db.select(
      'SELECT ${[
        for (final column in ['summary', 'reading_ease', 'description', 'word_count', 'released']) columns.contains(column) ? column : 'NULL AS $column',
        columns.contains('released_by') ? '(SELECT name FROM sources WHERE id=released_by) AS released_by' : 'NULL AS released_by',
      ].join(', ')} FROM book_details WHERE book_id=?',
      [id],
    ).firstOrNull;
    final hasSeries = db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name='book_series'",
        )
        .isNotEmpty;
    return (
      book: _book(db, rows.single),
      editions: List<CatalogEdition>.unmodifiable(
        db
            .select(
              '''SELECT e.*, s.name,
        s.website, s.catalog_credit, s.support_url FROM editions e
        JOIN sources s ON s.id=e.source_id WHERE e.book_id=? ORDER BY e.display_order''',
              [id],
            )
            .map(
              (row) => (
                sourceId: row['source_id'] as String,
                editionId: row['source_edition_id'] as String,
                sourceName: row['name'] as String,
                sourceWebsite: row['website'] as String,
                catalogCredit: row['catalog_credit'] as String?,
                supportUrl: row['support_url'] as String?,
                variant: row['variant_label'] as String,
                language: row['language'] as String,
                sourceUrl: row['source_url'] as String,
                rights: row['rights_line'] as String,
                acquisitionUrl: row['acquisition_url'] as String,
                format: row['acquisition_format'] as String,
                sizeBytes: row['size_bytes'] as int?,
                coverUrl: row['cover_url'] as String?,
              ),
            ),
      ),
      subjects: List<String>.unmodifiable(
        db
            .select(
              '''SELECT s.label FROM subjects s
        JOIN book_subjects bs ON bs.subject_id=s.id WHERE bs.book_id=? ORDER BY s.label''',
              [id],
            )
            .map((row) => row['label'] as String),
      ),
      authors: List<CatalogBookAuthor>.unmodifiable(
        authors.map(
          (row) => (
            id: row['id'] as String,
            name: (row['display_name'] ?? row['name']) as String,
            birthYear: row['birth_year'] as int?,
            deathYear: row['death_year'] as int?,
            books: row['n'] as int,
          ),
        ),
      ),
      summary: described?['summary'] as String?,
      readingEase: described?['reading_ease'] as int?,
      description: described?['description'] as String?,
      wordCount: described?['word_count'] as int?,
      released: described?['released'] as String?,
      releasedBy: described?['released_by'] as String?,
      series: !hasSeries
          ? const []
          : List.unmodifiable(
              db
                  .select(
                    'SELECT series, position FROM book_series WHERE book_id=? ORDER BY series',
                    [id],
                  )
                  .map(
                    (row) => (
                      name: row['series'] as String,
                      position: row['position'] as int?,
                    ),
                  ),
            ),
      moreByAuthor: authors.isEmpty
          ? const []
          : List<CatalogBook>.unmodifiable(
              db
                  .select(
                    '''SELECT b.id, b.title FROM book_authors ba
              JOIN books b ON b.id=ba.book_id
              WHERE ba.author_id=? AND ba.book_id<>?
              ORDER BY b.title COLLATE NOCASE, b.id LIMIT ?''',
                    [authors.first['id'], id, catalogMoreByAuthorLimit],
                  )
                  .map((row) => _book(db, row)),
            ),
    );
  });
}
