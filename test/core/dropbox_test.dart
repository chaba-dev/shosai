import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/connection_credentials.dart';
import 'package:shosai_flutter/core/dropbox_authorization.dart';
import 'package:shosai_flutter/core/dropbox_connection.dart';
import 'package:shosai_flutter/core/dropbox_location.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';

// The binding supplies the native-channel seam; HTTP still uses real sockets
// against the local protocol fixture, not Flutter's blanket HTTP-400 stub.
class _NativeHttp extends HttpOverrides {}

final class _Credentials implements ConnectionCredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// HTTP protocol fixture, not a Dropbox account. It exercises the real socket,
/// encoding, streaming and renewal paths without external credentials.
final class _Dropbox {
  late HttpServer server;
  Uri get root => Uri.parse('http://127.0.0.1:${server.port}/');
  final credentials = _Credentials();
  final calls = <String>[];
  final tokenForms = <Map<String, String>>[];
  List<int> book = [3, 11, 29, 47, 81, 109, 211];
  final uploaded = BytesBuilder();
  Map<String, dynamic>? commit;
  bool rejectAccess = false;
  bool revoked = false;
  bool offline = false;
  bool missing = false;
  bool ignoreRange = false;
  bool shortRange = false;
  int expiresIn = 14400;
  Completer<void>? tokenWait;
  Completer<void>? tokenArrived;
  Completer<void>? wait;
  Completer<void>? arrived;
  String? challenge;
  List<List<Map<String, dynamic>>>? recursivePages;
  List<List<Map<String, dynamic>>> _pages = [];
  bool repeatCursor = false;

  Map<String, dynamic> get folder => {
    '.tag': 'folder',
    'id': 'id:folder',
    'name': 'Books',
    'path_lower': '/books',
  };

  Map<String, dynamic> recursivePage(int index) => {
    'entries': _pages[index],
    'has_more': index + 1 < _pages.length,
    'cursor': 'recursive-${repeatCursor ? 1 : index + 1}',
  };

  Map<String, dynamic> get entry => {
    '.tag': 'file',
    'id': 'id:book',
    'name': 'Book.epub',
    'path_lower': '/books/book.epub',
    'size': book.length,
    'rev': 'r1',
  };

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      calls.add(request.uri.path);
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      if (request.uri.path == '/oauth2/token') {
        final form = Uri.splitQueryString(utf8.decode(body));
        tokenForms.add(form);
        if (tokenArrived?.isCompleted == false) tokenArrived!.complete();
        await tokenWait?.future;
        if (form['grant_type'] == 'authorization_code') {
          expect(form['code'], 'test-code');
          expect(
            base64Url
                .encode(
                  sha256.convert(ascii.encode(form['code_verifier']!)).bytes,
                )
                .replaceAll('=', ''),
            challenge,
          );
          expect(form.containsKey('client_secret'), false);
          expect(form.containsKey('redirect_uri'), false);
        }
        if (revoked) {
          request.response.statusCode = 400;
          request.response.write('{"error":"invalid_grant"}');
        } else {
          request.response.write(
            jsonEncode({
              'access_token': 'access-${tokenForms.length}',
              'expires_in': expiresIn,
              if (form['grant_type'] == 'authorization_code')
                'refresh_token': 'refresh-${tokenForms.length}',
            }),
          );
        }
      } else if (offline) {
        request.response.statusCode = 503;
      } else if (rejectAccess || revoked) {
        rejectAccess = false;
        request.response.statusCode = 401;
      } else if (missing) {
        request.response.statusCode = 409;
        request.response.write(
          '{"error":{".tag":"path","path":{".tag":"not_found"}}}',
        );
      } else {
        final args =
            jsonDecode(
                  request.headers.value('Dropbox-API-Arg') ?? utf8.decode(body),
                )
                as Map;
        // Model an App folder token: paths are relative to its dedicated root,
        // and account paths/IDs outside it cannot be resolved. This fixture is
        // not evidence of the real provider's permission enforcement.
        expect(request.headers.value('Dropbox-API-Path-Root'), null);
        final path = args['path'];
        final allowed = request.uri.path == '/files/list_folder'
            ? const ['', 'id:folder']
            : const ['id:book', 'id:folder', '/Book.epub'];
        if (path != null && !allowed.contains(path)) {
          request.response.statusCode = 409;
          request.response.write(
            '{"error":{".tag":"path","path":{".tag":"not_found"}}}',
          );
          await request.response.close();
          return;
        }
        switch (request.uri.path) {
          case '/files/list_folder':
            if (args['recursive'] == true) {
              expect(args['limit'], 2000);
              _pages =
                  recursivePages ??
                  (args['path'] == 'id:folder'
                      ? [
                          [entry],
                        ]
                      : [
                          [folder],
                          [entry],
                        ]);
              request.response.write(jsonEncode(recursivePage(0)));
              break;
            }
            expect(args['recursive'], false);
            request.response.write(
              jsonEncode({
                'entries': args['path'] == 'id:folder'
                    ? [entry]
                    : [
                        {'.tag': 'folder', 'id': 'id:folder', 'name': 'Books'},
                      ],
                'has_more': args['path'] == '',
                'cursor': args['path'] == '' ? 'page-2' : 'end',
              }),
            );
          case '/files/list_folder/continue':
            if ((args['cursor'] as String).startsWith('recursive-')) {
              request.response.write(
                jsonEncode(
                  recursivePage(
                    int.parse((args['cursor'] as String).split('-').last),
                  ),
                ),
              );
              break;
            }
            expect(args['cursor'], 'page-2');
            request.response.write(
              jsonEncode({
                'entries': [entry],
                'has_more': false,
                'cursor': 'end',
              }),
            );
          case '/files/get_metadata':
            request.response.write(
              jsonEncode(path == 'id:folder' ? folder : entry),
            );
          case '/files/download':
            if (arrived?.isCompleted == false) arrived!.complete();
            await wait?.future;
            final range = request.headers.value('range');
            if (range == null || ignoreRange) {
              request.response.add(book);
            } else {
              final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
              final start = int.parse(match[1]!);
              final end = shortRange ? start + 1 : int.parse(match[2]!) + 1;
              request.response.statusCode = 206;
              request.response.headers.set(
                'content-range',
                'bytes $start-${end - 1}/${book.length}',
              );
              request.response.add(book.sublist(start, end));
            }
          case '/files/upload_session/start':
            uploaded.clear();
            request.response.write('{"session_id":"upload-1"}');
          case '/files/upload_session/append_v2':
            expect((args['cursor'] as Map)['offset'], uploaded.length);
            expect(body.length, lessThanOrEqualTo(4 * 1024 * 1024));
            uploaded.add(body);
            request.response.write('null');
          case '/files/upload_session/finish':
            expect((args['cursor'] as Map)['offset'], uploaded.length);
            commit = (args['commit'] as Map).cast<String, dynamic>();
            uploaded.add(body);
            request.response.write(jsonEncode(entry));
          default:
            fail('Unexpected route: ${request.uri.path}');
        }
      }
      await request.response.close();
    });
  }

  DropboxConnectionProvider provider() => DropboxConnectionProvider(
    credentials: credentials,
    clientId: 'fixture-app-key',
    tokenEndpoint: root.resolve('oauth2/token'),
    api: root,
    content: root,
    authorize: (uri) async {
      expect(uri.host, 'www.dropbox.com');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['token_access_type'], 'offline');
      challenge = uri.queryParameters['code_challenge'];
      return 'test-code';
    },
  );

  Future<void> close() async {
    if (wait?.isCompleted == false) wait!.complete();
    if (tokenWait?.isCompleted == false) tokenWait!.complete();
    await server.close(force: true);
  }
}

Matcher failure(LocationFailure value) =>
    isA<LocationException>().having((e) => e.failure, 'failure', value);
Matcher cancelled = isA<CoreException>().having(
  (e) => e.kind,
  'kind',
  CoreErrorKind.cancelled,
);
Future<List<int>> readAll(Stream<List<int>> stream) =>
    stream.fold<List<int>>([], (a, b) => a..addAll(b));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _NativeHttp();
  late _Dropbox fixture;
  setUp(() async {
    fixture = _Dropbox();
    await fixture.start();
  });
  tearDown(() => fixture.close());

  test(
    'native handshake uses isolated vault entries and existing renewal',
    () async {
      const channel = MethodChannel('dev.shosai/dropbox_authorization');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var authorizations = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'authorize');
        expect(call.arguments, {'clientId': 'fixture-native-key'});
        authorizations++;
        return {
          'access_token': 'native-access-$authorizations',
          'refresh_token': 'native-refresh-$authorizations',
          'expires_in': 14400,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final provider = DropboxConnectionProvider(
        credentials: fixture.credentials,
        clientId: 'fixture-native-key',
        authorizeNative: const DropboxAuthorization().authorize,
        authorize: (_) =>
            throw StateError('Mobile must not request code entry'),
        tokenEndpoint: fixture.root.resolve('oauth2/token'),
        api: fixture.root,
        content: fixture.root,
      );
      final first = (await provider.setup('one'))!;
      final second = (await provider.setup('two'))!;
      expect(fixture.tokenForms, isEmpty); // SDK already exchanged the code.
      expect(fixture.credentials.values.values.toSet(), {
        'native-refresh-1',
        'native-refresh-2',
      });
      expect(jsonEncode(first.toJson()), isNot(contains('native-refresh')));
      expect(jsonEncode(first.toJson()), isNot(contains('native-access')));
      final reopened = DropboxConnectionProvider(
        credentials: fixture.credentials,
        clientId: '', // Persisted mobile grants also renew without new setup.
        tokenEndpoint: fixture.root.resolve('oauth2/token'),
        api: fixture.root,
      );
      expect((await (await reopened.open(first)).stat('id:book')).size, 7);
      expect(fixture.tokenForms.single, {
        'client_id': 'fixture-native-key',
        'grant_type': 'refresh_token',
        'refresh_token': 'native-refresh-1',
      });
      await reopened.release(first);
      expect(fixture.credentials.values.values.toList(), ['native-refresh-2']);
      expect((await (await provider.open(second)).stat('id:book')).size, 7);
    },
  );

  test(
    'native cancel, incomplete grant and safe errors never persist access',
    () async {
      const channel = MethodChannel('dev.shosai/dropbox_authorization');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Object? response;
      messenger.setMockMethodCallHandler(channel, (_) async {
        if (response is PlatformException) throw response;
        return response;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final provider = DropboxConnectionProvider(
        credentials: fixture.credentials,
        clientId: 'fixture-native-key',
        authorizeNative: const DropboxAuthorization().authorize,
      );
      expect(await provider.setup('cancelled'), null);
      for (final invalid in [
        {'access_token': 'short-lived', 'expires_in': 14400},
        {'access_token': '', 'refresh_token': 'refresh', 'expires_in': 14400},
        {'access_token': 'access', 'refresh_token': 'refresh', 'expires_in': 0},
      ]) {
        response = invalid;
        await expectLater(
          provider.setup('invalid'),
          throwsA(isA<CoreException>()),
        );
      }
      response = PlatformException(
        code: 'authorization',
        message: 'private callback',
      );
      await expectLater(
        provider.setup('failed'),
        throwsA(failure(LocationFailure.revoked)),
      );
      response = PlatformException(
        code: 'offline',
        details: 'private callback',
      );
      await expectLater(
        provider.setup('offline'),
        throwsA(failure(LocationFailure.offline)),
      );
      expect(fixture.credentials.values, isEmpty);
      expect(fixture.tokenForms, isEmpty);
    },
  );

  test(
    'recursive metadata uses continuations and selected-root relative depth',
    () async {
      final location = DropboxLocation(
        'one',
        DropboxClient(
          accessToken: ({bool renew = false}) async => 'fixture',
          api: fixture.root,
        ),
      );
      fixture.recursivePages = [
        [],
        [
          fixture.folder,
          fixture.entry,
          {
            ...fixture.entry,
            'id': 'deep',
            'path_lower': '/books/sub/deep.epub',
          },
        ],
      ];
      final pages = await location.listRecursive().toList();
      expect(pages.first, isEmpty);
      expect(pages.last.map((item) => item.depth), [0, 1, 2]);
      expect(fixture.calls, [
        '/files/list_folder',
        '/files/list_folder/continue',
      ]);
      fixture.calls.clear();
      fixture.recursivePages = [
        [
          fixture.entry,
          {
            ...fixture.entry,
            'id': 'deep',
            'path_lower': '/books/sub/deep.epub',
          },
        ],
      ];
      final selected = await location
          .listRecursive(directory: 'id:folder')
          .expand((page) => page)
          .toList();
      expect(selected.map((item) => item.depth), [0, 1]);
      expect(fixture.calls, ['/files/get_metadata', '/files/list_folder']);
      // Pickers retain the nonrecursive contract even on an optimized provider.
      expect((await location.list()).entries.single.isDirectory, true);
      fixture.recursivePages = [
        [
          {...fixture.entry, 'path_lower': '/books-other/book.epub'},
        ],
      ];
      await expectLater(
        location.listRecursive(directory: 'id:folder').drain<void>(),
        throwsA(isA<CoreException>()),
      );
    },
  );

  test(
    'recursive traversal rejects repeated cursors and stops before next page on cancel',
    () async {
      final location = DropboxLocation(
        'one',
        DropboxClient(
          accessToken: ({bool renew = false}) async => 'fixture',
          api: fixture.root,
        ),
      );
      fixture.recursivePages = [
        [],
        [],
        [fixture.entry],
      ];
      fixture.repeatCursor = true;
      await expectLater(
        location.listRecursive().drain<void>(),
        throwsA(isA<CoreException>()),
      );
      expect(fixture.calls, hasLength(2));
      fixture.calls.clear();
      fixture.repeatCursor = false;
      final cancellation = CancellationToken();
      await expectLater(
        location.listRecursive(cancellation: cancellation).map((page) {
          cancellation.cancel();
          return page;
        }).drain<void>(),
        throwsA(cancelled),
      );
      expect(fixture.calls, ['/files/list_folder']);
    },
  );

  test('build app key configures PKCE or explicitly disables setup', () async {
    final expected = const bool.hasEnvironment('SHOSAI_DROPBOX_APP_KEY')
        ? const String.fromEnvironment('SHOSAI_DROPBOX_APP_KEY')
        : '3yy8xd4pncextkh';
    Uri? authorization;
    final provider = DropboxConnectionProvider(
      credentials: fixture.credentials,
      tokenEndpoint: fixture.root.resolve('oauth2/token'),
      api: fixture.root,
      content: fixture.root,
      authorize: (uri) async {
        authorization = uri;
        fixture.challenge = uri.queryParameters['code_challenge'];
        return 'test-code';
      },
    );
    expect(provider.clientId, expected);
    if (expected.isEmpty) {
      await expectLater(
        provider.setup('default'),
        throwsA(
          isA<CoreException>().having(
            (error) => error.kind,
            'kind',
            CoreErrorKind.unsupported,
          ),
        ),
      );
      expect(authorization, null);
      expect(fixture.tokenForms, isEmpty);
      expect(fixture.credentials.values, isEmpty);
    } else {
      final connection = (await provider.setup('default'))!;
      expect(authorization!.queryParameters['client_id'], expected);
      expect(fixture.tokenForms.single['client_id'], expected);
      expect(connection.configuration['clientId'], expected);
      expect((await (await provider.open(connection)).stat('id:book')).size, 7);
      await provider.release(connection);
      expect(fixture.credentials.values, isEmpty);
    }
  });

  test(
    'S256 setup stores only refresh token, reopen renews and release isolates connections',
    () async {
      final provider = fixture.provider();
      final first = (await provider.setup('one'))!;
      final second = (await provider.setup('two'))!;
      expect(fixture.credentials.values.length, 2);
      expect(jsonEncode(first.toJson()), isNot(contains('refresh-')));
      expect(jsonEncode(first.toJson()), isNot(contains('access-')));
      // Disabling new setup must not change the key of an existing grant.
      final reopened = DropboxConnectionProvider(
        credentials: fixture.credentials,
        clientId: '',
        tokenEndpoint: fixture.root.resolve('oauth2/token'),
        api: fixture.root,
        content: fixture.root,
      );
      final location = await reopened.open(
        LibraryConnection.fromJson(first.toJson()),
      );
      await Future.wait([location.stat('id:book'), location.stat('id:book')]);
      expect(fixture.tokenForms.last['client_id'], 'fixture-app-key');
      expect(
        fixture.tokenForms
            .where((v) => v['grant_type'] == 'refresh_token')
            .length,
        1,
      );
      await reopened.release(first);
      await expectLater(
        location.stat('id:book'),
        throwsA(failure(LocationFailure.revoked)),
      );
      expect((await (await provider.open(second)).stat('id:book')).size, 7);
      expect(fixture.credentials.values.length, 1);
    },
  );

  test(
    'metadata pages and stat never download; whole and exclusive ranges preserve bytes',
    () async {
      final provider = fixture.provider();
      final location = await provider.open((await provider.setup('one'))!);
      final page = await location.list(limit: 1);
      expect(page.entries.single.key, 'id:folder');
      final next = await location.list(cursor: page.nextCursor, limit: 1);
      expect(next.entries.single.revision, 'r1');
      expect(next.nextCursor, null);
      expect(
        (await location.list(directory: 'id:folder')).entries.single.key,
        'id:book',
      );
      for (final outside in ['/Photos/private.jpg', 'id:outside']) {
        await expectLater(
          location.list(directory: outside),
          throwsA(failure(LocationFailure.missing)),
        );
        await expectLater(
          location.stat(outside),
          throwsA(failure(LocationFailure.missing)),
        );
      }
      await location.stat('id:book');
      expect(fixture.calls, isNot(contains('/files/download')));
      await expectLater(
        readAll(location.read('id:outside')),
        throwsA(failure(LocationFailure.missing)),
      );
      expect(await readAll(location.read('id:book')), fixture.book);
      expect(await readAll(location.read('id:book', start: 2, end: 5)), [
        29,
        47,
        81,
      ]);
      expect(await readAll(location.read('id:book', start: 5, end: 99)), [
        109,
        211,
      ]);
      final before = fixture.calls.where((v) => v == '/files/download').length;
      expect(await readAll(location.read('id:book', start: 7)), isEmpty);
      expect(await readAll(location.read('id:book', start: 9)), isEmpty);
      expect(
        await readAll(location.read('id:book', start: 3, end: 3)),
        isEmpty,
      );
      expect(fixture.calls.where((v) => v == '/files/download').length, before);
      await expectLater(
        readAll(location.read('id:book', start: -1)),
        throwsA(isA<CoreException>()),
      );
      fixture.ignoreRange = true;
      await expectLater(
        readAll(location.read('id:book', start: 1, end: 3)),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.unsupported,
          ),
        ),
      );
      fixture.ignoreRange = false;
      fixture.shortRange = true;
      await expectLater(
        readAll(location.read('id:book', start: 2, end: 5)),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.malformed,
          ),
        ),
      );
    },
  );

  test(
    'expired renewal is shared, cancellation isolates callers and release rejects stale renewal',
    () async {
      fixture.expiresIn = 1;
      final provider = fixture.provider();
      final connection = (await provider.setup('one'))!;
      final location = await provider.open(connection);
      fixture.tokenWait = Completer<void>();
      fixture.tokenArrived = Completer<void>();
      final token = CancellationToken();
      final cancelledCall = expectLater(
        location.stat('id:book', cancellation: token),
        throwsA(cancelled),
      );
      final healthyCall = location.stat('id:book');
      await fixture.tokenArrived!.future;
      token.cancel();
      await cancelledCall.timeout(const Duration(seconds: 2));
      fixture.tokenWait!.complete();
      expect((await healthyCall).size, 7);
      expect(fixture.tokenForms.length, 2);
      fixture.tokenWait = Completer<void>();
      fixture.tokenArrived = Completer<void>();
      final stale = expectLater(
        location.stat('id:book'),
        throwsA(failure(LocationFailure.revoked)),
      );
      await fixture.tokenArrived!.future;
      await provider.release(connection);
      fixture.tokenWait!.complete();
      await stale;
      expect(fixture.credentials.values, isEmpty);
    },
  );

  test(
    '401 renews once; revoked, missing and offline stay typed and retryable',
    () async {
      final provider = fixture.provider();
      final location = await provider.open((await provider.setup('one'))!);
      fixture.rejectAccess = true;
      expect((await location.stat('id:book')).name, 'Book.epub');
      expect(fixture.tokenForms.length, 2);
      fixture.offline = true;
      await expectLater(
        location.stat('id:book'),
        throwsA(failure(LocationFailure.offline)),
      );
      fixture.offline = false;
      fixture.missing = true;
      await expectLater(
        location.stat('id:book'),
        throwsA(failure(LocationFailure.missing)),
      );
      fixture.missing = false;
      expect((await location.stat('id:book')).key, 'id:book');
      fixture.revoked = true;
      await expectLater(
        location.stat('id:book'),
        throwsA(failure(LocationFailure.revoked)),
      );
    },
  );

  test(
    'cancellation closes a pending read and timeout bounds waiting for headers',
    () async {
      final provider = fixture.provider();
      final location = await provider.open((await provider.setup('one'))!);
      fixture.wait = Completer<void>();
      fixture.arrived = Completer<void>();
      final cancellation = CancellationToken();
      final reading = readAll(
        location.read('id:book', cancellation: cancellation),
      );
      final check = expectLater(reading, throwsA(cancelled));
      await fixture.arrived!.future;
      cancellation.cancel();
      await check.timeout(const Duration(seconds: 2));
      final bounded = DropboxLocation(
        'bounded',
        DropboxClient(
          accessToken: ({bool renew = false}) async => 'fixture',
          api: fixture.root,
          content: fixture.root,
          requestTimeout: const Duration(milliseconds: 100),
        ),
      );
      await expectLater(
        readAll(bounded.read('id:book')),
        throwsA(failure(LocationFailure.offline)),
      );
    },
  );

  test(
    'session upload streams bounded chunks and publishes only on finish',
    () async {
      final provider = fixture.provider();
      final location = await provider.open((await provider.setup('one'))!);
      for (final size in [4 * 1024 * 1024, 4 * 1024 * 1024 + 1]) {
        final data = List.generate(size, (i) => i % 251);
        expect(
          (await location.write(
            '書.epub',
            Stream.value(data),
            directory: 'id:folder',
          )).key,
          'id:book',
        );
        expect(fixture.uploaded.takeBytes(), data);
        expect(fixture.commit!['path'], 'id:folder/書.epub');
      }
      await location.write('Root.epub', Stream.value([17, 31, 63]));
      expect(fixture.commit!['path'], '/Root.epub');
      expect(fixture.uploaded.takeBytes(), [17, 31, 63]);
      fixture.commit = null;
      final token = CancellationToken();
      final source = StreamController<List<int>>();
      final writing = location.write(
        'cancel.epub',
        source.stream,
        cancellation: token,
      );
      final check = expectLater(writing, throwsA(cancelled));
      source.add([9, 7, 5]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await check.timeout(const Duration(seconds: 2));
      await source.close();
      expect(fixture.commit, null);
    },
  );

  test(
    'catalog stays lazy and selected book uses existing cache/Keep and identity seams',
    () async {
      fixture.book = await File(
        'packages/shosai_core/test/fixtures/sample.epub',
      ).readAsBytes();
      final directory = await Directory.systemTemp.createTemp('shosai-dropbox');
      final store = await Store.open('${directory.path}/library.sqlite3');
      final library = Library(
        store,
        managedDirectory: '${directory.path}/books',
      );
      final locations = LibraryLocations(store);
      final cache = BookFileCache(store, '${directory.path}/cache');
      final provider = fixture.provider();
      final folders = LibraryFolders(
        Preferences(store),
        library,
        locations,
        () async => '${directory.path}/stage.epub',
        cache,
        providers: [provider],
      );
      addTearDown(() async {
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      await folders.add((await provider.setup('one'))!);
      // The fixture root has a folder then book; selecting the source key is
      // persisted independently of credentials and book identities.
      await folders.configure('one', directory: 'id:folder', label: 'Books');
      final found = await folders.discover();
      expect(found.single.entry.key, 'id:book');
      expect(fixture.calls, isNot(contains('/files/download')));
      fixture.offline = true;
      expect(await folders.discover(refresh: true), isNotEmpty);
      expect(folders.scanWarnings, ['Dropbox']);
      fixture.offline = false;
      expect(await folders.discover(refresh: true), hasLength(1));
      expect(folders.scanWarnings, isEmpty);
      final book = await folders.importEntry('one', found.single.entry);
      final notes = Annotations(store);
      await notes.createNote(book.id, const BookAnchor(), 'Keep these notes.');
      expect(book.located, true);
      expect((await locations.copies(book.contentHash)).single.locator, (
        locationId: 'one',
        key: 'id:book',
      ));
      expect(fixture.calls.where((v) => v == '/files/download'), hasLength(1));
      await folders.setKept(book.id, true);
      fixture.offline = true;
      expect(
        await folders.withBookFile(book, (path) => File(path).readAsBytes()),
        fixture.book,
      );
      expect((await library.get(book.id))!.keptOnDevice, true);
      expect(fixture.calls.where((v) => v == '/files/download'), hasLength(1));
      await folders.remove('one');
      expect(
        (await locations.copies(book.contentHash)).single.failure,
        LocationFailure.revoked,
      );
      expect((await library.get(book.id))!.contentHash, book.contentHash);
      expect(
        await notes.summary(book.id),
        const NotesSummary(1, 'Keep these notes.'),
      );
      expect(fixture.credentials.values, isEmpty);
    },
  );
}
