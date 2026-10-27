import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/connection_credentials.dart';
import 'package:shosai_flutter/core/google_drive_authorization.dart';
import 'package:shosai_flutter/core/google_drive_connection.dart';
import 'package:shosai_flutter/core/google_drive_location.dart';
import 'package:shosai_flutter/core/library_folders.dart';

/// Real HTTP streaming with only the destination changed to a local Drive
/// fixture. No Google account, registered client or production token is used.
class _NativeHttp extends HttpOverrides {}

class _NativeGoogleAuthorization extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async => const ClientAuthorizationTokenData(accessToken: 'native-token');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RedirectClient extends Fake implements HttpClient {
  _RedirectClient(this.client, this.port);
  final HttpClient client;
  final int port;
  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => client.openUrl(
    method,
    Uri.http('127.0.0.1:$port', url.path, url.queryParameters),
  );
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  void close({bool force = false}) => client.close(force: force);
}

class _Credentials implements ConnectionCredentialStore {
  final values = <String, String>{};
  final readFailures = <String, Object>{};
  final writeFailures = <String, Object>{};
  Object? writeFailure;
  @override
  Future<String?> read(String key) async {
    if (readFailures[key] case final failure?) throw failure;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (writeFailure case final failure?) throw failure;
    if (writeFailures[key] case final failure?) throw failure;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Map<String, Object> _file(String id, {String? mime, int size = 11}) => {
  'id': id,
  'name': '$id.epub',
  'mimeType': mime ?? 'application/epub+zip',
  'size': '$size',
  'version': '42',
  'ownedByMe': true,
  'trashed': false,
};

void _json(HttpRequest request, Object value, {int status = 200}) {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(value));
  unawaited(request.response.close());
}

void main() {
  late HttpServer server;
  late GoogleDriveLocation location;
  late Future<void> Function(HttpRequest) handler;
  late List<bool> renewals;
  final native = _NativeHttp();

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    renewals = [];
    location = GoogleDriveLocation(
      'drive',
      DriveTransport(
        ({bool renew = false}) async {
          renewals.add(renew);
          return renew ? 'renewed' : 'initial';
        },
        client: () =>
            _RedirectClient(native.createHttpClient(null), server.port),
      ),
    );
    server.listen((request) => unawaited(handler(request)));
  });
  tearDown(() => server.close(force: true));

  test(
    'metadata pages preserve opaque IDs and skip Workspace/shortcuts',
    () async {
      var media = 0;
      handler = (request) async {
        if (request.uri.queryParameters['alt'] == 'media') media++;
        if (request.uri.path.endsWith('/books')) {
          _json(request, _file('books', mime: GoogleDriveLocation.folderMime));
        } else {
          expect(
            request.uri.queryParameters['q'],
            contains("'books' in parents"),
          );
          expect(request.uri.queryParameters['q'], contains("'me' in owners"));
          expect(request.uri.queryParameters['pageSize'], '3');
          if (request.uri.queryParameters['pageToken'] == null) {
            _json(request, {
              'files': [
                _file('A'),
                _file('folder', mime: GoogleDriveLocation.folderMime),
                _file('shortcut', mime: 'application/vnd.google-apps.shortcut'),
              ],
              'nextPageToken': 'opaque+/=',
            });
          } else {
            expect(request.uri.queryParameters['pageToken'], 'opaque+/=');
            _json(request, {
              'files': [
                _file('B'),
                _file('doc', mime: 'application/vnd.google-apps.document'),
              ],
            });
          }
        }
      };
      final page = await location.list(directory: 'books', limit: 3);
      expect(page.entries.map((e) => e.key), ['A', 'folder']);
      expect(page.entries.first.revision, '42');
      expect(page.entries.last.isDirectory, true);
      final next = await location.list(
        directory: 'books',
        cursor: page.nextCursor,
        limit: 3,
      );
      expect(next.entries.single.key, 'B');
      expect(media, 0);
    },
  );

  test(
    'whole and exclusive-end ranges stream bytes; EOF never fetches media',
    () async {
      var media = 0;
      handler = (request) async {
        if (request.uri.queryParameters['alt'] != 'media') {
          _json(request, _file('book'));
        } else {
          media++;
          final range = request.headers.value('range');
          if (range == null) {
            request.response.add(utf8.encode('abcdefghijk'));
          } else {
            expect(range, 'bytes=3-7');
            request.response.statusCode = 206;
            request.response.headers.set('content-range', 'bytes 3-7/11');
            request.response.add(utf8.encode('defgh'));
          }
          await request.response.close();
        }
      };
      expect(await utf8.decodeStream(location.read('book')), 'abcdefghijk');
      expect(
        await utf8.decodeStream(location.read('book', start: 3, end: 8)),
        'defgh',
      );
      expect(await location.read('book', start: 11).toList(), isEmpty);
      expect(await location.read('book', start: 4, end: 4).toList(), isEmpty);
      expect(media, 2);
      await expectLater(
        location.read('book', start: -1).drain<void>(),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.invalidRequest,
          ),
        ),
      );
    },
  );

  test('a server ignoring Range cannot cause a whole-file fallback', () async {
    handler = (request) async {
      if (request.uri.queryParameters['alt'] == 'media') {
        request.response.write('must not be returned');
        await request.response.close();
      } else {
        _json(request, _file('book'));
      }
    };
    await expectLater(
      location.read('book', start: 2).drain<void>(),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.unsupported,
        ),
      ),
    );
  });

  test(
    '401 renews once, while missing, revoked and rate-limit stay distinct',
    () async {
      handler = (request) async {
        if (request.headers.value('authorization') == 'Bearer initial') {
          _json(request, {}, status: 401);
        } else {
          _json(request, _file('book'));
        }
      };
      expect((await location.stat('book')).size, 11);
      expect(renewals, [false, true]);
      for (final pair in [
        (404, LocationFailure.missing),
        (401, LocationFailure.revoked),
        (403, LocationFailure.revoked),
        (429, LocationFailure.offline),
        (503, LocationFailure.offline),
      ]) {
        handler = (request) async => _json(request, {}, status: pair.$1);
        await expectLater(
          location.stat('book'),
          throwsA(
            isA<LocationException>().having(
              (e) => e.failure,
              'failure',
              pair.$2,
            ),
          ),
        );
      }
      handler = (request) async => _json(request, {
        'error': {
          'errors': [
            {'reason': 'rateLimitExceeded'},
          ],
        },
      }, status: 403);
      await expectLater(
        location.stat('book'),
        throwsA(
          isA<LocationException>().having(
            (e) => e.failure,
            'failure',
            LocationFailure.offline,
          ),
        ),
      );
    },
  );

  test('cancellation interrupts a stalled network response', () async {
    final entered = Completer<void>();
    handler = (request) async {
      entered.complete();
    };
    final cancellation = CancellationToken();
    final result = location.stat('book', cancellation: cancellation);
    final expectation = expectLater(
      result,
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.cancelled,
        ),
      ),
    );
    await entered.future;
    cancellation.cancel();
    await expectation.timeout(const Duration(seconds: 2));
  });

  for (final size in [262144, 524305]) {
    test(
      'resumable create/replace writes $size bytes without premature success',
      () async {
        final uploaded = <int>[];
        var creating = true;
        var puts = 0;
        handler = (request) async {
          if (request.uri.path == '/drive/v3/files') {
            _json(request, {
              'files': creating ? [] : [_file('existing')],
            });
          } else if (request.uri.path.startsWith('/upload/')) {
            expect(request.method, creating ? 'POST' : 'PATCH');
            if (!creating) expect(request.uri.path, endsWith('/existing'));
            await request.drain<void>();
            request.response.headers.set(
              'location',
              'https://www.googleapis.com/session',
            );
            await request.response.close();
          } else {
            puts++;
            final chunk = await request.fold<List<int>>(
              [],
              (a, b) => a..addAll(b),
            );
            expect(chunk.length, lessThanOrEqualTo(262144));
            final offset = uploaded.length;
            uploaded.addAll(chunk);
            final finalChunk = uploaded.length == size;
            expect(
              request.headers.value('content-range'),
              'bytes $offset-${uploaded.length - 1}/${finalChunk ? size : '*'}',
            );
            if (finalChunk) {
              _json(request, _file('uploaded', size: size));
            } else {
              request.response.statusCode = 308;
              request.response.headers.set(
                'range',
                'bytes=0-${uploaded.length - 1}',
              );
              await request.response.close();
            }
          }
        };
        final input = List.generate(size, (i) => (i * 17 + 5) % 251);
        for (final create in [true, false]) {
          creating = create;
          uploaded.clear();
          final entry = await location.write(
            'book.epub',
            Stream.fromIterable([input.sublist(0, 31), input.sublist(31)]),
          );
          expect(entry.key, 'uploaded');
          expect(uploaded, input);
        }
        expect(puts, size == 262144 ? 2 : 6);
      },
    );
  }

  test(
    'PKCE desktop authorization validates state and handles denial without a token',
    () async {
      final oauth = GoogleDriveAuthorization(
        desktopClientId: 'fixture-only',
        desktopClientSecret: 'fixture-companion',
        launch: (authorization) async {
          expect(authorization.host, 'accounts.google.com');
          final query = authorization.queryParameters;
          expect(query['code_challenge_method'], 'S256');
          expect(base64Url.decode('${query['code_challenge']}=').length, 32);
          expect(query.containsKey('client_secret'), false);
          final redirect = Uri.parse(query['redirect_uri']!);
          expect(redirect.host, '127.0.0.1');
          final client = native.createHttpClient(null);
          try {
            final bad = await (await client.getUrl(
              redirect.replace(
                queryParameters: {'state': 'wrong', 'error': 'access_denied'},
              ),
            )).close();
            expect(bad.statusCode, 400);
            await bad.drain<void>();
            final good = await (await client.getUrl(
              redirect.replace(
                queryParameters: {
                  'state': query['state']!,
                  'error': 'access_denied',
                },
              ),
            )).close();
            await good.drain<void>();
          } finally {
            client.close(force: true);
          }
          return true;
        },
      );
      expect(await oauth.authorize(), isNull);
    },
  );

  test(
    'credential generations isolate release and prevent late renewal resurrection',
    () async {
      final credentials = _Credentials();
      final renewing = Completer<void>();
      final proceed = Completer<void>();
      final provider = GoogleDriveConnectionProvider(
        credentials: credentials,
        authorize: () async => {
          'refresh_token': 'fixture-refresh',
          'access_token': 'fixture-access',
        },
        renew: (value, {bool force = false}) async {
          renewing.complete();
          await proceed.future;
          return value;
        },
      );
      final first = (await provider.setup('same'))!;
      final second = (await provider.setup('same'))!;
      expect(
        first.configuration['credential'],
        isNot(second.configuration['credential']),
      );
      expect(jsonEncode(first.toJson()), isNot(contains('fixture-refresh')));
      final opened = await provider.open(first);
      final result = HttpOverrides.runZoned(
        () => opened.stat('book'),
        createHttpClient: (context) =>
            _RedirectClient(native.createHttpClient(context), server.port),
      );
      final expectation = expectLater(
        result,
        throwsA(
          isA<LocationException>().having(
            (e) => e.failure,
            'failure',
            LocationFailure.revoked,
          ),
        ),
      );
      await renewing.future;
      await provider.release(first);
      proceed.complete();
      await expectation;
      expect(
        credentials.values.containsKey(first.configuration['credential']),
        false,
      );
      expect(
        credentials.values.containsKey(second.configuration['credential']),
        true,
      );
    },
  );

  test(
    'desktop code exchange and refresh use matching registration with PKCE',
    () async {
      late String challenge;
      var calls = 0;
      String? rejection;
      var description = 'fixture-private-code-and-token';
      handler = (request) async {
        expect(request.uri.path, '/token');
        final fields = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        expect(fields['client_id'], 'fixture-only');
        expect(fields['client_secret'], 'fixture-companion');
        if (rejection != null) {
          _json(request, {
            'error': rejection,
            'error_description': description,
          }, status: 400);
          return;
        }
        if (calls++ == 0) {
          expect(fields['grant_type'], 'authorization_code');
          expect(
            base64UrlEncode(
              sha256.convert(ascii.encode(fields['code_verifier']!)).bytes,
            ).replaceAll('=', ''),
            challenge,
          );
          expect(fields['code'], 'fixture-code');
          _json(request, {
            'access_token': 'first-token',
            'refresh_token': 'refresh-only',
            'expires_in': 1,
            'scope': googleDriveScope,
          });
        } else {
          expect(fields['grant_type'], 'refresh_token');
          expect(fields['refresh_token'], 'refresh-only');
          _json(request, {'access_token': 'next-token', 'expires_in': 3600});
        }
      };
      final oauth = GoogleDriveAuthorization(
        desktopClientId: 'fixture-only',
        desktopClientSecret: 'fixture-companion',
        launch: (uri) async {
          expect(uri.queryParameters.containsKey('client_secret'), false);
          challenge = uri.queryParameters['code_challenge']!;
          final client = native.createHttpClient(null);
          try {
            final response = await (await client.getUrl(
              Uri.parse(uri.queryParameters['redirect_uri']!).replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'fixture-code',
                },
              ),
            )).close();
            await response.drain<void>();
          } finally {
            client.close(force: true);
          }
          return true;
        },
      );
      await HttpOverrides.runZoned(
        () async {
          final credential = (await oauth.authorize())!;
          expect(credential.containsKey('client_secret'), false);
          final next = await oauth.renew(credential, force: true);
          expect(next['access_token'], 'next-token');
          expect(next['refresh_token'], 'refresh-only');
          expect(next.containsKey('client_secret'), false);
          for (final clientId in ['other-desktop', 'mobile-client']) {
            for (final force in [false, true]) {
              await expectLater(
                oauth.renew({
                  ...credential,
                  'client_id': clientId,
                  'expires': DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch,
                }, force: force),
                throwsA(
                  isA<LocationException>().having(
                    (e) => e.failure,
                    'registration mismatch even with unexpired access',
                    LocationFailure.revoked,
                  ),
                ),
              );
            }
          }
          for (final (error, detail, expected) in [
            ('invalid_client', 'fixture-private-code', 'invalid_client'),
            ('fixture-private-code', 'fixture-private-token', 'unknown_error'),
            (
              'invalid_request',
              'client_secret is missing.',
              'missing_client_secret',
            ),
            (
              'invalid_request',
              'client_secret is missing. fixture-private-code',
              'invalid_request',
            ),
          ]) {
            rejection = error;
            description = detail;
            await expectLater(
              oauth.authorize(),
              throwsA(
                isA<GoogleDriveSetupException>()
                    .having(
                      (e) => e.stage,
                      'stage',
                      GoogleDriveSetupStage.tokenExchange,
                    )
                    .having((e) => e.oauthError, 'safe OAuth code', expected),
              ),
            );
          }
          await expectLater(
            oauth.renew(credential, force: true),
            throwsA(
              isA<LocationException>().having(
                (e) => e.failure,
                'renewal remains isolated',
                LocationFailure.revoked,
              ),
            ),
          );
        },
        createHttpClient: (context) =>
            _RedirectClient(native.createHttpClient(context), server.port),
      );
      expect(calls, 2);
    },
  );

  test('desktop setup requires complete distributor configuration', () async {
    for (final (id, companion) in [('fixture-only', ''), ('', 'companion')]) {
      final oauth = GoogleDriveAuthorization(
        desktopClientId: id,
        desktopClientSecret: companion,
        launch: (_) async => fail('Incomplete registration opened the browser'),
      );
      await expectLater(
        oauth.authorize(),
        throwsA(isA<GoogleDriveRegistrationRequired>()),
      );
      await expectLater(
        oauth.renew({
          'kind': 'oauth',
          'client_id': 'fixture-only',
          'refresh_token': 'fixture-refresh',
          'access_token': 'fixture-access',
          'expires': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        }),
        throwsA(isA<LocationException>()),
      );
    }
  });

  test(
    'native Android renewal never uses desktop registration or HTTP',
    () async {
      final original = GoogleSignInPlatform.instance;
      GoogleSignInPlatform.instance = _NativeGoogleAuthorization();
      addTearDown(() => GoogleSignInPlatform.instance = original);
      final oauth = GoogleDriveAuthorization(
        desktopClientId: 'unrelated-desktop',
        desktopClientSecret: 'desktop-companion',
        androidServerClientId: 'native-audience',
      );
      final renewed = await HttpOverrides.runZoned(
        () => oauth.renew({
          'kind': 'android',
          'account': 'native-account',
          'email': 'fixture@example.invalid',
        }),
        createHttpClient: (_) => fail('Native renewal attempted token HTTP'),
      );
      expect(renewed['access_token'], 'native-token');
      expect(renewed.containsKey('client_secret'), false);
    },
  );

  test(
    'setup distinguishes secure-store failure from authorization rejection',
    () async {
      final credentials = _Credentials()
        ..writeFailure = PlatformException(
          code: 'locked',
          message: 'private-detail',
        );
      final provider = GoogleDriveConnectionProvider(
        credentials: credentials,
        authorize: () async => {'access_token': 'fixture-access'},
      );
      await expectLater(
        provider.setup('new'),
        throwsA(
          isA<GoogleDriveSetupException>().having(
            (e) => e.stage,
            'stage',
            GoogleDriveSetupStage.credentialStorage,
          ),
        ),
      );
      expect(credentials.values, isEmpty);
    },
  );

  test(
    'vault/GIS/timeout failures isolate discovery, copies recover, Keep stays offline',
    () async {
      final directory = await Directory.systemTemp.createTemp('drive-seams');
      final store = await Store.open('${directory.path}/library.sqlite3');
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final bytes = File(
        'packages/shosai_core/test/fixtures/sample.epub',
      ).readAsBytesSync();
      handler = (request) async {
        if (request.uri.queryParameters['alt'] == 'media') {
          request.response.add(bytes);
          await request.response.close();
        } else if (request.uri.path == '/drive/v3/files') {
          _json(request, {
            'files': [_file('book', size: bytes.length)],
          });
        } else {
          _json(request, _file('book', size: bytes.length));
        }
      };
      final credentials = _Credentials();
      Object? renewalFailure;
      var account = 0;
      final provider = GoogleDriveConnectionProvider(
        credentials: credentials,
        authorize: () async => {'access_token': 'account-${account++}'},
        renew: (credential, {bool force = false}) async {
          if (credential['access_token'] == 'account-0' &&
              renewalFailure != null) {
            throw renewalFailure!;
          }
          return credential;
        },
      );
      final library = Library(
        store,
        managedDirectory: '${directory.path}/books',
        inspectors: {BookFormat.epub: const EpubInspector()},
      );
      final cache = BookFileCache(store, '${directory.path}/cache');
      final preferences = Preferences(store);
      final locations = LibraryLocations(store);
      LibraryFolders open() => LibraryFolders(
        preferences,
        library,
        locations,
        () async => '${directory.path}/stage',
        cache,
        providers: [provider],
      );
      await HttpOverrides.runZoned(
        () async {
          final folders = open();
          final first = (await provider.setup('one'))!;
          final second = (await provider.setup('two'))!;
          final key = first.configuration['credential']!;
          await folders.add(first);
          await folders.add(second);
          final initial = await folders.discover();
          expect(initial.length, 2);
          final saved = credentials.values[key]!;
          for (final failure in [
            'read',
            'write',
            'malformed',
            'gis',
            'timeout',
          ]) {
            credentials.values[key] = saved;
            credentials.readFailures.clear();
            credentials.writeFailures.clear();
            renewalFailure = null;
            switch (failure) {
              case 'read':
                credentials.readFailures[key] = PlatformException(
                  code: 'locked',
                );
              case 'write':
                credentials.writeFailures[key] = PlatformException(
                  code: 'locked',
                );
              case 'malformed':
                credentials.values[key] = 'not-json';
              case 'gis':
                renewalFailure = const GoogleSignInException(
                  code: GoogleSignInExceptionCode.unknownError,
                );
              case 'timeout':
                renewalFailure = TimeoutException('fixture');
            }
            final catalog = await folders.discover(refresh: true);
            expect(catalog.length, 2, reason: failure);
            expect(
              catalog.singleWhere((e) => e.locationId == 'two').failure,
              isNull,
            );
            expect(
              catalog.singleWhere((e) => e.locationId == 'one').failure,
              failure == 'malformed'
                  ? LocationFailure.revoked
                  : LocationFailure.offline,
            );
            expect(folders.scanWarnings.length, 1);
          }
          credentials.values[key] = saved;
          credentials.readFailures.clear();
          credentials.writeFailures.clear();
          renewalFailure = null;
          // Revocation invalidates the core grant generation. Explicitly
          // reconnect after restoring authorization; retry alone cannot undo it.
          await folders.add(first);
          expect(
            (await folders.discover(
              refresh: true,
            )).every((e) => e.failure == null),
            true,
          );
          final book = await folders.importEntry('one', initial.first.entry);
          final other = await folders.importEntry('two', initial.last.entry);
          expect(
            other.id,
            book.id,
            reason: 'provider keys never become content identity',
          );
          await cache.discardUnkept(book.contentHash, book.format);
          credentials.readFailures[key] = PlatformException(code: 'locked');
          expect(
            await folders.withBookFile(
              book,
              (path) => File(path).readAsBytes(),
            ),
            bytes,
          );
          await folders.setKept(book.id, true);
          credentials.readFailures[second.configuration['credential']!] =
              PlatformException(code: 'locked');
          expect(
            await open().withBookFile(book, (path) => File(path).readAsBytes()),
            bytes,
          );
          expect((await library.get(book.id))!.keptOnDevice, true);
        },
        createHttpClient: (context) =>
            _RedirectClient(native.createHttpClient(context), server.port),
      );
    },
  );
}
