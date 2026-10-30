/// Persistent device-local associations between contents and capabilities.
library;

import '../cancellation.dart';
import '../errors.dart';
import '../store/store.dart';
import 'files.dart';
import 'location.dart';

typedef LocatedContent = ({BookLocator locator, LocationFailure? failure});

/// Location records are independent of notes and reading state. Removing a
/// connection keeps its books and locators, marking them unavailable. Connecting
/// again never declares old files available until the adapter reads them.
///
/// The generation returned by [connect] belongs to one adapter/grant lifetime.
/// Completions from an older grant cannot restore availability after removal or
/// reconnection. This object holds only sendable database state, not adapters.
final class LibraryLocations {
  const LibraryLocations(this._store);

  final Store _store;

  /// Metadata is stored per file, not in a size-limited preference value.
  Future<List<({String locationId, LocationEntry entry})>>
  catalog() => _store.read(
    (db) => [
      for (final row in db.select(
        'SELECT location_id, locator_key, name, size, revision FROM library_source_files',
      ))
        (
          locationId: row.columnAt(0) as String,
          entry: LocationEntry(
            key: row.columnAt(1) as String,
            name: row.columnAt(2) as String,
            isDirectory: false,
            size: row.columnAt(3) as int?,
            revision: row.columnAt(4) as String?,
          ),
        ),
    ],
  );

  Future<void> clearCatalog(String id) => _store.transaction((db) {
    db.execute('DELETE FROM library_source_files WHERE location_id = ?', [id]);
    db.execute('DELETE FROM library_source_admissions WHERE location_id = ?', [
      id,
    ]);
  });

  /// Admission is separate from source ownership: a local duplicate keeps its
  /// working local path while this mapping suppresses its source candidate.
  Future<void> admit(
    String id,
    int generation,
    LocationEntry entry,
    String hash,
  ) => _store.transaction((db) {
    if (!_hasGeneration(db, id, generation)) {
      throw const LocationException(LocationFailure.revoked);
    }
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
    final known = <String>{};
    final present = entries.map((entry) => entry.key).toSet();
    db.execute('DELETE FROM library_source_files WHERE location_id = ?', [id]);
    for (final entry in entries) {
      final previous = admitted[entry.key] ?? hidden[entry.key];
      if (previous != null &&
          previous.size == entry.size &&
          previous.revision == entry.revision) {
        known.add(entry.key);
      } else {
        db.execute(
          'INSERT INTO library_source_files (location_id, locator_key, name, size, revision) VALUES (?, ?, ?, ?, ?)',
          [id, entry.key, entry.name, entry.size, entry.revision],
        );
      }
    }
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

  Future<int> connect(String id, String label) {
    _checkText(id, 1024);
    _checkText(label, 1024);
    return _store.transaction((db) {
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

  Future<void> _observed(
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
  });
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
