/// Persistent device-local associations between contents and capabilities.
library;

import '../cancellation.dart';
import '../errors.dart';
import '../store/store.dart';
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
      db.execute(
        '''UPDATE book_locators SET failure = 'revoked' WHERE location_id = ?
           AND EXISTS (SELECT 1 FROM library_locations
             WHERE id = ? AND generation = ? AND removed = 0)''',
        [id, id, generation],
      );
      db.execute(
        '''UPDATE library_locations SET generation = generation + 1, removed = 1
           WHERE id = ? AND generation = ? AND removed = 0''',
        [id, generation],
      );
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
