/// The library's database records. Every query the library makes is here.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../store/store.dart';
import 'book.dart';
import 'files.dart';
import 'inspection.dart';

/// Library queries over the store.
///
/// Holds nothing but the [Store], so the bodies it sends to the store's
/// worker may capture it; the [Library] facade, which also holds locks and
/// inspectors, never builds a body itself.
final class LibraryRecords {
  const LibraryRecords(this._store);

  final Store _store;

  Future<Book?> book(int id) => _store.read((db) => _bookById(db, id));

  Future<Book?> bookWithContent(String hash) =>
      _store.read((db) => _bookByHash(db, hash));

  Future<Uint8List?> cover(int id) => _store.read(
    (db) =>
        db
                .select('SELECT cover FROM books WHERE id = ?', [id])
                .firstOrNull
                ?.columnAt(0)
            as Uint8List?,
  );

  Future<LibraryPage> page(
    String? query,
    BookFormat? format,
    int limit,
    int offset,
  ) => _store.read((db) => _page(db, query, format?.name, limit, offset));

  /// Record a referenced import of [path], or ask for its metadata first.
  Future<CommitOutcome> commitReferenced(
    String path,
    BookFormat format,
    FileFingerprint fingerprint,
    BookMetadata? metadata,
  ) => _store.transaction(
    (db) => _commitReferenced(db, path, format, fingerprint, metadata),
  );

  /// Throw unless [destination] is free for a private copy of [hash].
  Future<void> checkDestinationOwner(String destination, String hash) =>
      _store.read((db) => _checkDestinationOwner(db, destination, hash));

  /// Record a managed import published at [destination].
  Future<CommitOutcome> commitManaged(
    String source,
    String destination,
    BookFormat format,
    FileFingerprint fingerprint,
    BookMetadata? metadata,
  ) => _store.transaction(
    (db) =>
        _commitManaged(db, source, destination, format, fingerprint, metadata),
  );

  /// Returns the number of books updated (0 or 1).
  Future<int> updateProgress(int id, double progress) =>
      _store.transaction((db) {
        db.execute(
          '''UPDATE books SET progress = ?,
           last_read = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE id = ?''',
          [progress, id],
        );
        return db.updatedRows;
      });

  /// Delete book [id], recording its private copy (if any) as deletion debt.
  Future<Book?> remove(int id) =>
      _store.transaction((db) => _removeBook(db, id));

  /// Record [canonical] as the resolved path of the managed directory
  /// configured as [configured] the first time, and report whether it still
  /// is. Each configured path is recorded separately (under a hash of it, so
  /// the key stays within the preference limits), so a library configured
  /// with a new directory starts afresh while one whose directory was
  /// redirected is caught.
  Future<bool> claimManagedDirectory(String configured, String canonical) {
    final key =
        '$_managedDirectoryKey.${sha256.convert(utf8.encode(configured))}';
    return _store.transaction((db) {
      final recorded = db
          .select('SELECT value FROM preferences WHERE key = ?', [key])
          .firstOrNull
          ?.columnAt(0);
      if (recorded == null) {
        db.execute('INSERT INTO preferences (key, value) VALUES (?, ?)', [
          key,
          canonical,
        ]);
        return true;
      }
      return recorded == canonical;
    });
  }

  /// The paths among [paths] that no book or deletion debt owns.
  Future<List<String>> unowned(List<String> paths) {
    if (paths.isEmpty) return Future.value(const []);
    final candidates = List.of(paths);
    return _store.read((db) {
      final marks = List.filled(candidates.length, '?').join(', ');
      final owned = {
        for (final row in db.select(
          '''SELECT file_path FROM books WHERE file_path IN ($marks)
             UNION
             SELECT file_path FROM managed_file_deletion_debt
             WHERE file_path IN ($marks)''',
          [...candidates, ...candidates],
        ))
          row.columnAt(0) as String,
      };
      return [
        for (final path in candidates)
          if (!owned.contains(path)) path,
      ];
    });
  }

  /// Whether a book or a deletion debt owns [path].
  Future<bool> isOwned(String path) => _store.read(
    (db) => db
        .select(
          '''SELECT 1 FROM books WHERE file_path = ?1
         UNION ALL
         SELECT 1 FROM managed_file_deletion_debt WHERE file_path = ?1''',
          [path],
        )
        .isNotEmpty,
  );

  /// Record a private copy at [path], in [managedDirectory], to delete.
  Future<void> recordDeletionDebt(String path, String managedDirectory) =>
      _store.transaction(
        (db) => _recordDeletionDebt(db, path, managedDirectory),
      );

  /// Up to [limit] debt paths, least-tried first, each counted as tried.
  Future<List<String>> claimDeletionRetries(int limit) =>
      _store.transaction((db) {
        final paths = [
          for (final row in db.select(
            '''SELECT file_path FROM managed_file_deletion_debt
               ORDER BY retry_count, created_at, file_path LIMIT ?''',
            [limit],
          ))
            row.columnAt(0) as String,
        ];
        for (final path in paths) {
          db.execute(
            '''UPDATE managed_file_deletion_debt
               SET retry_count = retry_count + 1 WHERE file_path = ?''',
            [path],
          );
        }
        return paths;
      });

  /// The deletion debt at [path]: whether a book uses the path, and the
  /// managed directory recorded with the debt (null when there is none).
  Future<({bool inUse, String? directory})> deletionDebt(
    String path,
  ) => _store.read((db) {
    final used = db.select('SELECT 1 FROM books WHERE file_path = ?', [path]);
    final directory =
        db
                .select(
                  'SELECT managed_dir FROM managed_file_deletion_debt WHERE file_path = ?',
                  [path],
                )
                .firstOrNull
                ?.columnAt(0)
            as String?;
    return (inUse: used.isNotEmpty, directory: directory);
  });

  Future<void> clearDeletionDebt(String path) => _store.transaction(
    (db) => db.execute(
      'DELETE FROM managed_file_deletion_debt WHERE file_path = ?',
      [path],
    ),
  );
}

const _managedDirectoryKey = 'library.managed_directory';

const _bookColumns = '''id, title, author, format, file_path, storage_kind,
  original_path, content_hash, file_size, cover IS NOT NULL, progress,
  date_added, last_read''';

Book _book(Row row) => Book(
  id: row.columnAt(0) as int,
  title: row.columnAt(1) as String,
  author: row.columnAt(2) as String?,
  format: BookFormat.fromDatabase(row.columnAt(3) as String),
  path: row.columnAt(4) as String,
  storageKind: StorageKind.fromDatabase(row.columnAt(5) as String),
  originalPath: row.columnAt(6) as String,
  contentHash: row.columnAt(7) as String,
  fileSize: row.columnAt(8) as int,
  hasCover: row.columnAt(9) == 1,
  progress: row.columnAt(10) as double,
  dateAdded: row.columnAt(11) as String,
  lastRead: row.columnAt(12) as String?,
);

Book? _bookById(Database db, int id) => db
    .select('SELECT $_bookColumns FROM books WHERE id = ?', [id])
    .map(_book)
    .firstOrNull;

Book? _bookByPath(Database db, String path) => db
    .select('SELECT $_bookColumns FROM books WHERE file_path = ?', [path])
    .map(_book)
    .firstOrNull;

Book? _bookByHash(Database db, String hash) => db
    .select('SELECT $_bookColumns FROM books WHERE content_hash = ?', [hash])
    .map(_book)
    .firstOrNull;

LibraryPage _page(
  Database db,
  String? query,
  String? format,
  int limit,
  int offset,
) {
  final where = <String>[];
  final arguments = <Object?>[];
  if (query != null && query.isNotEmpty) {
    final pattern =
        '%${query.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
    where.add(r"(title LIKE ? ESCAPE '\' OR author LIKE ? ESCAPE '\')");
    arguments.addAll([pattern, pattern]);
  }
  if (format != null) {
    where.add('format = ?');
    arguments.add(format);
  }
  final rows = db.select(
    '''SELECT $_bookColumns FROM books
       ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
       ORDER BY last_read DESC, date_added DESC, id DESC
       LIMIT ? OFFSET ?''',
    [...arguments, limit + 1, offset],
  );
  final books = rows.take(limit).map(_book).toList();
  return LibraryPage(books, hasMore: rows.length > limit);
}

sealed class CommitOutcome {
  const CommitOutcome();
}

final class Committed extends CommitOutcome {
  const Committed(this.book, {required this.duplicate});

  final Book book;
  final bool duplicate;
}

/// The import has to insert a new book and needs its metadata first.
final class NeedsMetadata extends CommitOutcome {
  const NeedsMetadata();
}

CommitOutcome _commitReferenced(
  Database db,
  String path,
  BookFormat format,
  FileFingerprint fingerprint,
  BookMetadata? metadata,
) {
  final atPath = _bookByPath(db, path);
  if (atPath != null) {
    if (atPath.contentHash != fingerprint.hash) {
      throw CoreException.conflict(
        'The file contents no longer match the library book at $path.',
      );
    }
    return Committed(atPath, duplicate: true);
  }
  final sameContent = _bookByHash(db, fingerprint.hash);
  if (sameContent != null) {
    if (sameContent.managed || File(sameContent.path).existsSync()) {
      return Committed(sameContent, duplicate: true);
    }
    // The referenced file moved: follow the content to its new place.
    db.execute(
      'UPDATE books SET file_path = ?, original_path = ? WHERE id = ?',
      [path, path, sameContent.id],
    );
    return Committed(_bookById(db, sameContent.id)!, duplicate: true);
  }
  if (metadata == null) return const NeedsMetadata();
  return Committed(
    _insertBook(
      db,
      metadata,
      format,
      path,
      StorageKind.referenced,
      path,
      fingerprint,
    ),
    duplicate: false,
  );
}

void _checkDestinationOwner(Database db, String destination, String hash) {
  final owner = _bookByPath(db, destination);
  if (owner != null && (!owner.managed || owner.contentHash != hash)) {
    throw const CoreException.conflict(
      'The private copy location belongs to another library book.',
    );
  }
}

CommitOutcome _commitManaged(
  Database db,
  String source,
  String destination,
  BookFormat format,
  FileFingerprint fingerprint,
  BookMetadata? metadata,
) {
  _checkDestinationOwner(db, destination, fingerprint.hash);
  // A removed copy at this path is in use again.
  db.execute('DELETE FROM managed_file_deletion_debt WHERE file_path = ?', [
    destination,
  ]);
  final sameContent = _bookByHash(db, fingerprint.hash);
  if (sameContent != null) {
    if (!sameContent.managed || sameContent.path != destination) {
      db.execute(
        '''UPDATE books SET file_path = ?, storage_kind = 'managed', original_path = ?
           WHERE id = ?''',
        [destination, source, sameContent.id],
      );
      if (sameContent.managed) {
        // The copy moved to a new managed directory; the old one goes.
        _recordDeletionDebt(db, sameContent.path, p.dirname(sameContent.path));
      }
    }
    return Committed(_bookById(db, sameContent.id)!, duplicate: true);
  }
  if (metadata == null) return const NeedsMetadata();
  return Committed(
    _insertBook(
      db,
      metadata,
      format,
      destination,
      StorageKind.managed,
      source,
      fingerprint,
    ),
    duplicate: false,
  );
}

Book _insertBook(
  Database db,
  BookMetadata metadata,
  BookFormat format,
  String path,
  StorageKind storage,
  String originalPath,
  FileFingerprint fingerprint,
) {
  db.execute(
    '''INSERT INTO books (title, author, format, file_path, storage_kind,
         original_path, content_hash, file_size, cover)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      metadata.title,
      metadata.author,
      format.name,
      path,
      storage.name,
      originalPath,
      fingerprint.hash,
      fingerprint.size,
      metadata.cover,
    ],
  );
  return _bookById(db, db.lastInsertRowId)!;
}

Book? _removeBook(Database db, int id) {
  final book = _bookById(db, id);
  if (book == null) return null;
  db.execute('DELETE FROM books WHERE id = ?', [id]);
  // The copy's directory as recorded at import (its canonical path then),
  // never a fresh resolution of the configured directory.
  if (book.managed) _recordDeletionDebt(db, book.path, p.dirname(book.path));
  return book;
}

void _recordDeletionDebt(Database db, String path, String managedDirectory) {
  db.execute(
    '''INSERT INTO managed_file_deletion_debt (file_path, managed_dir) VALUES (?, ?)
       ON CONFLICT(file_path) DO UPDATE SET managed_dir = excluded.managed_dir''',
    [path, managedDirectory],
  );
}

/// The content hash of book [bookId], for records keyed by content.
String bookContentHash(Database db, int bookId) {
  final row = db.select('SELECT content_hash FROM books WHERE id = ?', [
    bookId,
  ]).firstOrNull;
  if (row == null) {
    throw const CoreException.notFound('The book is not in the library.');
  }
  return row.columnAt(0) as String;
}
