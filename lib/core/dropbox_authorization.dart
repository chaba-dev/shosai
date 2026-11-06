/// Browser-only mobile authorization. Dart owns the code exchange and vault.
library;

import 'dart:io';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:shosai_core/shosai_core.dart';

const dropboxScopes = [
  'files.metadata.read',
  'files.content.read',
  'files.content.write',
];

final class DropboxAuthorization {
  const DropboxAuthorization();

  static bool get supported => Platform.isIOS || Platform.isAndroid;

  Future<({String code, String verifier, String redirect})?> authorize(
    String clientId,
  ) async {
    final redirect = 'db-$clientId://2/token';
    try {
      // AppAuth generates S256 PKCE and state and validates the callback. Keep
      // its default non-ephemeral browser session so cookies can be reused.
      final result = await const FlutterAppAuth().authorize(
        AuthorizationRequest(
          clientId,
          redirect,
          serviceConfiguration: const AuthorizationServiceConfiguration(
            authorizationEndpoint: 'https://www.dropbox.com/oauth2/authorize',
            tokenEndpoint: 'https://api.dropboxapi.com/oauth2/token',
          ),
          scopes: dropboxScopes,
          additionalParameters: {'token_access_type': 'offline'},
        ),
      );
      final code = result.authorizationCode;
      final verifier = result.codeVerifier;
      if (code == null ||
          code.isEmpty ||
          verifier == null ||
          verifier.isEmpty) {
        throw const LocationException(LocationFailure.revoked);
      }
      return (code: code, verifier: verifier, redirect: redirect);
    } on FlutterAppAuthUserCancelledException {
      return null;
    } on FlutterAppAuthPlatformException {
      // Raw platform errors may contain callback URLs and authorization codes.
      throw const LocationException(LocationFailure.revoked);
    }
  }
}
