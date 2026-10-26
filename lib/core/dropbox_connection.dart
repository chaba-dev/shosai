/// Dropbox owns authorization, refresh and per-connection credential lifetimes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shosai_core/shosai_core.dart';

import 'connection_credentials.dart';
import 'dropbox_location.dart';
import 'library_connection.dart';

/// Dropbox's supported no-redirect code flow works in every native host:
/// authorization happens in the system browser; the code is entered in-app.
/// The verifier never leaves this effect except in the TLS token exchange.
final class DropboxConnectionProvider implements ConnectionProvider {
  DropboxConnectionProvider({
    required this.credentials,
    this.authorize,
    this.clientId = const String.fromEnvironment('SHOSAI_DROPBOX_APP_KEY'),
    Uri? tokenEndpoint,
    this.api,
    this.content,
  }) : tokenEndpoint =
           tokenEndpoint ?? Uri.https('api.dropboxapi.com', '/oauth2/token');

  final ConnectionCredentialStore credentials;
  final Future<String?> Function(Uri authorization)? authorize;
  final String clientId;
  final Uri tokenEndpoint;
  final Uri? api;
  final Uri? content;
  final Map<String, _DropboxSession> _sessions = {};

  @override
  String get id => 'dropbox';

  @override
  Future<LibraryConnection?> setup(String connectionId) async {
    if (clientId.isEmpty || authorize == null) {
      throw const CoreException(
        CoreErrorKind.unsupported,
        'This build needs a registered Dropbox app key.',
      );
    }
    final verifier = _random();
    final authorization = Uri.https('www.dropbox.com', '/oauth2/authorize', {
      'client_id': clientId,
      'response_type': 'code',
      'token_access_type': 'offline',
      'code_challenge_method': 'S256',
      'code_challenge': base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', ''),
      'scope': 'files.metadata.read files.content.read files.content.write',
    });
    final code = await authorize!(authorization);
    if (code == null) return null;
    final tokens = await _token({
      'grant_type': 'authorization_code',
      'code': code.trim(),
      'code_verifier': verifier,
    });
    final refresh = tokens['refresh_token'] as String?;
    if (refresh == null || refresh.isEmpty) {
      throw const CoreException.malformed(
        'Dropbox did not grant offline access.',
      );
    }
    final key = 'shosai.dropbox.$connectionId.${_random()}';
    await credentials.write(key, refresh);
    final connection = LibraryConnection(connectionId, 'Dropbox', id, {
      'credential': key,
      'clientId': clientId,
    });
    _sessions[key] = _DropboxSession(this, connection)..adopt(tokens);
    return connection;
  }

  _DropboxSession _session(LibraryConnection connection) =>
      _sessions.putIfAbsent(
        connection.configuration['credential']!,
        () => _DropboxSession(this, connection),
      );

  @override
  Future<LibraryConnection> refresh(LibraryConnection connection) async {
    // Refresh lazily on access. Offline launch must not require a network round
    // trip or prevent the existing cache/Keep path from opening a local book.
    if (await credentials.read(connection.configuration['credential']!) ==
        null) {
      throw const LocationException(LocationFailure.revoked);
    }
    return connection;
  }

  @override
  Future<LibraryLocation> open(LibraryConnection connection) async =>
      DropboxLocation(
        connection.id,
        DropboxClient(
          accessToken: _session(connection).token,
          api: api,
          content: content,
        ),
      );

  @override
  bool sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.configuration['credential'] == second.configuration['credential'];

  @override
  Future<void> release(LibraryConnection connection) async {
    final key = connection.configuration['credential']!;
    final session = _sessions.remove(key);
    session?.release();
    // Deleting this device's credential does not revoke other independently
    // connected folders/accounts using the same Dropbox app authorization.
    await credentials.delete(key);
  }

  Future<Map<String, dynamic>> _token(
    Map<String, String> fields, {
    String? appKey,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final timer = Timer(
      const Duration(seconds: 30),
      () => client.close(force: true),
    );
    try {
      final request = await client.postUrl(tokenEndpoint);
      request.followRedirects = false;
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(
        Uri(
          queryParameters: {'client_id': appKey ?? clientId, ...fields},
        ).query,
      );
      final response = await request.close();
      if (response.statusCode == 400 || response.statusCode == 401) {
        throw const LocationException(LocationFailure.revoked);
      }
      if (response.statusCode != 200) {
        throw const LocationException(LocationFailure.offline);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 64 * 1024) {
          throw const CoreException.limitExceeded(
            'Dropbox token response is too large.',
          );
        }
        bytes.add(chunk);
      }
      final value = (jsonDecode(utf8.decode(bytes.takeBytes())) as Map)
          .cast<String, dynamic>();
      if (value['access_token'] is! String || value['expires_in'] is! num) {
        throw const CoreException.malformed('Invalid Dropbox token response.');
      }
      return value;
    } on IOException {
      throw const LocationException(LocationFailure.offline);
    } on FormatException {
      throw const CoreException.malformed('Invalid Dropbox token response.');
    } finally {
      timer.cancel();
      client.close(force: true);
    }
  }
}

final class _DropboxSession {
  _DropboxSession(this.provider, this.connection);
  final DropboxConnectionProvider provider;
  final LibraryConnection connection;
  String? _access;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String>? _refreshing;
  bool _released = false;

  void adopt(Map<String, dynamic> value) {
    _access = value['access_token'] as String;
    _expires = DateTime.now().add(
      Duration(seconds: (value['expires_in'] as num).toInt() - 60),
    );
  }

  Future<String> token({bool renew = false}) async {
    if (_released) throw const LocationException(LocationFailure.revoked);
    if (!renew && _access != null && DateTime.now().isBefore(_expires)) {
      return _access!;
    }
    if (_refreshing != null) return _refreshing!;
    final work = _renew();
    _refreshing = work;
    try {
      return await work;
    } finally {
      _refreshing = null;
    }
  }

  Future<String> _renew() async {
    final refresh = await provider.credentials.read(
      connection.configuration['credential']!,
    );
    if (_released || refresh == null) {
      throw const LocationException(LocationFailure.revoked);
    }
    final value = await provider._token({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    }, appKey: connection.configuration['clientId']);
    if (_released) throw const LocationException(LocationFailure.revoked);
    adopt(value);
    return _access!;
  }

  void release() {
    _released = true;
    _access = null;
  }
}

String _random() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}
