/// Drive v3 metadata and lazy, streamed file access. No book bytes go to Shōsai.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';

typedef DriveAccessToken = Future<String> Function({bool renew});

/// Each request owns its socket, deadline and cancellation. A 401 retries once
/// with renewed authorization; callers supply replayable, bounded upload chunks.
final class DriveTransport {
  DriveTransport(this.token, {HttpClient Function()? client})
    : _client = client ?? HttpClient.new;

  final DriveAccessToken token;
  final HttpClient Function() _client;

  Stream<List<int>> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    CancellationToken? cancellation,
    void Function(HttpClientResponse)? response,
  }) async* {
    for (var attempt = 0; attempt < 2; attempt++) {
      cancellation.throwIfCancelled();
      final access = await Future.any([
        token(renew: attempt != 0).timeout(
          const Duration(seconds: 45),
          onTimeout: () =>
              throw const LocationException(LocationFailure.offline),
        ),
        if (cancellation != null)
          cancellation.whenCancelled.then<String>((_) {
            throw const CoreException.cancelled();
          }),
      ]);
      cancellation.throwIfCancelled();
      final client = _client()..connectionTimeout = const Duration(seconds: 30);
      var finished = false;
      var expired = false;
      final deadline = Timer(const Duration(minutes: 2), () {
        expired = true;
        client.close(force: true);
      });
      unawaited(
        cancellation?.whenCancelled.then((_) {
          if (!finished) client.close(force: true);
        }),
      );
      try {
        final request = await client.openUrl(method, uri);
        // Never follow redirects carrying credentials to a different host.
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $access');
        headers.forEach(request.headers.set);
        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        }
        final result = await request.close();
        cancellation.throwIfCancelled();
        if (expired) throw const LocationException(LocationFailure.offline);
        if (result.statusCode == 401 && attempt == 0) continue;
        if (result.statusCode == 416 && headers.containsKey('Range')) return;
        if (result.statusCode >= 300 &&
            result.statusCode < 400 &&
            result.statusCode != 308) {
          throw const LocationException(LocationFailure.offline);
        }
        if (result.statusCode >= 400) {
          if (result.statusCode == 401) {
            throw const LocationException(LocationFailure.revoked);
          }
          if (result.statusCode == 404 || result.statusCode == 410) {
            throw const LocationException(LocationFailure.missing);
          }
          if (result.statusCode == 403) {
            final error = await boundedBytes(result, 64 * 1024);
            final text = utf8.decode(error, allowMalformed: true);
            if (!text.contains('rateLimitExceeded') &&
                !text.contains('userRateLimitExceeded')) {
              throw const LocationException(LocationFailure.revoked);
            }
          }
          throw const LocationException(LocationFailure.offline);
        }
        response?.call(result);
        await for (final bytes in result.timeout(const Duration(seconds: 30))) {
          cancellation.throwIfCancelled();
          if (expired) throw const LocationException(LocationFailure.offline);
          yield bytes;
        }
        cancellation.throwIfCancelled();
        return;
      } on IOException {
        cancellation.throwIfCancelled();
        throw const LocationException(LocationFailure.offline);
      } on TimeoutException {
        cancellation.throwIfCancelled();
        throw const LocationException(LocationFailure.offline);
      } finally {
        finished = true;
        deadline.cancel();
        client.close(force: true);
      }
    }
  }

  Future<Map<String, dynamic>> json(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    CancellationToken? cancellation,
    void Function(HttpClientResponse)? response,
  }) async {
    final bytes = await boundedBytes(
      request(
        method,
        uri,
        headers: headers,
        body: body,
        cancellation: cancellation,
        response: response,
      ),
      2 * 1024 * 1024,
    );
    try {
      return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
    } on FormatException {
      throw const CoreException.malformed('Invalid Drive metadata.');
    } on TypeError {
      throw const CoreException.malformed('Invalid Drive metadata.');
    }
  }

  static Future<List<int>> boundedBytes(
    Stream<List<int>> stream,
    int max,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final part in stream) {
      if (bytes.length + part.length > max) {
        throw const CoreException.limitExceeded('Drive response is too large.');
      }
      bytes.add(part);
    }
    return bytes.takeBytes();
  }
}

final class GoogleDriveLocation implements LibraryLocation {
  GoogleDriveLocation(this.id, this.transport);

  @override
  final String id;
  final DriveTransport transport;
  static const folderMime = 'application/vnd.google-apps.folder';
  static const _fields = 'id,name,mimeType,size,version,trashed,ownedByMe';

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.https('www.googleapis.com', '/drive/v3/$path', query);

  static String _key(String key) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,256}$').hasMatch(key)) {
      throw const CoreException.invalidRequest('Invalid Drive file key.');
    }
    return key;
  }

  static LocationEntry _entry(Map<String, dynamic> file) => LocationEntry(
    key: _key(file['id'] as String),
    name: file['name'] as String,
    isDirectory: file['mimeType'] == folderMime,
    size: int.tryParse(file['size']?.toString() ?? ''),
    revision: file['version']?.toString(),
  );

  static bool _supported(Map<String, dynamic> file) =>
      file['mimeType'] == folderMime ||
      !(file['mimeType'] as String).startsWith('application/vnd.google-apps.');

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async {
    if (limit < 1 || limit > 1000 || (cursor?.length ?? 0) > 8192) {
      throw const CoreException.invalidRequest('Invalid Drive page.');
    }
    final parent = _key(directory ?? 'root');
    if (directory != null &&
        !(await stat(directory, cancellation: cancellation)).isDirectory) {
      throw const CoreException.invalidRequest('Choose a Drive folder.');
    }
    final result = await transport.json(
      'GET',
      _uri('files', {
        'q': "'$parent' in parents and trashed = false and 'me' in owners",
        'pageSize': '$limit',
        'fields': 'nextPageToken,incompleteSearch,files($_fields)',
        'spaces': 'drive',
        'corpora': 'user',
        'pageToken': ?cursor,
      }),
      cancellation: cancellation,
    );
    if (result['incompleteSearch'] == true) {
      throw const LocationException(LocationFailure.offline);
    }
    return LocationPage([
      for (final file in (result['files'] as List? ?? []).cast<Map>())
        if (_supported(file.cast<String, dynamic>()))
          _entry(file.cast<String, dynamic>()),
    ], nextCursor: result['nextPageToken'] as String?);
  }

  Future<Map<String, dynamic>> _metadata(
    String key,
    CancellationToken? cancellation,
  ) async {
    final file = await transport.json(
      'GET',
      _uri('files/${_key(key)}', {'fields': _fields}),
      cancellation: cancellation,
    );
    if (file['trashed'] == true) {
      throw const LocationException(LocationFailure.missing);
    }
    if (file['ownedByMe'] != true) {
      throw const LocationException(LocationFailure.revoked);
    }
    if (!_supported(file)) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'Native Workspace files and shortcuts are not books.',
      );
    }
    return file;
  }

  @override
  Future<LocationEntry> stat(
    String key, {
    CancellationToken? cancellation,
  }) async => _entry(await _metadata(key, cancellation));

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
    final entry = await stat(key, cancellation: cancellation);
    if (entry.isDirectory) {
      throw const CoreException.invalidRequest('A folder is not a book.');
    }
    if (end == start || (entry.size != null && start >= entry.size!)) return;
    final ranged = start != 0 || end != null;
    var received = 0;
    yield* transport
        .request(
          'GET',
          _uri('files/${_key(key)}', {'alt': 'media'}),
          headers: {
            if (ranged) 'Range': 'bytes=$start-${end == null ? '' : end - 1}',
          },
          cancellation: cancellation,
          response: (response) {
            if (!ranged && response.statusCode != 200) {
              throw const CoreException.malformed(
                'Invalid Drive media response.',
              );
            }
            if (ranged && response.statusCode != 206) {
              throw const CoreException(
                CoreErrorKind.unsupported,
                'Drive did not honor the requested byte range.',
              );
            }
            if (ranged &&
                !(response.headers.value('content-range') ?? '').startsWith(
                  'bytes $start-',
                )) {
              throw const CoreException.malformed('Invalid Drive byte range.');
            }
          },
        )
        .map((bytes) {
          received += bytes.length;
          if (received > maxBookInputBytes ||
              (end != null && received > end - start)) {
            throw const CoreException.limitExceeded(
              'Drive file exceeds read limit.',
            );
          }
          return bytes;
        });
  }

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) async {
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000') ||
        utf8.encode(name).length > 255) {
      throw const CoreException.invalidRequest('Invalid book name.');
    }
    final parent = directory ?? 'root';
    if (directory != null &&
        !(await stat(directory, cancellation: cancellation)).isDirectory) {
      throw const CoreException.invalidRequest('Choose a Drive folder.');
    }
    final existing = await transport.json(
      'GET',
      _uri('files', {
        'q':
            "'${_key(parent)}' in parents and trashed = false and 'me' in owners and name = '${name.replaceAll("'", "\\'")}'",
        'fields': 'nextPageToken,files($_fields)',
        'pageSize': '2',
      }),
      cancellation: cancellation,
    );
    final matches = (existing['files'] as List).cast<Map>();
    if (matches.length > 1 || existing['nextPageToken'] != null) {
      throw const CoreException.invalidRequest(
        'Several Drive files have this name. Choose a unique name.',
      );
    }
    final replacement = matches.firstOrNull;
    if (replacement != null &&
        (!_supported(replacement.cast<String, dynamic>()) ||
            replacement['mimeType'] == folderMime)) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'Cannot replace this Drive item.',
      );
    }
    // Resumable uploads publish only on the final chunk. Retain at most one
    // 256 KiB upload chunk, not a library or an entire book in memory.
    Uri? upload;
    await DriveTransport.boundedBytes(
      transport.request(
        replacement == null ? 'POST' : 'PATCH',
        Uri.https(
          'www.googleapis.com',
          '/upload/drive/v3/files${replacement == null ? '' : '/${_key(replacement['id'] as String)}'}',
          {'uploadType': 'resumable', 'fields': _fields},
        ),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: utf8.encode(
          jsonEncode({
            'name': name,
            if (replacement == null) 'parents': [_key(parent)],
          }),
        ),
        cancellation: cancellation,
        response: (response) {
          upload = Uri.tryParse(response.headers.value('location') ?? '');
        },
      ),
      64 * 1024,
    );
    final target = upload;
    if (target == null ||
        target.scheme != 'https' ||
        target.host != 'www.googleapis.com' ||
        target.userInfo.isNotEmpty) {
      throw const CoreException.malformed('Invalid Drive upload session.');
    }
    final iterator = StreamIterator(bytes);
    var part = <int>[];
    var offset = 0;
    var total = 0;
    var ended = false;
    try {
      while (!ended) {
        cancellation.throwIfCancelled();
        final buffer = BytesBuilder(copy: false);
        while (buffer.length < 256 * 1024) {
          if (part.isEmpty) {
            final next = await Future.any([
              iterator.moveNext().timeout(const Duration(seconds: 30)),
              if (cancellation != null)
                cancellation.whenCancelled.then((_) {
                  throw const CoreException.cancelled();
                }),
            ]);
            if (!next) {
              ended = true;
              break;
            }
            part = iterator.current;
          }
          final remaining = 256 * 1024 - buffer.length;
          final take = part.length < remaining ? part.length : remaining;
          buffer.add(part.sublist(0, take));
          part = part.sublist(take);
        }
        // Look ahead at exact chunk boundaries so the final PUT carries a
        // known total, rather than sending a status query that cannot finalize.
        while (!ended && part.isEmpty) {
          final next = await Future.any([
            iterator.moveNext().timeout(const Duration(seconds: 30)),
            if (cancellation != null)
              cancellation.whenCancelled.then<bool>((_) {
                throw const CoreException.cancelled();
              }),
          ]);
          ended = !next;
          if (next) part = iterator.current;
        }
        final chunk = buffer.takeBytes();
        total += chunk.length;
        if (total > maxBookInputBytes) {
          throw const CoreException.limitExceeded(
            'Drive upload exceeds file limit.',
          );
        }
        Map<String, dynamic>? completed;
        final result = await DriveTransport.boundedBytes(
          transport.request(
            'PUT',
            target,
            headers: {
              'Content-Type': 'application/octet-stream',
              'Content-Range': chunk.isEmpty
                  ? 'bytes */$total'
                  : 'bytes $offset-${total - 1}/${ended ? total : '*'}',
            },
            body: chunk,
            cancellation: cancellation,
            response: (response) {
              if ((!ended && response.statusCode != 308) ||
                  (ended &&
                      response.statusCode != 200 &&
                      response.statusCode != 201)) {
                throw const CoreException.malformed('Incomplete Drive upload.');
              }
              if (!ended &&
                  response.headers.value('range') != 'bytes=0-${total - 1}') {
                throw const CoreException.malformed(
                  'Incomplete Drive upload chunk.',
                );
              }
            },
          ),
          2 * 1024 * 1024,
        );
        if (ended) {
          completed = (jsonDecode(utf8.decode(result)) as Map)
              .cast<String, dynamic>();
          final entry = _entry(completed);
          if (entry.size != total) {
            throw const CoreException.malformed(
              'Incomplete Drive upload size.',
            );
          }
          return entry;
        }
        offset = total;
      }
      throw const CoreException.malformed('Incomplete Drive upload.');
    } on TimeoutException {
      throw const LocationException(LocationFailure.offline);
    } finally {
      await iterator.cancel();
    }
  }
}
