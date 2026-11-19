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
    stderr.writeln('Compressed input requires gzip on PATH.');
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
/// Use an output directory owned by the caller, with no concurrent writer at
/// the same path. Do not publish the snapshot until this function returns.
Future<({int works, int editions, int skipped})> importGutenbergFile(
  File input,
  File output,
) async {
  // Exclusive creation also refuses an existing catalog or the input itself.
  await output.create(exclusive: true);
  try {
    // SQLite can consume or remove existing sidecars even for a fresh file.
    for (final suffix in ['-journal', '-wal', '-shm']) {
      final sidecar = '${output.path}$suffix';
      if (await FileSystemEntity.type(sidecar, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Catalog output has an existing SQLite sidecar',
          sidecar,
        );
      }
    }
    final db = sqlite3.open(output.path);
    try {
      db.execute(catalogSchema);
      final bytes = input.path.endsWith('.gz')
          ? _readGzip(input)
          : input.openRead();
      return await _importRows(
        db,
        _validateQuotes(bytes.transform(utf8.decoder)),
      );
    } finally {
      db.close();
    }
  } on Object {
    await output.delete();
    rethrow;
  }
}

Stream<List<int>> _readGzip(File input) async* {
  // Dart's gzip stream accepts EOF before the trailer. gzip reports an error
  // for incomplete members or bad CRCs, even if it emitted complete CSV rows.
  final process = await Process.start('gzip', ['-dc', input.absolute.path]);
  final errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final done = process.exitCode;
  try {
    yield* process.stdout;
    if (await done != 0) {
      throw FormatException('Invalid Gutenberg gzip: ${(await errors).trim()}');
    }
  } finally {
    process.kill(); // Also stop decoding if the CSV consumer cancels early.
    await done;
    await errors;
  }
}

enum _CsvField { start, unquoted, quoted, afterQuote }

/// Keep the streaming CSV decoder, but reject inputs it silently repairs.
Stream<String> _validateQuotes(Stream<String> chunks) async* {
  var field = _CsvField.start;
  var first = true;
  await for (final chunk in chunks) {
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk.codeUnitAt(i);
      if (first) {
        first = false;
        if (c == 0xfeff) continue; // Optional UTF-8 BOM.
      }
      final separator = c == 0x2c || c == 0x0d || c == 0x0a;
      final quote = c == 0x22;
      field = switch (field) {
        _CsvField.start when quote => _CsvField.quoted,
        _CsvField.quoted => quote ? _CsvField.afterQuote : _CsvField.quoted,
        _CsvField.afterQuote when quote => _CsvField.quoted,
        _ when separator => _CsvField.start,
        _CsvField.afterQuote => throw const FormatException(
          'Unexpected data after quoted CSV field',
        ),
        _ => _CsvField.unquoted,
      };
    }
    yield chunk;
  }
  if (field == _CsvField.quoted) {
    throw const FormatException('Unclosed quoted CSV field');
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
