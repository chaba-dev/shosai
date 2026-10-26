/// Device-local, content-verified files; never a source of book identity.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../errors.dart';
import '../store/store.dart';
import 'book.dart';
import 'files.dart';
import 'location.dart';
import 'records.dart';

/// Automatic files share a byte budget and a 256-entry ceiling. Explicitly
/// kept files are outside that budget and are never automatically evicted.
/// A consumer owns its file until its callback completes; serial access and a
/// process lock prevent eviction while a document takes its immutable snapshot.
final class BookFileCache {
  BookFileCache(
    this._store,
    this.directory, {
    this.capacity = 256 * 1024 * 1024,
  }) {
    if (capacity < 0) throw ArgumentError.value(capacity, 'capacity');
  }

  final Store _store;
  final String directory;
  final int capacity;
  Future<void> _tail = Future.value();
  String? _root;
  static final _held = <String>{};

  /// Reconcile durable availability before the first library listing.
  Future<void> sweep() => _serial(() async {});

  Future<T> _serial<T>(Future<T> Function() effect) {
    final result = _tail.then((_) => _locked(effect));
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<T> _locked<T>(Future<T> Function() effect) async {
    await Directory(directory).create(recursive: true);
    final root = await Directory(directory).resolveSymbolicLinks();
    if (!_held.add(root)) {
      throw const CoreException(
        CoreErrorKind.inaccessible,
        'The book cache is in use.',
      );
    }
    RandomAccessFile? lock;
    try {
      await _validateRoot(root);
      lock = await File('$root/.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      await _validateRoot(root);
      _root = root;
      await _reconcile();
      return await effect();
    } finally {
      try {
        await lock?.close();
      } finally {
        _root = null;
        _held.remove(root);
      }
    }
  }

  Future<void> _validateRoot(String root) async {
    if (await Directory(directory).resolveSymbolicLinks() != root ||
        await Directory(root).resolveSymbolicLinks() != root ||
        !await LibraryRecords(
          _store,
        ).claimManagedDirectory(p.normalize(p.absolute(directory)), root)) {
      throw const CoreException(
        CoreErrorKind.inaccessible,
        'The book cache directory has been redirected.',
      );
    }
  }

  String _path(String hash, BookFormat format) =>
      '${_root!}/$hash.${format.name}';

  /// Fetch only on a miss. Oversized automatic files are transient: at most
  /// one bounded incoming file exists, and it is removed after consumption.
  /// No file is published until its entire content matches the expected hash.
  Future<T> withFile<T>(
    Book book,
    Stream<List<int>> Function() fetch,
    Future<T> Function(String path) consume, {
    bool keep = false,
    CancellationToken? cancellation,
  }) => _serial(() async {
    cancellation.throwIfCancelled();
    final hash = book.contentHash;
    final path = _path(hash, book.format);
    final state = await _state(hash);
    final kept = keep || state?.kept == true;
    if (state != null) {
      final fingerprint = await fingerprintFile(
        path,
        cancellation: cancellation,
      );
      if (fingerprint.hash == hash) {
        await _record(hash, book.format, fingerprint.size, kept);
        return consume(path);
      }
      await _drop(hash, book.format);
    }
    final retain = kept || book.fileSize <= capacity;
    if (retain && !kept) await _trim(reserve: book.fileSize, entries: 1);
    await _validateRoot(_root!);
    final incoming = File(uniqueTemporaryPath(_root!, 'incoming'));
    try {
      final output = await incoming.open(mode: FileMode.writeOnly);
      try {
        var size = 0;
        await for (final chunk in fetch()) {
          cancellation.throwIfCancelled();
          size += chunk.length;
          if (size > maxBookInputBytes || size > book.fileSize) {
            throw const LocationException(LocationFailure.missing);
          }
          await output.writeFrom(chunk);
        }
      } finally {
        await output.close();
      }
      final fingerprint = await fingerprintFile(
        incoming.path,
        cancellation: cancellation,
      );
      if (fingerprint.hash != hash) {
        throw const LocationException(LocationFailure.missing);
      }
      cancellation.throwIfCancelled();
      if (!retain) return await consume(incoming.path);
      await _validateRoot(_root!);
      await incoming.rename(path);
      await _record(hash, book.format, fingerprint.size, kept);
      return await consume(path);
    } finally {
      // A redirected root must not turn cleanup into deletion elsewhere.
      try {
        if (await Directory(_root!).resolveSymbolicLinks() == _root &&
            await incoming.exists()) {
          await incoming.delete();
        }
      } on FileSystemException {
        // A missing root leaves nothing safe to clean up. A later sweep will
        // recover an interrupted incoming file if the original root returns.
      }
    }
  });

  /// Releasing an explicit keep makes it evictable, not a deleted library
  /// record. No source file, reading state, or annotation is changed.
  Future<void> release(Book book) => _serial(() async {
    await _release(book.contentHash);
    await _trim();
  });

  Future<void> _release(String hash) => _store.transaction(
    (db) => db.execute(
      'UPDATE book_file_cache SET kept = 0 WHERE content_hash = ?',
      [hash],
    ),
  );

  Future<void> discardLocation(String id) => _serial(() async {
    for (final row in await _locationEntries(id)) {
      await _drop(row.hash, row.format);
    }
  });

  Future<List<({String hash, BookFormat format})>> _locationEntries(
    String id,
  ) => _store.read(
    (db) => [
      for (final row in db.select(
        '''SELECT DISTINCT c.content_hash, c.format
          FROM book_file_cache c JOIN book_locators l USING (content_hash)
          WHERE l.location_id = ? AND c.kept = 0''',
        [id],
      ))
        (
          hash: row.columnAt(0) as String,
          format: BookFormat.fromDatabase(row.columnAt(1) as String),
        ),
    ],
  );

  Future<void> discardUnkept(String hash, BookFormat format) =>
      _serial(() async {
        if ((await _state(hash))?.kept == false) await _drop(hash, format);
      });

  Future<({bool kept})?> _state(String hash) => _store.read((db) {
    final row = db.select(
      'SELECT kept FROM book_file_cache WHERE content_hash = ?',
      [hash],
    ).firstOrNull;
    return row == null ? null : (kept: row.columnAt(0) == 1);
  });

  Future<void> _record(String hash, BookFormat format, int size, bool kept) =>
      _store.transaction(
        (db) => db.execute(
          '''
        INSERT INTO book_file_cache (content_hash, format, size, kept, accessed)
        VALUES (?, ?, ?, ?, (SELECT coalesce(max(accessed), 0) + 1 FROM book_file_cache))
        ON CONFLICT(content_hash) DO UPDATE SET kept = excluded.kept,
          accessed = excluded.accessed
      ''',
          [hash, format.name, size, kept ? 1 : 0],
        ),
      );

  Future<void> _drop(String hash, BookFormat format) async {
    await _validateRoot(_root!);
    final file = File(_path(hash, format));
    // Delete first: a failed deletion must still count against the budget.
    if (await file.exists()) await file.delete();
    await _forget(hash);
  }

  Future<void> _forget(String hash) => _store.transaction(
    (db) => db.execute('DELETE FROM book_file_cache WHERE content_hash = ?', [
      hash,
    ]),
  );

  Future<void> _trim({int reserve = 0, int entries = 0}) async {
    final rows = await _entries(automaticOnly: true);
    var size = rows.fold(0, (sum, row) => sum + row.size);
    var count = rows.length;
    for (final row in rows) {
      if (size + reserve <= capacity && count + entries <= 256) break;
      await _drop(row.hash, row.format);
      size -= row.size;
      count--;
    }
  }

  Future<List<({String hash, BookFormat format, int size})>> _entries({
    bool automaticOnly = false,
  }) => _store.read(
    (db) => [
      for (final row in db.select(
        'SELECT content_hash, format, size FROM book_file_cache ${automaticOnly ? 'WHERE kept = 0' : ''} ORDER BY accessed, content_hash',
      ))
        (
          hash: row.columnAt(0) as String,
          format: BookFormat.fromDatabase(row.columnAt(1) as String),
          size: row.columnAt(2) as int,
        ),
    ],
  );

  /// Recover publication/deletion interrupted by a crash and files removed by
  /// the OS. Unknown files are deleted only inside this dedicated cache root.
  Future<void> _reconcile() async {
    final entries = await _entries();
    final names = {for (final row in entries) '${row.hash}.${row.format.name}'};
    await for (final entry in Directory(_root!).list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (entry is File &&
          !names.contains(name) &&
          (RegExp(r'^[0-9a-f]{64}\.(epub|pdf)$').hasMatch(name) ||
              name.startsWith('.shosai-incoming-'))) {
        await _validateRoot(_root!);
        await entry.delete();
      }
    }
    for (final row in entries) {
      if (!await File(_path(row.hash, row.format)).exists()) {
        await _forget(row.hash);
      }
    }
    await _trim();
  }
}
