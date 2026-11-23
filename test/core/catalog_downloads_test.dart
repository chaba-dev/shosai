import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/catalog.dart';
import 'package:shosai_flutter/core/catalog_downloads.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';

import '../support/catalog_fixture.dart';

// Real socket/stream fixture, with the production HTTPS URLs routed to a
// loopback HTTP server. This does not test TLS or contact a public source.
class _LocalClient implements HttpClient {
  _LocalClient(this.root) : client = HttpClient();
  final Uri root;
  final HttpClient client;
  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      client.getUrl(root.resolve(url.path));
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late Store store;
  late Library library;
  late LibraryFolders folders;
  late CatalogClient catalog;
  late CatalogDownloads downloads;
  late HttpServer server;
  late List<int> bytes;
  var responseCode = 200;
  var compressed = false;
  Completer<void>? wait;
  late Completer<void> arrived;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('catalog-add-');
    store = await Store.open('${root.path}/personal.sqlite3');
    library = Library(store, managedDirectory: '${root.path}/books');
    folders = LibraryFolders(
      Preferences(store),
      library,
      LibraryLocations(store),
      () async => '${root.path}/stage',
      BookFileCache(store, '${root.path}/cache'),
    );
    catalog = createCatalogFixture(Directory('${root.path}/catalog'));
    bytes = File(
      'packages/shosai_core/test/fixtures/sample.epub',
    ).readAsBytesSync();
    responseCode = 200;
    compressed = false;
    wait = null;
    arrived = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.userAgentHeader),
        catalogUserAgent,
      );
      if (!arrived.isCompleted) arrived.complete();
      await wait?.future;
      request.response.statusCode = responseCode;
      if (responseCode == 302) {
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://insecure.example/book.epub',
        );
      } else {
        final body = compressed ? gzip.encode(bytes) : bytes;
        if (compressed) {
          request.response.headers.set('Content-Encoding', 'gzip');
        }
        request.response.contentLength = body.length;
        request.response.add(body);
      }
      await request.response.close();
    });
    var sequence = 0;
    downloads = CatalogDownloads(
      catalog,
      folders,
      () async => '${root.path}/download-${sequence++}',
      client: () => _LocalClient(Uri.parse('http://127.0.0.1:${server.port}/')),
    );
  });
  tearDown(() async {
    if (wait?.isCompleted == false) wait!.complete();
    await server.close(force: true);
    await folders.close();
    await catalog.close();
    await store.close();
    root.deleteSync(recursive: true);
  });

  Future<({Book book, bool existing})> add({
    String? location,
    CancellationToken? token,
  }) async {
    final option = (await folders.saveOptions()).locations
        .where((g) => g.connection.id == location)
        .firstOrNull;
    return downloads.add(
      bookId: '0',
      sourceId: 'gutenberg',
      editionId: '0:0',
      locationId: location,
      destination: option == null
          ? null
          : (
              generation: option.generation,
              directory: option.connection.directory,
            ),
      cancellation: token ?? CancellationToken(),
    );
  }

  Future<Directory> connect() async {
    final target = Directory('${root.path}/connected')..createSync();
    await folders.add(
      LibraryConnection('folder', 'My books', 'folder', {
        'kind': 'path',
        'grant': target.path,
      }),
    );
    return target;
  }

  test(
    'Add is content-idempotent, preserves reading state and writes no duplicate to a new destination',
    () async {
      final first = await add();
      expect(first.existing, false);
      expect(first.book.storageKind, StorageKind.managed);
      expect(first.book.lastRead, isNull);
      final original = File(first.book.path).statSync();
      final target = await connect();
      final again = await add(location: 'folder');
      expect(again.existing, true);
      expect(again.book.id, first.book.id);
      expect(again.book.lastRead, isNull);
      expect(File(first.book.path).statSync().modified, original.modified);
      expect(target.listSync(), isEmpty);
      expect(
        root.listSync().where((f) => f.path.contains('/download-')),
        isEmpty,
      );
      expect((await library.page()).books, hasLength(1));
    },
  );

  test(
    'matching preferred filename is adopted without rewriting; a differing collision gets the lowest free suffix',
    () async {
      final target = await connect();
      final source = Directory('${target.path}/Project Gutenberg')
        ..createSync();
      final name = 'Pride and Prejudice - Jane Austen.epub';
      final original = File('${source.path}/$name')..writeAsBytesSync(bytes);
      final modified = original.statSync().modified;
      final adopted = await add(location: 'folder');
      expect(source.listSync(), hasLength(1));
      expect(original.statSync().modified, modified);
      expect(adopted.book.located, true);
      expect(
        await folders.withBookFile(
          adopted.book,
          (path) => File(path).readAsBytes(),
        ),
        bytes,
      );

      // Another valid EPUB with different bytes (ZIP archive comment).
      final changed = [...bytes, 120];
      changed[bytes.length - 2] = 1;
      bytes = changed;
      final second = await add(location: 'folder');
      expect(second.book.id, isNot(adopted.book.id));
      expect(original.readAsBytesSync(), isNot(bytes));
      expect(
        File(
          '${source.path}/Pride and Prejudice - Jane Austen (2).epub',
        ).readAsBytesSync(),
        bytes,
      );
      expect(source.listSync(), hasLength(2));
    },
  );

  test(
    'portable case/normalization collisions are not replaced and a file cannot be treated as a source folder',
    () async {
      final target = await connect();
      File('${target.path}/Project Gutenberg').writeAsStringSync('keep me');
      final source = Directory('${target.path}/Project Gutenberg (2)')
        ..createSync();
      final collision = File(
        '${source.path}/PRIDE AND PREJUDICE - JANE AUSTEN.EPUB',
      )..writeAsStringSync('different');
      final saved = await add(location: 'folder');
      expect(saved.book.located, true);
      expect(collision.readAsStringSync(), 'different');
      expect(
        File(
          '${source.path}/Pride and Prejudice - Jane Austen (2).epub',
        ).readAsBytesSync(),
        bytes,
      );
    },
  );

  test(
    'invalid bytes and HTTPS downgrade never publish or admit a book',
    () async {
      final target = await connect();
      bytes = [1, 2, 3, 4];
      await expectLater(add(location: 'folder'), throwsA(isA<CoreException>()));
      responseCode = 302;
      await expectLater(add(location: 'folder'), throwsA(isA<CoreException>()));
      expect(target.listSync(), isEmpty);
      expect((await library.page()).books, isEmpty);
      expect(
        root.listSync().where((f) => f.path.contains('/download-')),
        isEmpty,
      );
    },
  );

  for (final repair in [false, true]) {
    test(
      'failed local admission rolls back and retry adopts published bytes (repair: $repair)',
      () async {
        final target = await connect();
        Book? previous;
        if (repair) {
          final stage = File('${root.path}/old-stage.epub')
            ..writeAsBytesSync(bytes);
          previous = (await library.importFile(
            stage.path,
            managed: false,
          )).book!;
          await library.updateProgress(previous.id, 0.375);
          stage.deleteSync();
          final source = Directory('${target.path}/Project Gutenberg')
            ..createSync();
          File(
            '${source.path}/Pride and Prejudice - Jane Austen.epub',
          ).writeAsStringSync('occupied');
        }
        await store.transaction(
          (db) => db.execute(
            "CREATE TRIGGER fault BEFORE INSERT ON book_locators BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END",
          ),
        );
        await expectLater(
          add(location: 'folder'),
          throwsA(isA<CoreException>()),
        );
        expect((await library.page()).books, hasLength(repair ? 1 : 0));
        final published = File(
          '${target.path}/Project Gutenberg/Pride and Prejudice - Jane Austen${repair ? ' (2)' : ''}.epub',
        );
        final modified = published.statSync().modified;
        await store.transaction((db) => db.execute('DROP TRIGGER fault'));
        final saved = await add(location: 'folder');
        expect((await library.page()).books, hasLength(1));
        expect(saved.existing, repair);
        if (repair) {
          expect(saved.book.id, previous!.id);
          expect(saved.book.progress, 0.375);
        }
        expect(published.statSync().modified, modified);
        expect(published.parent.listSync(), hasLength(repair ? 2 : 1));
        expect(
          await folders.withBookFile(
            saved.book,
            (path) => File(path).readAsBytes(),
          ),
          bytes,
        );
      },
    );
  }

  test(
    'Add honors the displayed destination even when it changes before catalog lookup',
    () async {
      final target = await connect();
      for (final name in ['Original', 'Changed']) {
        Directory('${target.path}/$name').createSync();
      }
      await folders.configure(
        'folder',
        directory: 'Original',
        label: 'Original',
      );
      final option = (await folders.saveOptions()).locations.single;
      await folders.configure('folder', directory: 'Changed', label: 'Changed');
      await expectLater(
        downloads.add(
          bookId: '0',
          sourceId: 'gutenberg',
          editionId: '0:0',
          locationId: 'folder',
          destination: (
            generation: option.generation,
            directory: option.connection.directory,
          ),
          cancellation: CancellationToken(),
        ),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.conflict,
          ),
        ),
      );
      expect(Directory('${target.path}/Original').listSync(), isEmpty);
      expect(Directory('${target.path}/Changed').listSync(), isEmpty);
      expect((await library.page()).books, isEmpty);
    },
  );

  test(
    'changing the selected directory during download requires reselection and writes nowhere',
    () async {
      final target = await connect();
      for (final name in ['Original', 'Changed']) {
        Directory('${target.path}/$name').createSync();
      }
      await folders.configure(
        'folder',
        directory: 'Original',
        label: 'Original',
      );
      wait = Completer<void>();
      final pending = add(location: 'folder');
      final failure = expectLater(
        pending,
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.conflict,
          ),
        ),
      );
      await arrived.future;
      await folders.configure('folder', directory: 'Changed', label: 'Changed');
      wait!.complete();
      await failure;
      expect(Directory('${target.path}/Original').listSync(), isEmpty);
      expect(Directory('${target.path}/Changed').listSync(), isEmpty);
      expect((await library.page()).books, isEmpty);
      final saved = await add(location: 'folder');
      expect(
        await folders.withBookFile(
          saved.book,
          (path) => File(path).readAsBytes(),
        ),
        bytes,
      );
      expect(Directory('${target.path}/Original').listSync(), isEmpty);
    },
  );

  test(
    'gzip transfers validate decoded book bytes rather than wire length',
    () async {
      compressed = true;
      expect(gzip.encode(bytes).length, isNot(bytes.length));
      final saved = await add();
      expect(File(saved.book.path).readAsBytesSync(), bytes);
      expect((await library.page()).books, hasLength(1));
    },
  );

  test(
    'unsupported destination items reserve portable names without being read or adopted',
    () async {
      final target = await connect();
      final adapter = _InterceptSave(
        await FolderLocation.open('folder', target.path),
        true,
        occupied: [
          LocationEntry(
            key: 'unowned-folder',
            name: 'Project Gutenberg',
            isDirectory: true,
            readable: false,
          ),
          LocationEntry(
            key: 'unsupported-item',
            name: 'PRIDE AND PREJUDICE - JANE AUSTEN.EPUB',
            isDirectory: false,
            size: bytes.length,
            readable: false,
          ),
        ],
      );
      await folders.close();
      folders = LibraryFolders(
        Preferences(store),
        library,
        LibraryLocations(store),
        () async => '${root.path}/stage',
        BookFileCache(store, '${root.path}/cache'),
        providers: [_SaveProvider(adapter)],
      );
      final result = await folders.saveDownloadedBook(
        'packages/shosai_core/test/fixtures/sample.epub',
        locationId: 'folder',
        destination: (
          generation: (await folders.saveOptions()).locations.single.generation,
          directory: null,
        ),
        source: 'Project Gutenberg',
        title: 'Pride and Prejudice',
        author: 'Jane Austen',
        format: BookFormat.epub,
      );
      expect(
        File(
          '${target.path}/Project Gutenberg (2)/Pride and Prejudice - Jane Austen (2).epub',
        ).readAsBytesSync(),
        bytes,
      );
      expect(
        await folders.withBookFile(
          result.book,
          (path) => File(path).readAsBytes(),
        ),
        bytes,
      );
    },
  );

  for (final lateCancel in [false, true]) {
    test(
      'save ${lateCancel ? 'finishes association after late cancellation' : 'adopts a concurrent identical publication without a suffix'}',
      () async {
        final target = await connect();
        final adapter = _InterceptSave(
          await FolderLocation.open('folder', target.path),
          lateCancel,
        );
        await folders.close();
        folders = LibraryFolders(
          Preferences(store),
          library,
          LibraryLocations(store),
          () async => '${root.path}/stage',
          BookFileCache(store, '${root.path}/cache'),
          providers: [_SaveProvider(adapter)],
        );
        final token = CancellationToken();
        final result = await folders.saveDownloadedBook(
          'packages/shosai_core/test/fixtures/sample.epub',
          locationId: 'folder',
          destination: (
            generation:
                (await folders.saveOptions()).locations.single.generation,
            directory: null,
          ),
          source: 'Project Gutenberg',
          title: 'Pride and Prejudice',
          author: 'Jane Austen',
          format: BookFormat.epub,
          cancellation: token,
        );
        expect(token.isCancelled, lateCancel);
        expect(result.book.located, true);
        expect(
          Directory('${target.path}/Project Gutenberg').listSync(),
          hasLength(1),
        );
        expect(
          await folders.withBookFile(
            result.book,
            (path) => File(path).readAsBytes(),
          ),
          bytes,
        );
      },
    );
  }

  test(
    'cancelling a stalled download cleans staging and admits nothing',
    () async {
      wait = Completer<void>();
      final token = CancellationToken();
      final pending = add(token: token);
      final failure = expectLater(
        pending,
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.cancelled,
          ),
        ),
      );
      await arrived.future;
      token.cancel();
      await failure;
      expect((await library.page()).books, isEmpty);
      expect(
        root.listSync().where((f) => f.path.contains('/download-')),
        isEmpty,
      );
    },
  );

  test(
    'private choice survives reconnects and mobile never offers folder sources',
    () async {
      await connect();
      expect((await folders.saveOptions()).selected, 'folder');
      await folders.selectSaveLocation(null);
      expect((await folders.saveOptions()).selected, isNull);
      final mobile = LibraryFolders(
        Preferences(store),
        library,
        LibraryLocations(store),
        () async => '${root.path}/mobile-stage',
        BookFileCache(store, '${root.path}/mobile-cache'),
        folderSources: false,
      );
      expect((await mobile.saveOptions()).locations, isEmpty);
      await mobile.close();
    },
  );
}

class _SaveProvider implements ConnectionProvider {
  _SaveProvider(this.location);
  final LibrarySaveLocation location;
  @override
  String get id => 'folder';
  @override
  Future<LibraryLocation> open(LibraryConnection connection) async => location;
  @override
  Future<LibraryConnection> refresh(LibraryConnection connection) async =>
      connection;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InterceptSave implements LibrarySaveLocation, LibrarySaveInventory {
  _InterceptSave(this.location, this.lateCancel, {this.occupied = const []});
  final LibrarySaveLocation location;
  final bool lateCancel;
  final List<LocationEntry> occupied;
  var first = true;
  @override
  String get id => location.id;
  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) => location.list(
    directory: directory,
    cursor: cursor,
    limit: limit,
    cancellation: cancellation,
  );
  @override
  Future<LocationPage> listForSave({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async {
    final page = await list(
      directory: directory,
      cursor: cursor,
      limit: limit,
      cancellation: cancellation,
    );
    return LocationPage([
      ...page.entries,
      ...occupied,
    ], nextCursor: page.nextCursor);
  }

  @override
  Future<LocationEntry> stat(String key, {CancellationToken? cancellation}) =>
      location.stat(key, cancellation: cancellation);
  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) => location.read(key, start: start, end: end, cancellation: cancellation);
  @override
  Future<LocationEntry> createDirectory(
    String name, {
    String? directory,
    CancellationToken? cancellation,
  }) => location.createDirectory(
    name,
    directory: directory,
    cancellation: cancellation,
  );
  @override
  Future<LocationEntry> createFile(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) async {
    final result = await location.createFile(
      name,
      bytes,
      directory: directory,
      cancellation: cancellation,
    );
    if (lateCancel) cancellation?.cancel();
    if (first && !lateCancel) {
      first = false;
      throw const CoreException.conflict('Another device published first.');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
