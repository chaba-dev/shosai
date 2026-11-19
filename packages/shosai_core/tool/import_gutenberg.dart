import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';

const _base = 'https://www.gutenberg.org';
const _source = 'gutenberg';
const _columns = [
  'Text#',
  'Type',
  'Title',
  'Language',
  'Authors',
  'Subjects',
  'Bookshelves',
];

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/import_gutenberg.dart '
      '<pg_catalog.csv[.gz]> <new-catalog.sqlite>',
    );
    stderr.writeln('Input: $_base/cache/epub/feeds/pg_catalog.csv.gz');
    exitCode = 64;
    return;
  }
  try {
    final result = await importGutenbergFile(File(args[0]), File(args[1]));
    stdout.writeln(
      'Imported ${result.works} works and ${result.editions} '
      'candidate EPUB editions; skipped ${result.skipped} non-text records.',
    );
  } on Exception catch (error) {
    stderr.writeln('Gutenberg import failed: $error');
    exitCode = 1;
  }
}

/// Imports a downloaded official CSV (optionally gzipped) into a new snapshot.
/// A caller must not publish the snapshot until this function returns.
Future<({int works, int editions, int skipped})> importGutenbergFile(
  File input,
  File output,
) async {
  // Exclusive creation also refuses an existing catalog or the input itself.
  await output.create(exclusive: true);
  try {
    final db = sqlite3.open(output.path);
    try {
      db.execute(catalogSchema);
      final bytes = input.openRead();
      final decoded = input.path.endsWith('.gz')
          ? bytes.transform(gzip.decoder)
          : bytes;
      return await _importRows(db, decoded.transform(utf8.decoder));
    } finally {
      db.close();
    }
  } on Object {
    await output.delete();
    rethrow;
  }
}

Future<({int works, int editions, int skipped})> _importRows(
  Database db,
  Stream<String> csvText,
) async {
  final statements = <String, PreparedStatement>{};
  void write(String sql, List<Object?> values) =>
      statements.putIfAbsent(sql, () => db.prepare(sql)).execute(values);

  db.execute('BEGIN');
  try {
    db.execute('INSERT INTO sources (id, name, website) VALUES (?, ?, ?)', [
      _source,
      'Project Gutenberg',
      '$_base/',
    ]);
    Map<String, int>? indexes;
    var width = 0;
    var record = 0;
    var works = 0;
    var skipped = 0;
    await for (final row in csvText.transform(
      Csv(fieldDelimiter: ',').decoder,
    )) {
      record++;
      if (indexes == null) {
        width = row.length;
        indexes = {for (var i = 0; i < width; i++) row[i].toString(): i};
        if (indexes.length != width || !_columns.every(indexes.containsKey)) {
          throw const FormatException('Invalid Gutenberg CSV header');
        }
        continue;
      }
      if (row.length != width) {
        throw FormatException('Wrong number of fields in CSV record $record');
      }
      String field(String name) => (row[indexes![name]!] as String).trim();
      if (field('Type') != 'Text') {
        skipped++;
        continue;
      }
      final id = field('Text#');
      final title = field('Title');
      final language = field('Language');
      if (!_number.hasMatch(id) || title.isEmpty || language.isEmpty) {
        throw FormatException(
          'Invalid ebook ID, title, or language in CSV record $record',
        );
      }
      final work = '$_source:$id';
      write('INSERT INTO books (id, title) VALUES (?, ?)', [work, title]);
      var position = 0;
      for (final author in _values(field('Authors'))) {
        // The CSV includes role/date qualifiers but no Gutenberg author IDs.
        final authorId = '$_source:$author';
        write(
          'INSERT INTO authors (id, name, sort_name) VALUES (?, ?, ?) '
          'ON CONFLICT (id) DO NOTHING',
          [authorId, author, author],
        );
        write('INSERT INTO book_authors VALUES (?, ?, ?)', [
          work,
          authorId,
          position++,
        ]);
      }
      final subjects = _values(field('Subjects'));
      for (final subject in subjects) {
        final subjectId = 'lcsh:$subject';
        write(
          'INSERT INTO subjects VALUES (?, ?) ON CONFLICT (id) DO NOTHING',
          [subjectId, subject],
        );
        write('INSERT INTO book_subjects VALUES (?, ?)', [work, subjectId]);
      }
      final categories = {
        for (final shelf in _values(field('Bookshelves')))
          if (shelf.startsWith('Category:') &&
              shelf.substring(9).trim().isNotEmpty)
            shelf.substring(9).trim(),
      };
      if (categories.isEmpty) {
        categories.addAll(
          subjects.map((subject) => _subjectCategories[subject]).nonNulls,
        );
      }
      for (final category in categories) {
        final categoryId = '$_source:$category';
        write(
          'INSERT INTO categories VALUES (?, ?) ON CONFLICT (id) DO NOTHING',
          [categoryId, category],
        );
        write('INSERT INTO book_categories VALUES (?, ?)', [work, categoryId]);
      }
      final sourceUrl = '$_base/ebooks/$id';
      for (final (order, variant, label, suffix) in const [
        (0, 'images', 'With images', 'epub3.images'),
        (1, 'noimages', 'Without images', 'epub.noimages'),
      ]) {
        // The CSV cannot confirm rights, format availability, or file size.
        write(
          '''
          INSERT INTO editions (
            source_id, source_edition_id, book_id, title, variant_label,
            display_order, language, source_url, rights_line, acquisition_url,
            acquisition_format, cover_url
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [
            _source,
            '$id:$variant',
            work,
            title,
            label,
            order,
            language,
            sourceUrl,
            'Rights not listed in the offline catalog. Check Project Gutenberg.',
            '$sourceUrl.$suffix',
            'epub',
            '$_base/cache/epub/$id/pg$id.cover.medium.jpg',
          ],
        );
      }
      works++;
    }
    if (works == 0) {
      throw const FormatException('No text records in Gutenberg CSV');
    }
    db.execute('COMMIT');
    return (works: works, editions: works * 2, skipped: skipped);
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    for (final statement in statements.values) {
      statement.close();
    }
  }
}

final _number = RegExp(r'^[1-9][0-9]*$');

// Exact LCSH genres only, when Gutenberg has not assigned a Browse category.
const _subjectCategories = {
  'Science fiction': 'Science-Fiction & Fantasy',
  'Fantasy fiction': 'Science-Fiction & Fantasy',
  'Detective and mystery stories': 'Crime, Thrillers and Mystery',
  'Romance fiction': 'Romance',
  'Poetry': 'Poetry',
  'Short stories': 'Short Stories',
};

Set<String> _values(String field) => {
  for (final value in field.split(';'))
    if (value.trim().isNotEmpty) value.trim(),
};
