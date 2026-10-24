/// Folder grants stay on this device; native provider URLs are not file paths.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:shosai_core/shosai_core.dart';

const _channel = MethodChannel('dev.shosai/library_folders');

/// Nonsecret configuration. Apple bookmarks and SAF grants must never be
/// synchronized to another device or included in exported book records.
final class FolderGrant {
  const FolderGrant(this.id, this.label, this.kind, this.grant);

  final String id;
  final String label;
  final String kind;
  final String grant;

  Map<String, String> toJson() => {
    'id': id,
    'label': label,
    'kind': kind,
    'grant': grant,
  };

  factory FolderGrant.fromJson(Map<String, dynamic> value) => FolderGrant(
    value['id'] as String,
    value['label'] as String,
    value['kind'] as String,
    value['grant'] as String,
  );

  static Future<FolderGrant?> pick(String id) async {
    if (Platform.isLinux || Platform.isWindows) {
      final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
      if (path == null) return null;
      return FolderGrant(
        id,
        path.split(Platform.pathSeparator).last,
        'path',
        path,
      );
    }
    final value = await _channel.invokeMapMethod<String, String>('pick');
    if (value == null) return null;
    return FolderGrant(id, value['label']!, 'platform', value['grant']!);
  }

  Future<LibraryLocation> open() async => switch (kind) {
    'path' => FolderLocation.open(id, grant),
    'platform' => PlatformFolderLocation(id, grant),
    _ => throw const CoreException(
      CoreErrorKind.unsupported,
      'Unknown folder grant.',
    ),
  };

  /// Renew resolved Apple bookmarks before saving their device configuration;
  /// an old absolute URL is not a replacement for a stale security bookmark.
  Future<FolderGrant> refreshed() async {
    if (kind != 'platform' || (!Platform.isIOS && !Platform.isMacOS)) {
      return this;
    }
    final renewed = await _channel.invokeMethod<String>('refresh', {
      'grant': grant,
    });
    return FolderGrant(id, label, kind, renewed!);
  }

  Future<void> release() async {
    if (kind == 'platform') {
      await _channel.invokeMethod<void>('release', {'grant': grant});
    }
  }
}

/// Native holds an open stream (and Apple scope) until close. Messages contain
/// at most 64 KiB, with one outstanding read/write per operation. Neither a
/// listing nor stat requests any file contents from the provider.
final class PlatformFolderLocation implements LibraryLocation {
  const PlatformFolderLocation(this.id, this.grant);

  @override
  final String id;
  final String grant;

  Future<T?> _call<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, {'grant': grant, ...args});
    } on PlatformException catch (error) {
      throw switch (error.code) {
        'offline' => const LocationException(LocationFailure.offline),
        'revoked' => const LocationException(LocationFailure.revoked),
        'missing' => const LocationException(LocationFailure.missing),
        'unsupported' => const CoreException(
          CoreErrorKind.unsupported,
          'This folder provider does not support the operation.',
        ),
        _ => const CoreException(
          CoreErrorKind.inaccessible,
          'The folder could not be accessed.',
        ),
      };
    }
  }

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
    final page = (await _call<Map>('list', {
      'directory': directory,
      'offset': offset,
      'limit': limit,
    }))!;
    cancellation.throwIfCancelled();
    return LocationPage(
      (page['entries'] as List).cast<Map>().map(_entry),
      nextCursor: page['nextCursor'] as String?,
    );
  }

  @override
  Future<LocationEntry> stat(
    String key, {
    CancellationToken? cancellation,
  }) async {
    cancellation.throwIfCancelled();
    final result = _entry((await _call<Map>('stat', {'key': key}))!);
    cancellation.throwIfCancelled();
    return result;
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
    final token = (await _call<String>('openRead', {
      'key': key,
      'start': start,
    }))!;
    try {
      var remaining = end == null ? null : end - start;
      while (remaining == null || remaining > 0) {
        cancellation.throwIfCancelled();
        final count = remaining == null || remaining > 65536
            ? 65536
            : remaining;
        final bytes = (await _call<Uint8List>('read', {
          'token': token,
          'count': count,
        }))!;
        cancellation.throwIfCancelled();
        if (bytes.isEmpty) break;
        if (remaining != null) remaining -= bytes.length;
        yield bytes;
      }
    } finally {
      await _call<void>('close', {'token': token});
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
        name.contains('\u0000')) {
      throw const CoreException.invalidRequest('Invalid destination name.');
    }
    cancellation.throwIfCancelled();
    final token = (await _call<String>('openWrite', {
      'directory': directory,
      'name': name,
    }))!;
    try {
      var length = 0;
      await for (final chunk in bytes) {
        length += chunk.length;
        if (length > maxBookInputBytes) {
          throw const CoreException.limitExceeded(
            'The book exceeds the file limit.',
          );
        }
        for (var offset = 0; offset < chunk.length; offset += 65536) {
          cancellation.throwIfCancelled();
          final stop = offset + 65536 > chunk.length
              ? chunk.length
              : offset + 65536;
          await _call<void>('write', {
            'token': token,
            'bytes': Uint8List.fromList(chunk.sublist(offset, stop)),
          });
        }
      }
      cancellation.throwIfCancelled();
      return _entry((await _call<Map>('commit', {'token': token}))!);
    } finally {
      // Close is idempotent; unfinished writes are deleted, never published as
      // complete. Successful commit already released its handle and scope.
      await _call<void>('close', {'token': token});
    }
  }
}

LocationEntry _entry(Map value) => LocationEntry(
  key: value['key'] as String,
  name: value['name'] as String,
  isDirectory: value['isDirectory'] as bool,
  size: value['size'] as int?,
  revision: value['revision'] as String?,
);
