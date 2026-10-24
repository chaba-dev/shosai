/// Ordinary filesystem folders, including folders synced by desktop clients.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../errors.dart';
import 'files.dart';
import 'location.dart';

/// A device-local ordinary folder. Sandboxed Apple/Android providers use their
/// platform grant adapters instead; content URIs are never filesystem paths.
final class FolderLocation implements LibraryLocation {
  FolderLocation._(this.id, this.directory, this._root);

  static Future<FolderLocation> open(String id, String directory) async {
    try {
      final root = await Directory(directory).resolveSymbolicLinks();
      return FolderLocation._(id, p.absolute(directory), root);
    } on FileSystemException catch (error) {
      throw _failure(error);
    }
  }

  @override
  final String id;
  final String directory;
  final String _root;

  Future<String> _path(String? key) async {
    if (key != null &&
        (key.isEmpty ||
            key.contains('\\') ||
            key.contains('\u0000') ||
            p.posix.isAbsolute(key) ||
            key
                .split('/')
                .any((part) => part.isEmpty || part == '.' || part == '..'))) {
      throw const CoreException.invalidRequest('Invalid folder-relative key.');
    }
    if (await Directory(directory).resolveSymbolicLinks() != _root) {
      throw const LocationException(LocationFailure.revoked);
    }
    final target = key == null ? _root : p.joinAll([_root, ...key.split('/')]);
    final resolved = await File(target).resolveSymbolicLinks();
    if (resolved != _root && !p.isWithin(_root, resolved)) {
      throw const LocationException(LocationFailure.revoked);
    }
    return resolved;
  }

  LocationEntry _entry(String path, FileStat stat) => LocationEntry(
    key: p.relative(path, from: _root).split(p.separator).join('/'),
    name: p.basename(path),
    isDirectory: stat.type == FileSystemEntityType.directory,
    size: stat.type == FileSystemEntityType.file ? stat.size : null,
    revision: '${stat.modified.microsecondsSinceEpoch}:${stat.size}',
  );

  /// Cursors are enumeration offsets, not snapshots. A caller must restart a
  /// listing if the folder changes while paging. Memory is bounded by limit;
  /// enumeration never retains the entire directory or reads file contents.
  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async {
    final offset = cursor == null ? 0 : int.tryParse(cursor);
    if (limit < 1 || limit > 500 || offset == null || offset < 0) {
      throw const CoreException.invalidRequest('Invalid folder page.');
    }
    cancellation.throwIfCancelled();
    try {
      final root = await _path(directory);
      final entries = <LocationEntry>[];
      var seen = 0;
      await for (final entity in Directory(root).list(followLinks: false)) {
        cancellation.throwIfCancelled();
        // Do not traverse links, devices, sockets, or our unpublished writes.
        if (entity is Link ||
            p.basename(entity.path).startsWith('.shosai-write-')) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file &&
            stat.type != FileSystemEntityType.directory) {
          continue;
        }
        if (seen++ < offset) continue;
        if (entries.length == limit) {
          return LocationPage(entries, nextCursor: '${offset + limit}');
        }
        entries.add(_entry(entity.path, stat));
      }
      return LocationPage(entries);
    } on FileSystemException catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<LocationEntry> stat(
    String key, {
    CancellationToken? cancellation,
  }) async {
    cancellation.throwIfCancelled();
    try {
      final path = await _path(key);
      final value = await FileStat.stat(path);
      cancellation.throwIfCancelled();
      if (value.type == FileSystemEntityType.notFound) {
        throw const LocationException(LocationFailure.missing);
      }
      return _entry(path, value);
    } on FileSystemException catch (error) {
      throw _failure(error);
    }
  }

  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) async* {
    if (start < 0 || (end != null && end < start)) {
      throw const CoreException.invalidRequest('Invalid byte range.');
    }
    cancellation.throwIfCancelled();
    try {
      final path = await _path(key);
      cancellation.throwIfCancelled();
      if ((await FileStat.stat(path)).type != FileSystemEntityType.file) {
        throw const CoreException.invalidRequest('Read requires a regular file.');
      }
      final file = await File(path).open();
      try {
        final length = await file.length();
        final stop = end == null || end > length ? length : end;
        if (start >= stop) return;
        await file.setPosition(start);
        var remaining = stop - start;
        while (remaining > 0) {
          cancellation.throwIfCancelled();
          final bytes = await file.read(remaining > 65536 ? 65536 : remaining);
          cancellation.throwIfCancelled();
          if (bytes.isEmpty) break;
          remaining -= bytes.length;
          yield bytes;
        }
      } finally {
        await file.close();
      }
    } on FileSystemException catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) async {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        name.startsWith('.shosai-write-')) {
      throw const CoreException.invalidRequest('Invalid destination name.');
    }
    cancellation.throwIfCancelled();
    Directory? temporary;
    try {
      final parent = await _path(directory);
      temporary = await Directory(parent).createTemp('.shosai-write-');
      final file = File(p.join(temporary.path, 'contents'));
      final output = await file.open(mode: FileMode.writeOnly);
      try {
        var length = 0;
        await for (final chunk in bytes) {
          cancellation.throwIfCancelled();
          length += chunk.length;
          if (length > maxBookInputBytes) {
            throw const CoreException.limitExceeded(
              'The book exceeds the file limit.',
            );
          }
          await output.writeFrom(chunk);
        }
        cancellation.throwIfCancelled();
        await output.flush();
      } finally {
        await output.close();
      }
      // Validate the grant again before publication. Rename publishes only the
      // finished file, replacing a destination link rather than following it.
      if (await _path(directory) != parent) {
        throw const LocationException(LocationFailure.revoked);
      }
      cancellation.throwIfCancelled();
      final destination = p.join(parent, name);
      await file.rename(destination);
      return _entry(destination, await FileStat.stat(destination));
    } on FileSystemException catch (error) {
      throw _failure(error);
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          // A failed cleanup never changes the result of an atomic publication.
        }
      }
    }
  }
}

Exception _failure(FileSystemException error) {
  final code = error.osError?.errorCode;
  if (code == 2 || (Platform.isWindows && code == 3)) {
    return const LocationException(LocationFailure.missing);
  }
  if (code == 1 || code == 13 || (Platform.isWindows && code == 5)) {
    return const LocationException(LocationFailure.revoked);
  }
  return const CoreException(
    CoreErrorKind.inaccessible,
    'The folder could not be accessed.',
  );
}
