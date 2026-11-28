/// Device source configuration, metadata discovery and lazy content admission.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';

abstract interface class LibraryFoldersHost {
  LibraryFolders get folders;
  Future<FlutterLibraryBook> admitSourceFile(
    LibrarySourceFile file, {
    CancellationToken? cancellation,
  });
}

/// Admission cannot reuse an earlier decision when its evidence changed.
enum EditionAdmissionConflict implements Exception {
  sourceChanged,
  addedSeparately,
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
  BookProtection get protection => preview?.protection ?? BookProtection.none;

  BookFormat? get format =>
      BookFormat.fromExtension(entry.name.split('.').last.toLowerCase());

  /// Whether a preview may still be read: a book, reachable, not yet read.
  bool get previewable => preview == null && failure == null && format != null;

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
    Map<BookFormat, BookPreviewer> previewers = const {
      BookFormat.epub: EpubPreviewer(),
    },
    this.folderSources = true,
  }) : _providers = List.unmodifiable(providers),
       _previewers = Map.unmodifiable(previewers);

  /// How an unopened file of each format is previewed; a format without
  /// one keeps its generated cover until it is opened.
  final Map<BookFormat, BookPreviewer> _previewers;

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
  Map<String, LocationFailure?> _scanFailures = const {};
  Map<String, LocationFailure?> _refreshFailures = const {};

  /// At most one warning per configured connection, never raw provider errors.
  List<({String source, LocationFailure? failure})> get scanWarnings =>
      List.unmodifiable([
        for (final grant in _grants)
          if (_scanFailures.containsKey(grant.id) ||
              _refreshFailures.containsKey(grant.id))
            (
              source: grant.label,
              failure: _scanFailures.containsKey(grant.id)
                  ? _scanFailures[grant.id]
                  : _refreshFailures[grant.id],
            ),
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
    final failures = <String, LocationFailure?>{};
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
        failures[grant.id] = error is LocationException ? error.failure : null;
      }
    }
    cancellation.throwIfCancelled();
    // Persistence is an application failure, not a provider failure. Do not
    // swallow it or publish configuration that was not saved successfully.
    await _save(next);
    _grants = List.unmodifiable(next);
    _refreshFailures = Map.unmodifiable(failures);
  }

  Future<List<LibraryConnection>> list() => _serial(() async {
    await _load();
    return _grants;
  });

  /// The first connected location is the default until the reader chooses.
  /// An explicit private-library choice is distinct from having no preference.
  Future<
    ({
      List<({LibraryConnection connection, int generation})> locations,
      String? selected,
    })
  >
  saveOptions() => _serial(() async {
    await _load();
    final locations = _scanned;
    return (
      locations:
          List<({LibraryConnection connection, int generation})>.unmodifiable([
            for (final connection in locations)
              (
                connection: connection,
                generation: _generations[connection.id]!,
              ),
          ]),
      selected: await _saveLocation(),
    );
  });

  Future<String?> _saveLocation() async {
    final saved = await _preferences.get('device.library.save-location');
    final locations = _scanned;
    return saved == 'private'
        ? null
        : locations.where((g) => g.id == saved).firstOrNull?.id ??
              locations.firstOrNull?.id;
  }

  Future<void> selectSaveLocation(String? id) => _serial(() async {
    await _load();
    if (id != null && !_scanned.any((g) => g.id == id)) {
      throw const LocationException(LocationFailure.revoked);
    }
    await _preferences.set('device.library.save-location', id ?? 'private');
  });

  /// The downloaded bytes are verified before any external publication. A
  /// duplicate is an idempotent Add, not an instruction to open the reader.
  /// Grant changes and other admissions cannot interleave with publication.
  Future<({Book book, bool existing})> saveDownloadedBook(
    String path, {
    required String? locationId,
    required String source,
    required String title,
    required String? author,
    required BookFormat format,
    required ({int generation, String? directory})? destination,
    CancellationToken? cancellation,
  }) => _serial(() async {
    await _load(cancellation: cancellation);
    cancellation.throwIfCancelled();
    if (locationId != null &&
        (destination == null ||
            _generations[locationId] != destination.generation ||
            _grant(locationId).directory != destination.directory)) {
      throw const CatalogDestinationChanged();
    }
    return _saveNewBook(
      path,
      locationId: locationId,
      source: source,
      title: title,
      author: author,
      format: format,
      cancellation: cancellation,
    );
  });

  /// Books handed to Shōsai, by Choose files on a phone or tablet or by
  /// another app opening them in Shōsai, go where catalog downloads go: the
  /// _Save new books to_ location as it is now. There each keeps its own
  /// [names] entry (by default its path's file name) at the top of the
  /// location, cleaned and numbered like every name Shōsai writes (RFD 12,
  /// Layout of the save location). The private library still names its
  /// copies by content hash. Each file is reported on its own, continuing
  /// past failures, as [Library.importPaths] does.
  Future<ImportReport> saveHandedBooks(
    List<String> paths, {
    List<String>? names,
    CancellationToken? cancellation,
  }) async {
    if (paths.length > maxSelectedImportPaths ||
        (names != null && names.length != paths.length)) {
      throw const CoreException.invalidRequest('Invalid handed books.');
    }
    var imported = 0, failed = 0, cancelled = false;
    final items = <ImportItem>[];
    for (final (index, path) in paths.indexed) {
      if (cancellation?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      ImportItem item;
      try {
        item = await _serial(() async {
          await _load(cancellation: cancellation);
          checkBookPath(path);
          final format = await detectBookFormat(path);
          if (format == null) {
            throw const CoreException(
              CoreErrorKind.unsupported,
              'Unsupported format.',
            );
          }
          final name =
              names?[index] ?? path.substring(path.lastIndexOf('/') + 1);
          final dot = name.lastIndexOf('.');
          final title = dot < 0 ? name : name.substring(0, dot);
          // The record keeps the path it was saved from. A handed path can be
          // reused for another book (iOS Inbox/Notes.pdf), so save from a
          // fresh copy that is deleted afterwards, as catalog downloads do.
          final staging = await Directory(await _newPath()).create();
          try {
            final staged =
                '${staging.path}/${bookFileName(title, null, format.name)}';
            await copyAndFingerprint(path, staged, cancellation: cancellation);
            final saved = await _saveNewBook(
              staged,
              locationId: await _saveLocation(),
              source: null,
              title: title,
              author: null,
              format: format,
              cancellation: cancellation,
            );
            return ImportItem.imported(
              path,
              saved.book,
              duplicate: saved.existing,
            );
          } finally {
            await staging.delete(recursive: true);
          }
        });
      } on CoreException catch (error) {
        if (error.kind == CoreErrorKind.cancelled) {
          cancelled = true;
          break;
        }
        item = ImportItem.failed(path, error.message);
      } on LocationException catch (error) {
        item = ImportItem.failed(path, 'Location ${error.failure.name}.');
      } on FileSystemException catch (error) {
        item = ImportItem.failed(
          path,
          'Could not import: ${error.osError?.message ?? error.message}',
        );
      }
      item.book == null ? failed++ : imported++;
      if (items.length < maxImportReportItems) items.add(item);
    }
    return ImportReport(
      imported: imported,
      failed: failed,
      cancelled: cancelled,
      items: List.unmodifiable(items),
    );
  }

  /// Save [path] to [locationId], or to the private library when it is null.
  /// A catalog download goes into its [source]'s folder; a null [source]
  /// writes at the top of the location. Runs inside [_serial].
  Future<({Book book, bool existing})> _saveNewBook(
    String path, {
    required String? locationId,
    required String? source,
    required String title,
    required String? author,
    required BookFormat format,
    CancellationToken? cancellation,
  }) async {
    final fingerprint = await fingerprintFile(path, cancellation: cancellation);
    final known = await _library.withContent(fingerprint.hash);
    if (known != null) {
      if (known.located) {
        // Reuse a copy only when it still reads with these bytes; a missing
        // one is saved again below and joins the same book by its hash.
        try {
          await _withBookFile(known, (_) async {}, cancellation: cancellation);
          return (book: known, existing: true);
        } on LocationException {
          cancellation.throwIfCancelled();
        }
      } else if (await fileHasFingerprint(known.path, fingerprint)) {
        return (book: known, existing: true);
      } else if (known.managed) {
        // A damaged private copy is repaired where it is, never moved.
        locationId = null;
      }
    }
    if (locationId == null) {
      // A located book here failed to read just now, so its private copy
      // becomes the one it opens from, in the same commit. Its source
      // admissions stay: a scan recognizes those files, and Private stays
      // the copy the book reads.
      final item = await _library.importFile(
        path,
        managed: true,
        replaceCopies: known != null && known.located,
        cancellation: cancellation,
      );
      if (item.book == null) {
        throw CoreException.malformed(
          item.error ?? 'The book could not be added.',
        );
      }
      return (book: item.book!, existing: item.duplicate);
    }
    final grant = _grant(locationId);
    if (!_scans(grant)) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'Folders are not book sources on this device.',
      );
    }
    final adapter = await _provider(grant.provider).open(grant);
    if (adapter is! LibrarySaveLocation) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'This location cannot safely save new books.',
      );
    }
    final metadata = await _library.inspectFile(path, format, cancellation);
    if (!await fingerprint.unchangedSince(path)) {
      throw const CoreException.conflict('The downloaded file changed.');
    }
    final directory = source == null
        ? grant.directory
        : (await _saveFolder(
            adapter,
            grant.directory,
            source,
            cancellation,
          )).key;
    final plain = bookFileName(title, author, format.name);
    final extension = '.${format.name}';
    final stem = bookNameKey(
      plain.substring(0, plain.length - extension.length),
    );
    // A failed local admission may have already published a numbered name.
    // Adopt identical bytes only in this generated series, not arbitrary files.
    final names = RegExp(
      '^${RegExp.escape(stem)}'
      r'(?: \((?:[2-9]|[1-9][0-9]+)\))?'
      '${RegExp.escape(extension)}'
      r'$',
    );
    List<LocationEntry> matches = [];
    for (var attempt = 0; attempt < 8; attempt++) {
      final entries = await _saveEntries(adapter, directory, cancellation);
      matches = [];
      for (final entry in entries.where(
        (e) =>
            e.readable && !e.isDirectory && names.hasMatch(bookNameKey(e.name)),
      )) {
        final current = await adapter.stat(
          entry.key,
          cancellation: cancellation,
        );
        if (current.isDirectory || current.size != fingerprint.size) continue;
        bool same = current.sha256 == fingerprint.hash;
        if (!same && current.dropboxContentHash != null) {
          final parts = <int>[];
          final input = await File(path).open();
          try {
            while (true) {
              cancellation.throwIfCancelled();
              final block = await input.read(4 * 1024 * 1024);
              if (block.isEmpty) break;
              parts.addAll(sha256.convert(block).bytes);
            }
          } finally {
            await input.close();
          }
          same = sha256.convert(parts).toString() == current.dropboxContentHash;
        }
        if (!same && grant.provider == FolderConnectionProvider.providerId) {
          final digest = await sha256
              .bind(
                adapter.read(
                  current.key,
                  end: fingerprint.size + 1,
                  cancellation: cancellation,
                ),
              )
              .first;
          same = digest.toString() == fingerprint.hash;
        }
        if (!same) continue;
        final after = await adapter.stat(
          current.key,
          cancellation: cancellation,
        );
        if (after.size == current.size && after.revision == current.revision) {
          matches.add(after);
        }
      }
      if (matches.isNotEmpty) break;
      final taken = entries.map((e) => bookNameKey(e.name)).toSet();
      var number = 1;
      while (taken.contains(
        bookNameKey(bookFileName(title, author, format.name, number: number)),
      )) {
        if (++number > maxDiscoveryEntries + 1) {
          throw const CoreException.limitExceeded(
            'Too many destination names.',
          );
        }
      }
      cancellation.throwIfCancelled();
      try {
        matches = [
          await adapter.createFile(
            bookFileName(title, author, format.name, number: number),
            File(path).openRead(),
            directory: directory,
            cancellation: cancellation,
          ),
        ];
        break;
      } on CoreException catch (error) {
        if (error.kind != CoreErrorKind.conflict) rethrow;
        // Re-list and recheck identical bytes: a race must not blindly number
        // a file another device just saved with the same content.
      }
    }
    if (matches.isEmpty) {
      throw const CoreException.conflict('The destination keeps changing.');
    }
    // Publication/adoption is the commit boundary. Do not cancel between
    // admitting these bytes and associating their durable provider locations.
    final item = await _locations.importPublished(
      path,
      format,
      fingerprint,
      metadata,
      locationId,
      _generations[locationId]!,
      matches,
    );
    final book = item.book;
    await _cache.withFile(book, () => File(path).openRead(), (_) async {});
    _catalog = List.unmodifiable(
      _catalog.where(
        (file) =>
            file.locationId != locationId ||
            !matches.any((e) => e.key == file.entry.key),
      ),
    );
    return (book: (await _library.get(book.id))!, existing: item.existing);
  }

  Future<List<LocationEntry>> _saveEntries(
    LibraryLocation location,
    String? directory,
    CancellationToken? cancellation,
  ) async {
    final entries = <LocationEntry>[];
    final cursors = <String?>{};
    String? cursor;
    do {
      cancellation.throwIfCancelled();
      if (!cursors.add(cursor)) {
        throw const CoreException.malformed('Repeated destination page.');
      }
      final page = location is LibrarySaveInventory
          ? await (location as LibrarySaveInventory).listForSave(
              directory: directory,
              cursor: cursor,
              limit: 500,
              cancellation: cancellation,
            )
          : await location.list(
              directory: directory,
              cursor: cursor,
              limit: 500,
              cancellation: cancellation,
            );
      entries.addAll(page.entries);
      if (entries.length > maxDiscoveryEntries) {
        throw const CoreException.limitExceeded(
          'Too many destination entries.',
        );
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    return entries;
  }

  Future<LocationEntry> _saveFolder(
    LibrarySaveLocation location,
    String? parent,
    String source,
    CancellationToken? cancellation,
  ) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final entries = await _saveEntries(location, parent, cancellation);
      for (var number = 1; number <= maxDiscoveryEntries + 1; number++) {
        final name = number == 1 ? source : '$source ($number)';
        final matches = entries
            .where((e) => bookNameKey(e.name) == bookNameKey(name))
            .toList();
        final folders =
            matches.where((e) => e.readable && e.isDirectory).toList()
              ..sort((a, b) {
                final left = utf8.encode(a.name), right = utf8.encode(b.name);
                for (var i = 0; i < min(left.length, right.length); i++) {
                  if (left[i] != right[i]) return left[i].compareTo(right[i]);
                }
                final order = left.length.compareTo(right.length);
                if (order != 0) return order;
                final created = (a.createdAt ?? DateTime.utc(1970)).compareTo(
                  b.createdAt ?? DateTime.utc(1970),
                );
                return created != 0 ? created : a.key.compareTo(b.key);
              });
        if (folders.isNotEmpty) return folders.first;
        if (matches.isNotEmpty) continue;
        try {
          return await location.createDirectory(
            name,
            directory: parent,
            cancellation: cancellation,
          );
        } on CoreException catch (error) {
          if (error.kind != CoreErrorKind.conflict) rethrow;
          break; // A concurrent creator won; prefer its folder on re-list.
        }
      }
    }
    throw const CoreException.conflict('The source folder keeps changing.');
  }

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

  /// Replace only authorization, never the source identity, directory or its
  /// catalog/cache. The caller owns the unused grant until persistence adopts
  /// it, and must discard it if validation, cancellation or saving fails.
  Future<void> reconnect(
    LibraryConnection previous,
    LibraryConnection authorization, {
    CancellationToken? cancellation,
  }) => _serial(() async {
    cancellation.throwIfCancelled();
    await _load(cancellation: cancellation);
    final current = _grant(previous.id);
    if (!_sameAccess(current, previous) ||
        current.directory != previous.directory ||
        authorization.id != current.id ||
        authorization.provider != current.provider) {
      throw const CoreException.cancelled();
    }
    final next = LibraryConnection(
      current.id,
      current.label,
      current.provider,
      authorization.configuration,
      directory: current.directory,
      directoryLabel: current.directoryLabel,
    );
    final provider = _provider(current.provider);
    final location = await provider.open(next);
    if (next.directory == null) {
      // Legacy root connections have no account identifier. Require ownership
      // of a known file when there is one, rather than adopting another
      // account's root and reconciling the old books against unrelated files.
      final keys = await _locations.connectionKeys(current.id);
      var matched = keys.isEmpty;
      for (final key in keys) {
        try {
          await location.stat(key, cancellation: cancellation);
          matched = true;
          break;
        } on LocationException catch (error) {
          if (error.failure == LocationFailure.offline) rethrow;
        }
      }
      if (!matched) throw const LocationException(LocationFailure.revoked);
    }
    await location.list(
      directory: next.directory,
      limit: 1,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();
    final grants = [
      for (final grant in _grants) grant.id == next.id ? next : grant,
    ];
    // Adopt configuration and generation in one transaction. A close after
    // this commit must not discard the now-durable credential.
    final generation = await _locations.connect(
      current.id,
      current.label,
      preferences: {
        'device.library.folders': jsonEncode([
          for (final grant in grants) grant.toJson(),
        ]),
      },
    );
    _grants = List.unmodifiable(grants);
    _generations[current.id] = generation;
    _cancelPreviews(current.id);
    _discovered = false;
    _refreshFailures = Map.unmodifiable(
      {..._refreshFailures}..remove(current.id),
    );
    try {
      await provider.release(current);
    } catch (_) {
      // The replacement is already durable. Failure to delete the obsolete
      // local credential must not undo it or report a failed authorization.
    }
  });

  /// Explicitly verify failed book links online, bypassing cache reads without
  /// evicting or replacing any payload. No discovery or admission is performed.
  Future<({int verified, int unavailable})> revalidate(
    String id, {
    CancellationToken? cancellation,
  }) => _serial(() async {
    cancellation.throwIfCancelled();
    await _load(cancellation: cancellation);
    final grant = _grant(id);
    if (!_scans(grant)) {
      throw const CoreException.invalidRequest('This source cannot be read.');
    }
    final location = await _provider(grant.provider).open(grant);
    cancellation.throwIfCancelled();
    return _locations.revalidate(
      location,
      _generations[id]!,
      cancellation: cancellation,
    );
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

  /// Scan metadata. A bounded traversal follows provider directory keys, not
  /// file paths. It reads the bytes of only a file whose size matches
  /// content the reader removed, to keep that content hidden wherever it
  /// moves (see [LibraryLocations.hideRemovedCopies]). Publish only complete scans:
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
    if (_discovered && !refresh) {
      // A removal since the last scan can hide a file listed then.
      _catalog = List.unmodifiable(await _listed(_catalog));
      return _catalog;
    }
    final next = <LibrarySourceFile>[];
    final failures = <String, LocationFailure?>{};
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
          grant.directoryLabel,
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
              entries[entry.key] = entry.withKnownSize();
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
        known.addAll(
          await _locations.hideRemovedCopies(
            location,
            generation,
            cancellation: cancellation,
          ),
        );
        next.addAll([
          for (final entry in entries.values)
            if (!known.contains(entry.key))
              LibrarySourceFile(grant.id, grant.label, entry),
        ]);
      } on LocationException catch (error) {
        failures[grant.id] = error.failure;
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
        failures[grant.id] = null;
        // An invalid or over-limit source must not hide other connections or
        // local books, nor reconcile unseen files as missing.
        next.addAll(_catalog.where((file) => file.locationId == grant.id));
      }
    }
    cancellation.throwIfCancelled();
    _catalog = List.unmodifiable(await _withPreviews(await _listed(next)));
    _scanFailures = Map.unmodifiable(failures);
    _discovered = true;
    return _catalog;
  });

  /// The files among [files] still offered in the stored catalog, at the size
  /// and revision they were listed with: hidden files, and ones that may be
  /// removed content not yet read, are left out.
  Future<List<LibrarySourceFile>> _listed(List<LibrarySourceFile> files) async {
    final offered = {
      for (final file in await _locations.catalog())
        (file.locationId, file.entry.key, file.entry.size, file.entry.revision),
    };
    return [
      for (final file in files)
        if (offered.contains((
          file.locationId,
          file.entry.key,
          file.entry.size,
          file.entry.revision,
        )))
          file,
    ];
  }

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
    final pending = [
      for (final file in files)
        if (file.previewable && _previewers.containsKey(file.format)) file,
    ];
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
        metadata = await _previewers[file.format]!.preview(
          location,
          file.entry,
          cancellation: token,
        );
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
    String? rootName,
  ) async* {
    if (location is RecursiveLibraryLocation) {
      yield* (location as RecursiveLibraryLocation).listRecursive(
        directory: root,
        cancellation: cancellation,
      );
      return;
    }
    final pending = <({String? key, String? name, int depth})>[
      (key: root, name: rootName, depth: 0),
    ];
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
            (
              entry: LocationEntry(
                key: entry.key,
                name: entry.name,
                isDirectory: entry.isDirectory,
                size: entry.size,
                revision: entry.revision,
                folderName: entry.folderName ?? directory.name,
                sha256: entry.sha256,
                dropboxContentHash: entry.dropboxContentHash,
              ),
              depth: directory.depth,
            ),
        ];
        for (final entry in page.entries.where((e) => e.isDirectory)) {
          pending.add((
            key: entry.key,
            name: entry.name,
            depth: directory.depth + 1,
          ));
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
    Future<void> verifySource() async {
      final current = (await location.stat(
        entry.key,
        cancellation: cancellation,
      )).withKnownSize();
      if (current.isDirectory ||
          current.name != entry.name ||
          current.size != entry.size ||
          current.revision != entry.revision ||
          (current.folderName != null &&
              current.folderName != entry.folderName)) {
        throw EditionAdmissionConflict.sourceChanged;
      }
    }

    await verifySource();
    var grouped = true;
    final book = await _stage(
      location.read(entry.key, cancellation: cancellation),
      (path) async {
        // Check again after streaming, before import commits an identity.
        await verifySource();
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
        final local =
            book.path != canonicalBookPath(path) &&
            (await _locations.copies(book.contentHash)).isEmpty &&
            await File(book.path).exists();
        if (!local) {
          // Import's commit is the cancellation boundary. Finish its
          // association even if cancellation arrives after that commit.
          await _locations.locate(book.contentHash, (
            locationId: id,
            key: entry.key,
          ), generation: generation);
          await _cache.withFile(
            book,
            () => File(path).openRead(),
            (_) async {},
          );
        }
        // Resolve any provisional grouping only after ownership is safe.
        // A rejected group or budget must not strand a committed book at
        // the staging path that _stage removes when this callback returns.
        grouped = await _locations.admit(
          id,
          generation,
          entry,
          book.contentHash,
          inheritPreview: entry.revision != null,
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
    if (!grouped) throw EditionAdmissionConflict.addedSeparately;
    return book;
  });

  /// Reader/search get the bytes from a recorded device locator. A path left
  /// by staging is never an alternate route around a revoked grant.
  Future<T> withBookFile<T>(
    Book book,
    Future<T> Function(String path) read, {
    bool keep = false,
    CancellationToken? cancellation,
  }) => _serial(
    () => _withBookFile(book, read, keep: keep, cancellation: cancellation),
  );

  Future<T> _withBookFile<T>(
    Book book,
    Future<T> Function(String path) read, {
    bool keep = false,
    CancellationToken? cancellation,
  }) async {
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
  }

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
