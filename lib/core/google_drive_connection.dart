library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shosai_core/shosai_core.dart';

import 'connection_credentials.dart';
import 'google_drive_authorization.dart';
import 'google_drive_location.dart';
import 'library_connection.dart';

final class GoogleDriveConnectionProvider implements ConnectionProvider {
  GoogleDriveConnectionProvider({
    ConnectionCredentialStore credentials =
        const PlatformConnectionCredentialStore(),
    GoogleDriveAuthorization? authorization,
    Future<Map<String, dynamic>?> Function()? authorize,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>, {bool force})?
    renew,
  }) : _credentials = credentials {
    final oauth = authorization ?? GoogleDriveAuthorization();
    _authorize = authorize ?? oauth.authorize;
    _renew = renew ?? oauth.renew;
  }

  final ConnectionCredentialStore _credentials;
  late final Future<Map<String, dynamic>?> Function() _authorize;
  late final Future<Map<String, dynamic>> Function(
    Map<String, dynamic>, {
    bool force,
  })
  _renew;
  final Map<String, Future<String>> _renewing = {};
  final Set<String> _released = {};

  @override
  String get id => 'google-drive';

  @override
  Future<LibraryConnection?> setup(String connectionId) async {
    final credential = await _authorize();
    if (credential == null) return null;
    final key =
        'shosai.google-drive.$connectionId.${GoogleDriveAuthorization.nonce()}';
    await _credentials.write(key, jsonEncode(credential));
    return LibraryConnection(connectionId, 'Google Drive', id, {
      'credential': key,
    });
  }

  String _key(LibraryConnection connection) {
    final key = connection.configuration['credential'];
    if (key == null ||
        !key.startsWith('shosai.google-drive.${connection.id}.')) {
      throw const LocationException(LocationFailure.revoked);
    }
    return key;
  }

  Future<String> _token(String key, {bool renew = false}) {
    if (_released.contains(key)) {
      throw const LocationException(LocationFailure.revoked);
    }
    return _renewing[key] ??= _refreshToken(key, force: renew).whenComplete(() {
      _renewing.remove(key);
    });
  }

  Future<String> _refreshToken(String key, {required bool force}) async {
    try {
      final raw = await _credentials.read(key);
      if (raw == null) throw const LocationException(LocationFailure.revoked);
      final credential = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final next = await _renew(
        credential,
        force: force,
      ).timeout(const Duration(seconds: 45));
      // Removal must not race an outstanding refresh into resurrecting a token.
      if (_released.contains(key)) {
        throw const LocationException(LocationFailure.revoked);
      }
      await _credentials.write(key, jsonEncode(next));
      if (_released.contains(key)) {
        await _credentials.delete(key);
        throw const LocationException(LocationFailure.revoked);
      }
      return next['access_token'] as String;
    } on TimeoutException {
      throw const LocationException(LocationFailure.offline);
    } on PlatformException {
      // A locked/unavailable vault is retryable, not evidence of revocation.
      throw const LocationException(LocationFailure.offline);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const CoreException.cancelled();
      }
      throw LocationException(switch (error.code) {
        GoogleSignInExceptionCode.userMismatch ||
        GoogleSignInExceptionCode.clientConfigurationError ||
        GoogleSignInExceptionCode.providerConfigurationError ||
        GoogleSignInExceptionCode.uiUnavailable => LocationFailure.revoked,
        _ => LocationFailure.offline,
      });
    } on FormatException {
      throw const LocationException(LocationFailure.revoked);
    } on TypeError {
      throw const LocationException(LocationFailure.revoked);
    }
  }

  @override
  Future<LibraryConnection> refresh(LibraryConnection connection) async {
    // Renew lazily on an actual network operation. Opening kept books offline
    // does not require a credential-store or token-endpoint round trip.
    _key(connection);
    return connection;
  }

  @override
  Future<LibraryLocation> open(LibraryConnection connection) async {
    final key = _key(connection);
    return GoogleDriveLocation(
      connection.id,
      DriveTransport(({bool renew = false}) => _token(key, renew: renew)),
    );
  }

  @override
  bool sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.configuration['credential'] == second.configuration['credential'];

  @override
  Future<void> release(LibraryConnection connection) async {
    final key = _key(connection);
    _released.add(key);
    // Google revocation is project-wide, NOT per token/connection. Deleting
    // this device-local credential leaves independent connections authorized.
    await _credentials.delete(key);
  }
}
