/// Device source configuration, metadata discovery and lazy content admission.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';

abstract interface class LibraryFoldersHost {
  LibraryFolders get folders;
  Future<FlutterLibraryBook> admitSourceFile(
    LibrarySourceFile file, {
    CancellationToken? cancellation,
  });
}

/// A discovered file is not yet an identified book. Only opening it reads its
/// bytes and associates its content identity with this device-local locator.
final class LibrarySourceFile {
  const LibrarySourceFile(
    this.locationId,
    this.source,
    this.entry, {
    this.failure,
    this.preview,
  });
  final String locationId;
  final String source;
  final LocationEntry entry;
  final LocationFailure? failure;

  /// What the file's own contents say about it, read before it is opened;
  /// null until [LibraryFolders.previewSourceFiles] has read it.
  final SourcePreview? preview;

  BookLocator get locator => (locationId: locationId, key: entry.key);

  /// The file's own title, or its name without the extension.
  String get title =>
      preview?.title ?? entry.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
  String? get author => preview?.author;

  /// Whether a preview may still be read: an EPUB, reachable, not yet read.
  bool get previewable =>
      preview == null &&
      failure == null &&
      entry.name.toLowerCase().endsWith('.epub');

  LibrarySourceFile _withPreview(SourcePreview? preview) => LibrarySourceFile(
    locationId,
    source,
    entry,
    failure: failure,
    preview: preview,
  );
}

/// How many unopened files are previewed at once.
const sourcePreviewConcurrency = 3;

/// Scan activity, not an estimate of a provider's unknown total. Books are
/// unique EPUB/PDF candidates seen in the current source, not admitted content.
final class LibraryDiscoveryProgress {
  const LibraryDiscoveryProgress({
    required this.source,
    required this.sourceIndex,
    required this.sourceCount,
    required this.booksFound,
  });

  final String source;
  final int sourceIndex;
  final int sourceCount;
  final int booksFound;
}

/// Shared by the application's bridges, not owned by a dialog or widget.
/// Mutations and staged admissions are serialized, so removing a grant cannot
/// race a late import into publishing an unassociated, apparently local book.
final class LibraryFolders {
  LibraryFolders(
    this._preferences,
    this._library,
    this._locations,
    this._newPath,
    this._cache, {
    List<ConnectionProvider> providers = const [FolderConnectionProvider()],
    this.folderSources = true,
  }) : _providers = List.unmodifiable(providers);

  /// Whether device folders may be read as book sources. Phones and tablets
  /// read books only from files they were given and from storage accounts
  /// (RFD 12 outcome 6): a folder connection kept from an earlier build is
  /// listed so it can be removed, but is never scanned or offered.
  final bool folderSources;

  bool _scans(LibraryConnection grant) =>
      folderSources || grant.provider != FolderConnectionProvider.providerId;

  List<LibraryConnection> get _scanned =>
      _grants.where(_scans).toList(growable: false);

  final Preferences _preferences;
  final Library _library;
  final LibraryLocations _locations;
  final Future<String> Function() _newPath;
  final BookFileCache _cache;
  final List<ConnectionProvider> _providers;
  final Map<String, int> _generations = {};
  List<LibraryConnection> _grants = const [];
  List<LibrarySourceFile> _catalog = const [];
  Set<String> _scanFailures = const {};
  Set<String> _refreshFailures = const {};

  /// At most one warning per configured connection, never raw provider errors.
  List<String> get scanWarnings => List.unmodifiable([
    for (final grant in _grants)
      if (_scanFailures.contains(grant.id) ||
          _refreshFailures.contains(grant.id))
        grant.label,
  ]);
  bool _discovered = false;
  bool _catalogLoaded = false;
  bool _loaded = false;
  Future<void> _tail = Future.value();
  bool _closed = false;

  /// The previews in flight from each connection, cancelled when it is
  /// removed or pointed at another directory.
  final Map<String, Set<CancellationToken>> _previewCancellations = {};

  void _cancelPreviews(String id) {
    for (final token in _previewCancellations.remove(id) ?? const {}) {
      token.cancel();
    }
  }

  Future<T> _serial<T>(Future<T> Function() effect) {
    if (_closed) return Future.error(const CoreException.cancelled());
    final result = _tail.then((_) => effect());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> drain() => _tail;

  Future<void> close() {
    _closed = true;
    for (final id in _previewCancellations.keys.toList()) {
      _cancelPreviews(id);
    }
    return drain();
  }

  // All callers run inside _serial. Publish successful initialization only;
  // configuration read/write failures must be retryable in this same service.
  Future<void> _load({CancellationToken? cancellation}) async {
    if (_loaded) return;
    final raw = await _preferences.get('device.library.folders');
    if (raw == null) {
      _loaded = true;
      return;
    }
    final grants = (jsonDecode(raw) as List)
        .map(
          (value) => value is Map
              ? FolderConnectionProvider.migrate(value.cast<String, dynamic>())
              : LibraryConnection.fromJson(value as List),
        )
        .toList();
    await _refresh(grants, cancellation: cancellation);
    for (final grant in _grants) {
      _generations[grant.id] = await _locations.connect(grant.id, grant.label);
    }
    _loaded = true;
  }

  Future<void> _refresh(
    List<LibraryConnection> grants, {
    CancellationToken? cancellation,
  }) async {
    final next = <LibraryConnection>[];
    final failures = <String>{};
    for (final grant in grants) {
      cancellation.throwIfCancelled();
      try {
        next.add(await _provider(grant.provider).refresh(grant));
      } catch (error) {
        if (error is CoreException && error.kind == CoreErrorKind.cancelled) {
          rethrow;
        }
        // Isolate provider failures, including unexpected adapter errors, but
        // expose a warning instead of pretending refresh succeeded. The old
        // grant may still work; only an access attempt changes availability.
        next.add(grant);
        failures.add(grant.id);
      }
    }
    cancellation.throwIfCancelled();
    // Persistence is an application failure, not a provider failure. Do not
    // swallow it or publish configuration that was not saved successfully.
    await _save(next);
    _grants = List.unmodifiable(next);
    _refreshFailures = Set.unmodifiable(failures);
  }

  Future<List<LibraryConnection>> list() => _serial(() async {
    await _load();
    return _grants;
  });

  ConnectionProvider _provider(String id) => _providers.firstWhere(
    (provider) => provider.id == id,
    orElse: () => throw const CoreException(
      CoreErrorKind.unsupported,
      'Unknown connection provider.',
    ),
  );

  Future<LibraryConnection?> setup(String provider, String id) {
    if (!folderSources && provider == FolderConnectionProvider.providerId) {
      return Future.error(
        const CoreException(
          CoreErrorKind.unsupported,
          'Folders are not book sources on this device.',
        ),
      );
    }
    return _provider(provider).setup(id);
  }

  bool _sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.provider == second.provider &&
      _provider(first.provider).sameAccess(first, second);

  /// The picker is injected and awaited by the controller. Persist only grants,
  /// never access tokens, passwords, or the book bytes themselves.
  Future<void> add(LibraryConnection grant) => _serial(() async {
    await _load();
    // Picking the same SAF tree twice must not produce two independent owners
    // of one Android permission: removing either would revoke the other.
    final existing = _grants
        .where((entry) => _sameAccess(entry, grant))
        .firstOrNull;
    if (existing != null) {
      _generations[existing.id] = await _locations.connect(
        existing.id,
        existing.label,
      );
      _discovered = false;
      return;
    }
    final next = [..._grants.where((entry) => entry.id != grant.id), grant];
    if (next.length > 32) {
      throw const CoreException.limitExceeded(
        'At most 32 folders may be connected.',
      );
    }
    await _save(next);
    _generations[grant.id] = await _locations.connect(grant.id, grant.label);
    _grants = List.unmodifiable(next);
    _discovered = false;
  });

  Future<void> configure(String id, {String? directory, String? label}) =>
      _serial(() async {
        await _load();
        final grant = _grant(id);
        final next = grant.withDirectory(directory, label);
        await _save([for (final item in _grants) item.id == id ? next : item]);
        _grants = List.unmodifiable([
          for (final item in _grants) item.id == id ? next : item,
        ]);
        _cancelPreviews(id);
        _catalog = List.unmodifiable(
          _catalog.where((file) => file.locationId != id),
        );
        await _locations.clearCatalog(id);
        _discovered = false;
      });

  /// Scan metadata only. A bounded traversal follows provider directory keys,
  /// not file paths, and never reads book bytes. Publish only complete scans:
  /// an interrupted/offline listing must not mark its unseen files missing.
  Future<List<LibrarySourceFile>> discover({
    bool refresh = false,
    CancellationToken? cancellation,
    void Function(LibraryDiscoveryProgress progress)? onProgress,
  }) => _serial(() async {
    cancellation.throwIfCancelled();
    final wasLoaded = _loaded;
    await _load(cancellation: cancellation);
    if (refresh && wasLoaded) {
      await _refresh(_grants, cancellation: cancellation);
    }
    if (!_catalogLoaded) {
      _catalog = [
        for (final file in await _locations.catalog())
          if (_scanned.any((grant) => grant.id == file.locationId))
            LibrarySourceFile(
              file.locationId,
              _grant(file.locationId).label,
              file.entry,
            ),
      ];
      _catalog = await _withPreviews(_catalog);
      _catalogLoaded = true;
    }
    if (_discovered && !refresh) return List.unmodifiable(_catalog);
    final next = <LibrarySourceFile>[];
    final failures = <String>{};
    final scanned = _scanned;
    for (final grant in scanned) {
      cancellation.throwIfCancelled();
      final generation = _generations[grant.id]!;
      final entries = <String, LocationEntry>{};
      void report() => onProgress?.call(
        LibraryDiscoveryProgress(
          source: grant.directoryLabel ?? grant.label,
          sourceIndex: scanned.indexOf(grant) + 1,
          sourceCount: scanned.length,
          booksFound: entries.length,
        ),
      );
      report();
      try {
        final location = await _provider(grant.provider).open(grant);
        var count = 0;
        await for (final page in _discoveryPages(
          location,
          grant.directory,
          cancellation,
        )) {
          cancellation.throwIfCancelled();
          for (final item in page) {
            final entry = item.entry;
            if (++count > maxDiscoveryEntries ||
                item.depth < 0 ||
                item.depth > 32) {
              throw const CoreException.limitExceeded(
                'The source contains too many entries.',
              );
            }
            if (!entry.isDirectory &&
                BookFormat.fromExtension(entry.name.split('.').last) != null) {
              entries[entry.key] = entry;
              if (entries.length > maxDiscoveredBooks) {
                throw const CoreException.limitExceeded(
                  'The source contains too many books.',
                );
              }
            }
          }
          report();
        }
        cancellation.throwIfCancelled();
        final known = await _locations.scan(
          grant.id,
          generation,
          entries.values.toList(),
        );
        next.addAll([
          for (final entry in entries.values)
            if (!known.contains(entry.key))
              LibrarySourceFile(grant.id, grant.label, entry),
        ]);
      } on LocationException catch (error) {
        failures.add(grant.id);
        await _locations.unavailable(grant.id, generation, error.failure);
        next.addAll([
          for (final file in _catalog)
            if (file.locationId == grant.id)
              LibrarySourceFile(
                file.locationId,
                file.source,
                file.entry,
                failure: error.failure,
              ),
        ]);
      } on CoreException catch (error) {
        if (error.kind == CoreErrorKind.cancelled) rethrow;
        failures.add(grant.id);
        // An invalid or over-limit source must not hide other connections or
        // local books, nor reconcile unseen files as missing.
        next.addAll(_catalog.where((file) => file.locationId == grant.id));
      }
    }
    cancellation.throwIfCancelled();
    _catalog = List.unmodifiable(await _withPreviews(next));
    _scanFailures = Set.unmodifiable(failures);
    _discovered = true;
    return _catalog;
  });

  /// [files] with the previews stored for them.
  Future<List<LibrarySourceFile>> _withPreviews(
    List<LibrarySourceFile> files,
  ) async {
    final previews = await _locations.previews();
    return [
      for (final file in files) file._withPreview(previews[file.locator]),
    ];
  }

  /// The preview cover of the unopened file at [locator], or null.
  Future<Uint8List?> sourceCover(BookLocator locator) =>
      _locations.previewCover(locator);

  /// Read the title, author and cover of each [LibrarySourceFile.previewable]
  /// file among [files] through its connection's byte ranges, without
  /// downloading it, [sourcePreviewConcurrency] at a time.
  ///
  /// Each stored preview is reported to [onPreviewed] as the file carrying
  /// it. This runs beside the serialized mutations, never queued behind or
  /// ahead of them: opening a book or scanning does not wait for previews.
  /// What keeps a preview from outliving its grant or its bytes is the store,
  /// which refuses one from an older connection generation or for a file no
  /// longer listed as it was read. Removing or redirecting a connection
  /// cancels its previews; [cancellation] stops the whole pass. A file that
  /// cannot be previewed (not a readable EPUB, over a limit) is recorded as
  /// read, so it is not fetched again while unchanged; one that cannot be
  /// reached now is left to the next pass.
  Future<void> previewSourceFiles(
    List<LibrarySourceFile> files, {
    required void Function(LibrarySourceFile file) onPreviewed,
    CancellationToken? cancellation,
    int concurrency = sourcePreviewConcurrency,
  }) async {
    final pending = files.where((file) => file.previewable).toList();
    final locations = <String, Future<LibraryLocation>>{};
    // One token per connection in this pass, stopped by the pass or by the
    // connection's removal.
    final tokens = <String, CancellationToken>{};
    CancellationToken tokenFor(String id) => tokens.putIfAbsent(id, () {
      final token = CancellationToken();
      unawaited(cancellation?.whenCancelled.then((_) => token.cancel()));
      _previewCancellations.putIfAbsent(id, () => {}).add(token);
      return token;
    });

    Future<void> preview(LibrarySourceFile file) async {
      final id = file.locationId;
      final generation = _generations[id];
      final grant = _grants.where((grant) => grant.id == id).firstOrNull;
      if (generation == null || grant == null || !_scans(grant)) return;
      final token = tokenFor(id);
      if (token.isCancelled) return;
      BookMetadata metadata;
      try {
        final location = await locations.putIfAbsent(
          id,
          () => _provider(grant.provider).open(grant),
        );
        metadata = await previewEpub(location, file.entry, cancellation: token);
      } on CoreException catch (error) {
        if (error.kind == CoreErrorKind.cancelled || token.isCancelled) return;
        metadata = const BookMetadata();
      } catch (_) {
        // Unreachable now (offline, revoked) or failing in its adapter: left
        // for a later pass, and the other files still get theirs.
        return;
      }
      if (token.isCancelled) return;
      final saved = await _locations.savePreview(
        id,
        generation,
        file.entry,
        metadata,
      );
      if (saved == null) return;
      final previewed = file._withPreview(saved);
      _catalog = List.unmodifiable([
        for (final known in _catalog)
          known.locator == file.locator &&
                  known.entry.size == file.entry.size &&
                  known.entry.revision == file.entry.revision
              ? previewed
              : known,
      ]);
      if (!token.isCancelled) onPreviewed(previewed);
    }

    Future<void> worker() async {
      while (pending.isNotEmpty &&
          !_closed &&
          !(cancellation?.isCancelled ?? false)) {
        await preview(pending.removeAt(0));
      }
    }

    try {
      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    } finally {
      for (final MapEntry(key: id, value: token) in tokens.entries) {
        _previewCancellations[id]?.remove(token);
        if (_previewCancellations[id]?.isEmpty ?? false) {
          _previewCancellations.remove(id);
        }
      }
    }
  }

  /// Optimized providers own server pagination; others retain the bounded
  /// directory-key traversal, including empty pages with a continuation.
  Stream<List<LocationTreeEntry>> _discoveryPages(
    LibraryLocation location,
    String? root,
    CancellationToken? cancellation,
  ) async* {
    if (location is RecursiveLibraryLocation) {
      yield* (location as RecursiveLibraryLocation).listRecursive(
        directory: root,
        cancellation: cancellation,
      );
      return;
    }
    final pending = <({String? key, int depth})>[(key: root, depth: 0)];
    final visited = <String?>{};
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      if (!visited.add(directory.key)) continue;
      String? cursor;
      final cursors = <String?>{};
      do {
        cancellation.throwIfCancelled();
        if (!cursors.add(cursor)) {
          throw const CoreException.malformed('Repeated source page.');
        }
        if (cursors.length > maxDiscoveryEntries) {
          throw const CoreException.limitExceeded('Too many source pages.');
        }
        final page = await location.list(
          directory: directory.key,
          cursor: cursor,
          cancellation: cancellation,
        );
        yield [
          for (final entry in page.entries)
            (entry: entry, depth: directory.depth),
        ];
        for (final entry in page.entries.where((e) => e.isDirectory)) {
          pending.add((key: entry.key, depth: directory.depth + 1));
        }
        cursor = page.nextCursor;
      } while (cursor != null);
    }
  }

  Future<void> discard(LibraryConnection grant) {
    // A picker can finish while the application is closing. Cleanup of a
    // never-adopted grant needs no new access to the already-closed store.
    Future<void> releaseUnused() async {
      if (!_grants.any((entry) => _sameAccess(entry, grant))) {
        await _provider(grant.provider).release(grant);
      }
    }

    return _closed
        ? drain().then((_) => releaseUnused())
        : _serial(() async {
            await _load();
            await releaseUnused();
          });
  }

  static String newId() {
    final random = Random.secure();
    return 'connection-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> remove(String id) => _serial(() async {
    await _load();
    final grant = _grant(id);
    _cancelPreviews(id);
    // Unavailable is durable before attempting platform cleanup. A failed
    // cleanup never deletes a book or makes its annotations inaccessible.
    await _locations.remove(id);
    await _locations.clearCatalog(id);
    await _cache.discardLocation(id);
    await _save(_grants.where((entry) => entry.id != id).toList());
    _grants = List.unmodifiable(_grants.where((entry) => entry.id != id));
    _generations.remove(id);
    _discovered = false;
    await _provider(grant.provider).release(grant);
  });

  // Retain the historical key and replace its value atomically. Adding a row
  // would lock out a valid legacy store at the preference row/total-byte limit.
  Future<void> _save(List<LibraryConnection> grants) => _preferences.set(
    'device.library.folders',
    jsonEncode([for (final grant in grants) grant.toJson()]),
  );

  LibraryConnection _grant(String id) => _grants.firstWhere(
    (entry) => entry.id == id,
    orElse: () => throw const LocationException(LocationFailure.revoked),
  );

  Future<LocationPage> browse(
    String id, {
    String? directory,
    String? cursor,
    CancellationToken? cancellation,
  }) => _serial(() async {
    await _load();
    cancellation.throwIfCancelled();
    final generation = _generations[id];
    if (generation == null) {
      throw const LocationException(LocationFailure.revoked);
    }
    try {
      final grant = _grant(id);
      final location = await _provider(grant.provider).open(grant);
      return await location.list(
        directory: directory,
        cursor: cursor,
        cancellation: cancellation,
      );
    } on LocationException catch (error) {
      await _locations.unavailable(id, generation, error.failure);
      rethrow;
    }
  });

  /// Browse an authorized but unadopted cloud connection for explicit source
  /// confirmation. No saved grant, location generation or catalog is created.
  Future<LocationPage> browsePending(
    LibraryConnection grant, {
    String? directory,
    String? cursor,
    CancellationToken? cancellation,
  }) => _serial(() async {
    cancellation.throwIfCancelled();
    final location = await _provider(grant.provider).open(grant);
    cancellation.throwIfCancelled();
    return location.list(
      directory: directory,
      cursor: cursor,
      cancellation: cancellation,
    );
  });

  /// Only the selected book is read. Unopened folder entries are metadata,
  /// not fake book identities made from paths or provider IDs.
  Future<Book> importEntry(
    String id,
    LocationEntry entry, {
    CancellationToken? cancellation,
  }) => _serial(() async {
    await _load();
    cancellation.throwIfCancelled();
    final grant = _grant(id);
    final location = await _provider(grant.provider).open(grant);
    final generation = _generations[id]!;
    final book = await _stage(
      location.read(entry.key, cancellation: cancellation),
      (path) async {
        final item = await _library.importFile(
          path,
          managed: false,
          cancellation: cancellation,
        );
        final book = item.book;
        if (book == null) {
          throw CoreException.malformed(
            item.error ?? 'The book could not be imported.',
          );
        }
        // An explicit local import already owns this content. Adding the
        // same book from a folder is a duplicate, not permission to replace
        // its working local source with a dependency on that folder grant.
        await _locations.admit(id, generation, entry, book.contentHash);
        if (book.path != canonicalBookPath(path) &&
            (await _locations.copies(book.contentHash)).isEmpty &&
            await File(book.path).exists()) {
          return book;
        }
        // Import's commit is the cancellation boundary. Finish its association
        // even if cancellation arrives immediately after that commit.
        await _locations.locate(book.contentHash, (
          locationId: id,
          key: entry.key,
        ), generation: generation);
        await _cache.withFile(
          book,
          () => File(path).openRead(),
          (_) async {},
          cancellation: cancellation,
        );
        return (await _library.get(book.id))!;
      },
      name: entry.name,
      cancellation: cancellation,
    );
    _catalog = List.unmodifiable(
      _catalog.where(
        (file) => file.locationId != id || file.entry.key != entry.key,
      ),
    );
    return book;
  });

  /// Reader/search get the bytes from a recorded device locator. A path left
  /// by staging is never an alternate route around a revoked grant.
  Future<T> withBookFile<T>(
    Book book,
    Future<T> Function(String path) read, {
    bool keep = false,
    CancellationToken? cancellation,
  }) => _serial(() async {
    final copies = await _locations.copies(book.contentHash);
    if (copies.isEmpty) {
      if (book.locationFailure != null) {
        throw const LocationException(LocationFailure.revoked);
      }
      return read(book.path); // legacy, explicitly imported local files
    }
    LocationException? lastFailure;
    for (final copy in copies) {
      cancellation.throwIfCancelled();
      final id = copy.locator.locationId;
      var generation = _generations[id];
      try {
        return await _cache.withFile(
          book,
          () async* {
            // A verified cached copy does not depend on provider refresh or
            // readable connection preferences. Initialize only on a cache miss.
            await _load();
            final currentGeneration = generation = _generations[id];
            if (currentGeneration == null) {
              throw const LocationException(LocationFailure.revoked);
            }
            final grant = _grant(id);
            final location = await _provider(grant.provider).open(grant);
            yield* _locations.read(
              location,
              currentGeneration,
              book.contentHash,
              copy.locator.key,
              cancellation: cancellation,
            );
          },
          read,
          keep: keep,
          cancellation: cancellation,
        );
      } on LocationException catch (error) {
        final failedGeneration = generation;
        if (failedGeneration != null) {
          await _locations.failed(
            book.contentHash,
            copy.locator,
            generation: failedGeneration,
            failure: error.failure,
          );
        }
        lastFailure = error;
      }
    }
    throw lastFailure ?? const LocationException(LocationFailure.revoked);
  });

  Future<void> setKept(
    int bookId,
    bool keep, {
    CancellationToken? cancellation,
  }) async {
    final book = await _library.get(bookId);
    if (book == null || !book.located) {
      throw const CoreException.notFound('The book has no library location.');
    }
    if (keep) {
      await withBookFile(
        book,
        (_) async {},
        keep: true,
        cancellation: cancellation,
      );
    } else {
      await _serial(() async {
        await _load();
        cancellation.throwIfCancelled();
        await _cache.release(book);
        final copies = await _locations.copies(book.contentHash);
        if (copies.every(
          (copy) => !_generations.containsKey(copy.locator.locationId),
        )) {
          await _cache.discardUnkept(book.contentHash, book.format);
        }
      });
    }
  }

  Future<T> _stage<T>(
    Stream<List<int>> input,
    Future<T> Function(String path) consume, {
    required String name,
    CancellationToken? cancellation,
  }) async {
    final extension = name.split('.').last.toLowerCase();
    if (BookFormat.fromExtension(extension) == null) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'Choose an EPUB or PDF.',
      );
    }
    if (name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        utf8.encode(name).length > 255) {
      throw const CoreException.invalidRequest('Invalid book name.');
    }
    final staging = Directory(await _newPath());
    cancellation.throwIfCancelled();
    await staging.create();
    final path = '${staging.path}/$name';
    final file = File(path);
    try {
      final output = await file.open(mode: FileMode.writeOnly);
      try {
        var length = 0;
        await for (final bytes in input) {
          cancellation.throwIfCancelled();
          length += bytes.length;
          if (length > maxBookInputBytes) {
            throw const CoreException.limitExceeded(
              'The book exceeds the file limit.',
            );
          }
          await output.writeFrom(bytes);
        }
      } finally {
        await output.close();
      }
      cancellation.throwIfCancelled();
      return await consume(path);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
