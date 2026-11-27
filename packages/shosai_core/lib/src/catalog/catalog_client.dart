/// Replaceable free-book metadata, independent of the personal library store.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../catalog.dart';
import '../cancellation.dart';
import '../worker.dart';
import 'catalog_database.dart';

export 'catalog_database.dart'
    show
        CatalogBook,
        CatalogCategory,
        CatalogEdition,
        CatalogBookDetails,
        CatalogBookAuthor,
        CatalogAuthor,
        catalogMoreByAuthorLimit,
        CatalogFilters;

enum CatalogRefresh { notDue, unchanged, installed }

/// One application-owned catalog. Nothing is fetched at construction or during
/// local queries. Search asks [refresh] when used; attempts (including failures)
/// are persisted before network access, so relaunches cannot bypass the daily
/// limit. The caller may continue querying the installed snapshot during an
/// update, and presents failures without discarding offline results.
final class CatalogClient {
  CatalogClient(
    this.directory, {
    required this.userAgent,
    Uri? snapshot,
    DateTime Function()? clock,
  }) : snapshot = snapshot ?? Uri.parse('https://catalog.shosai.dev/current/'),
       _clock = clock ?? DateTime.now;

  final String directory;
  final String userAgent;
  final Uri snapshot;
  final DateTime Function() _clock;
  Future<CatalogRefresh>? _refreshing;
  CancellationToken? _refreshCancellation;
  bool _closed = false;

  // POSIX locks are per-process. A second owner here must not acquire and
  // close a descriptor that releases the first owner's lock.
  static final Set<String> _updating = {};

  String get _database => '$directory/catalog.sqlite3';

  /// Coalesces concurrent requests. Cancellation belongs to the application
  /// owner, not an individual query; leaving Search need not abort an update.
  Future<CatalogRefresh> refresh({CancellationToken? cancellation}) {
    _checkOpen();
    if (_refreshing case final running?) return running;
    _refreshCancellation = cancellation ?? CancellationToken();
    return _refreshing = _refresh(_refreshCancellation).whenComplete(() {
      _refreshing = null;
      _refreshCancellation = null;
    });
  }

  /// Cancels and drains an update before the application owner exits. Local
  /// queries already started finish on their own read-only connections.
  Future<void> close() async {
    _closed = true;
    _refreshCancellation?.cancel();
    try {
      await _refreshing;
    } on Object {
      // The caller of refresh still receives its error.
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('The catalog is closed');
  }

  Future<CatalogRefresh> _refresh(CancellationToken? cancellation) async {
    cancellation.throwIfCancelled();
    await Directory(directory).create(recursive: true);
    final root = await Directory(directory).resolveSymbolicLinks();
    if (!_updating.add(root)) {
      throw StateError('The catalog is already updating');
    }
    try {
      final lock = await File('$root/refresh.lock').open(mode: FileMode.append);
      try {
        // Another application instance may use this support directory. Refuse a
        // competing refresh rather than deleting its staging files or blocking
        // application shutdown waiting for its network request.
        await lock.lock(FileLock.exclusive);
        return await _install(cancellation);
      } finally {
        await lock.close();
      }
    } finally {
      _updating.remove(root);
    }
  }

  Future<CatalogRefresh> _install(CancellationToken? cancellation) async {
    cancellation.throwIfCancelled();
    // The exclusive lease proves these belong to interrupted prior runs.
    await for (final entry in Directory(directory).list(followLinks: false)) {
      if (entry is Directory &&
          p.basename(entry.path).startsWith('.staging-')) {
        await entry.delete(recursive: true);
      }
    }
    // Each catalog database version throttles separately, so a catalog an
    // earlier app version installed, which this one cannot read, is replaced
    // at once rather than leaving Search unusable until the next daily attempt.
    final attempt = File('$directory/checked-at-v$catalogDatabaseVersion');
    final now = _clock().toUtc();
    if (await attempt.exists()) {
      final previous = DateTime.parse(await attempt.readAsString());
      if (now.difference(previous) < const Duration(days: 1)) {
        return CatalogRefresh.notDue;
      }
    }
    final pending = File('${attempt.path}.new');
    await pending.writeAsString(now.toIso8601String(), flush: true);
    await pending.rename(attempt.path);
    final stage = await Directory(directory).createTemp('.staging-');
    final database = _database;
    final root = snapshot.toString();
    final agent = userAgent;
    final staging = stage.path;
    try {
      final changed = await runCancellable(
        () => _download(root, agent, database, staging),
        cancellation: cancellation,
      );
      cancellation.throwIfCancelled();
      if (!changed) return CatalogRefresh.unchanged;
      // The worker has closed SQLite after integrity/index validation. Rename
      // on the same filesystem is the sole publication point. Readers already
      // holding the old inode finish against it; later readers see the new one.
      await File('$staging/catalog.sqlite3').rename(database);
      return CatalogRefresh.installed;
    } finally {
      await stage.delete(recursive: true);
    }
  }

  Future<bool> get isInstalled async => File(_database).exists();

  /// Title/author substring search. Empty queries browse locally; filters and
  /// paging never contact a source. Query syntax is literal, not FTS syntax.
  Future<List<CatalogBook>> search({
    String query = '',
    String? category,
    String? language,
    String? source,
    String? author,
    int limit = 30,
    int offset = 0,
    CancellationToken? cancellation,
  }) {
    _checkOpen();
    if (limit < 1 || limit > 100 || offset < 0) {
      throw ArgumentError('Invalid catalog page');
    }
    final database = _database;
    return runCancellable(
      () => searchCatalog(
        database,
        query,
        category,
        language,
        source,
        author,
        limit,
        offset,
      ),
      cancellation: cancellation,
    );
  }

  Future<List<CatalogCategory>> categories({CancellationToken? cancellation}) {
    _checkOpen();
    final database = _database;
    return runCancellable(
      () => catalogCategories(database),
      cancellation: cancellation,
    );
  }

  Future<Map<String, List<CatalogBook>>> categoryPreviews({
    required List<String> categoryIds,
    CancellationToken? cancellation,
  }) {
    _checkOpen();
    if (categoryIds.isEmpty) return Future.value(const {});
    final database = _database;
    return runCancellable(
      () => catalogCategoryPreviews(database, categoryIds),
      cancellation: cancellation,
    );
  }

  Future<List<CatalogAuthor>> authors({
    String query = '',
    int limit = 30,
    int offset = 0,
    CancellationToken? cancellation,
  }) {
    _checkOpen();
    if (limit < 1 || limit > 100 || offset < 0) {
      throw ArgumentError('Invalid catalog page');
    }
    final database = _database;
    return runCancellable(
      () => catalogAuthors(database, query, limit, offset),
      cancellation: cancellation,
    );
  }

  Future<CatalogFilters> filters({CancellationToken? cancellation}) {
    _checkOpen();
    final database = _database;
    return runCancellable(
      () => catalogFilters(database),
      cancellation: cancellation,
    );
  }

  Future<CatalogBookDetails?> book(
    String id, {
    CancellationToken? cancellation,
  }) {
    _checkOpen();
    final database = _database;
    return runCancellable(
      () => catalogBook(database, id),
      cancellation: cancellation,
    );
  }
}

const _fileLimit = 24 * 1024 * 1024;
const _snapshotLimit = 512 * 1024 * 1024;

Future<bool> _download(
  String root,
  String agent,
  String database,
  String stage,
) async {
  final client = HttpClient()
    ..userAgent = agent
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30);
  final origin = Uri.parse(root);
  try {
    final manifestFile = File('$stage/manifest.json');
    await _fetch(
      client,
      origin.resolve('manifest.json'),
      manifestFile,
      1024 * 1024,
    );
    final text = await manifestFile.readAsString();
    final manifest = CatalogManifest.parse(text);
    var total = 0;
    for (final file in manifest.files.values) {
      total += file.sizeBytes;
      if (file.sizeBytes > _fileLimit || total > _snapshotLimit) {
        throw const FormatException('Catalog exceeds download limits');
      }
    }
    if (catalogMatches(database, manifest)) return false;
    for (final entry in manifest.files.entries) {
      final file = File('$stage/${entry.key}');
      await file.parent.create(recursive: true);
      await _fetch(
        client,
        origin.resolve(entry.key),
        file,
        entry.value.sizeBytes,
      );
    }
    // Every listed file is checked before importing. Thumbnails are not
    // listed here; covers load them when shown.
    importCatalog(stage, text, origin);
    return true;
  } finally {
    client.close(force: true);
  }
}

Future<void> _fetch(HttpClient client, Uri uri, File file, int limit) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 30));
  try {
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > limit) {
      throw const FormatException('Catalog download failed');
    }
    var size = 0;
    final handle = await file.open(mode: FileMode.write);
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        size += chunk.length;
        if (size > limit) throw const FormatException('Catalog file too large');
        await handle.writeFrom(chunk);
      }
      await handle.flush();
    } finally {
      await handle.close();
    }
  } finally {
    request.abort();
  }
}
