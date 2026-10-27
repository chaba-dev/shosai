/// Google-supported native authorization; never an embedded webview.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:url_launcher/url_launcher.dart';

import 'google_drive_location.dart';

const googleDriveScope = 'https://www.googleapis.com/auth/drive';

final class GoogleDriveRegistrationRequired implements Exception {
  const GoogleDriveRegistrationRequired();
}

enum GoogleDriveSetupStage { tokenExchange, permissions, credentialStorage }

/// Only fixed stage names and allowlisted OAuth codes cross into presentation.
/// Never retain Google's raw response, which may contain sensitive details.
final class GoogleDriveSetupException implements Exception {
  const GoogleDriveSetupException.permissions()
    : stage = GoogleDriveSetupStage.permissions,
      oauthError = null;
  const GoogleDriveSetupException.credentialStorage()
    : stage = GoogleDriveSetupStage.credentialStorage,
      oauthError = null;
  const GoogleDriveSetupException._token(this.oauthError)
    : stage = GoogleDriveSetupStage.tokenExchange;

  factory GoogleDriveSetupException.tokenRejected(
    Object? error, {
    Object? description,
  }) {
    // Recognize only complete fixed provider messages. Never expose arbitrary
    // descriptions, even ones that mention a known parameter among secrets.
    if (error == 'invalid_request' &&
        (description == 'client_secret is missing.' ||
            description == 'client_secret is missing' ||
            description == 'Missing required parameter: client_secret')) {
      return const GoogleDriveSetupException._token('missing_client_secret');
    }
    return GoogleDriveSetupException._token(switch (error) {
      'invalid_client' ||
      'invalid_grant' ||
      'invalid_request' ||
      'unauthorized_client' ||
      'unsupported_grant_type' ||
      'invalid_scope' ||
      'access_denied' => error as String,
      _ => 'unknown_error',
    });
  }

  final GoogleDriveSetupStage stage;
  final String? oauthError;
}

/// Public registration identifiers supplied by the distributor, not invented
/// defaults. Google Cloud consent, platform registrations and test users must
/// be configured before a real account can connect.
final class GoogleDriveAuthorization {
  GoogleDriveAuthorization({
    this.desktopClientId = const String.fromEnvironment(
      'GOOGLE_DRIVE_DESKTOP_CLIENT_ID',
    ),
    this.desktopClientSecret = const String.fromEnvironment(
      'GOOGLE_DRIVE_DESKTOP_CLIENT_SECRET',
    ),
    this.iosClientId = const String.fromEnvironment(
      'GOOGLE_DRIVE_IOS_CLIENT_ID',
    ),
    this.androidServerClientId = const String.fromEnvironment(
      'GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID',
    ),
    Future<bool> Function(Uri)? launch,
  }) : _launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final String desktopClientId;
  // Google Desktop clients are public clients: this distributor registration
  // parameter is extractable from the binary, not a confidential user token.
  final String desktopClientSecret;
  final String iosClientId;
  final String androidServerClientId;
  final Future<bool> Function(Uri) _launch;
  static Future<void>? _androidInitialization;

  Future<void> _android() => _androidInitialization ??= GoogleSignIn.instance
      .initialize(serverClientId: androidServerClientId);

  static String nonce() => base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');

  static Never _unconfigured() => throw const GoogleDriveRegistrationRequired();

  Future<Map<String, dynamic>?> authorize() async {
    try {
      if (Platform.isAndroid) {
        if (androidServerClientId.isEmpty) _unconfigured();
        await _android();
        // Clear only the chooser's default identity, never revoke other Drive
        // connections. Later renewal explicitly addresses each stored account.
        await GoogleSignIn.instance.signOut();
        final account = await GoogleSignIn.instance.authenticate();
        final auth = await account.authorizationClient.authorizeScopes([
          googleDriveScope,
        ]);
        return {
          'kind': 'android',
          'account': account.id,
          'email': account.email,
          'access_token': auth.accessToken,
          'expires': 0,
        };
      }
      if (Platform.isIOS) {
        if (iosClientId.isEmpty) _unconfigured();
        final redirect =
            '${iosClientId.split('.').reversed.join('.')}:/oauthredirect';
        final result = await const FlutterAppAuth().authorizeAndExchangeCode(
          AuthorizationTokenRequest(
            iosClientId,
            redirect,
            serviceConfiguration: const AuthorizationServiceConfiguration(
              authorizationEndpoint:
                  'https://accounts.google.com/o/oauth2/v2/auth',
              tokenEndpoint: 'https://oauth2.googleapis.com/token',
            ),
            scopes: [googleDriveScope],
            promptValues: ['consent', 'select_account'],
          ),
        );
        if (result.accessToken == null ||
            result.refreshToken == null ||
            !(result.scopes ?? []).contains(googleDriveScope)) {
          throw const GoogleDriveSetupException.permissions();
        }
        return {
          'kind': 'oauth',
          'client_id': iosClientId,
          'refresh_token': result.refreshToken,
          'access_token': result.accessToken,
          'expires':
              result.accessTokenExpirationDateTime?.millisecondsSinceEpoch ?? 0,
        };
      }
      if (desktopClientId.isEmpty || desktopClientSecret.isEmpty) {
        _unconfigured();
      }
      return await _desktop();
    } on FlutterAppAuthUserCancelledException {
      return null;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      throw const LocationException(LocationFailure.revoked);
    } on FlutterAppAuthPlatformException {
      throw const LocationException(LocationFailure.revoked);
    } on IOException {
      throw const LocationException(LocationFailure.offline);
    }
  }

  Future<Map<String, dynamic>?> _desktop() async {
    final verifier = nonce();
    final state = nonce();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}/oauthredirect';
    final completion = Completer<String?>();
    final listener = server.listen((request) async {
      final query = request.uri.queryParameters;
      if (request.method != 'GET' ||
          request.uri.path != '/oauthredirect' ||
          query['state'] != state) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.text;
      request.response.write(
        'Authorization response received. Return to Shōsai to check whether '
        'the connection completed. You may close this browser tab.',
      );
      await request.response.close();
      if (!completion.isCompleted) {
        completion.complete(
          query['error'] == 'access_denied' ? null : query['code'],
        );
      }
    });
    try {
      final launched = await _launch(
        Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
          'client_id': desktopClientId,
          'redirect_uri': redirect,
          'response_type': 'code',
          'scope': googleDriveScope,
          'state': state,
          'code_challenge_method': 'S256',
          'code_challenge': base64UrlEncode(
            sha256.convert(ascii.encode(verifier)).bytes,
          ).replaceAll('=', ''),
          'access_type': 'offline',
          'prompt': 'consent select_account',
        }),
      );
      if (!launched) throw const LocationException(LocationFailure.offline);
      final code = await completion.future.timeout(const Duration(minutes: 5));
      if (code == null) return null;
      final result = await _token({
        'client_id': desktopClientId,
        'client_secret': desktopClientSecret,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
      });
      if (result['refresh_token'] is! String ||
          !(result['scope'] as String? ?? '')
              .split(' ')
              .contains(googleDriveScope)) {
        throw const GoogleDriveSetupException.permissions();
      }
      return {...result, 'kind': 'oauth', 'client_id': desktopClientId};
    } on TimeoutException {
      return null;
    } finally {
      await listener.cancel();
      await server.close(force: true);
    }
  }

  Future<Map<String, dynamic>> renew(
    Map<String, dynamic> credential, {
    bool force = false,
  }) async {
    if (credential['kind'] == 'android') {
      await _android();
      if (force && credential['access_token'] is String) {
        await GoogleSignInPlatform.instance.clearAuthorizationToken(
          ClearAuthorizationTokenParams(
            accessToken: credential['access_token'] as String,
          ),
        );
      }
      final auth = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: [googleDriveScope],
                userId: credential['account'] as String,
                email: credential['email'] as String,
                promptIfUnauthorized: false,
              ),
            ),
          );
      if (auth == null) throw const LocationException(LocationFailure.revoked);
      return {...credential, 'access_token': auth.accessToken};
    }
    final desktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    if (desktop &&
        (desktopClientId.isEmpty ||
            desktopClientSecret.isEmpty ||
            credential['client_id'] != desktopClientId)) {
      // Never send a distributor's companion parameter for another client ID.
      throw const LocationException(LocationFailure.revoked);
    }
    if (!force &&
        (credential['expires'] as int? ?? 0) >
            DateTime.now()
                .add(const Duration(minutes: 1))
                .millisecondsSinceEpoch) {
      return credential;
    }
    try {
      final result = await _token({
        'client_id': credential['client_id'] as String,
        if (desktop) 'client_secret': desktopClientSecret,
        'refresh_token': credential['refresh_token'] as String,
        'grant_type': 'refresh_token',
      });
      return {...credential, ...result};
    } on GoogleDriveSetupException {
      // Existing connections retain the location failure/isolation contract.
      throw const LocationException(LocationFailure.revoked);
    }
  }

  Future<Map<String, dynamic>> _token(Map<String, String> fields) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final deadline = Timer(
      const Duration(seconds: 30),
      () => client.close(force: true),
    );
    try {
      final request = await client.postUrl(
        Uri.https('oauth2.googleapis.com', '/token'),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(Uri(queryParameters: fields).query);
      final response = await request.close();
      final bytes = await DriveTransport.boundedBytes(response, 64 * 1024);
      if (response.statusCode == 400 || response.statusCode == 401) {
        Object? error;
        Object? description;
        try {
          final value = jsonDecode(utf8.decode(bytes));
          if (value is Map) {
            error = value['error'];
            description = value['error_description'];
          }
        } on FormatException {
          // Malformed error bodies still produce a fixed, safe diagnostic.
        }
        throw GoogleDriveSetupException.tokenRejected(
          error,
          description: description,
        );
      }
      if (response.statusCode != 200) {
        throw const LocationException(LocationFailure.offline);
      }
      final value = (jsonDecode(utf8.decode(bytes)) as Map)
          .cast<String, dynamic>();
      if (value['access_token'] is! String || value['expires_in'] is! int) {
        throw const CoreException.malformed('Invalid Google token response.');
      }
      return {
        ...value,
        'expires': DateTime.now()
            .add(Duration(seconds: value['expires_in'] as int))
            .millisecondsSinceEpoch,
      };
    } on IOException {
      throw const LocationException(LocationFailure.offline);
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}
