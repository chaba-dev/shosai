import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:shosai_core/catalog.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

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
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tool/import_gutenberg.dart '
      '<pg_catalog.csv[.gz]> <rdf-files.tar.bz2|catalog.rdf> <new-catalog.sqlite>',
    );
    stderr.writeln('Inputs: $_base/cache/epub/feeds/');
    stderr.writeln('Compressed inputs require gzip and bzip2 on PATH.');
    exitCode = 64;
    return;
  }
  try {
    final result = await importGutenbergFile(
      File(args[0]),
      File(args[2]),
      rdf: File(args[1]),
    );
    stdout.writeln(
      'Imported ${result.works} works and ${result.editions} EPUB editions, '
      'listed in the RDF or inferred for new releases; skipped '
      '${result.skipped} non-text records or records without an EPUB.',
    );
  } on Exception catch (error) {
    stderr.writeln('Gutenberg import failed: $error');
    exitCode = 1;
  }
}

/// Joins the official CSV's search metadata with RDF-listed EPUB downloads.
/// [rdf] is the downloaded bulk tar.bz2 or an XML/RDF file, never a live URL.
/// Use an output directory owned by the caller, with no concurrent writer at
/// the same path. Do not publish the snapshot until this function returns.
Future<({int works, int editions, int skipped})> importGutenbergFile(
  File input,
  File output, {
  required File rdf,
}) async {
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
      await _importRdf(db, rdf);
      final bytes = input.path.endsWith('.gz')
          ? _readGzip(input)
          : input.openRead();
      return await _importRows(db, _readCsvRows(bytes.transform(utf8.decoder)));
    } finally {
      db.close();
    }
  } on Object {
    await output.delete();
    rethrow;
  }
}

const _rdfNamespace = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
const _pgNamespace = 'http://www.gutenberg.org/2009/pgterms/';
const _dcNamespace = 'http://purl.org/dc/terms/';

Future<void> _importRdf(Database db, File input) async {
  db.execute('''
    CREATE TEMP TABLE listed_epubs (
      ebook_id TEXT NOT NULL,
      variant TEXT NOT NULL,
      label TEXT NOT NULL,
      preference INTEGER NOT NULL,
      url TEXT NOT NULL,
      size_bytes INTEGER,
      rights_line TEXT NOT NULL,
      PRIMARY KEY (ebook_id, variant)
    ) STRICT;
    CREATE TEMP TABLE listed_details (
      ebook_id TEXT PRIMARY KEY,
      summary TEXT,
      reading_ease INTEGER
    ) STRICT;
    CREATE TEMP TABLE listed_agents (
      ebook_id TEXT NOT NULL,
      name TEXT NOT NULL,
      birth_year INTEGER,
      death_year INTEGER,
      PRIMARY KEY (ebook_id, name)
    ) STRICT;
  ''');
  final insert = db.prepare(
    'INSERT INTO listed_epubs VALUES (?, ?, ?, ?, ?, ?, ?)',
  );
  final insertDetails = db.prepare(
    'INSERT INTO listed_details VALUES (?, ?, ?)',
  );
  // An agent appears once per role; its name and years do not change.
  final insertAgent = db.prepare(
    'INSERT INTO listed_agents VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING',
  );
  final _RdfSink sink = (
    epub: insert.execute,
    detail: insertDetails.execute,
    agent: insertAgent.execute,
  );
  void write(_RdfRows rows) {
    rows.epubs.forEach(sink.epub);
    rows.details.forEach(sink.detail);
    rows.agents.forEach(sink.agent);
  }

  db.execute('BEGIN');
  try {
    if (input.path.endsWith('.tar.bz2')) {
      // Parse batches of members on other isolates, and insert their rows in
      // archive order so the tables fill exactly as a serial pass would.
      // Results are captured when queued: a batch that fails before its turn
      // must fail the import through this loop, not as an unhandled error.
      final pending = Queue<Future<Result<_RdfRows>>>();
      var batch = <Uint8List>[];
      var batchBytes = 0;
      void queue() {
        pending.add(Result.capture(_parseRdfInIsolate(batch)));
        batch = [];
        batchBytes = 0;
      }

      await for (final member in _readRdfArchive(input)) {
        batch.add(member);
        batchBytes += member.length;
        if (batch.length < 64 && batchBytes < _maxBatchBytes) continue;
        queue();
        if (pending.length > Platform.numberOfProcessors) {
          write(await Result.release(pending.removeFirst()));
        }
      }
      if (batch.isNotEmpty) queue();
      while (pending.isNotEmpty) {
        write(await Result.release(pending.removeFirst()));
      }
    } else {
      await _parseRdf([input.openRead()], sink);
    }
    if (db.select('SELECT 1 FROM listed_epubs LIMIT 1').isEmpty) {
      throw const FormatException('No EPUB files listed in Gutenberg RDF');
    }
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    insert.close();
    insertDetails.close();
    insertAgent.close();
  }
}

/// Receives the rows RDF documents contribute to the temporary tables, in the
/// order the documents and their elements list them.
typedef _RdfSink = ({
  void Function(List<Object?>) epub,
  void Function(List<Object?>) detail,
  void Function(List<Object?>) agent,
});

typedef _RdfRows = ({
  List<List<Object?>> epubs,
  List<List<Object?>> details,
  List<List<Object?>> agents,
});

/// Batches flush at 64 members or this many bytes, whichever comes first.
const _maxBatchBytes = 4 << 20;

/// Gutenberg's RDF documents are tens of kilobytes; a larger member is not one.
const _maxRdfMemberBytes = 16 << 20;

Future<_RdfRows> _parseRdfInIsolate(List<Uint8List> members) => Isolate.run(
  () async {
    final _RdfRows rows = (epubs: [], details: [], agents: []);
    await _parseRdf(
      [for (final member in members) Stream.value(member)],
      (epub: rows.epubs.add, detail: rows.details.add, agent: rows.agents.add),
    );
    return rows;
  },
);

Future<void> _parseRdf(
  Iterable<Stream<List<int>>> documents,
  _RdfSink sink,
) async {
  // Validate each complete member, retaining only one ebook subtree at a time.
  final nodes = Stream.fromIterable(documents).asyncExpand(
    (bytes) => bytes
        .transform(utf8.decoder)
        .toXmlEvents(
          validateDocument: true,
          validateNesting: true,
          validateNamespace: true,
          withNamespace: true,
          withParent: true,
        )
        .tapEachEvent(
          onStartElement: (event) {
            final attributes = <(String?, String)>{};
            for (final attribute in event.attributes) {
              if (!attributes.add((
                attribute.namespacePrefix == null
                    ? null
                    : attribute.namespaceUri,
                attribute.localName,
              ))) {
                throw const FormatException('Duplicate RDF attribute');
              }
            }
            if (event.parent == null &&
                (event.localName != 'RDF' ||
                    event.namespaceUri != _rdfNamespace)) {
              throw const FormatException('Expected an RDF document root');
            }
          },
          onText: (event) {
            if (event.parent == null &&
                event.value.codeUnits.any(
                  (code) =>
                      code != 0x20 &&
                      code != 0x09 &&
                      code != 0x0a &&
                      code != 0x0d,
                )) {
              throw const FormatException('Unexpected text outside RDF root');
            }
          },
          onCDATA: (event) {
            if (event.parent == null) {
              throw const FormatException('Unexpected CDATA outside RDF root');
            }
          },
        )
        .selectSubtreeEvents(
          (event) =>
              event.localName == 'ebook' && event.namespaceUri == _pgNamespace,
        )
        .normalizeEvents()
        .toXmlNodes(),
  );
  await for (final batch in nodes) {
    for (final ebook in batch.whereType<XmlElement>()) {
      final about = ebook.getAttribute('about', namespaceUri: _rdfNamespace);
      final match = RegExp(r'^ebooks/([1-9][0-9]*)$').firstMatch(about ?? '');
      if (match == null) {
        throw FormatException('Invalid RDF ebook ID: $about');
      }
      final id = match[1]!;
      // Sort repeated values so record and element order cannot change output.
      List<String> texts(String name) => {
        for (final element in ebook.findElements(
          name,
          namespaceUri: _pgNamespace,
        ))
          if (element.innerText.trim().isNotEmpty) element.innerText.trim(),
      }.toList()..sort();
      final summary = texts('marc520').join('\n\n');
      final ease = texts('marc908')
          .map((note) => _readingEase.firstMatch(note)?[1])
          .nonNulls
          .map((score) => double.parse(score).round())
          .firstOrNull;
      if (summary.isNotEmpty || ease != null) {
        sink.detail([id, summary.isEmpty ? null : summary, ease]);
      }
      for (final agent in ebook.findAllElements(
        'agent',
        namespaceUri: _pgNamespace,
      )) {
        final name = agent
            .getElement('name', namespaceUri: _pgNamespace)
            ?.innerText
            .trim();
        if (name == null || name.isEmpty) continue;
        int? year(String element) => int.tryParse(
          agent
                  .getElement(element, namespaceUri: _pgNamespace)
                  ?.innerText
                  .trim() ??
              '',
        );
        sink.agent([id, name, year('birthdate'), year('deathdate')]);
      }
      final rights = {
        for (final statement in ebook.findElements(
          'rights',
          namespaceUri: _dcNamespace,
        ))
          if (statement.innerText.trim().isNotEmpty) statement.innerText.trim(),
      }.toList()..sort();
      final rightsLine = rights.isEmpty
          ? 'Rights not listed in the offline catalog. Check Project Gutenberg.'
          : rights.join('\n');
      final files = <String>[];
      var listed = false;
      for (final format in ebook.findElements(
        'hasFormat',
        namespaceUri: _dcNamespace,
      )) {
        final file = format.getElement('file', namespaceUri: _pgNamespace);
        if (file == null) continue;
        files.add(
          file.getAttribute('about', namespaceUri: _rdfNamespace) ?? '',
        );
        final epub = file
            .findElements('format', namespaceUri: _dcNamespace)
            .any(
              (format) => format.descendants.whereType<XmlElement>().any(
                (value) =>
                    value.name.local == 'value' &&
                    value.namespaceUri == _rdfNamespace &&
                    value.innerText.trim() == 'application/epub+zip',
              ),
            );
        if (!epub) continue;
        final url = Uri.tryParse(
          file.getAttribute('about', namespaceUri: _rdfNamespace) ?? '',
        );
        if (url == null ||
            url.scheme != 'https' ||
            url.host != 'www.gutenberg.org' ||
            url.userInfo.isNotEmpty ||
            url.hasPort ||
            url.hasQuery ||
            url.hasFragment ||
            url.pathSegments.isEmpty) {
          throw FormatException('Invalid RDF EPUB URL: $url');
        }
        final (variant, label, preference) = switch (url.path) {
          final path when path == '/ebooks/$id.epub3.images' => (
            'images',
            'EPUB3 with images',
            0,
          ),
          final path when path == '/ebooks/$id.epub.images' => (
            'epub2-images',
            'EPUB2 with images',
            1,
          ),
          final path when path == '/ebooks/$id.epub.noimages' => (
            'noimages',
            'EPUB2 without images',
            2,
          ),
          _ => (url.toString(), 'EPUB · ${url.pathSegments.last}', 3),
        };
        final extent = file
            .getElement('extent', namespaceUri: _dcNamespace)
            ?.innerText
            .trim();
        final size = extent == null ? null : int.tryParse(extent);
        if (extent != null && (size == null || size <= 0)) {
          throw FormatException('Invalid RDF EPUB size: $extent');
        }
        sink.epub([
          id,
          variant,
          label,
          preference,
          url.toString(),
          size,
          rightsLine,
        ]);
        listed = true;
      }
      // A new release lists only its uploaded sources until Gutenberg adds
      // the formats it generates, while it already serves the EPUBs. List
      // the two standard variants, sizes unknown, for a record of uploaded
      // sources that include its main text. TeX and PDF works, and records
      // with generated formats but no EPUB, stay unlisted.
      final uploads = '$_base/files/$id/';
      if (!listed &&
          files.isNotEmpty &&
          files.every((url) => url.startsWith(uploads)) &&
          files.any(
            (url) =>
                url == '$uploads$id-0.txt' || url == '$uploads$id-h/$id-h.htm',
          )) {
        sink.epub([
          id,
          'images',
          'EPUB3 with images',
          0,
          '$_base/ebooks/$id.epub3.images',
          null,
          rightsLine,
        ]);
        sink.epub([
          id,
          'noimages',
          'EPUB2 without images',
          2,
          '$_base/ebooks/$id.epub.noimages',
          null,
          rightsLine,
        ]);
      }
    }
  }
}

Stream<Uint8List> _readRdfArchive(File input) async* {
  // Read the tar stream from bzip2 directly: starting a process per member
  // (tar --to-command) made reading, not parsing, the cost of the import.
  // Only `.rdf` regular files are yielded; no archive path touches the disk.
  final process = await Process.start('bzip2', ['-dc', input.absolute.path]);
  final errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final done = process.exitCode;
  final reader = ChunkedStreamReader(process.stdout);
  Future<Uint8List> read(int length) async {
    final bytes = await reader.readBytes(length);
    if (bytes.length != length) {
      throw const FormatException('Truncated RDF archive');
    }
    return bytes;
  }

  Future<void> skip(int length) async {
    while (length > 0) {
      final chunk = length < 65536 ? length : 65536;
      await read(chunk);
      length -= chunk;
    }
  }

  try {
    // A GNU long name or POSIX extended header describes the next member.
    String? path;
    int? size;
    while (true) {
      final header = await read(512);
      if (header.every((byte) => byte == 0)) {
        if ((await read(512)).any((byte) => byte != 0)) {
          throw const FormatException('Invalid end of RDF archive');
        }
        break;
      }
      var sum = 0;
      for (var i = 0; i < 512; i++) {
        sum += i >= 148 && i < 156 ? 0x20 : header[i];
      }
      final headerSize = _octal(header, 124, 12);
      if (headerSize == null || _octal(header, 148, 8) != sum) {
        throw const FormatException('Invalid RDF archive header');
      }
      final type = header[156];
      final length = type == 0x4c || type == 0x78
          ? headerSize
          : size ?? headerSize;
      final padded = (length + 511) ~/ 512 * 512;
      if (type == 0x4c || type == 0x78) {
        if (length > _maxRdfMemberBytes) {
          throw const FormatException('RDF archive header too large');
        }
        final body = Uint8List.sublistView(await read(padded), 0, length);
        if (type == 0x4c) {
          path = utf8.decode(body).split('\u0000').first;
        } else {
          final records = _paxRecords(body);
          path = records['path'] ?? path;
          if (records['size'] case final value?) {
            size = RegExp(r'^[0-9]+$').hasMatch(value)
                ? int.parse(value)
                : throw const FormatException('Invalid RDF archive size');
          }
        }
        continue;
      }
      String field(int start, int length) => utf8
          .decode(header.sublist(start, start + length))
          .split('\u0000')
          .first;
      final prefix = ascii.decode(header.sublist(257, 262)) == 'ustar'
          ? field(345, 155)
          : '';
      final name =
          path ?? (prefix.isEmpty ? field(0, 100) : '$prefix/${field(0, 100)}');
      path = null;
      size = null;
      // Regular and contiguous files; links, directories and others are skipped.
      if ((type == 0x30 || type == 0 || type == 0x37) &&
          name.endsWith('.rdf')) {
        if (length > _maxRdfMemberBytes) {
          throw FormatException('RDF archive member too large: $name');
        }
        yield Uint8List.sublistView(await read(padded), 0, length);
      } else {
        await skip(padded);
      }
    }
    // The record padding after the two end blocks is zeros.
    while (true) {
      final rest = await reader.readBytes(65536);
      if (rest.isEmpty) break;
      if (rest.any((byte) => byte != 0)) {
        throw const FormatException('Data after the end of the RDF archive');
      }
    }
    if (await done != 0) {
      throw FormatException(
        'Invalid Gutenberg RDF archive: ${(await errors).trim()}',
      );
    }
  } finally {
    process.kill();
    await reader.cancel();
    await done;
    await errors;
  }
}

/// POSIX extended header records: "LENGTH key=value\n", where LENGTH counts
/// the whole record in bytes, so values may contain newlines.
Map<String, String> _paxRecords(Uint8List body) {
  final records = <String, String>{};
  var start = 0;
  while (start < body.length) {
    final space = body.indexOf(0x20, start);
    final digits = space < 0
        ? null
        : ascii.decode(body.sublist(start, space), allowInvalid: true);
    final length = digits != null && RegExp(r'^[1-9][0-9]*$').hasMatch(digits)
        ? int.parse(digits)
        : null;
    final end = length == null ? -1 : start + length;
    if (length == null ||
        end <= space + 1 ||
        end > body.length ||
        body[end - 1] != 0x0a) {
      throw const FormatException('Invalid RDF archive extended header');
    }
    final record = utf8.decode(body.sublist(space + 1, end - 1));
    final equals = record.indexOf('=');
    if (equals <= 0) {
      throw const FormatException('Invalid RDF archive extended header');
    }
    records[record.substring(0, equals)] = record.substring(equals + 1);
    start = end;
  }
  return records;
}

int? _octal(Uint8List bytes, int start, int length) {
  final text = ascii
      .decode(bytes.sublist(start, start + length), allowInvalid: true)
      .replaceAll('\u0000', ' ')
      .trim();
  return RegExp(r'^[0-7]+$').hasMatch(text) ? int.parse(text, radix: 8) : null;
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

/// Parse comma-delimited records without treating a read boundary as EOF.
/// Keep the field and row state so quote pairs and CRLF can span chunks.
Stream<List<String>> _readCsvRows(Stream<String> chunks) async* {
  final value = StringBuffer();
  var row = <String>[];
  var field = _CsvField.start;
  var first = true;
  var skipLf = false;
  await for (final chunk in chunks) {
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk.codeUnitAt(i);
      if (first) {
        first = false;
        if (c == 0xfeff) continue;
      }
      if (skipLf) {
        skipLf = false;
        if (c == 0x0a) continue;
      }
      final quote = c == 0x22;
      if (field == _CsvField.quoted ||
          (field == _CsvField.afterQuote && quote)) {
        if (field == _CsvField.quoted && quote) {
          field = _CsvField.afterQuote;
        } else {
          value.writeCharCode(c);
          field = _CsvField.quoted;
        }
        continue;
      }
      final lineEnd = c == 0x0d || c == 0x0a;
      if (c == 0x2c || lineEnd) {
        if (!lineEnd || row.isNotEmpty || field != _CsvField.start) {
          row.add(value.toString());
          value.clear();
          if (lineEnd) {
            yield row;
            row = [];
          }
        }
        field = _CsvField.start;
        skipLf = c == 0x0d;
        continue;
      }
      if (field == _CsvField.afterQuote) {
        throw const FormatException('Unexpected data after quoted CSV field');
      }
      if (field == _CsvField.start && quote) {
        field = _CsvField.quoted;
      } else {
        value.writeCharCode(c);
        field = _CsvField.unquoted;
      }
    }
  }
  if (field == _CsvField.quoted) {
    throw const FormatException('Unclosed quoted CSV field');
  }
  if (row.isNotEmpty || field != _CsvField.start) {
    yield row..add(value.toString());
  }
}

Future<({int works, int editions, int skipped})> _importRows(
  Database db,
  Stream<List<String>> rows,
) async {
  final statements = <String, PreparedStatement>{};
  void write(String sql, List<Object?> values) =>
      statements.putIfAbsent(sql, () => db.prepare(sql)).execute(values);

  db.execute('BEGIN');
  try {
    db.execute(
      'INSERT INTO sources (id, name, website, support_url) VALUES (?, ?, ?, ?)',
      [_source, 'Project Gutenberg', '$_base/', '$_base/donate/'],
    );
    Map<String, int>? indexes;
    var width = 0;
    var record = 0;
    var works = 0;
    var editions = 0;
    var skipped = 0;
    await for (final row in rows) {
      record++;
      if (indexes == null) {
        width = row.length;
        indexes = {for (var i = 0; i < width; i++) row[i]: i};
        if (indexes.length != width || !_columns.every(indexes.containsKey)) {
          throw const FormatException('Invalid Gutenberg CSV header');
        }
        continue;
      }
      if (row.length != width) {
        throw FormatException('Wrong number of fields in CSV record $record');
      }
      String field(String name) => row[indexes![name]!].trim();
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
      final listed = statements
          .putIfAbsent(
            'listed',
            () => db.prepare(
              'SELECT * FROM listed_epubs WHERE ebook_id = ? ORDER BY preference, url',
            ),
          )
          .select([id]);
      if (listed.isEmpty) {
        skipped++;
        continue;
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
        // The CSV appends ", <years>" and " [<role>]" to the RDF agent name.
        final named = author.replaceFirst(_role, '');
        final agent = statements
            .putIfAbsent(
              'agent',
              () => db.prepare('''
                SELECT name, birth_year, death_year FROM listed_agents
                WHERE ebook_id = ? AND (? = name OR substr(?, 1, length(name) + 2) = name || ', ')
                ORDER BY length(name) DESC LIMIT 1
              '''),
            )
            .select([id, named, named])
            .firstOrNull;
        if (agent != null) {
          write(
            'INSERT INTO author_details VALUES (?, ?, ?, ?) '
            'ON CONFLICT (author_id) DO UPDATE SET '
            'birth_year = COALESCE(author_details.birth_year, excluded.birth_year), '
            'death_year = COALESCE(author_details.death_year, excluded.death_year)',
            [
              authorId,
              readingOrder(agent['name'] as String),
              agent['birth_year'],
              agent['death_year'],
            ],
          );
        }
      }
      final details = statements
          .putIfAbsent(
            'details',
            () => db.prepare(
              'SELECT summary, reading_ease FROM listed_details WHERE ebook_id = ?',
            ),
          )
          .select([id])
          .firstOrNull;
      if (details != null) {
        write('INSERT INTO book_details VALUES (?, ?, ?)', [
          work,
          details['summary'],
          details['reading_ease'],
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
      for (final (order, edition) in listed.indexed) {
        write(
          '''
          INSERT INTO editions (
            source_id, source_edition_id, book_id, title, variant_label,
            display_order, language, source_url, rights_line, acquisition_url,
            acquisition_format, size_bytes, cover_url
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [
            _source,
            '$id:${edition['variant']}',
            work,
            title,
            edition['label'],
            order,
            language,
            sourceUrl,
            edition['rights_line'],
            edition['url'],
            'epub',
            edition['size_bytes'],
            '$_base/cache/epub/$id/pg$id.cover.medium.jpg',
          ],
        );
        editions++;
      }
      works++;
    }
    if (works == 0) {
      throw const FormatException('No text records with RDF-listed EPUBs');
    }
    db.execute('COMMIT');
    return (works: works, editions: editions, skipped: skipped);
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
final _role = RegExp(r' \[[^\]]*\]$');
final _readingEase = RegExp(r'^Reading ease score: (-?[0-9]+(?:\.[0-9]+)?)\b');

/// "Austen, Jane" reads as "Jane Austen", "Wells, H. G. (Herbert George)" as
/// "H. G. Wells" and "Beethoven, Ludwig van" as "Ludwig van Beethoven".
/// Only a recognisable personal-name inversion is reordered: a surname of
/// capitalised words, then forenames or initials, optionally with name
/// particles. Corporate, qualified and uncertain headings, such as
/// "Henry VIII, King of England", "Alfred A. Knopf, Inc." or
/// "British Museum (Natural History). Department of Mineralogy", keep the
/// heading exactly as catalogued.
String readingOrder(String name) {
  final parts = name.split(', ');
  if (parts.length != 2) return name;
  final surname = parts[0].trim();
  // The only parenthesis a personal inversion carries expands its forenames.
  final forenames = parts[1].replaceFirst(_expansion, '').trim();
  bool words(String text, RegExp shape) {
    final list = text.split(' ');
    return shape.hasMatch(list.first) &&
        list.every((word) => shape.hasMatch(word) || _particles.contains(word));
  }

  return words(surname, _nameWord) && words(forenames, _forenameWord)
      ? '$forenames $surname'
      : name;
}

final _expansion = RegExp(r' \([^()]*\)$');
final _nameWord = RegExp(r"^\p{Lu}[\p{L}'’-]*$", unicode: true);
// A forename, or initials such as "H." or "J.R.R."; not abbreviations such as
// "Inc." or "Conn.", which are as likely to qualify a corporate heading.
final _forenameWord = RegExp(
  r"^(?:\p{Lu}[\p{L}'’-]*|(?:\p{Lu}\.)+)$",
  unicode: true,
);
// Name particles that may follow a forename or start a surname; titles such
// as "of" and epithets such as "the Younger" do not qualify.
const _particles = {
  'da', 'de', 'del', 'della', 'der', 'di', 'du', 'la', 'le', //
  'ten', 'ter', 'van', 'von', 'zu',
};

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
