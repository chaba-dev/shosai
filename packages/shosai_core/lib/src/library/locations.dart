/// Persistent device-local associations between contents and capabilities.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../cancellation.dart';
import '../errors.dart';
import '../preferences.dart';
import '../store/store.dart';
import 'editions.dart';
import 'files.dart';
import 'inspection.dart';
import 'location.dart';

typedef LocatedContent = ({BookLocator locator, LocationFailure? failure});

/// What an unopened source file's contents said about it, read at the size
/// and revision it was listed with. Its cover is read separately, by
/// [LibraryLocations.previewCover].
final class SourcePreview {
  const SourcePreview({this.title, this.author, this.hasCover = false});

  final String? title;
  final String? author;
  final bool hasCover;
}

/// Location records are independent of notes and reading state. Removing a
/// connection keeps its books and locators, marking them unavailable, and
/// keeps what it admitted and hid. A later connection's scan recognizes a file
/// listed at the size and revision a removed connection admitted or hid it at,
/// and takes over that record (see [scan]); any other old file stays
/// unavailable until the adapter reads it.
///
/// The generation returned by [connect] belongs to one adapter/grant lifetime.
/// Completions from an older grant cannot restore availability after removal or
/// reconnection. This object holds only sendable database state, not adapters.
final class LibraryLocations {
  const LibraryLocations(this._store);

  final Store _store;

  /// Existing opaque file keys can identify a root-scoped source when fresh
  /// authorization cannot read the old account's identity.
  Future<List<String>> connectionKeys(String id) => _store.read(
    (db) => [
      for (final row in db.select(
        '''SELECT locator_key FROM book_locators WHERE location_id = ?
           UNION SELECT locator_key FROM library_source_files WHERE location_id = ?
           UNION SELECT locator_key FROM library_source_admissions WHERE location_id = ?
           UNION SELECT locator_key FROM library_hidden_source_files WHERE location_id = ?''',
        [id, id, id, id],
      ))
        row.columnAt(0) as String,
    ],
  );

  /// Metadata is stored per file, not in a size-limited preference value.
  Future<List<({String locationId, LocationEntry entry})>>
  catalog() => _store.read(
    (db) => [
      for (final row in db.select(
        'SELECT location_id, locator_key, name, size, revision, folder_name FROM library_source_files',
      ))
        (
          locationId: row.columnAt(0) as String,
          entry: LocationEntry(
            key: row.columnAt(1) as String,
            name: row.columnAt(2) as String,
            isDirectory: false,
            size: row.columnAt(3) as int?,
            revision: row.columnAt(4) as String?,
            folderName: row.columnAt(5) as String?,
          ),
        ),
    ],
  );

  /// The stored previews of unopened source files, without their covers.
  /// A preview is kept only while its file is listed unchanged, so each
  /// belongs to the file now in the catalog.
  Future<Map<BookLocator, SourcePreview>> previews() => _store.read(
    (db) => {
      for (final row in db.select(
        '''SELECT location_id, locator_key, title, author, cover IS NOT NULL
           FROM library_source_previews''',
      ))
        (
          locationId: row.columnAt(0) as String,
          key: row.columnAt(1) as String,
        ): SourcePreview(
          title: row.columnAt(2) as String?,
          author: row.columnAt(3) as String?,
          hasCover: row.columnAt(4) == 1,
        ),
    },
  );

  /// The preview cover of the unopened file at [locator], or null.
  Future<Uint8List?> previewCover(BookLocator locator) => _store.read(
    (db) =>
        db
                .select(
                  '''SELECT cover FROM library_source_previews
                     WHERE location_id = ? AND locator_key = ?''',
                  [locator.locationId, locator.key],
                )
                .firstOrNull
                ?.columnAt(0)
            as Uint8List?,
  );

  /// Record what [entry]'s contents said about it, and return the preview as
  /// stored. Ignored, and reported as null, unless the connection is still in
  /// generation [generation] and the file is still listed, unopened, at the
  /// size and revision it was read at: a preview never outlives the file or
  /// the grant it came from.
  Future<SourcePreview?> savePreview(
    String id,
    int generation,
    LocationEntry entry,
    BookMetadata metadata,
  ) {
    String? text(String? value) {
      final collapsed = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
      return collapsed == null ||
              collapsed.isEmpty ||
              utf8.encode(collapsed).length > 4096
          ? null
          : collapsed;
    }

    final title = text(metadata.title);
    final author = text(metadata.author);
    final publication = metadata.publication.encode();
    final given = metadata.cover;
    final cover = given == null || given.isEmpty || given.length > maxCoverBytes
        ? null
        : given;
    return _store.transaction((db) {
      if (!_hasGeneration(db, id, generation)) return null;
      if (db
          .select(
            '''SELECT 1 FROM library_source_files
               WHERE location_id = ? AND locator_key = ?
                 AND size IS ? AND revision IS ?''',
            [id, entry.key, entry.size, entry.revision],
          )
          .isEmpty) {
        return null;
      }
      db.execute(
        '''INSERT INTO library_source_previews
             (location_id, locator_key, size, revision, title, author, cover, publication_metadata)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(location_id, locator_key) DO UPDATE SET
             size = excluded.size, revision = excluded.revision,
             title = excluded.title, author = excluded.author,
             cover = excluded.cover, publication_metadata = excluded.publication_metadata''',
        [
          id,
          entry.key,
          entry.size,
          entry.revision,
          title,
          author,
          cover,
          publication,
        ],
      );
      return SourcePreview(
        title: title,
        author: author,
        hasCover: cover != null,
      );
    });
  }

  /// Forget the connection's listing. Its admissions and hidden files stay:
  /// they say which listed file is which book, so the next scan of the same
  /// files, by this connection or one that replaces it, offers no book that
  /// is already on the shelf. The scan forgets the files it no longer lists.
  Future<void> clearCatalog(String id) => _store.transaction((db) {
    db.execute('DELETE FROM library_source_files WHERE location_id = ?', [id]);
    db.execute('DELETE FROM library_source_previews WHERE location_id = ?', [
      id,
    ]);
  });

  /// Admission is separate from source ownership: a local duplicate keeps its
  /// working local path while this mapping suppresses its source candidate.
  /// Returns false if verified facts rejected the preview's chosen group;
  /// the file is still admitted, with its content kept separately.
  /// Disable [inheritPreview] when the adapter cannot verify a source revision.
  Future<bool> admit(
    String id,
    int generation,
    LocationEntry entry,
    String hash, {
    bool inheritPreview = true,
  }) => _store.transaction((db) {
    if (!_hasGeneration(db, id, generation)) {
      throw const LocationException(LocationFailure.revoked);
    }
    db.execute(
      '''UPDATE books SET display_name = COALESCE(display_name, ?),
         source_folder = COALESCE(source_folder, ?) WHERE content_hash = ?''',
      [entry.name, entry.folderName, hash],
    );
    final grouped = admitEditionFile(
      db,
      sourceEditionKey(
        (locationId: id, key: entry.key),
        entry.size,
        entry.revision,
      ),
      hash,
      inheritPreview: inheritPreview,
    );
    db.execute(
      '''INSERT INTO library_source_admissions
          (location_id, locator_key, content_hash, size, revision) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(location_id, locator_key) DO UPDATE SET
          content_hash = excluded.content_hash, size = excluded.size, revision = excluded.revision''',
      [id, entry.key, hash, entry.size, entry.revision],
    );
    db.execute(
      'DELETE FROM library_source_files WHERE location_id = ? AND locator_key = ?',
      [id, entry.key],
    );
    // The book's own record now shows the file.
    db.execute(
      'DELETE FROM library_source_previews WHERE location_id = ? AND locator_key = ?',
      [id, entry.key],
    );
    // The content is in the library again: its other hidden copies are
    // admitted copies once more, so they stay off the shelf as duplicates.
    db.execute(
      '''INSERT INTO library_source_admissions
           (location_id, locator_key, content_hash, size, revision)
         SELECT location_id, locator_key, content_hash, size, revision
         FROM library_hidden_source_files WHERE content_hash = ?
         ON CONFLICT(location_id, locator_key) DO NOTHING''',
      [hash],
    );
    db.execute(
      'DELETE FROM library_hidden_source_files WHERE content_hash = ?',
      [hash],
    );
    return grouped;
  });

  /// Source files whose books were removed from the library, newest first.
  /// Their files are untouched in their locations; a scan leaves them off the
  /// shelf while their bytes are unchanged.
  Future<List<({String locationId, LocationEntry entry, String contentHash})>>
  hidden() => _store.read(
    (db) => [
      for (final row in db.select(
        '''SELECT h.location_id, h.locator_key, h.content_hash, h.size, h.revision
           FROM library_hidden_source_files h
           JOIN library_locations l ON l.id = h.location_id AND l.removed = 0
           ORDER BY h.hidden_at DESC, h.location_id, h.locator_key''',
      ))
        (
          locationId: row.columnAt(0) as String,
          entry: LocationEntry(
            key: row.columnAt(1) as String,
            name: (row.columnAt(1) as String).split('/').last,
            isDirectory: false,
            size: row.columnAt(3) as int?,
            revision: row.columnAt(4) as String?,
          ),
          contentHash: row.columnAt(2) as String,
        ),
    ],
  );

  /// Offer a hidden file on the shelf again. It is a candidate like a newly
  /// discovered file: opening it reads the bytes and brings the book, and the
  /// notes its content kept, back.
  Future<void> unhide(BookLocator locator) => _store.transaction((db) {
    final row = db
        .select(
          '''SELECT content_hash, size, revision FROM library_hidden_source_files
             WHERE location_id = ? AND locator_key = ?''',
          [locator.locationId, locator.key],
        )
        .firstOrNull;
    if (row == null) {
      throw const CoreException.notFound('The file is not hidden.');
    }
    db.execute(
      '''INSERT INTO library_source_files (location_id, locator_key, name, size, revision)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(location_id, locator_key) DO NOTHING''',
      [
        locator.locationId,
        locator.key,
        locator.key.split('/').last,
        row.columnAt(1),
        row.columnAt(2),
      ],
    );
    db.execute(
      'DELETE FROM library_hidden_source_files WHERE location_id = ? AND locator_key = ?',
      [locator.locationId, locator.key],
    );
  });

  /// Publish a complete bounded scan. Changed bytes at an admitted key become
  /// candidates again, without changing the old book identity or its notes.
  /// A hidden file (its book removed from the library) stays off the shelf
  /// while its bytes are unchanged; changed or gone, it is forgotten.
  ///
  /// A file a removed connection admitted or hid, listed again at the same
  /// key, size and revision, is the same file reconnected: its record moves to
  /// this connection, so its book is located here and reads again, or stays
  /// off the shelf, without being offered as a new candidate.
  Future<Set<String>> scan(
    String id,
    int generation,
    List<LocationEntry> entries,
  ) => _store.transaction((db) {
    if (!_hasGeneration(db, id, generation)) {
      throw const LocationException(LocationFailure.revoked);
    }
    if (entries.length > maxDiscoveredBooks) {
      throw const CoreException.limitExceeded(
        'The source contains too many books.',
      );
    }
    final admitted = {
      for (final row in db.select(
        'SELECT locator_key, size, revision FROM library_source_admissions WHERE location_id = ?',
        [id],
      ))
        row.columnAt(0) as String: (
          size: row.columnAt(1) as int?,
          revision: row.columnAt(2) as String?,
        ),
    };
    final hidden = {
      for (final row in db.select(
        'SELECT locator_key, size, revision FROM library_hidden_source_files WHERE location_id = ?',
        [id],
      ))
        row.columnAt(0) as String: (
          size: row.columnAt(1) as int?,
          revision: row.columnAt(2) as String?,
        ),
    };
    // What removed connections admitted or hid, by file key: a file listed
    // again at the same size and revision is taken over below.
    final removedAdmitted = {
      for (final row in db.select(
        '''SELECT a.locator_key, a.location_id, a.content_hash, a.size, a.revision
           FROM library_source_admissions a
           JOIN library_locations l ON l.id = a.location_id AND l.removed = 1''',
      ))
        row.columnAt(0) as String: _RemovedRecord(
          locationId: row.columnAt(1) as String,
          contentHash: row.columnAt(2) as String,
          size: row.columnAt(3) as int?,
          revision: row.columnAt(4) as String?,
        ),
    };
    final removedHidden = {
      for (final row in db.select(
        '''SELECT h.locator_key, h.location_id, h.content_hash, h.size,
                  h.revision, h.hidden_at
           FROM library_hidden_source_files h
           JOIN library_locations l ON l.id = h.location_id AND l.removed = 1''',
      ))
        row.columnAt(0) as String: _RemovedRecord(
          locationId: row.columnAt(1) as String,
          contentHash: row.columnAt(2) as String,
          size: row.columnAt(3) as int?,
          revision: row.columnAt(4) as String?,
          hiddenAt: row.columnAt(5) as String,
        ),
    };
    final known = <String>{};
    final present = entries.map((entry) => entry.key).toSet();
    db.execute('DELETE FROM library_source_files WHERE location_id = ?', [id]);
    for (final entry in entries) {
      final previous = admitted[entry.key] ?? hidden[entry.key];
      final unchanged =
          previous != null &&
          previous.size == entry.size &&
          previous.revision == entry.revision;
      if (unchanged ||
          _reconnected(db, id, entry, removedAdmitted, removedHidden)) {
        known.add(entry.key);
      } else {
        db.execute(
          '''INSERT INTO library_source_files
          (location_id, locator_key, name, size, revision, folder_name)
          VALUES (?, ?, ?, ?, ?, ?)''',
          [
            id,
            entry.key,
            entry.name,
            entry.size,
            entry.revision,
            entry.folderName,
          ],
        );
      }
    }
    // A preview belongs to the bytes it was read from: one whose file went,
    // changed, or is now a known book is forgotten.
    db.execute(
      '''DELETE FROM library_source_previews WHERE location_id = ?
         AND NOT EXISTS (SELECT 1 FROM library_source_files f
           WHERE f.location_id = library_source_previews.location_id
             AND f.locator_key = library_source_previews.locator_key
             AND f.size IS library_source_previews.size
             AND f.revision IS library_source_previews.revision)''',
      [id],
    );
    for (final row in db.select(
      'SELECT locator_key FROM book_locators WHERE location_id = ?',
      [id],
    )) {
      final key = row.columnAt(0) as String;
      if (!present.contains(key)) {
        db.execute(
          "UPDATE book_locators SET failure = 'missing' WHERE location_id = ? AND locator_key = ?",
          [id, key],
        );
      }
    }
    for (final key in admitted.keys.where((key) => !present.contains(key))) {
      db.execute(
        'DELETE FROM library_source_admissions WHERE location_id = ? AND locator_key = ?',
        [id, key],
      );
    }
    for (final key in hidden.keys.where((key) => !known.contains(key))) {
      db.execute(
        'DELETE FROM library_hidden_source_files WHERE location_id = ? AND locator_key = ?',
        [id, key],
      );
    }
    return known;
  });

  /// Adopt a connection generation and its optional preference changes in one
  /// transaction, so credential replacement cannot leave a half-connected source.
  Future<int> connect(
    String id,
    String label, {
    Map<String, String> preferences = const {},
  }) {
    _checkText(id, 1024);
    _checkText(label, 1024);
    return _store.transaction((db) {
      if (preferences.isNotEmpty) {
        Preferences.setAllInTransaction(db, preferences);
      }
      db.execute(
        '''INSERT INTO library_locations (id, label) VALUES (?, ?)
           ON CONFLICT(id) DO UPDATE SET label = excluded.label,
             generation = generation + 1, removed = 0''',
        [id, label],
      );
      return db
              .select('SELECT generation FROM library_locations WHERE id = ?', [
                id,
              ])
              .first
              .columnAt(0)
          as int;
    });
  }

  /// Associate already identified content with another device-local copy.
  /// The book must exist; keys never become content identities.
  Future<void> locate(
    String contentHash,
    BookLocator locator, {
    required int generation,
  }) async {
    _checkText(locator.key, 16384);
    final accepted = await _store.transaction((db) {
      if (!_hasGeneration(db, locator.locationId, generation)) return false;
      if (db.select('SELECT 1 FROM books WHERE content_hash = ?', [
        contentHash,
      ]).isEmpty) {
        throw const CoreException.notFound(
          'The content is not in the library.',
        );
      }
      db.execute(
        '''INSERT INTO book_locators
             (content_hash, location_id, locator_key, failure)
           VALUES (?, ?, ?, NULL)
           ON CONFLICT(content_hash, location_id, locator_key)
           DO UPDATE SET failure = NULL''',
        [contentHash, locator.locationId, locator.key],
      );
      return true;
    });
    if (!accepted) throw const LocationException(LocationFailure.revoked);
  }

  Future<List<LocatedContent>> copies(String contentHash) => _store.read(
    (db) => [
      for (final row in db.select(
        '''SELECT location_id, locator_key, failure FROM book_locators
           WHERE content_hash = ? ORDER BY location_id, locator_key''',
        [contentHash],
      ))
        (
          locator: (
            locationId: row.columnAt(0) as String,
            key: row.columnAt(1) as String,
          ),
          failure: switch (row.columnAt(2)) {
            null => null,
            final String name => LocationFailure.values.byName(name),
            _ => throw const CoreException.malformed('Invalid location state.'),
          },
        ),
    ],
  );

  Future<void> remove(String id) => _store.transaction((db) {
    db.execute(
      '''UPDATE library_locations SET removed = 1, generation = generation + 1
         WHERE id = ?''',
      [id],
    );
    db.execute(
      "UPDATE book_locators SET failure = 'revoked' WHERE location_id = ?",
      [id],
    );
  });

  /// Reconcile a complete metadata scan, without claiming to verify bytes.
  /// Return identified keys so discovery never invents identities for files
  /// that have not been read. Missing files retain their books and notes.
  Future<Set<String>> reconcile(
    String id,
    int generation,
    Set<String> present,
  ) => _store.transaction((db) {
    if (!_hasGeneration(db, id, generation)) {
      throw const LocationException(LocationFailure.revoked);
    }
    final keys = <String>{};
    for (final row in db.select(
      'SELECT locator_key FROM book_locators WHERE location_id = ?',
      [id],
    )) {
      final key = row.columnAt(0) as String;
      keys.add(key);
      if (!present.contains(key)) {
        db.execute(
          "UPDATE book_locators SET failure = 'missing' WHERE location_id = ? AND locator_key = ?",
          [id, key],
        );
      }
    }
    return keys;
  });

  /// A failed folder listing or grant acquisition affects the connection as a
  /// whole. A successful metadata listing does not validate any book's bytes.
  Future<void> unavailable(
    String id,
    int generation,
    LocationFailure failure,
  ) => _store.transaction(
    (db) => _connectionFailure(db, id, generation, failure),
  );

  /// An adapter can lose its grant before it opens a stream (for example a
  /// desktop folder disappearing). Record that failure with the same lifetime
  /// guards as streamed reads; it must not bypass availability accounting.
  Future<void> failed(
    String contentHash,
    BookLocator locator, {
    required int generation,
    required LocationFailure failure,
  }) => _observed(
    locator.locationId,
    generation,
    contentHash,
    locator.key,
    failure,
  );

  /// Check failed links against their original content identity, without
  /// admitting files, replacing cached copies or reconciling the catalog.
  /// Streams full contents with a size bound; only verified, still-current
  /// links lose their failure. A failed check leaves its old record intact.
  Future<({int verified, int unavailable})> revalidate(
    LibraryLocation location,
    int generation, {
    CancellationToken? cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final id = location.id;
    final copies = await _store.read(
      (db) => [
        for (final row in db.select(
          '''SELECT l.content_hash, l.locator_key, b.file_size
           FROM book_locators l JOIN books b ON b.content_hash = l.content_hash
           WHERE l.location_id = ? AND l.failure IS NOT NULL
           ORDER BY l.content_hash, l.locator_key''',
          [id],
        ))
          (
            hash: row.columnAt(0) as String,
            key: row.columnAt(1) as String,
            size: row.columnAt(2) as int,
          ),
      ],
    );
    var verified = 0;
    var unavailable = 0;
    for (final copy in copies) {
      cancellation.throwIfCancelled();
      if (!await _store.read((db) => _hasGeneration(db, id, generation))) {
        throw const CoreException.cancelled();
      }
      try {
        if (!await _matchesContents(location, copy, cancellation)) {
          unavailable++;
          continue;
        }
        cancellation.throwIfCancelled();
        if (!await _observed(id, generation, copy.hash, copy.key, null)) {
          throw const CoreException.cancelled();
        }
        verified++;
      } on LocationException {
        // One inaccessible file must not erase another file's successful
        // verification or invalidate a working source's authorization.
        unavailable++;
      }
    }
    cancellation.throwIfCancelled();
    if (!await _store.read((db) => _hasGeneration(db, id, generation))) {
      throw const CoreException.cancelled();
    }
    return (verified: verified, unavailable: unavailable);
  }

  /// Read just the requested file/range; record expected availability failures
  /// without removing the book or changing any of its annotations.
  Stream<List<int>> read(
    LibraryLocation location,
    int generation,
    String contentHash,
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) async* {
    if (start < 0 || (end != null && end < start)) {
      throw const CoreException.invalidRequest('Invalid byte range.');
    }
    cancellation.throwIfCancelled();
    // Capture only records in StoreBody, never the platform adapter.
    final id = location.id;
    final accepted = await _store.read((db) {
      if (!_hasGeneration(db, id, generation)) return false;
      if (db
          .select(
            '''SELECT 1 FROM book_locators WHERE content_hash = ?
           AND location_id = ? AND locator_key = ?''',
            [contentHash, id, key],
          )
          .isEmpty) {
        throw const CoreException.notFound('The book locator is not recorded.');
      }
      return true;
    });
    if (!accepted) throw const LocationException(LocationFailure.revoked);
    cancellation.throwIfCancelled();
    try {
      await for (final chunk in location.read(
        key,
        start: start,
        end: end,
        cancellation: cancellation,
      )) {
        cancellation.throwIfCancelled();
        yield chunk;
      }
      cancellation.throwIfCancelled();
      await _observed(id, generation, contentHash, key, null);
    } on LocationException catch (error) {
      await _observed(id, generation, contentHash, key, error.failure);
      rethrow;
    }
  }

  Future<bool> _observed(
    String id,
    int generation,
    String hash,
    String key,
    LocationFailure? failure,
  ) => _store.transaction((db) {
    // A revoked grant affects all its files, not merely the requested one.
    if (failure == LocationFailure.revoked) {
      _connectionFailure(db, id, generation, failure!);
    } else {
      db.execute(
        '''UPDATE book_locators SET failure = ?
           WHERE content_hash = ? AND location_id = ? AND locator_key = ?
           AND EXISTS (SELECT 1 FROM library_locations
             WHERE id = ? AND generation = ? AND removed = 0)''',
        [failure?.name, hash, id, key, id, generation],
      );
    }
    return db.updatedRows > 0;
  });
}

// Keep stream callbacks (and their cancellation token) out of the lexical
// context of StoreBody closures sent to the database isolate.
Future<bool> _matchesContents(
  LibraryLocation location,
  ({String hash, String key, int size}) copy,
  CancellationToken? cancellation,
) async {
  var size = 0;
  final digest = await sha256
      .bind(
        location.read(copy.key, cancellation: cancellation).map((chunk) {
          cancellation.throwIfCancelled();
          size += chunk.length;
          if (size > copy.size) {
            throw const LocationException(LocationFailure.missing);
          }
          return chunk;
        }),
      )
      .single;
  cancellation.throwIfCancelled();
  return size == copy.size && digest.toString() == copy.hash;
}

/// What a removed connection admitted or hid: the file's key, size and
/// revision, the book it was, and when it was hidden.
class _RemovedRecord {
  const _RemovedRecord({
    required this.locationId,
    required this.contentHash,
    required this.size,
    required this.revision,
    this.hiddenAt,
  });

  final String locationId;
  final String contentHash;
  final int? size;
  final String? revision;
  final String? hiddenAt;

  bool matches(LocationEntry entry) =>
      size == entry.size && revision == entry.revision;
}

/// Move the record a removed connection kept of [entry], listed by [id] at the
/// size and revision it was admitted or hidden at, to [id]. An admitted file
/// keeps its admission; where the removed connection also located its book,
/// that locator moves to [id] and reads again. A hidden file stays off the
/// shelf. Reports whether such a record was found.
bool _reconnected(
  Database db,
  String id,
  LocationEntry entry,
  Map<String, _RemovedRecord> removedAdmitted,
  Map<String, _RemovedRecord> removedHidden,
) {
  final admission = removedAdmitted[entry.key];
  if (admission != null && admission.matches(entry)) {
    db.execute(
      '''INSERT INTO library_source_admissions
           (location_id, locator_key, content_hash, size, revision)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(location_id, locator_key) DO UPDATE SET
           content_hash = excluded.content_hash, size = excluded.size,
           revision = excluded.revision''',
      [id, entry.key, admission.contentHash, entry.size, entry.revision],
    );
    // Admission and location are separate: a book that was only admitted
    // from the removed connection (its working source is a local import) is
    // not made to depend on this one.
    db.execute(
      '''INSERT INTO book_locators
           (content_hash, location_id, locator_key, failure)
         SELECT content_hash, ?, locator_key, NULL FROM book_locators
         WHERE content_hash = ? AND location_id = ? AND locator_key = ?
         ON CONFLICT(content_hash, location_id, locator_key)
         DO UPDATE SET failure = NULL''',
      [id, admission.contentHash, admission.locationId, entry.key],
    );
    // The file is a book here now, not a hidden file this connection once
    // knew at other bytes.
    db.execute(
      'DELETE FROM library_hidden_source_files WHERE location_id = ? AND locator_key = ?',
      [id, entry.key],
    );
    db.execute(
      'DELETE FROM library_source_admissions WHERE location_id = ? AND locator_key = ?',
      [admission.locationId, entry.key],
    );
    db.execute(
      '''DELETE FROM book_locators
         WHERE content_hash = ? AND location_id = ? AND locator_key = ?''',
      [admission.contentHash, admission.locationId, entry.key],
    );
    return true;
  }
  final hidden = removedHidden[entry.key];
  if (hidden == null || !hidden.matches(entry)) return false;
  db.execute(
    '''INSERT INTO library_hidden_source_files
         (location_id, locator_key, content_hash, size, revision, hidden_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(location_id, locator_key) DO UPDATE SET
         content_hash = excluded.content_hash, size = excluded.size,
         revision = excluded.revision, hidden_at = excluded.hidden_at''',
    [
      id,
      entry.key,
      hidden.contentHash,
      entry.size,
      entry.revision,
      hidden.hiddenAt,
    ],
  );
  db.execute(
    'DELETE FROM library_hidden_source_files WHERE location_id = ? AND locator_key = ?',
    [hidden.locationId, entry.key],
  );
  return true;
}

void _connectionFailure(
  Database db,
  String id,
  int generation,
  LocationFailure failure,
) {
  db.execute(
    '''UPDATE book_locators SET failure = ? WHERE location_id = ?
       AND EXISTS (SELECT 1 FROM library_locations
         WHERE id = ? AND generation = ? AND removed = 0)''',
    [failure.name, id, id, generation],
  );
  if (failure == LocationFailure.revoked) {
    db.execute(
      '''UPDATE library_locations SET generation = generation + 1, removed = 1
         WHERE id = ? AND generation = ? AND removed = 0''',
      [id, generation],
    );
  }
}

bool _hasGeneration(Database db, String id, int generation) => db
    .select(
      '''SELECT 1 FROM library_locations
       WHERE id = ? AND generation = ? AND removed = 0''',
      [id, generation],
    )
    .isNotEmpty;

void _checkText(String value, int maxLength) {
  if (value.isEmpty || value.length > maxLength || value.contains('\u0000')) {
    throw const CoreException.invalidRequest('Invalid location identifier.');
  }
}
