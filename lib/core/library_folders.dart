/// Device folder configuration and one-file admission through location grants.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';

abstract interface class LibraryFoldersHost {
  LibraryFolders get folders;
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
  );

  final Preferences _preferences;
  final Library _library;
  final LibraryLocations _locations;
  final Future<String> Function() _newPath;
  final Map<String, int> _generations = {};
  List<FolderGrant> _grants = const [];
  Future<void>? _loading;
  Future<void> _tail = Future.value();
  bool _closed = false;

  Future<T> _serial<T>(Future<T> Function() effect) {
    if (_closed) return Future.error(const CoreException.cancelled());
    final result = _tail.then((_) => effect());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> drain() => _tail;

  Future<void> close() {
    _closed = true;
    return drain();
  }

  Future<void> _load() => _loading ??= () async {
    final raw = await _preferences.get('device.library.folders');
    if (raw == null) return;
    final grants = (jsonDecode(raw) as List)
        .map(
          (value) =>
              FolderGrant.fromJson((value as Map).cast<String, dynamic>()),
        )
        .toList();
    for (var index = 0; index < grants.length; index++) {
      var grant = grants[index];
      try {
        grant = grants[index] = await grant.refreshed();
      } on PlatformException {
        // Keep an offline/revoked configuration so its books and notes remain
        // visible. Access attempts report the failure through location state.
      }
      _generations[grant.id] = await _locations.connect(grant.id, grant.label);
    }
    await _save(grants);
    _grants = List.unmodifiable(grants);
  }();

  Future<List<FolderGrant>> list() => _serial(() async {
    await _load();
    return _grants;
  });

  /// The picker is injected and awaited by the controller. Persist only grants,
  /// never access tokens, passwords, or the book bytes themselves.
  Future<void> add(FolderGrant grant) => _serial(() async {
    await _load();
    // Picking the same SAF tree twice must not produce two independent owners
    // of one Android permission: removing either would revoke the other.
    final existing = _grants
        .where(
          (entry) => entry.kind == grant.kind && entry.grant == grant.grant,
        )
        .firstOrNull;
    if (existing != null) {
      _generations[existing.id] = await _locations.connect(
        existing.id,
        existing.label,
      );
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
  });

  Future<void> discard(FolderGrant grant) {
    // A picker can finish while the application is closing. Cleanup of a
    // never-adopted grant needs no new access to the already-closed store.
    Future<void> releaseUnused() async {
      if (!_grants.any(
        (entry) => entry.kind == grant.kind && entry.grant == grant.grant,
      )) {
        await grant.release();
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
    return 'folder-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> remove(String id) => _serial(() async {
    await _load();
    final grant = _grant(id);
    // Unavailable is durable before attempting platform cleanup. A failed
    // cleanup never deletes a book or makes its annotations inaccessible.
    await _locations.remove(id);
    await _save(_grants.where((entry) => entry.id != id).toList());
    _grants = List.unmodifiable(_grants.where((entry) => entry.id != id));
    _generations.remove(id);
    await grant.release();
  });

  Future<void> _save(List<FolderGrant> grants) => _preferences.set(
    'device.library.folders',
    jsonEncode([for (final grant in grants) grant.toJson()]),
  );

  FolderGrant _grant(String id) => _grants.firstWhere(
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
      final location = await _grant(id).open();
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

  /// Only the selected book is read. Unopened folder entries are metadata,
  /// not fake book identities made from paths or provider IDs.
  Future<Book> importEntry(
    String id,
    LocationEntry entry, {
    CancellationToken? cancellation,
  }) => _serial(() async {
    await _load();
    cancellation.throwIfCancelled();
    final location = await _grant(id).open();
    final generation = _generations[id]!;
    return _stage(
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
        return book;
      },
      name: entry.name,
      cancellation: cancellation,
    );
  });

  /// Reader/search get the bytes from a recorded device locator. A path left
  /// by staging is never an alternate route around a revoked grant.
  Future<T> withBookFile<T>(
    Book book,
    Future<T> Function(String path) read, {
    CancellationToken? cancellation,
  }) => _serial(() async {
    await _load();
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
      final generation = _generations[id];
      if (generation == null) {
        lastFailure = const LocationException(LocationFailure.revoked);
        continue;
      }
      try {
        final location = await _grant(id).open();
        return await _stage(
          _locations.read(
            location,
            generation,
            book.contentHash,
            copy.locator.key,
            cancellation: cancellation,
          ),
          (path) async {
            final fingerprint = await fingerprintFile(
              path,
              cancellation: cancellation,
            );
            if (fingerprint.hash != book.contentHash) {
              throw const LocationException(LocationFailure.missing);
            }
            return read(path);
          },
          name: 'book.${book.format.name}',
          cancellation: cancellation,
        );
      } on LocationException catch (error) {
        await _locations.failed(
          book.contentHash,
          copy.locator,
          generation: generation,
          failure: error.failure,
        );
        lastFailure = error;
      }
    }
    throw lastFailure ?? const LocationException(LocationFailure.revoked);
  });

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
