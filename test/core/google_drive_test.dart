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
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/library/folders_controller.dart';

/// Real HTTP streaming with only the destination changed to a local Drive
/// fixture. No Google account, registered client or production token is used.
class _NativeHttp extends HttpOverrides {}

class _NativeGoogleAuthorization extends GoogleSignInPlatform {
  String? accessToken = 'native-token';

  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<void> clearAuthorizationToken(
    ClearAuthorizationTokenParams params,
  ) async {}

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async => accessToken == null
      ? null
      : ClientAuthorizationTokenData(accessToken: accessToken!);

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

  for (final (sourceDirectory, localDuplicate) in [
    (null, false),
    ('owned-folder', false),
    (null, true),
  ]) {
    test(
      'Google reconnect preserves the existing ${sourceDirectory ?? 'root'} source and ${localDuplicate ? 'admission-only duplicate' : 'saved books'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'drive-reconnect',
        );
        final database = '${directory.path}/library.sqlite3';
        var store = await Store.open(database);
        final bytes = File(
          'packages/shosai_core/test/fixtures/sample.epub',
        ).readAsBytesSync();
        final credentials = _Credentials();
        var serial = 0;
        var mode = 'initial';
        var revoked = false;
        Completer<void>? authorizationGate;
        Completer<void>? validationStarted;
        Completer<void>? validationGate;
        final provider = GoogleDriveConnectionProvider(
          credentials: credentials,
          authorize: () async {
            await authorizationGate?.future;
            return mode == 'cancel'
                ? null
                : {'access_token': 'account-${serial++}'};
          },
          renew: (value, {bool force = false}) async => value,
        );
        late Library library;
        late LibraryLocations locations;
        late Preferences preferences;
        late LibraryFolders folders;
        void open() {
          library = Library(
            store,
            managedDirectory: '${directory.path}/books',
            inspectors: {BookFormat.epub: const EpubInspector()},
          );
          locations = LibraryLocations(store);
          preferences = Preferences(store);
          folders = LibraryFolders(
            preferences,
            library,
            locations,
            () async => '${directory.path}/stage',
            BookFileCache(store, '${directory.path}/cache'),
            providers: [provider],
          );
        }

        open();
        addTearDown(() async {
          await folders.close();
          await store.close();
          await directory.delete(recursive: true);
        });
        handler = (request) async {
          if (mode == 'close-validation') {
            validationStarted!.complete();
            await validationGate!.future;
          }
          final token = request.headers.value(HttpHeaders.authorizationHeader);
          if (revoked && token == 'Bearer account-0') {
            _json(request, {}, status: 401);
          } else if (mode == 'offline') {
            _json(request, {}, status: 503);
          } else if (mode == 'wrong-account' &&
              request.uri.path != '/drive/v3/files') {
            _json(request, {}, status: 403);
          } else if (mode == 'wrong-account') {
            // Another account's root lists successfully, but owns none of
            // the original source's keys. Listing alone must not adopt it.
            _json(request, {
              'files': [_file('unrelated-book')],
            });
          } else if (request.uri.queryParameters['alt'] == 'media') {
            request.response.add(bytes);
            await request.response.close();
          } else if (request.uri.path == '/drive/v3/files') {
            // The independent source must not list the same opaque files:
            // main now deliberately transfers unchanged admissions when a
            // replacement connection rediscovers a removed source's files.
            final prefix = token == 'Bearer account-1' ? 'other-' : '';
            _json(request, {
              'files': [
                _file('${prefix}book', size: bytes.length),
                if (!localDuplicate) _file('${prefix}unopened'),
              ],
            });
          } else {
            final key = request.uri.path.split('/').last;
            _json(
              request,
              _file(
                key,
                mime: key == 'owned-folder'
                    ? GoogleDriveLocation.folderMime
                    : null,
                size: bytes.length,
              ),
            );
          }
        };
        await HttpOverrides.runZoned(
          () async {
            final previous = (await provider.setup(
              'drive',
            ))!.withDirectory(sourceDirectory, 'Reading');
            final other = (await provider.setup('other'))!;
            await folders.add(previous);
            await folders.add(other);
            final file = (await folders.discover()).firstWhere(
              (file) => file.locationId == 'drive' && file.entry.key == 'book',
            );
            if (localDuplicate) {
              await library.importFile(
                'packages/shosai_core/test/fixtures/sample.epub',
                managed: true,
              );
            }
            final book = await folders.importEntry('drive', file.entry);
            if (!localDuplicate) await folders.setKept(book.id, true);
            final kept = (await library.get(book.id))!.keptOnDevice;
            await Annotations(
              store,
            ).createNote(book.id, const BookAnchor(), 'Keep this note');
            final bookmark = await Bookmarks(
              store,
            ).toggle(book.id, 2, offset: 17, title: 'Keep this bookmark');
            const position = ReadingPosition(unit: 2, offset: 33, zoom: 1.7);
            await ReadingState(store).save(book.id, position, unitCount: 5);
            revoked = true;
            await folders.discover(refresh: true);
            expect(
              (await locations.copies(
                book.contentHash,
              )).map((copy) => copy.failure),
              localDuplicate ? [] : [LocationFailure.revoked],
            );
            final saved = await preferences.get('device.library.folders');
            final oldCredentials = Map.of(credentials.values);
            final catalog = (await locations.catalog())
                .map((file) => (file.locationId, file.entry.key))
                .toList();
            for (final attempt in [
              'cancel',
              'vault',
              'offline',
              'wrong-account',
              'save-failure',
              'generation-failure',
              'close',
              'close-validation',
              'success',
            ]) {
              mode = attempt;
              authorizationGate = attempt == 'close' ? Completer<void>() : null;
              validationStarted = attempt == 'close-validation'
                  ? Completer<void>()
                  : null;
              validationGate = attempt == 'close-validation'
                  ? Completer<void>()
                  : null;
              credentials.writeFailure = attempt == 'vault'
                  ? PlatformException(code: 'locked')
                  : null;
              final controller = FoldersController(
                folders: folders,
                setup: (_) async => null,
                setupGoogleDrive: (id) async {
                  final grant = await folders.setup('google-drive', id);
                  if (grant == null || attempt != 'save-failure') return grant;
                  return LibraryConnection(
                    grant.id,
                    grant.label,
                    grant.provider,
                    {
                      ...grant.configuration,
                      'oversized': 'x' * maxPreferenceValueBytes,
                    },
                  );
                },
                confirmRemoval: (_) async => false,
              )..dispatch(const FoldersStarted());
              await controller.drain();
              if (attempt == 'generation-failure') {
                await store.transaction(
                  (db) => db.execute('''
                  CREATE TEMP TRIGGER reconnect_storage_failure
                  BEFORE UPDATE ON library_locations WHEN OLD.id = 'drive'
                  BEGIN SELECT RAISE(ABORT, 'fixture generation write failure'); END
                '''),
                );
              }
              controller.dispatch(const FoldersSelected('drive'));
              controller.dispatch(const FoldersReconnectRequested());
              if (attempt == 'close') {
                controller.dispose();
                authorizationGate!.complete();
              } else if (attempt == 'close-validation') {
                await validationStarted!.future;
                controller.dispose();
                validationGate!.complete();
              }
              await controller.drain();
              if (attempt == 'generation-failure') {
                await store.transaction(
                  (db) => db.execute('DROP TRIGGER reconnect_storage_failure'),
                );
              }
              if (!attempt.startsWith('close')) {
                if ([
                  'vault',
                  'offline',
                  'wrong-account',
                  'save-failure',
                  'generation-failure',
                ].contains(attempt)) {
                  expect(controller.model.error, isNotNull, reason: attempt);
                } else {
                  expect(controller.model.error, isNull, reason: attempt);
                }
                controller.dispose();
              }
              credentials.writeFailure = null;
              expect((await library.get(book.id))!.keptOnDevice, kept);
              expect(await ReadingState(store).load(book.id), position);
              expect(await Bookmarks(store).list(book.id), [bookmark]);
              expect(
                (await Annotations(store).summary(book.id)).latest,
                'Keep this note',
              );
              expect(
                await folders.withBookFile(
                  book,
                  (path) => File(path).readAsBytes(),
                ),
                bytes,
              );
              expect(
                (await locations.catalog())
                    .map((file) => (file.locationId, file.entry.key))
                    .toList(),
                catalog,
              );
              final grants = await folders.list();
              expect(grants, hasLength(2));
              expect(grants.last.toJson(), other.toJson());
              expect(grants.first.id, previous.id);
              expect(grants.first.directory, previous.directory);
              expect(grants.first.directoryLabel, previous.directoryLabel);
              if (attempt != 'success') {
                expect(
                  await preferences.get('device.library.folders'),
                  saved,
                  reason: attempt,
                );
                expect(credentials.values, oldCredentials, reason: attempt);
                expect(
                  (await locations.copies(
                    book.contentHash,
                  )).map((copy) => copy.failure),
                  localDuplicate ? [] : [LocationFailure.revoked],
                );
              } else {
                expect(
                  grants.first.configuration,
                  isNot(previous.configuration),
                );
                expect(credentials.values, hasLength(2));
                expect(
                  credentials.values.containsKey(
                    previous.configuration['credential'],
                  ),
                  isFalse,
                );
              }
            }
            final adopted = await preferences.get('device.library.folders');
            final superseded = (await provider.setup('drive'))!;
            await expectLater(
              folders.reconnect(previous, superseded),
              throwsA(
                isA<CoreException>().having(
                  (error) => error.kind,
                  'stale authorization',
                  CoreErrorKind.cancelled,
                ),
              ),
            );
            await folders.discard(superseded);
            expect(await preferences.get('device.library.folders'), adopted);
            expect(credentials.values, hasLength(2));
            // Reopen the actual store and rebuild the service, not just the dialog.
            await folders.close();
            await store.close();
            store = await Store.open(database);
            open();
            final grants = await folders.list();
            expect(grants, hasLength(2));
            expect(grants.first.id, 'drive');
            expect(grants.first.directory, sourceDirectory);
            expect(
              (await folders.discover(refresh: true))
                  .where((file) => file.locationId == 'drive')
                  .map((file) => file.entry.key),
              localDuplicate ? [] : ['unopened'],
            );
            expect(await ReadingState(store).load(book.id), position);
            expect(await Bookmarks(store).list(book.id), [bookmark]);
            expect(
              (await Annotations(store).summary(book.id)).latest,
              'Keep this note',
            );
            expect(
              await folders.withBookFile(
                book,
                (path) => File(path).readAsBytes(),
              ),
              bytes,
            );
            Future<Map<String, List<List<Object?>>>> snapshot() => store.read(
              (db) => {
                for (final table in db.select(
                  "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                ))
                  table['name'] as String: [
                    for (final row in db.select(
                      'SELECT * FROM "${table['name']}"',
                    ))
                      row.values.toList(),
                  ],
              },
            );
            for (final kept in [true, false]) {
              if (!localDuplicate) await folders.setKept(book.id, kept);
              if (!kept) {
                mode = 'offline';
                await folders.discover(refresh: true);
                mode = 'success';
              }
              final before = await snapshot();
              expect(await folders.revalidate('drive'), (
                verified: localDuplicate ? 0 : 1,
                unavailable: 0,
              ));
              final after = await snapshot();
              expect(after.remove('book_locators'), [
                for (final row in before.remove('book_locators')!)
                  [...row.take(3), row[1] == 'drive' ? null : row[3]],
              ]);
              expect(
                after,
                before,
                reason: 'only verified locator flags may change',
              );
              expect(
                await folders.withBookFile(
                  book,
                  (path) => File(path).readAsBytes(),
                ),
                bytes,
              );
              expect(await ReadingState(store).load(book.id), position);
              expect(await Bookmarks(store).list(book.id), [bookmark]);
              expect(
                (await Annotations(store).summary(book.id)).latest,
                'Keep this note',
              );
            }
          },
          createHttpClient: (context) =>
              _RedirectClient(native.createHttpClient(context), server.port),
        );
      },
    );
  }

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
    'Android Drive retries offline in the same service and renews only after rejection',
    () async {
      final directory = await Directory.systemTemp.createTemp('drive-recovery');
      final store = await Store.open('${directory.path}/library.sqlite3');
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final original = GoogleSignInPlatform.instance;
      final platform = _NativeGoogleAuthorization()
        ..accessToken = 'existing-token';
      GoogleSignInPlatform.instance = platform;
      addTearDown(() => GoogleSignInPlatform.instance = original);
      final oauth = GoogleDriveAuthorization(
        androidServerClientId: 'native-audience',
      );
      final provider = GoogleDriveConnectionProvider(
        authorization: oauth,
        credentials: _Credentials(),
        authorize: () async => {
          'kind': 'android',
          'account': 'native-account',
          'email': 'fixture@example.invalid',
          'access_token': 'existing-token',
        },
      );
      final folders = LibraryFolders(
        Preferences(store),
        Library(store, managedDirectory: '${directory.path}/books'),
        LibraryLocations(store),
        () async => '${directory.path}/stage',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      final grant = (await provider.setup('drive'))!;
      var listedKey = 'before';
      var rejectExisting = false;
      handler = (request) async {
        if (rejectExisting &&
            request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer existing-token') {
          _json(request, {}, status: 401);
        } else if (request.uri.path == '/drive/v3/files') {
          _json(request, {
            'files': [_file(listedKey)],
          });
        } else {
          _json(request, _file('book'));
        }
      };
      var port = server.port;
      await HttpOverrides.runZoned(
        () async {
          await folders.add(grant);
          expect((await folders.discover()).single.entry.key, 'before');

          // No HTTP service and no silent SDK authorization are available.
          // The stored bearer must reach the transport, which reports offline,
          // rather than permanently invalidating the location generation.
          platform.accessToken = null;
          await server.close(force: true);
          final offline = (await folders.discover(refresh: true)).single;
          expect(offline.entry.key, 'before');
          expect(offline.failure, LocationFailure.offline);
          expect(folders.scanWarnings, ['Google Drive']);

          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          port = server.port;
          server.listen((request) => unawaited(handler(request)));
          listedKey = 'after';
          // The same service must publish fresh metadata, not hide the warning
          // while serving its old catalog, and must not need reconnection.
          final recovered = (await folders.discover(refresh: true)).single;
          expect(recovered.entry.key, 'after');
          expect(recovered.failure, isNull);
          expect(folders.scanWarnings, isEmpty);

          // A real 401 still requires native authorization. Missing permission
          // remains revoked; a replacement token retries the actual request.
          rejectExisting = true;
          final location = await provider.open(grant);
          await expectLater(
            location.stat('book'),
            throwsA(
              isA<LocationException>().having(
                (error) => error.failure,
                'rejected access needs authorization',
                LocationFailure.revoked,
              ),
            ),
          );
          platform.accessToken = 'renewed-native-token';
          expect((await location.stat('book')).key, 'book');
        },
        createHttpClient: (context) =>
            _RedirectClient(native.createHttpClient(context), port),
      );
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
