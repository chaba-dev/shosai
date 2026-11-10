/// The annotation store's database records.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../errors.dart';
import '../library/records.dart';
import '../store/store.dart';
import 'annotation.dart';
import 'quote.dart';
import 'resolution.dart';

/// A new annotation, validated and ready to insert.
final class NewAnnotation {
  const NewAnnotation({
    required this.anchor,
    required this.quote,
    required this.color,
    required this.body,
    required this.provenance,
  });

  final AnnotationAnchor anchor;
  final QuoteSelector? quote;

  /// A highlight's color; null for notes.
  final HighlightColor? color;
  final String? body;
  final AnnotationProvenance? provenance;
}

/// A book's annotations and the content they are resolved against.
final class BookAnnotations {
  const BookAnnotations(
    this.contentHash,
    this.annotations, [
    this.normalization = maxQuoteNormalizationWork,
    this.sharedContents = const {},
  ]);

  final String contentHash;
  final List<StoredAnnotation> annotations;

  /// The listing's normalization allowance left once every stored selector
  /// was checked, for resolving them.
  final int normalization;
  final Set<String> sharedContents;
}

/// Annotation queries over the store. Holds nothing but the [Store], so the
/// bodies it sends may capture it.
final class AnnotationRecords {
  const AnnotationRecords(this._store);

  final Store _store;

  Future<
    Map<
      String,
      ({AnnotationResolution resolution, List<AnnotationFragment> fragments})
    >
  >
  projections(String hash, String resolver, List<String> ids) => _store.read(
    (db) => {
      if (ids.isNotEmpty)
        for (final row in db.select(
          '''SELECT annotation_id, resolution, fragments
        FROM annotation_projections WHERE target_hash = ? AND resolver = ?
        AND annotation_id IN (${_marks(ids.length)})''',
          [hash, resolver, ...ids],
        ))
          row.columnAt(0) as String: (
            resolution: AnnotationResolution.values.byName(
              row.columnAt(1) as String,
            ),
            fragments: [
              for (final raw in jsonDecode(row.columnAt(2) as String) as List)
                (
                  unit: (raw as List)[0] as int,
                  start: raw[1] as int,
                  end: raw[2] as int,
                ),
            ],
          ),
    },
  );

  Future<void> saveProjections(
    String hash,
    String resolver,
    List<ResolvedAnnotation> items,
  ) => _store.transaction((db) {
    for (final item in items) {
      if (item.resolution == AnnotationResolution.incomplete) continue;
      db.execute(
        '''INSERT OR REPLACE INTO annotation_projections
          (annotation_id, target_hash, resolver, resolution, fragments) VALUES (?, ?, ?, ?, ?)''',
        [
          item.id,
          hash,
          resolver,
          item.resolution.name,
          jsonEncode([
            for (final f in item.fragments) [f.unit, f.start, f.end],
          ]),
        ],
      );
    }
  });

  Future<StoredAnnotation> create(
    AnnotationOwner owner,
    NewAnnotation annotation,
  ) => _store.transaction((db) => _create(db, owner, annotation));

  Future<BookAnnotations> list(AnnotationOwner owner) =>
      _store.read((db) => _list(db, owner));

  Future<NotesSummary> summary(int bookId) =>
      _store.read((db) => _summary(db, bookId));

  Future<bool> update(
    AnnotationOwner owner,
    String id,
    HighlightColor color,
    String? body,
  ) => _store.transaction((db) => _update(db, owner, id, color, body));

  Future<bool> updateNote(AnnotationOwner owner, String id, String body) =>
      _store.transaction((db) => _updateNote(db, owner, id, body));

  Future<LibraryNotesPage> libraryNotes(
    int offset,
    int limit,
    List<int>? after,
  ) => _store.read((db) => _libraryNotes(db, offset, limit, after));

  Future<bool> delete(AnnotationOwner owner, String id) =>
      _store.transaction((db) => _delete(db, owner, id));

  Future<AssociationSourcePage> associationSources(
    int bookId,
    String? cursor,
    int limit,
  ) => _store.read((db) => _associationSources(db, bookId, cursor, limit));

  Future<AssociationOutcome> associate(String sourceVersionId, int bookId) =>
      _store.transaction((db) => _associate(db, sourceVersionId, bookId));
}

final _random = Random.secure();

/// A random (version 4) UUID.
String newUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [
    for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

const _now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";

/// A modification time strictly after the previous one, even within one
/// millisecond.
const _nextModifiedAt = '''CASE WHEN $_now > modified_at THEN $_now
       ELSE strftime('%Y-%m-%dT%H:%M:%fZ', modified_at, '+0.001 seconds') END''';

typedef _Book = ({String hash, String format, String title});

/// Whose annotations a query reaches: a library book, or a content opened
/// outside the library. Holds only sendable values.
sealed class AnnotationOwner {
  const AnnotationOwner();
}

final class LibraryBookOwner extends AnnotationOwner {
  const LibraryBookOwner(this.bookId);

  final int bookId;
}

final class ContentOwner extends AnnotationOwner {
  const ContentOwner(this.content);

  final AnnotatedContent content;
}

_Book _owner(Database db, AnnotationOwner owner) => switch (owner) {
  LibraryBookOwner(:final bookId) => _book(db, bookId),
  ContentOwner(:final content) => (
    hash: content.contentHash,
    format: content.format.name,
    title: content.title,
  ),
};

_Book _book(Database db, int bookId) {
  final row = db.select(
    'SELECT content_hash, format, title FROM books WHERE id = ?',
    [bookId],
  ).firstOrNull;
  if (row == null) {
    throw const CoreException.notFound('The book is not in the library.');
  }
  return (
    hash: row.columnAt(0) as String,
    format: row.columnAt(1) as String,
    title: row.columnAt(2) as String,
  );
}

typedef _Version = ({String id, String documentId, String format});

_Version? _version(Database db, String hash) {
  final row = db
      .select(
        '''SELECT id, document_id, format FROM annotation_document_versions
       WHERE content_hash = ?''',
        [hash],
      )
      .firstOrNull;
  return row == null
      ? null
      : (
          id: row.columnAt(0) as String,
          documentId: row.columnAt(1) as String,
          format: row.columnAt(2) as String,
        );
}

/// The book's version, created (with a new document) on its first
/// annotation.
_Version _ensureVersion(Database db, _Book book) {
  final existing = _version(db, book.hash);
  if (existing != null) return existing;
  final documentId = newUuid();
  final versionId = newUuid();
  db.execute('INSERT INTO annotation_documents (id, format) VALUES (?, ?)', [
    documentId,
    book.format,
  ]);
  db.execute(
    '''INSERT INTO annotation_document_versions
         (id, document_id, format, content_hash, title)
       VALUES (?, ?, ?, ?, ?)''',
    [versionId, documentId, book.format, book.hash, book.title],
  );
  return (id: versionId, documentId: documentId, format: book.format);
}

/// Turn the bookmark notes migration 8 kept for content [hash], which no
/// book held then, into page notes, now that a book with it says their
/// format. Called as the book is added to the library.
void adoptPendingBookmarkNotes(
  Database db, {
  required String hash,
  required String format,
  required String title,
}) {
  final notes = db.select(
    '''SELECT unit, location_offset, note, created_at
       FROM pending_bookmark_notes WHERE content_hash = ? ORDER BY id''',
    [hash],
  );
  if (notes.isEmpty) return;
  final version = _ensureVersion(db, (
    hash: hash,
    format: format,
    title: title,
  ));
  if (version.format != format) {
    // Only a content opened outside the library names its own format; the
    // notes' places mean nothing in another.
    throw CoreException.invalidRequest(
      'The content was annotated as ${version.format.toUpperCase()}, not '
      '${format.toUpperCase()}.',
    );
  }
  final epub = format == 'epub';
  for (final note in notes) {
    final unit = note.columnAt(0) as int;
    db.execute(
      '''INSERT INTO annotations (id, version_id, format, kind, anchor_version,
           body, epub_spine_index, epub_scalar_start, pdf_page,
           created_at, modified_at)
         VALUES (?, ?, ?, 'page', 1, ?, ?, ?, ?, ?, ?)''',
      [
        newUuid(),
        version.id,
        version.format,
        note.columnAt(2),
        epub ? unit : null,
        epub ? (note.columnAt(1) as int? ?? 0) : null,
        epub ? null : unit,
        note.columnAt(3),
        note.columnAt(3),
      ],
    );
  }
  // Over the limits a reader loads, the import fails and the notes wait.
  checkAnnotationSnapshot(db, [hash]);
  db.execute('DELETE FROM pending_bookmark_notes WHERE content_hash = ?', [
    hash,
  ]);
}

/// Throw unless the document's live annotations are within the snapshot
/// limits a reader loads at once.
void _checkSnapshot(Database db, Set<String> ids) {
  final row = db.select(
    '''SELECT COUNT(*),
         COALESCE(SUM($annotationBaseBytes
           + length(CAST(a.id AS BLOB))
           + length(CAST(COALESCE(a.body, '') AS BLOB))
           + length(CAST(COALESCE(a.original_quote, '') AS BLOB))
           + length(CAST(COALESCE(a.normalized_exact, '') AS BLOB))
           + length(CAST(COALESCE(a.normalized_prefix, '') AS BLOB))
           + length(CAST(COALESCE(a.normalized_suffix, '') AS BLOB))
           + length(CAST(COALESCE(a.epub_resource_path, '') AS BLOB))
           + length(CAST(COALESCE(a.source_system, '') AS BLOB))
           + length(CAST(COALESCE(a.source_id, '') AS BLOB))
           + COALESCE(length(a.pdf_rectangles), 0)), 0),
         COALESCE(SUM(COALESCE(length(a.pdf_rectangles), 0) / 16), 0)
       FROM annotations a
       JOIN annotation_document_versions v ON v.id = a.version_id
       WHERE v.document_id IN (${_marks(ids.length)}) AND a.deleted_at IS NULL''',
    ids.toList(),
  ).single;
  if ((row.columnAt(0) as int) > maxAnnotationsPerDocument ||
      (row.columnAt(1) as int) > maxAnnotationDocumentBytes ||
      (row.columnAt(2) as int) > maxPdfRectanglesPerDocument) {
    throw const CoreException.limitExceeded(
      "The book's annotations exceed what one book may hold.",
    );
  }
}

/// Validate a prospective shared snapshot and every edition that shares its
/// version documents. Call within the mutation's transaction, so rejection
/// never leaves successfully saved notes that the reader cannot load.
void checkAnnotationSnapshot(Database db, Iterable<String> hashes) {
  final documents = {for (final hash in hashes) ..._documentIds(db, hash)};
  if (documents.isEmpty) return;
  _checkSnapshot(db, documents);
  for (final row in db.select(
    '''SELECT DISTINCT content_hash FROM annotation_document_versions
    WHERE document_id IN (${_marks(documents.length)})''',
    documents.toList(),
  )) {
    final affected = _documentIds(db, row.columnAt(0) as String);
    if (!documents.containsAll(affected)) {
      _checkSnapshot(db, affected);
    }
  }
}

StoredAnnotation _create(
  Database db,
  AnnotationOwner owner,
  NewAnnotation annotation,
) {
  final book = _owner(db, owner);
  final anchor = annotation.anchor;
  final format = switch (anchor) {
    EpubAnchor() || EpubPlaceAnchor() => 'epub',
    PdfAnchor() || PdfPageAnchor() => 'pdf',
    BookAnchor() => book.format,
  };
  if (format != book.format) {
    throw CoreException.invalidRequest(
      'A ${format.toUpperCase()} annotation cannot belong to a '
      '${book.format.toUpperCase()} book.',
    );
  }
  final version = _ensureVersion(db, book);
  if (version.format != format) {
    // Only a content opened outside the library names its own format.
    throw CoreException.invalidRequest(
      'The content was annotated as ${version.format.toUpperCase()}, not '
      '${format.toUpperCase()}.',
    );
  }
  final id = newUuid();
  final quote = annotation.quote;
  final epub = anchor is EpubAnchor ? anchor : null;
  final pdf = anchor is PdfAnchor ? anchor : null;
  final place = anchor is EpubPlaceAnchor ? anchor : null;
  final page = anchor is PdfPageAnchor ? anchor : null;
  db.execute(
    '''INSERT INTO annotations (id, version_id, format, kind, anchor_version,
         original_quote, normalization_profile, normalized_exact,
         normalized_prefix, normalized_suffix, color, body,
         source_system, source_id,
         epub_spine_index, epub_resource_path, epub_scalar_start, epub_scalar_end,
         pdf_page, pdf_char_start, pdf_char_end, pdf_rectangles)
       VALUES (?, ?, ?, ?, $anchorVersion, ?, ?, ?, ?, ?, ?, ?, ?, ?,
               ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      id,
      version.id,
      format,
      _kindNames[anchor.kind],
      quote?.original,
      quote == null ? null : quoteProfileV1,
      quote?.exact,
      quote?.prefix,
      quote?.suffix,
      annotation.color?.name,
      annotation.body,
      annotation.provenance?.system,
      annotation.provenance?.id,
      epub?.spineIndex ?? place?.spineIndex,
      epub?.resourcePath ?? place?.resourcePath,
      epub?.start ?? place?.offset,
      epub?.end,
      pdf?.page ?? page?.page,
      pdf?.start,
      pdf?.end,
      pdf == null ? null : encodeRectangles(pdf.rectangles),
    ],
  );
  checkAnnotationSnapshot(db, [book.hash]);
  return _annotation(
    db.select('$_select WHERE a.id = ?', [id]).single,
    NormalizationAllowance(),
  );
}

const _select = '''SELECT a.id, v.content_hash, a.format,
    a.original_quote, a.normalized_exact, a.normalized_prefix,
    a.normalized_suffix, a.color, a.body, a.source_system, a.source_id,
    a.epub_spine_index, a.epub_resource_path, a.epub_scalar_start,
    a.epub_scalar_end, a.pdf_page, a.pdf_char_start, a.pdf_char_end,
    a.pdf_rectangles, a.created_at, a.modified_at, a.kind
  FROM annotations a
  JOIN annotation_document_versions v ON v.id = a.version_id''';

/// Each [AnnotationKind] as the `kind` column stores it.
const _kindNames = {
  AnnotationKind.highlight: 'highlight',
  AnnotationKind.pageNote: 'page',
  AnnotationKind.bookNote: 'book',
};

AnnotationKind _kind(String name) =>
    _kindNames.entries.firstWhere((entry) => entry.value == name).key;

/// The annotation [row] holds, its selector checked within [allowance].
StoredAnnotation _annotation(Row row, NormalizationAllowance allowance) {
  final exact = row.columnAt(4) as String?;
  final system = row.columnAt(9) as String?;
  final color = row.columnAt(7) as String?;
  return StoredAnnotation(
    id: row.columnAt(0) as String,
    contentHash: row.columnAt(1) as String,
    anchor: switch ((_kind(row.columnAt(21) as String), row.columnAt(2))) {
      (AnnotationKind.highlight, 'epub') => EpubAnchor(
        spineIndex: row.columnAt(11) as int,
        resourcePath: row.columnAt(12) as String,
        start: row.columnAt(13) as int,
        end: row.columnAt(14) as int,
      ),
      (AnnotationKind.highlight, _) => PdfAnchor(
        page: row.columnAt(15) as int,
        start: row.columnAt(16) as int?,
        end: row.columnAt(17) as int?,
        rectangles: decodeRectangles(row.columnAt(18) as Uint8List),
      ),
      (AnnotationKind.pageNote, 'epub') => EpubPlaceAnchor(
        spineIndex: row.columnAt(11) as int,
        resourcePath: row.columnAt(12) as String?,
        offset: row.columnAt(13) as int,
      ),
      (AnnotationKind.pageNote, _) => PdfPageAnchor(row.columnAt(15) as int),
      (AnnotationKind.bookNote, _) => const BookAnchor(),
    },
    quote: exact == null ? null : _quote(row, exact, allowance),
    color: color == null ? null : HighlightColor.values.byName(color),
    body: row.columnAt(8) as String?,
    provenance: system == null
        ? null
        : AnnotationProvenance(system, row.columnAt(10) as String?),
    createdAt: row.columnAt(19) as String,
    modifiedAt: row.columnAt(20) as String,
  );
}

/// [rectangles] as little-endian float32 quadruples. Throws
/// [CoreErrorKind.invalidRequest] unless their float32 rounding is valid
/// (see [checkRectangles]), so no invalid rectangle is ever stored.
/// The stored selector of [row], checked as [QuoteSelector.of] builds them,
/// so resolution can trust it. Throws [CoreErrorKind.malformed] for an
/// invalid selector and [CoreErrorKind.limitExceeded] when checking it
/// needs more than [allowance] has left.
QuoteSelector _quote(Row row, String exact, NormalizationAllowance allowance) {
  final quote = QuoteSelector(
    original: row.columnAt(3) as String?,
    exact: exact,
    prefix: row.columnAt(5) as String,
    suffix: row.columnAt(6) as String,
  );
  checkQuoteSelector(
    quote,
    kind: CoreErrorKind.malformed,
    allowance: allowance,
  );
  return quote;
}

Uint8List encodeRectangles(List<PageRect> rectangles) {
  rectangles = checkRectangles(rectangles);
  final data = ByteData(rectangles.length * 16);
  for (var index = 0; index < rectangles.length; index++) {
    final rectangle = rectangles[index];
    final offset = index * 16;
    data.setFloat32(offset, rectangle.left, Endian.little);
    data.setFloat32(offset + 4, rectangle.top, Endian.little);
    data.setFloat32(offset + 8, rectangle.right, Endian.little);
    data.setFloat32(offset + 12, rectangle.bottom, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// The rectangles [encodeRectangles] stored in [bytes]. Throws
/// [CoreErrorKind.malformed] unless they are 1 to [maxPdfRectangles] valid
/// rectangles.
List<PageRect> decodeRectangles(Uint8List bytes) {
  if (bytes.length % 16 != 0) {
    throw const CoreException.malformed(
      'Stored PDF annotation rectangles are truncated.',
    );
  }
  final data = ByteData.sublistView(bytes);
  final rectangles = [
    for (var offset = 0; offset + 16 <= bytes.length; offset += 16)
      PageRect(
        data.getFloat32(offset, Endian.little),
        data.getFloat32(offset + 4, Endian.little),
        data.getFloat32(offset + 8, Endian.little),
        data.getFloat32(offset + 12, Endian.little),
      ),
  ];
  return checkRectangles(rectangles, kind: CoreErrorKind.malformed);
}

BookAnnotations _list(Database db, AnnotationOwner owner) {
  final book = _owner(db, owner);
  final documents = _documentIds(db, book.hash);
  if (documents.isEmpty) return BookAnnotations(book.hash, const []);
  _checkSnapshot(db, documents);
  final rows = db.select(
    '''$_select
       WHERE v.document_id IN (${_marks(documents.length)}) AND a.deleted_at IS NULL
       ORDER BY a.created_at, a.rowid
       LIMIT ?''',
    [...documents, maxAnnotationsPerDocument + 1],
  );
  if (rows.length > maxAnnotationsPerDocument) {
    throw const CoreException.limitExceeded(
      'The book has more than $maxAnnotationsPerDocument annotations.',
    );
  }
  // One allowance for every row: normalizing stored selectors runs on the
  // store's only worker, so a listing may not spend more than one operation.
  final allowance = NormalizationAllowance();
  final shared = {
    for (final row in db.select(
      '''SELECT content_hash FROM annotation_document_versions
    WHERE document_id IN (${_marks(documents.length)}) AND document_id NOT IN
      (SELECT document_id FROM annotation_document_versions WHERE content_hash = ?)''',
      [...documents, book.hash],
    ))
      row.columnAt(0) as String,
  };
  return BookAnnotations(
    book.hash,
    [for (final row in rows) _annotation(row, allowance)],
    allowance.remaining,
    shared,
  );
}

String _marks(int count) => List.filled(count, '?').join(',');

Set<String> _editionHashes(Database db, String hash) => {
  for (final row in db.select(
    '''SELECT substr(member.file_key, 6)
    FROM shelf_members target JOIN shelf_members member ON member.edition_id = target.edition_id
    WHERE target.file_key = ? AND member.file_key LIKE 'hash:%' ''',
    ['hash:$hash'],
  ))
    row.columnAt(0) as String,
};

Set<String> _documentIds(Database db, String hash) {
  final hashes = {hash, ..._editionHashes(db, hash)};
  return {
    for (final row in db.select(
      '''SELECT DISTINCT document_id
    FROM annotation_document_versions WHERE content_hash IN (${_marks(hashes.length)})''',
      hashes.toList(),
    ))
      row.columnAt(0) as String,
  };
}

NotesSummary _summary(Database db, int bookId) {
  final hash = db
      .select('SELECT content_hash FROM books WHERE id = ?', [bookId])
      .firstOrNull
      ?.columnAt(0);
  final documents = hash == null
      ? <String>{}
      : _documentIds(db, hash as String);
  if (documents.isEmpty) return NotesSummary.empty;
  final live = '''FROM annotations a
       JOIN annotation_document_versions v ON v.id = a.version_id
       WHERE v.document_id IN (${_marks(documents.length)}) AND a.deleted_at IS NULL''';
  final count =
      db.select('SELECT count(*) $live', documents.toList()).first.columnAt(0)
          as int;
  final latest = db
      .select(
        '''SELECT coalesce(${_words('a.original_quote')},
             ${_words('a.normalized_exact')}, ${_words('a.body')}) AS words
           $live AND words IS NOT NULL
           ORDER BY a.created_at DESC, a.rowid DESC LIMIT 1''',
        documents.toList(),
      )
      .firstOrNull
      ?.columnAt(0);
  return NotesSummary(count, latest as String?);
}

/// [column] when it has words: a geometry-only annotation's empty note and a
/// note of spaces quote nothing.
String _words(String column) =>
    "CASE WHEN trim($column, $_whiteSpace) <> '' THEN $column END";

/// Unicode's White_Space characters and the byte order mark, as Dart's
/// `String.trim` takes them.
const _whiteSpace =
    'char(9, 10, 11, 12, 13, 32, 133, 160, 5760, 8192, 8193, 8194, 8195, '
    '8196, 8197, 8198, 8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, '
    '12288, 65279)';

/// The live annotation [id] of the book's document, as an update target.
String _ownedBy(int count) =>
    '''id = ? AND deleted_at IS NULL AND version_id IN (
    SELECT id FROM annotation_document_versions WHERE document_id IN (${_marks(count)}))''';

bool _update(
  Database db,
  AnnotationOwner owner,
  String id,
  HighlightColor color,
  String? body,
) {
  final hash = _owner(db, owner).hash;
  final documents = _documentIds(db, hash);
  if (documents.isEmpty) return false;
  db.execute(
    '''UPDATE annotations SET color = ?, body = ?, modified_at = $_nextModifiedAt
       WHERE ${_ownedBy(documents.length)} AND kind = 'highlight' ''',
    [color.name, body, id, ...documents],
  );
  if (db.updatedRows != 1) return false;
  checkAnnotationSnapshot(db, [hash]);
  return true;
}

bool _updateNote(Database db, AnnotationOwner owner, String id, String body) {
  final hash = _owner(db, owner).hash;
  final documents = _documentIds(db, hash);
  if (documents.isEmpty) return false;
  db.execute(
    '''UPDATE annotations SET body = ?, modified_at = $_nextModifiedAt
       WHERE ${_ownedBy(documents.length)} AND kind <> 'highlight' ''',
    [body, id, ...documents],
  );
  if (db.updatedRows != 1) return false;
  checkAnnotationSnapshot(db, [hash]);
  return true;
}

LibraryNotesPage _libraryNotes(
  Database db,
  int offset,
  int limit,
  List<int>? after,
) {
  // Library books whose documents hold live annotations, in the library's
  // recent order: from the first when the books before the page are checked
  // in the same statement.
  final from = after == null ? offset : 0;
  final books = db.select(
    '''WITH candidates AS (SELECT $bookColumns,
         (SELECT v.document_id FROM annotation_document_versions v
          WHERE v.content_hash = books.content_hash) AS document,
         row_number() OVER (PARTITION BY coalesce(
           (SELECT edition_id FROM shelf_members WHERE file_key = 'hash:' || books.content_hash),
           'book:' || books.id)
           ORDER BY last_read DESC, date_added DESC, id DESC) AS edition_rank
       FROM books
       WHERE EXISTS (
         SELECT 1 FROM annotation_document_versions dv
         JOIN annotations a ON a.version_id = dv.id
         WHERE dv.document_id = document AND a.deleted_at IS NULL))
       SELECT * FROM candidates WHERE edition_rank = 1
       ORDER BY last_read DESC, date_added DESC, id DESC
       LIMIT ? OFFSET ?''',
    [offset - from + limit + 1, from],
  );
  if (after != null) {
    final before = [for (final row in books.take(offset)) row['id'] as int];
    if (before.length != after.length ||
        before.indexed.any((entry) => after[entry.$1] != entry.$2)) {
      return const LibraryNotesPage.changed();
    }
  }
  final page = books.skip(offset - from).toList();
  return LibraryNotesPage([
    for (final row in page.take(limit))
      BookNotes(
        bookFromRow(row),
        noteEntries(
          db,
          row['document'] as String,
          documents: _documentIds(db, row['content_hash'] as String),
        ),
      ),
  ], hasMore: page.length > limit);
}

/// The live annotations of document [documentId] as the notes surfaces list
/// them, in reading order: book notes first, then each unit's annotations by
/// where they start.
List<NoteEntry> noteEntries(
  Database db,
  String documentId, {
  Set<String>? documents,
}) => [
  for (final row in db.select(
    '''SELECT a.id, a.kind, a.color,
         coalesce(a.original_quote, a.normalized_exact), a.body,
         coalesce(a.epub_spine_index, a.pdf_page),
         coalesce(a.epub_scalar_start, a.pdf_char_start),
         a.created_at, a.modified_at
       FROM annotations a
       JOIN annotation_document_versions v ON v.id = a.version_id
       WHERE v.document_id IN (${_marks((documents ?? {documentId}).length)}) AND a.deleted_at IS NULL
       ORDER BY a.kind <> 'book',
         coalesce(a.epub_spine_index, a.pdf_page),
         coalesce(a.epub_scalar_start, a.pdf_char_start, 0),
         a.created_at, a.rowid
       LIMIT ?''',
    [
      ...?documents,
      if (documents == null) documentId,
      maxAnnotationsPerDocument,
    ],
  ))
    NoteEntry(
      id: row.columnAt(0) as String,
      kind: _kind(row.columnAt(1) as String),
      color: switch (row.columnAt(2) as String?) {
        final color? => HighlightColor.values.byName(color),
        null => null,
      },
      quote: row.columnAt(3) as String?,
      body: row.columnAt(4) as String?,
      unit: row.columnAt(5) as int?,
      offset: row.columnAt(6) as int?,
      createdAt: row.columnAt(7) as String,
      modifiedAt: row.columnAt(8) as String,
    ),
];

bool _delete(Database db, AnnotationOwner owner, String id) {
  final documents = _documentIds(db, _owner(db, owner).hash);
  if (documents.isEmpty) return false;
  db.execute(
    '''UPDATE annotations SET deleted_at = $_now, modified_at = $_nextModifiedAt
       WHERE ${_ownedBy(documents.length)}''',
    [id, ...documents],
  );
  return db.updatedRows == 1;
}

/// Versions of the book's format, outside its document, whose documents
/// hold live annotations.
const _sourceCandidates = '''FROM annotation_document_versions v
  WHERE v.format = ? AND v.document_id IS NOT ?
    AND EXISTS (
      SELECT 1 FROM annotation_document_versions dv
      JOIN annotations a ON a.version_id = dv.id
      WHERE dv.document_id = v.document_id AND a.deleted_at IS NULL)''';

AssociationSourcePage _associationSources(
  Database db,
  int bookId,
  String? cursor,
  int limit,
) {
  final book = _book(db, bookId);
  final documentId = _version(db, book.hash)?.documentId;
  final rows = db.select(
    '''SELECT v.id, v.title, v.content_hash,
         (SELECT COUNT(*) FROM annotation_document_versions dv
          JOIN annotations a ON a.version_id = dv.id
          WHERE dv.document_id = v.document_id AND a.deleted_at IS NULL)
       $_sourceCandidates AND v.id > ?
       ORDER BY v.id LIMIT ?''',
    [book.format, documentId, cursor ?? '', limit + 1],
  );
  final sources = [
    for (final row in rows.take(limit))
      AssociationSource(
        versionId: row.columnAt(0) as String,
        title: row.columnAt(1) as String,
        contentHash: row.columnAt(2) as String,
        liveAnnotations: row.columnAt(3) as int,
      ),
  ];
  String? previous;
  if (cursor != null) {
    // The cursor that lists the page before this one; null for the first.
    final earlier = db.select(
      '''SELECT v.id $_sourceCandidates AND v.id <= ?
         ORDER BY v.id DESC LIMIT ?''',
      [book.format, documentId, cursor, limit + 1],
    );
    previous = earlier.length > limit
        ? earlier[limit].columnAt(0) as String
        : null;
  }
  return AssociationSourcePage(
    sources,
    nextCursor: rows.length > limit ? sources.last.versionId : null,
    previousCursor: previous,
  );
}

AssociationOutcome _associate(Database db, String sourceVersionId, int bookId) {
  final source = db.select(
    'SELECT document_id, format FROM annotation_document_versions WHERE id = ?',
    [sourceVersionId],
  ).firstOrNull;
  if (source == null) {
    throw const CoreException.notFound('The annotation source does not exist.');
  }
  final sourceDocument = source.columnAt(0) as String;
  final book = _book(db, bookId);
  if (source.columnAt(1) != book.format) {
    throw const CoreException.invalidRequest(
      'The annotation source is a different format.',
    );
  }
  final target = _version(db, book.hash);
  if (target != null) {
    if (target.documentId == sourceDocument) {
      return AssociationOutcome.alreadyAssociated;
    }
    // Both contents already have annotations: the book's document absorbs
    // the source's versions, and with them their annotations.
    _checkVersionCapacity(db, [target.documentId, sourceDocument], 0);
    db.execute(
      'UPDATE annotation_document_versions SET document_id = ? WHERE document_id = ?',
      [target.documentId, sourceDocument],
    );
    db.execute('DELETE FROM annotation_documents WHERE id = ?', [
      sourceDocument,
    ]);
    checkAnnotationSnapshot(db, [book.hash]);
    return AssociationOutcome.associated;
  }
  _checkVersionCapacity(db, [sourceDocument], 1);
  db.execute(
    '''INSERT INTO annotation_document_versions
         (id, document_id, format, content_hash, title, associated_from_version_id)
       VALUES (?, ?, ?, ?, ?, ?)''',
    [
      newUuid(),
      sourceDocument,
      book.format,
      book.hash,
      book.title,
      sourceVersionId,
    ],
  );
  checkAnnotationSnapshot(db, [book.hash]);
  return AssociationOutcome.associated;
}

void _checkVersionCapacity(
  Database db,
  List<String> documents,
  int additional,
) {
  final count =
      db
              .select(
                '''SELECT COUNT(*) FROM annotation_document_versions
               WHERE document_id IN (${List.filled(documents.length, '?').join(', ')})''',
                documents,
              )
              .single
              .columnAt(0)
          as int;
  if (count + additional > maxAnnotationDocumentVersions) {
    throw const CoreException.limitExceeded(
      'A book’s annotations span at most $maxAnnotationDocumentVersions contents.',
    );
  }
}
