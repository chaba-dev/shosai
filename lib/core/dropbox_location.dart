/// Direct device-to-Dropbox transport. No catalog operation reads book bytes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';

/// One connection's authenticated transport. Tokens remain owned by its provider.
final class DropboxClient {
  DropboxClient({
    required this.accessToken,
    Uri? api,
    Uri? content,
    this.requestTimeout = const Duration(seconds: 60),
  }) : api = api ?? Uri.https('api.dropboxapi.com', '/2/'),
       content = content ?? Uri.https('content.dropboxapi.com', '/2/');

  final Future<String> Function({bool renew}) accessToken;
  final Uri api;
  final Uri content;
  final Duration requestTimeout;

  Future<Map<String, dynamic>> rpc(
    String route,
    Map<String, Object?> arguments, {
    CancellationToken? cancellation,
    bool upload = false,
    List<int> bytes = const [],
  }) async {
    final body = await _boundedJson(
      request(
        route,
        arguments,
        cancellation: cancellation,
        upload: upload,
        bytes: bytes,
      ),
    );
    return body;
  }

  /// Each request has its own socket owner. Cancellation and deadlines close
  /// that owner even while waiting for headers or while the consumer is paused.
  /// Only a rejected token retries, once, before exposing any response bytes.
  Stream<List<int>> request(
    String route,
    Map<String, Object?> arguments, {
    CancellationToken? cancellation,
    bool upload = false,
    bool download = false,
    List<int> bytes = const [],
    int? start,
    int? end,
  }) async* {
    for (var attempt = 0; attempt < 2; attempt++) {
      cancellation.throwIfCancelled();
      final token = await _cancel(
        accessToken(renew: attempt != 0),
        cancellation,
      );
      final client = HttpClient()..connectionTimeout = requestTimeout;
      var active = true;
      var timedOut = false;
      final timer = Timer(requestTimeout, () {
        timedOut = true;
        client.close(force: true);
      });
      unawaited(
        cancellation?.whenCancelled.then((_) {
          if (active) client.close(force: true);
        }),
      );
      try {
        final request = await client.postUrl(
          (upload || download ? content : api).resolve(route),
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final encoded = jsonEncode(arguments);
        if (upload || download) {
          // Dropbox requires non-ASCII header characters escaped as UTF-16.
          request.headers.set(
            'Dropbox-API-Arg',
            String.fromCharCodes([
              for (final unit in encoded.codeUnits)
                ...unit >= 127
                    ? '\\u${unit.toRadixString(16).padLeft(4, '0')}'.codeUnits
                    : [unit],
            ]),
          );
          if (upload) {
            request.headers.contentType = ContentType.binary;
            request.contentLength = bytes.length;
            request.add(bytes);
          }
        } else {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(encoded));
        }
        if (start != null) {
          request.headers.set(
            'Range',
            'bytes=$start-${end == null ? '' : end - 1}',
          );
        }
        final response = await request.close();
        cancellation.throwIfCancelled();
        if (response.statusCode == 401 && attempt == 0) continue;
        if (download && start != null && response.statusCode == 416) {
          final total = RegExp(
            r'^bytes \*/(\d+)$',
          ).firstMatch(response.headers.value('content-range') ?? '');
          if (total != null && start >= int.parse(total[1]!)) return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await _failure(response);
        }
        int? expectedBytes;
        if (start != null) {
          final range = RegExp(
            r'^bytes (\d+)-(\d+)/(\d+)$',
          ).firstMatch(response.headers.value('content-range') ?? '');
          if (response.statusCode != 206 ||
              range == null ||
              int.parse(range[1]!) != start) {
            throw const CoreException(
              CoreErrorKind.unsupported,
              'Dropbox did not honor the byte range.',
            );
          }
          final last = int.parse(range[2]!);
          final total = int.parse(range[3]!);
          if (last < start ||
              last != (end == null ? total : min(end, total)) - 1) {
            throw const CoreException.malformed('Invalid Dropbox byte range.');
          }
          expectedBytes = last - start + 1;
        }
        var received = 0;
        await for (final chunk in response) {
          cancellation.throwIfCancelled();
          received += chunk.length;
          if (start != null && end != null && received > end - start) {
            throw const CoreException.malformed('Invalid Dropbox byte range.');
          }
          yield chunk;
        }
        cancellation.throwIfCancelled();
        if (timedOut) throw const LocationException(LocationFailure.offline);
        if (expectedBytes != null && received != expectedBytes) {
          throw const LocationException(LocationFailure.offline);
        }
        return;
      } on IOException {
        cancellation.throwIfCancelled();
        throw const LocationException(LocationFailure.offline);
      } finally {
        active = false;
        timer.cancel();
        client.close(force: true);
      }
    }
  }
}

final class DropboxLocation implements LibraryLocation {
  const DropboxLocation(this.id, this.client);

  @override
  final String id;
  final DropboxClient client;

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async {
    if (limit < 1 || limit > 2000) {
      throw const CoreException.invalidRequest('Invalid Dropbox page size.');
    }
    final result = await client.rpc(
      cursor == null ? 'files/list_folder' : 'files/list_folder/continue',
      cursor == null
          ? {'path': directory ?? '', 'recursive': false, 'limit': limit}
          : {'cursor': cursor},
      cancellation: cancellation,
    );
    return LocationPage(
      (result['entries'] as List).cast<Map<String, dynamic>>().map(_entry),
      nextCursor: result['has_more'] == true
          ? result['cursor'] as String
          : null,
    );
  }

  @override
  Future<LocationEntry> stat(
    String key, {
    CancellationToken? cancellation,
  }) async => _entry(
    await client.rpc('files/get_metadata', {
      'path': key,
    }, cancellation: cancellation),
  );

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
    if (end == start) return;
    final ranged = start != 0 || end != null;
    if (ranged) {
      final entry = await stat(key, cancellation: cancellation);
      if (entry.isDirectory) {
        throw const CoreException.invalidRequest('A folder is not a book.');
      }
      final size = entry.size!;
      if (start >= size) return;
      end = min(end ?? size, size);
    }
    yield* client.request(
      'files/download',
      {'path': key},
      download: true,
      start: ranged ? start : null,
      end: end,
      cancellation: cancellation,
    );
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
      throw const CoreException.invalidRequest('Invalid Dropbox file name.');
    }
    // Upload sessions bound memory regardless of the caller's chunk sizes.
    // Only finish publishes a file; cancelled/failed sessions expire at Dropbox.
    final session = await client.rpc(
      'files/upload_session/start',
      {'close': false},
      upload: true,
      cancellation: cancellation,
    );
    final sessionId = session['session_id'] as String;
    var offset = 0;
    final buffer = BytesBuilder(copy: false);
    Future<void> append() async {
      final chunk = buffer.takeBytes();
      // This endpoint returns Void (empty or JSON null), not metadata.
      await client
          .request(
            'files/upload_session/append_v2',
            {
              'cursor': {'session_id': sessionId, 'offset': offset},
              'close': false,
            },
            upload: true,
            bytes: chunk,
            cancellation: cancellation,
          )
          .drain<void>();
      offset += chunk.length;
    }

    final iterator = StreamIterator(bytes);
    try {
      while (await _cancel(iterator.moveNext(), cancellation)) {
        final chunk = iterator.current;
        for (var index = 0; index < chunk.length;) {
          cancellation.throwIfCancelled();
          final count = min(
            4 * 1024 * 1024 - buffer.length,
            chunk.length - index,
          );
          buffer.add(Uint8List.fromList(chunk.sublist(index, index + count)));
          index += count;
          if (buffer.length == 4 * 1024 * 1024) await append();
        }
      }
      cancellation.throwIfCancelled();
      return _entry(
        await client.rpc(
          'files/upload_session/finish',
          {
            'cursor': {'session_id': sessionId, 'offset': offset},
            'commit': {
              'path': '${directory ?? ''}/$name',
              'mode': 'overwrite',
              'autorename': false,
            },
          },
          upload: true,
          bytes: buffer.takeBytes(),
          cancellation: cancellation,
        ),
      );
    } finally {
      await iterator.cancel();
    }
  }
}

LocationEntry _entry(Map<String, dynamic> value) => LocationEntry(
  key: value['id'] as String,
  name: value['name'] as String,
  isDirectory: value['.tag'] == 'folder',
  size: value['size'] as int?,
  revision: value['rev'] as String?,
);

Future<T> _cancel<T>(Future<T> work, CancellationToken? token) {
  token.throwIfCancelled();
  return token == null
      ? work
      : Future.any([
          work,
          token.whenCancelled.then<T>(
            (_) => throw const CoreException.cancelled(),
          ),
        ]);
}

Future<Map<String, dynamic>> _boundedJson(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > 8 * 1024 * 1024) {
      throw const CoreException.limitExceeded('Dropbox metadata is too large.');
    }
    bytes.add(chunk);
  }
  if (bytes.isEmpty) return {};
  try {
    return (jsonDecode(utf8.decode(bytes.takeBytes())) as Map)
        .cast<String, dynamic>();
  } on FormatException {
    throw const CoreException.malformed('Invalid Dropbox response.');
  }
}

Future<Never> _failure(HttpClientResponse response) async {
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw const LocationException(LocationFailure.revoked);
  }
  if (response.statusCode == 429 || response.statusCode >= 500) {
    throw const LocationException(LocationFailure.offline);
  }
  final body = await _boundedJson(response);
  final error = body['error'];
  if (error is Map &&
      (error['path'] is Map) &&
      (error['path'] as Map)['.tag'] == 'not_found') {
    throw const LocationException(LocationFailure.missing);
  }
  throw const CoreException(
    CoreErrorKind.inaccessible,
    'Dropbox could not complete the request.',
  );
}
