/// Search across the library: book text and notes (RFD 6, Notes and search).
library;

import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:isolate';
import 'dart:typed_data';

import '../annotations/annotation.dart';
import '../annotations/records.dart';
import '../cancellation.dart';
import '../errors.dart';
import '../library/book.dart';
import '../library/records.dart';
import '../store/store.dart';
import '../unit_text.dart';
import 'search.dart';

/// Most text matches one book's results keep; [BookTextHits.more] says when
/// the book has others.
const maxLibraryTextMatchesPerBook = 100;

/// Most notes one search returns, across every book it covers.
const maxLibraryNoteHits = 500;

/// Most notes one search reads.
const maxLibraryNotesSearched = 65536;

/// UTF-8 bytes of one book's text that library search keeps and searches:
/// what one in-book search covers.
const maxLibraryTextBytes = 8 * 1024 * 1024;

/// Longest text version name, in UTF-8 bytes.
const maxTextVersionBytes = 256;

/// Matches kept in one note's quote or body.
const _maxMatchesPerNoteField = 16;

/// Which words of a note matched.
enum NoteField { quote, body }

/// One match in a note: [length] Unicode scalars of its [field] from
/// [offset].
final class NoteMatch {
  const NoteMatch(this.field, this.offset, this.length);

  final NoteField field;
  final int offset;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is NoteMatch &&
      other.field == field &&
      other.offset == offset &&
      other.length == length;

  @override
  int get hashCode => Object.hash(field, offset, length);

  @override
  String toString() => 'NoteMatch(${field.name}, $offset, $length)';
}

/// A note whose quote or body holds the query.
final class NoteHit {
  const NoteHit(this.note, this.matches);

  final NoteEntry note;

  /// In field order, then text order.
  final List<NoteMatch> matches;
}

/// One book's notes that hold the query, in reading order.
final class BookNoteHits {
  const BookNoteHits(this.book, this.hits);

  final Book book;
  final List<NoteHit> hits;
}

/// One book's text matches, in reading order, or why the book could not be
/// searched.
final class BookTextHits {
  const BookTextHits(
    this.book,
    this.matches, {
    this.more = false,
    this.partial = false,
    this.error,
  });

  /// A book that could not be read: its file is missing, say.
  const BookTextHits.failed(this.book, CoreException this.error)
    : matches = const [],
      more = false,
      partial = false;

  final Book book;

  /// At most [maxLibraryTextMatchesPerBook].
  final List<SearchMatch> matches;

  /// Whether the book holds matches beyond [matches].
  final bool more;

  /// Whether only the first [maxLibraryTextBytes] of the book's text were
  /// searched.
  final bool partial;
  final CoreException? error;
}

/// Opens [book] and calls [read] with its text, then closes it. Supplied by
/// the application, which owns the document engines.
typedef BookTextReader =
    Future<void> Function(
      Book book,
      Future<void> Function(UnitTextSource text) read,
    );

/// Book text and notes across the library, or within one book.
///
/// A book's text is read through the application's [BookTextReader] the
/// first time it is searched and saved, compressed, so later searches read
/// it from the store. [textVersions] name each format's text extraction: a
/// book saved under another name is read again, and a book removed from the
/// library loses its saved text.
final class LibrarySearch {
  LibrarySearch(Store store, {required this.textVersions})
    : _records = LibrarySearchRecords(store) {
    for (final version in textVersions.values) {
      final bytes = utf8.encode(version).length;
      if (bytes < 1 || bytes > maxTextVersionBytes) {
        throw const CoreException.invalidRequest(
          'A text version is 1 to $maxTextVersionBytes bytes.',
        );
      }
    }
  }

  final LibrarySearchRecords _records;
  final Map<BookFormat, String> textVersions;

  /// The notes of every library book, or of book [bookId], whose quote or
  /// body holds [query], with the same case-insensitive matching as book
  /// search. Books come most recently read first, and at most
  /// [maxLibraryNoteHits] notes in all.
  Future<List<BookNoteHits>> notes(
    String query, {
    int? bookId,
    CancellationToken? cancellation,
  }) async {
    // Checks the query before reading anything.
    firstMatches(const [], query, maxMatches: 1);
    if (query.isEmpty) return const [];
    cancellation.throwIfCancelled();
    final books = await _records.notes(bookId);
    cancellation.throwIfCancelled();
    final notes = [
      for (final (_, entries) in books)
        for (final note in entries) (note.quote, note.body),
    ];
    final found = await _inIsolate(_matchNotes, notes, query);
    cancellation.throwIfCancelled();
    final results = <BookNoteHits>[];
    var index = 0;
    var next = 0;
    for (final (book, entries) in books) {
      final hits = <NoteHit>[];
      for (final note in entries) {
        if (next < found.length && found[next].$1 == index) {
          hits.add(NoteHit(note, found[next].$2));
          next++;
        }
        index++;
      }
      if (hits.isNotEmpty) results.add(BookNoteHits(book, hits));
    }
    return results;
  }

  /// The text matches of [query] in every library book, or in book [bookId],
  /// one book at a time, most recently read first; books without matches
  /// are left out.
  ///
  /// A book whose text is not saved yet is opened through [read], and its
  /// text saved. A book that cannot be read yields a [BookTextHits.failed]
  /// and the search goes on. Cancelling [cancellation] ends the stream with
  /// [CoreErrorKind.cancelled].
  Stream<BookTextHits> text(
    String query, {
    int? bookId,
    required BookTextReader read,
    CancellationToken? cancellation,
  }) async* {
    firstMatches(const [], query, maxMatches: 1);
    if (query.isEmpty) return;
    cancellation.throwIfCancelled();
    await _records.forgetRemoved();
    final books = await _records.books(bookId);
    for (final book in books) {
      cancellation.throwIfCancelled();
      final version = textVersions[book.format];
      if (version == null) continue;
      final BookTextHits hits;
      try {
        hits = await _searchBook(book, version, query, read, cancellation);
      } on CoreException catch (error) {
        if (error.kind == CoreErrorKind.cancelled) rethrow;
        cancellation.throwIfCancelled();
        yield BookTextHits.failed(book, error);
        continue;
      }
      cancellation.throwIfCancelled();
      if (hits.matches.isNotEmpty) yield hits;
    }
  }

  Future<BookTextHits> _searchBook(
    Book book,
    String version,
    String query,
    BookTextReader read,
    CancellationToken? cancellation,
  ) async {
    final saved = await _records.savedText(book.contentHash, version);
    cancellation.throwIfCancelled();
    if (saved != null) {
      final (matches, more) = await _inIsolate(
        _searchSaved,
        saved.units,
        query,
      );
      return BookTextHits(book, matches, more: more, partial: saved.truncated);
    }
    _ReadText? opened;
    try {
      await read(book, (source) async {
        opened = await _readText(source, cancellation);
      });
    } on CoreException {
      rethrow;
    } on Exception catch (error) {
      throw CoreException(
        CoreErrorKind.inaccessible,
        'The book could not be read: $error',
      );
    }
    cancellation.throwIfCancelled();
    final text =
        opened ??
        (throw const CoreException(
          CoreErrorKind.inaccessible,
          'The book could not be read.',
        ));
    final (matches, more, compressed) = await _inIsolate(
      _searchAndCompress,
      text.units,
      query,
    );
    cancellation.throwIfCancelled();
    await _records.saveText(
      book.contentHash,
      version,
      unitCount: text.unitCount,
      bytes: text.bytes,
      truncated: text.truncated,
      units: compressed,
    );
    return BookTextHits(book, matches, more: more, partial: text.truncated);
  }
}

/// [work] of [input] and [query] in another isolate. Top level so the
/// closure sent there captures only its arguments, never a caller's context.
Future<R> _inIsolate<T, R>(
  R Function(T input, String query) work,
  T input,
  String query,
) => Isolate.run(() => work(input, query));

typedef _ReadText = ({
  int unitCount,
  List<(int, String)> units,
  int bytes,
  bool truncated,
});

/// [source]'s unit texts, up to [maxLibraryTextBytes] in all: a unit that
/// would go past it, and every later one, is left out.
Future<_ReadText> _readText(
  UnitTextSource source,
  CancellationToken? cancellation,
) async {
  final units = <(int, String)>[];
  var bytes = 0;
  var truncated = false;
  for (var unit = 0; unit < source.unitCount; unit++) {
    cancellation.throwIfCancelled();
    final text = await source.unitText(unit, cancellation: cancellation);
    if (text == null || text.text.isEmpty) continue;
    final length = utf8Length(text.text);
    if (bytes + length > maxLibraryTextBytes) {
      truncated = true;
      break;
    }
    bytes += length;
    units.add((unit, text.text));
  }
  return (
    unitCount: source.unitCount,
    units: units,
    bytes: bytes,
    truncated: truncated,
  );
}

(List<SearchMatch>, bool, List<(int, Uint8List)>) _searchAndCompress(
  List<(int, String)> units,
  String query,
) {
  final (matches, more) = firstMatches(
    units,
    query,
    maxMatches: maxLibraryTextMatchesPerBook,
  );
  final codec = ZLibCodec();
  return (
    matches,
    more,
    [
      for (final (unit, text) in units)
        (unit, Uint8List.fromList(codec.encode(utf8.encode(text)))),
    ],
  );
}

(List<SearchMatch>, bool) _searchSaved(
  List<(int, Uint8List)> units,
  String query,
) {
  final codec = ZLibCodec();
  return firstMatches(
    [for (final (unit, text) in units) (unit, utf8.decode(codec.decode(text)))],
    query,
    maxMatches: maxLibraryTextMatchesPerBook,
  );
}

/// The notes of [notes] (quote, body) that hold [query], by index, until
/// [maxLibraryNoteHits] are found.
List<(int, List<NoteMatch>)> _matchNotes(
  List<(String?, String?)> notes,
  String query,
) {
  final found = <(int, List<NoteMatch>)>[];
  for (final (index, (quote, body)) in notes.indexed) {
    final matches = <NoteMatch>[];
    for (final (field, text) in [
      (NoteField.quote, quote),
      (NoteField.body, body),
    ]) {
      if (text == null || text.isEmpty) continue;
      final (fieldMatches, _) = firstMatches(
        [(0, text)],
        query,
        maxMatches: _maxMatchesPerNoteField,
      );
      for (final match in fieldMatches) {
        matches.add(NoteMatch(field, match.offset, match.length));
      }
    }
    if (matches.isEmpty) continue;
    found.add((index, matches));
    if (found.length >= maxLibraryNoteHits) break;
  }
  return found;
}

/// A book's saved text: its units' compressed texts.
typedef SavedText = ({List<(int, Uint8List)> units, bool truncated});

/// Library search's queries over the store. Holds nothing but the [Store],
/// so the bodies it sends may capture it.
final class LibrarySearchRecords {
  const LibrarySearchRecords(this._store);

  final Store _store;

  /// The library's books, or book [bookId], most recently read first.
  Future<List<Book>> books(int? bookId) =>
      _store.read((db) => _books(db, bookId));

  /// The books with live notes, or book [bookId] if it has any, with their
  /// notes in reading order.
  Future<List<(Book, List<NoteEntry>)>> notes(int? bookId) =>
      _store.read((db) => _notes(db, bookId));

  /// Forget the saved texts of contents no longer in the library.
  Future<void> forgetRemoved() => _store.transaction(_forgetRemoved);

  Future<SavedText?> savedText(String contentHash, String version) =>
      _store.read((db) => _savedText(db, contentHash, version));

  /// Save a book's text, replacing any saved before.
  Future<void> saveText(
    String contentHash,
    String version, {
    required int unitCount,
    required int bytes,
    required bool truncated,
    required List<(int, Uint8List)> units,
  }) => _store.transaction(
    (db) =>
        _saveText(db, contentHash, version, unitCount, bytes, truncated, units),
  );
}

const _recent = 'last_read DESC, date_added DESC, id DESC';

List<Book> _books(Database db, int? bookId) => db
    .select(
      '''SELECT $bookColumns FROM books
       WHERE ?1 IS NULL OR id = ?1 ORDER BY $_recent''',
      [bookId],
    )
    .map(bookFromRow)
    .toList();

List<(Book, List<NoteEntry>)> _notes(Database db, int? bookId) {
  final rows = db.select(
    '''SELECT $bookColumns,
         (SELECT v.document_id FROM annotation_document_versions v
          WHERE v.content_hash = books.content_hash) AS document
       FROM books
       WHERE document IS NOT NULL AND (?1 IS NULL OR id = ?1)
       ORDER BY $_recent''',
    [bookId],
  );
  final results = <(Book, List<NoteEntry>)>[];
  var count = 0;
  for (final row in rows) {
    final entries = noteEntries(db, row['document'] as String);
    if (entries.isEmpty) continue;
    count += entries.length;
    if (count > maxLibraryNotesSearched) {
      throw const CoreException.limitExceeded(
        'The library has more than $maxLibraryNotesSearched notes to search.',
      );
    }
    results.add((bookFromRow(row), entries));
  }
  return results;
}

void _forgetRemoved(Database db) => db.execute('''DELETE FROM book_texts
     WHERE content_hash NOT IN (SELECT content_hash FROM books)''');

SavedText? _savedText(Database db, String contentHash, String version) {
  final book = db
      .select(
        '''SELECT truncated FROM book_texts
           WHERE content_hash = ? AND text_version = ?''',
        [contentHash, version],
      )
      .firstOrNull;
  if (book == null) return null;
  return (
    units: [
      for (final row in db.select(
        '''SELECT unit, text FROM book_text_units
           WHERE content_hash = ? ORDER BY unit''',
        [contentHash],
      ))
        (row.columnAt(0) as int, row.columnAt(1) as Uint8List),
    ],
    truncated: book.columnAt(0) == 1,
  );
}

void _saveText(
  Database db,
  String contentHash,
  String version,
  int unitCount,
  int bytes,
  bool truncated,
  List<(int, Uint8List)> units,
) {
  db.execute('DELETE FROM book_texts WHERE content_hash = ?', [contentHash]);
  // The book left the library while it was being read.
  if (db.select('SELECT 1 FROM books WHERE content_hash = ?', [
    contentHash,
  ]).isEmpty) {
    return;
  }
  db.execute(
    '''INSERT INTO book_texts
         (content_hash, text_version, unit_count, text_bytes, truncated)
       VALUES (?, ?, ?, ?, ?)''',
    [contentHash, version, unitCount, bytes, truncated ? 1 : 0],
  );
  final insert = db.prepare(
    'INSERT INTO book_text_units (content_hash, unit, text) VALUES (?, ?, ?)',
  );
  try {
    for (final (unit, text) in units) {
      insert.execute([contentHash, unit, text]);
    }
  } finally {
    insert.close();
  }
}
