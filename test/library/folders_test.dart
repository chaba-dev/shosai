import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_core/shosai_core.dart' hide Row;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/dropbox_connection.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/folders_controller.dart';
import 'package:shosai_flutter/library/folders_view.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/main.dart' show ShosaiShell;
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../support/production_shell_harness.dart';

/// A local test adapter whose configuration has no folder-grant fields. This
/// exercises the Settings/service contract, not a pretend cloud integration.
final class _FixtureProvider implements ConnectionProvider {
  _FixtureProvider(this.root, {this.id = 'fixture'});
  final String root;
  final released = <String>{};
  final releaseCalls = <String, int>{};
  final releaseFailures = <String, Object>{};
  final refreshFailures = <String, Object>{};
  final refreshedConfiguration = <String, Map<String, String>>{};
  final locations = <String, LibraryLocation>{};

  @override
  final String id;

  @override
  Future<LibraryConnection?> setup(String connectionId) async =>
      LibraryConnection(connectionId, 'Books', id, {'root': root});

  @override
  Future<LibraryConnection> refresh(LibraryConnection connection) async {
    final failure = refreshFailures[connection.id];
    if (failure != null) throw failure;
    return LibraryConnection(
      connection.id,
      connection.label,
      connection.provider,
      refreshedConfiguration[connection.id] ?? connection.configuration,
      directory: connection.directory,
      directoryLabel: connection.directoryLabel,
    );
  }

  @override
  Future<LibraryLocation> open(LibraryConnection connection) async {
    if (released.contains(connection.id)) {
      throw const LocationException(LocationFailure.revoked);
    }
    if (locations[connection.id] case final location?) return location;
    return FolderLocation.open(
      connection.id,
      connection.configuration['root']!,
    );
  }

  @override
  bool sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.configuration['root'] == second.configuration['root'] &&
      first.configuration['credential'] == second.configuration['credential'];

  @override
  Future<void> release(LibraryConnection connection) async {
    releaseCalls.update(connection.id, (count) => count + 1, ifAbsent: () => 1);
    if (releaseFailures[connection.id] case final failure?) throw failure;
    released.add(connection.id);
  }
}

class _PagedLocation implements LibraryLocation {
  _PagedLocation(this.id);
  @override
  final String id;
  final pages = <String?, List<LocationPage>>{};
  Future<void> Function(String? directory)? beforeList;

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async {
    cancellation.throwIfCancelled();
    await beforeList?.call(directory);
    return pages[directory]![cursor == null ? 0 : int.parse(cursor)];
  }

  // Discovery must never use stat/read/write to identify a candidate.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Metadata listing only');
}

class _RecursiveLocation extends _PagedLocation
    implements RecursiveLibraryLocation {
  _RecursiveLocation(super.id);
  List<List<LocationTreeEntry>> tree = [];
  Object? failure;
  Future<void> Function()? afterPage;
  @override
  Stream<List<LocationTreeEntry>> listRecursive({
    String? directory,
    CancellationToken? cancellation,
  }) async* {
    for (final page in tree) {
      cancellation.throwIfCancelled();
      yield page;
      await afterPage?.call();
    }
    if (failure case final error?) throw error;
  }
}

class _SourceBridge extends HarnessBridge implements LibraryFoldersHost {
  _SourceBridge(this.folders);
  @override
  final LibraryFolders folders;
  @override
  Future<FlutterLibraryBook> admitSourceFile(
    LibrarySourceFile file, {
    CancellationToken? cancellation,
  }) => throw StateError('No content reads');
}

void main() {
  setUpAll(loadHarnessFonts);
  test(
    'replaced, cancelled and disposed discovery cannot restore stale activity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-progress',
      );
      final store = await Store.open('${directory.path}/library.sqlite3');
      final provider = _FixtureProvider(directory.path);
      final location = _RecursiveLocation('one')
        ..tree = [
          [
            (
              entry: const LocationEntry(
                key: 'one',
                name: 'One.epub',
                isDirectory: false,
              ),
              depth: 0,
            ),
          ],
        ];
      final gates = <Completer<void>>[];
      location.afterPage = () {
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      };
      provider.locations['one'] = location;
      final folders = LibraryFolders(
        Preferences(store),
        Library(store, managedDirectory: '${directory.path}/books'),
        LibraryLocations(store),
        () async => '${directory.path}/unused',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      await folders.add(LibraryConnection('one', 'Books', 'fixture', const {}));
      final bridge = _SourceBridge(folders);
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => null,
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
      );
      addTearDown(() async {
        controller.dispose();
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 100 && !ready(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(ready(), true);
      }

      controller.dispatch(const LibraryStarted());
      await until(() => gates.length == 1);
      expect(controller.model.discoveryProgress?.booksFound, 1);
      controller.dispatch(const LibraryRefreshed());
      expect(controller.model.discoveryProgress, null);
      gates.first.complete();
      await until(() => gates.length == 2);
      expect(controller.model.discoveryProgress?.booksFound, 1);
      expect(controller.model.loadError, null);
      controller.dispatch(const LibraryOperationCancelled());
      expect(controller.model.discoveryProgress, null);
      gates[1].complete();
      await until(() => !controller.model.loading);
      expect(controller.model.discoveryProgress, null);
      expect(controller.model.loadError, 'Library check cancelled.');
      controller.dispatch(const LibraryRefreshed());
      await until(() => gates.length == 3);
      controller.dispose();
      final disposed = controller.model;
      gates[2].complete();
      await until(() => bridge.isDisposed);
      expect(identical(controller.model, disposed), true);
    },
  );

  test(
    'recursive scan progress deduplicates books and incomplete scans retain catalog per source',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-discovery',
      );
      final store = await Store.open('${directory.path}/library.sqlite3');
      final provider = _FixtureProvider(directory.path);
      final recursive = _RecursiveLocation('recursive');
      final fallback = _PagedLocation('fallback');
      const book = LocationEntry(
        key: 'book',
        name: 'Book.epub',
        isDirectory: false,
      );
      const pdf = LocationEntry(
        key: 'pdf',
        name: 'Second.PDF',
        isDirectory: false,
      );
      const folder = LocationEntry(
        key: 'subfolder',
        name: 'Books',
        isDirectory: true,
      );
      const ignored = LocationEntry(
        key: 'text',
        name: 'Notes.txt',
        isDirectory: false,
      );
      recursive.tree = [
        [(entry: book, depth: 32)],
        [],
        [
          (entry: book, depth: 32),
          (entry: pdf, depth: 0),
          (entry: ignored, depth: 0),
        ],
      ];
      // Empty filtered pages with continuation and cyclic folder references are valid.
      fallback.pages[null] = [
        LocationPage([], nextCursor: '1'),
        LocationPage([folder]),
      ];
      fallback.pages['subfolder'] = [
        LocationPage([folder, pdf]),
      ];
      provider.locations.addAll({'recursive': recursive, 'fallback': fallback});
      final locations = LibraryLocations(store);
      final folders = LibraryFolders(
        Preferences(store),
        Library(store, managedDirectory: '${directory.path}/books'),
        locations,
        () async => '${directory.path}/unused',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      addTearDown(() async {
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      for (final id in provider.locations.keys) {
        await folders.add(LibraryConnection(id, id, 'fixture', {'root': id}));
      }
      final progress = <LibraryDiscoveryProgress>[];
      expect(
        (await folders.discover(
          onProgress: progress.add,
        )).map((f) => '${f.locationId}/${f.entry.key}'),
        ['recursive/book', 'recursive/pdf', 'fallback/pdf'],
      );
      expect(
        progress.where((p) => p.sourceIndex == 1).map((p) => p.booksFound),
        [0, 1, 1, 2],
      );
      expect(progress.last.sourceCount, 2);
      expect(progress.last.booksFound, 1);
      final original = (await locations.catalog())
          .map((f) => '${f.locationId}/${f.entry.key}')
          .toSet();
      // A partial failed source retains its unseen books while a healthy source updates.
      recursive.tree = [
        [(entry: pdf, depth: 0)],
      ];
      recursive.failure = const CoreException.malformed('Broken continuation');
      fallback.pages['subfolder'] = [
        LocationPage([book]),
      ];
      expect(
        (await folders.discover(
          refresh: true,
        )).map((f) => '${f.locationId}/${f.entry.key}'),
        ['recursive/book', 'recursive/pdf', 'fallback/book'],
      );
      expect(folders.scanWarnings, ['recursive']);
      // Cancellation after a page never publishes that source's incomplete replacement.
      final token = CancellationToken();
      recursive.failure = null;
      await expectLater(
        folders.discover(
          refresh: true,
          cancellation: token,
          onProgress: (p) {
            if (p.booksFound == 1) token.cancel();
          },
        ),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.cancelled,
          ),
        ),
      );
      expect(
        (await locations.catalog())
            .where((f) => f.locationId == 'recursive')
            .map((f) => '${f.locationId}/${f.entry.key}')
            .toSet(),
        original.where((key) => key.startsWith('recursive/')).toSet(),
      );
      // Both entry and candidate limits, and just past the depth boundary, retain catalog.
      for (final tree in <List<LocationTreeEntry>>[
        [(entry: pdf, depth: 33)],
        List.generate(
          maxDiscoveryEntries + 1,
          (_) => (entry: ignored, depth: 0),
        ),
        List.generate(
          maxDiscoveredBooks + 1,
          (i) => (
            entry: LocationEntry(key: '$i', name: '$i.pdf', isDirectory: false),
            depth: 0,
          ),
        ),
      ]) {
        recursive.tree = [tree];
        await folders.discover(refresh: true);
        expect(folders.scanWarnings, ['recursive']);
        expect(
          (await locations.catalog()).where((f) => f.locationId == 'recursive'),
          hasLength(2),
        );
      }
      recursive.tree = [];
      await folders.discover(refresh: true);
      expect(
        (await locations.catalog()).where((f) => f.locationId == 'recursive'),
        isEmpty,
      );
      expect(folders.scanWarnings, isEmpty);
    },
  );

  test(
    'refresh isolates provider failures and retries without losing access',
    () async {
      final directory = await Directory.systemTemp.createTemp('shosai-refresh');
      final store = await Store.open('${directory.path}/library.sqlite3');
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final source = Directory('${directory.path}/source')..createSync();
      File(
        'packages/shosai_core/test/fixtures/sample.epub',
      ).copySync('${source.path}/book.epub');
      final preferences = Preferences(store);
      final provider = _FixtureProvider(source.path);
      final connections = [
        for (final id in ['failing', 'healthy'])
          LibraryConnection(id, 'Books $id', 'fixture', {'root': source.path}),
      ];
      await preferences.set('device.library.folders', jsonEncode(connections));
      final folders = LibraryFolders(
        preferences,
        Library(store, managedDirectory: '${directory.path}/books'),
        LibraryLocations(store),
        () async => '${directory.path}/unused',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      for (final failure in <Object>[
        const LocationException(LocationFailure.offline),
        const CoreException(CoreErrorKind.unsupported, 'Unavailable provider.'),
        StateError('Private adapter details must not reach the warning.'),
      ]) {
        provider.refreshFailures['failing'] = failure;
        final files = await folders.discover(refresh: true);
        expect(files.map((file) => file.locationId), ['failing', 'healthy']);
        expect(folders.scanWarnings, ['Books failing']);
        expect((await folders.list()).first.configuration, {
          'root': source.path,
        });
        expect(folders.scanWarnings, ['Books failing']);
      }

      // Cancellation aborts the operation, rather than becoming a source warning.
      provider.refreshFailures['failing'] = const CoreException.cancelled();
      await expectLater(
        folders.discover(refresh: true),
        throwsA(
          isA<CoreException>().having(
            (error) => error.kind,
            'kind',
            CoreErrorKind.cancelled,
          ),
        ),
      );
      provider.refreshFailures.clear();
      await folders.discover(refresh: true);
      expect(folders.scanWarnings, isEmpty);

      // A save error belongs to the application boundary, not to an adapter.
      final saved = await preferences.get('device.library.folders');
      provider.refreshedConfiguration['healthy'] = {
        'root': source.path,
        'oversized': 'x' * maxPreferenceValueBytes,
      };
      await expectLater(
        folders.discover(refresh: true),
        throwsA(
          isA<CoreException>().having(
            (error) => error.kind,
            'kind',
            CoreErrorKind.limitExceeded,
          ),
        ),
      );
      expect(await preferences.get('device.library.folders'), saved);
      expect((await folders.list()).last.configuration, {'root': source.path});
      expect(folders.scanWarnings, isEmpty);
      provider.refreshedConfiguration.clear();
      expect(await folders.discover(refresh: true), hasLength(2));
    },
  );

  test('failed initialization retries and does not block kept books', () async {
    final directory = await Directory.systemTemp.createTemp(
      'shosai-load-retry',
    );
    final store = await Store.open('${directory.path}/library.sqlite3');
    addTearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });
    final source = Directory('${directory.path}/source')..createSync();
    final original = File(
      'packages/shosai_core/test/fixtures/sample.epub',
    ).copySync('${source.path}/book.epub');
    final library = Library(
      store,
      managedDirectory: '${directory.path}/books',
      inspectors: {BookFormat.epub: const EpubInspector()},
    );
    final preferences = Preferences(store);
    final locations = LibraryLocations(store);
    final cache = BookFileCache(store, '${directory.path}/cache');
    final provider = _FixtureProvider(source.path);
    LibraryFolders open() => LibraryFolders(
      preferences,
      library,
      locations,
      () async => '${directory.path}/staged.epub',
      cache,
      providers: [provider],
    );
    var folders = open();
    await folders.add((await provider.setup('kept'))!);
    final book = await folders.importEntry(
      'kept',
      (await folders.browse('kept')).entries.single,
    );
    await folders.setKept(book.id, true);
    final saved = (await preferences.get('device.library.folders'))!;
    final bytes = original.readAsBytesSync();
    original.deleteSync();
    folders = open();
    await preferences.set('device.library.folders', 'not JSON');
    await expectLater(folders.list(), throwsFormatException);
    expect(
      await folders.withBookFile(book, (path) => File(path).readAsBytes()),
      bytes,
    );
    await preferences.set('device.library.folders', saved);
    // Even a failure after decoding must not memoize a failed initialization.
    provider.refreshedConfiguration['kept'] = {
      'root': source.path,
      'oversized': 'x' * maxPreferenceValueBytes,
    };
    await expectLater(folders.list(), throwsA(isA<CoreException>()));
    expect(await preferences.get('device.library.folders'), saved);
    provider.refreshedConfiguration.clear();
    expect((await folders.list()).single.id, 'kept');
    expect(
      await folders.withBookFile(book, (path) => File(path).readAsBytes()),
      bytes,
    );
    expect((await library.get(book.id))!.keptOnDevice, isTrue);
  });

  test(
    'a book removed from the library is not offered by the next scan',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-remove-source',
      );
      final store = await Store.open('${directory.path}/library.sqlite3');
      addTearDown(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      final source = Directory('${directory.path}/source')..createSync();
      final file = File(
        'packages/shosai_core/test/fixtures/sample.epub',
      ).copySync('${source.path}/book.epub');
      final library = Library(
        store,
        managedDirectory: '${directory.path}/books',
        inspectors: {BookFormat.epub: const EpubInspector()},
      );
      final locations = LibraryLocations(store);
      final folders = LibraryFolders(
        Preferences(store),
        library,
        locations,
        () async => '${directory.path}/staged.epub',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [_FixtureProvider(source.path)],
      );
      addTearDown(folders.close);
      await folders.add(
        LibraryConnection('src', 'Books', 'fixture', {'root': source.path}),
      );
      final offered = await folders.discover();
      expect(offered.map((f) => f.entry.name), ['book.epub']);
      final book = await folders.importEntry('src', offered.single.entry);
      expect(await folders.discover(refresh: true), isEmpty);

      expect((await library.remove(book.id)).removed, true);
      expect((await library.page()).books, isEmpty);
      // The file is untouched, and the shelf does not offer it again.
      expect(file.existsSync(), isTrue);
      expect(await folders.discover(refresh: true), isEmpty);
      expect((await locations.hidden()).single.entry.name, 'book.epub');

      // Unhiding offers it again, and opening it brings the book back.
      await locations.unhide((
        locationId: 'src',
        key: offered.single.entry.key,
      ));
      final again = await folders.discover(refresh: true);
      expect(again.map((f) => f.entry.name), ['book.epub']);
      final restored = await folders.importEntry('src', again.single.entry);
      expect(restored.contentHash, book.contentHash);
      expect(await locations.hidden(), isEmpty);
      expect(await folders.discover(refresh: true), isEmpty);

      // A file that changes after its book was removed is a new candidate.
      await library.remove(restored.id);
      file.writeAsBytesSync([...file.readAsBytesSync(), 0]);
      expect((await folders.discover(refresh: true)).map((f) => f.entry.name), [
        'book.epub',
      ]);
      expect(await locations.hidden(), isEmpty);
    },
  );

  testWidgets('settings manages multiple independent connections', (
    tester,
  ) async {
    Uri? authorization;
    const browserChannel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      browserChannel,
      (call) async {
        if (call.method == 'launch') {
          authorization = Uri.parse((call.arguments as Map)['url'] as String);
        }
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        browserChannel,
        null,
      ),
    );
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (directory, core) = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-connections',
      );
      final core = await ShosaiCore.open(
        directory.path,
        pdfEngine: PdfrxPdfEngine(),
      );
      for (final id in ['one', 'two']) {
        final source = Directory('${directory.path}/$id')..createSync();
        if (id == 'two') {
          File(
            'packages/shosai_core/test/fixtures/sample.epub',
          ).copySync('${source.path}/discovered.epub');
        }
        await core.folders.add(
          LibraryConnection(id, 'Books $id', 'folder', {
            'kind': 'path',
            'grant': source.path,
          }),
        );
      }
      return (directory, core);
    }))!;
    final bridge = ApplicationBridge(core);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final closing = () async {
        bridge.dispose();
        await bridge.drain();
        await core.close();
        await directory.delete(recursive: true);
      }().whenComplete(() => closed = true);
      for (var frame = 0; frame < 500 && !closed; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(closed, isTrue);
      await closing;
    });
    await tester.pumpWidget(
      productionShell(
        home: ProductShell(
          bridgeFactory: () => bridge,
          readerBuilder: (_, book, _, _, _, _, _, _, _, _) => Text(
            'Reading ${book.title}',
            key: const ValueKey('source-reader'),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      // Allow the real filesystem and database effects to complete.
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }

    await settle();
    expect(find.text('discovered').last, findsOneWidget);
    expect((await tester.runAsync(core.library.page))!.bookCount, 0);
    expect(find.text('Connections'), findsNothing);
    await tester.tap(find.text('Settings'));
    await settle();
    expect(find.text('Library connections'), findsOneWidget);
    final continuous = find.byType(ShadSwitch).first;
    final before = tester.widget<ShadSwitch>(continuous).value;
    await tester.tap(continuous);
    await tester.tap(find.text('Manage connections'));
    await settle();
    expect(find.text('Books one'), findsOneWidget);
    expect(find.text('Connect Dropbox'), findsOneWidget);
    await captureHarnessArtifact(tester, 'dropbox-connections');
    await tester.tap(find.text('Connect Dropbox'));
    await settle();
    if (DropboxConnectionProvider.defaultClientId.isEmpty) {
      expect(authorization, null);
      expect(find.textContaining('Dropbox is not configured'), findsOneWidget);
      await captureHarnessArtifact(tester, 'dropbox-registration-required');
      await tester.tap(find.widgetWithText(ShadButton, 'Close').last);
    } else {
      expect(
        authorization!.queryParameters['client_id'],
        DropboxConnectionProvider.defaultClientId,
      );
      expect(authorization!.queryParameters['code_challenge_method'], 'S256');
      expect(find.textContaining('Dropbox is not configured'), findsNothing);
      expect(find.textContaining('Add your books to this app'), findsOneWidget);
      await captureHarnessArtifact(tester, 'dropbox-default-configured');
      await tester.tap(find.widgetWithText(ShadButton, 'Cancel').last);
    }
    await settle();
    expect((await tester.runAsync(core.folders.list))!.length, 2);
    expect(
      find.descendant(
        of: find.byType(LibraryFoldersDialog),
        matching: find.text('Books two'),
      ),
      findsOneWidget,
    );
    final first = find.ancestor(
      of: find.text('Books one'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: first, matching: find.byIcon(Icons.link_off)),
    );
    await settle();
    await tester.tap(find.widgetWithText(ShadButton, 'Disconnect folder').last);
    await settle();
    expect(find.text('Books one'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(LibraryFoldersDialog),
        matching: find.text('Books two'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await settle();
    expect(find.text('Library connections'), findsOneWidget);
    expect(
      tester.widget<ShadSwitch>(continuous).value,
      !before,
      reason: 'connection management preserves reader settings',
    );
    await tester.tap(find.text('Library'));
    await settle();
    expect(
      (await tester.runAsync(core.folders.list))!.map((grant) => grant.id),
      ['two'],
    );
    await tester.ensureVisible(find.text('discovered').last);
    await tester.pump();
    await tester.tap(find.text('discovered').last);
    for (
      var attempt = 0;
      attempt < 20 &&
          find.byKey(const ValueKey('source-reader')).evaluate().isEmpty;
      attempt++
    ) {
      await settle();
    }
    expect(find.byKey(const ValueKey('source-reader')), findsOneWidget);
    final book = (await tester.runAsync(core.library.page))!.books.single;
    expect(find.text('Reading ${book.title}'), findsOneWidget);
    expect(book.located, isTrue);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Library'));
    await settle();
    await tester.pumpWidget(const SizedBox());
    await settle();
  });

  for (final (locale, action, useRoot) in [
    for (final locale in [const Locale('en'), const Locale('ja')])
      for (final action in ['folder', 'dropbox', 'google-drive'])
        for (final root in [false, if (action != 'folder') true])
          (locale, action, root),
  ]) {
    testWidgets(
      '$action confirms ${useRoot ? 'root' : 'subfolder'} without importing books (${locale.languageCode})',
      (tester) async {
        final setup = (await tester.runAsync(() async {
          final directory = await Directory.systemTemp.createTemp(
            'shosai-folders-ui',
          );
          final store = await Store.open('${directory.path}/library.sqlite3');
          final library = Library(
            store,
            managedDirectory: '${directory.path}/managed',
            inspectors: {BookFormat.epub: const EpubInspector()},
          );
          final source = Directory('${directory.path}/source')..createSync();
          Directory('${source.path}/Reading').createSync();
          File(
            'packages/shosai_core/test/fixtures/sample.epub',
          ).copySync('${source.path}/Reading/chosen.epub');
          File(
            'packages/shosai_core/test/fixtures/sample.pdf',
          ).copySync('${source.path}/unopened.pdf');
          final staging = Directory('${directory.path}/staging')..createSync();
          var stagingPath = staging.path;
          if (!Platform.isWindows) {
            // Reproduce macOS's /var versus /private/var staging paths on
            // every POSIX host, without mistaking one file for two copies.
            final alias = Link('${directory.path}/staging-alias')
              ..createSync(staging.path);
            stagingPath = alias.path;
          }
          var serial = 0;
          final provider = _FixtureProvider(source.path, id: action);
          final folders = LibraryFolders(
            Preferences(store),
            library,
            LibraryLocations(store),
            () async => '$stagingPath/stage-${serial++}',
            BookFileCache(store, '${directory.path}/cache'),
            providers: [provider],
          );
          return (directory, store, library, folders, source, provider);
        }))!;
        final (directory, store, library, folders, source, provider) = setup;
        addTearDown(() async {
          await tester.runAsync(() async {
            await store.close();
            await directory.delete(recursive: true);
          });
        });
        Future<LibraryConnection?> connect(String id, String selected) async =>
            LibraryConnection(id, 'Books', provider.id, {
              'root': source.path,
              'setup': selected,
            });
        final controller = FoldersController(
          folders: folders,
          // Local metadata fixtures exercise all three independent setup
          // intents together, not live cloud OAuth/device acceptance.
          setup: (id) => connect(id, 'folder'),
          setupDropbox: (id) => connect(id, 'dropbox'),
          setupGoogleDrive: (id) => connect(id, 'google-drive'),
          confirmRemoval: (_) async => true,
        )..dispatch(const FoldersStarted());
        addTearDown(controller.dispose);
        tester.view.physicalSize = locale.languageCode == 'ja'
            ? const Size(390, 844)
            : const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.platformBrightnessTestValue =
            locale.languageCode == 'ja' ? Brightness.dark : Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final l10n = await AppLocalizations.delegate.load(locale);
        await tester.pumpWidget(
          ShosaiShell(
            locale: locale,
            home: RepaintBoundary(
              key: harnessBoundaryKey,
              child: LibraryFoldersDialog(controller: controller),
            ),
          ),
        );
        Future<void> settle() async {
          for (
            var attempt = 0;
            controller.model.busy && attempt < 500;
            attempt++
          ) {
            await tester.pump(const Duration(milliseconds: 16));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
          expect(controller.model.busy, isFalse);
          await tester.pumpAndSettle();
          expect(controller.model.busy, isFalse);
          expect(tester.takeException(), isNull);
        }

        await settle();
        expect(find.text(l10n.dropboxConnect), findsOneWidget);
        expect(find.text(l10n.locationAddGoogleDrive), findsOneWidget);
        await tester.tap(
          find.text(switch (action) {
            'dropbox' => l10n.dropboxConnect,
            'google-drive' => l10n.locationAddGoogleDrive,
            _ => l10n.locationAddFolder,
          }),
        );
        await settle();
        if (action == 'folder') {
          await tester.tap(find.text('Books'));
          await settle();
          expect(find.text(l10n.locationSourceFolder), findsOneWidget);
          await tester.tap(find.text(l10n.locationChooseFolder));
          await settle();
        } else {
          expect(find.text(l10n.locationConfirmSource), findsOneWidget);
          expect(
            find.text(
              action == 'google-drive'
                  ? l10n.locationMyDrive
                  : l10n.locationDropboxAppFolder,
            ),
            findsOneWidget,
          );
          expect(controller.model.pending, isNotNull);
          expect(await tester.runAsync(folders.list), isEmpty);
          expect(await tester.runAsync(folders.discover), isEmpty);
          expect(
            await tester.runAsync(() => LibraryLocations(store).catalog()),
            isEmpty,
          );
          await captureHarnessArtifact(
            tester,
            'onboarding-$action-${locale.languageCode}-pending',
          );
          // A cancelled attempt is never adopted, even if the dialog later closes.
          await tester.tap(find.text(l10n.locationCancel));
          await settle();
          expect(await tester.runAsync(folders.list), isEmpty);
          expect(provider.released, hasLength(1));
          expect(find.text(l10n.dropboxConnect), findsOneWidget);
          await captureHarnessArtifact(
            tester,
            'onboarding-$action-${locale.languageCode}-cancelled',
          );
          await tester.tap(
            find.text(
              action == 'dropbox'
                  ? l10n.dropboxConnect
                  : l10n.locationAddGoogleDrive,
            ),
          );
          await settle();
        }
        expect(find.text('unopened.pdf'), findsNothing);
        if (!useRoot) {
          await tester.tap(find.text('Reading'));
          await settle();
        }
        expect(find.text('chosen.epub'), findsNothing);
        await tester.tap(find.text(l10n.locationUseFolder));
        await settle();
        expect(find.text(l10n.locationSourceFolder), findsOneWidget);
        expect(controller.model.pending, isNull);
        expect(find.text(l10n.locationMyDrive), findsNothing);
        expect(find.text(l10n.locationDropboxAppFolder), findsNothing);
        expect(
          controller.model.grants.single.directory,
          useRoot ? null : 'Reading',
        );
        if (!useRoot) expect(find.text('Reading'), findsOneWidget);
        await captureHarnessArtifact(
          tester,
          'onboarding-$action-${locale.languageCode}-${useRoot ? 'root' : 'subfolder'}-confirmed',
        );
        expect((await tester.runAsync(library.page))!.bookCount, 0);
        final files = (await tester.runAsync(folders.discover))!;
        expect(
          files.map((file) => file.entry.name),
          useRoot ? ['unopened.pdf', 'chosen.epub'] : ['chosen.epub'],
        );
        final connection = controller.model.grants.single;
        expect(connection.provider, action);
        expect(connection.configuration, {
          'root': source.path,
          'setup': action,
        });
        await tester.tap(find.widgetWithText(ShadButton, l10n.locationRemove));
        await settle();
        expect(find.text('Books'), findsNothing);
        expect((await tester.runAsync(library.page))!.bookCount, 0);
        expect(File('${source.path}/Reading/chosen.epub').existsSync(), isTrue);
        await expectLater(
          provider.open(connection),
          throwsA(isA<LocationException>()),
        );
      },
    );
  }

  test(
    'pending cloud cancellation isolates saved roots and ignores late pages',
    () async {
      final directory = await Directory.systemTemp.createTemp('pending-cloud');
      final store = await Store.open('${directory.path}/library.sqlite3');
      final provider = _FixtureProvider(directory.path);
      final preferences = Preferences(store);
      final folders = LibraryFolders(
        preferences,
        Library(store, managedDirectory: '${directory.path}/books'),
        LibraryLocations(store),
        () async => '${directory.path}/unused',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      addTearDown(() async {
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      const book = LocationEntry(
        key: 'book',
        name: 'Saved.pdf',
        isDirectory: false,
      );
      provider.locations['existing'] = _PagedLocation('existing')
        ..pages[null] = [
          LocationPage([book]),
        ];
      await folders.add(
        LibraryConnection('existing', 'Saved root', 'fixture', {
          'root': directory.path,
          'credential': 'existing',
        }),
      );
      expect((await folders.discover()).single.entry.key, 'book');
      final saved = await preferences.get('device.library.folders');
      for (final request in const [
        FoldersAddDropboxRequested(),
        FoldersAddGoogleDriveRequested(),
      ]) {
        for (final exit in [
          'cancel',
          'back',
          'dispose',
          'cancel-close',
          'back-close',
        ]) {
          final started = Completer<void>();
          final finish = Completer<void>();
          late LibraryConnection pending;
          Future<LibraryConnection?> authorize(String id) async {
            pending = LibraryConnection(id, 'Pending', 'fixture', {
              'root': directory.path,
              'credential': id,
            });
            provider.locations[id] = _PagedLocation(id)
              ..pages[null] = [
                LocationPage([book]),
              ]
              ..beforeList = (_) async {
                started.complete();
                await finish.future; // Deliberately ignores late cancellation.
              };
            return pending;
          }

          final controller = FoldersController(
            folders: folders,
            setup: (_) async => null,
            setupDropbox: authorize,
            setupGoogleDrive: authorize,
            confirmRemoval: (_) async => true,
          )..dispatch(const FoldersStarted());
          await controller.drain();
          controller.dispatch(request);
          await started.future;
          expect(controller.model.pending?.id, pending.id);
          switch (exit) {
            case 'cancel' || 'cancel-close':
              controller.dispatch(const FoldersCancelRequested());
            case 'back' || 'back-close':
              controller.dispatch(const FoldersBackRequested());
            case 'dispose':
              controller.dispose();
          }
          if (exit.endsWith('-close')) controller.dispose();
          final beforeCompletion = controller.model;
          finish.complete();
          await controller.drain();
          if (exit == 'dispose' || exit.endsWith('-close')) {
            expect(identical(controller.model, beforeCompletion), true);
          } else {
            expect(controller.model.pending, isNull);
            expect(controller.model.choosingDirectory, false);
            expect(controller.model.entries, isEmpty);
            controller.dispose();
            await controller.drain();
          }
          expect(provider.released, contains(pending.id));
          expect(provider.releaseCalls[pending.id], 1);
          expect(provider.released, isNot(contains('existing')));
          expect((await folders.list()).single.directory, isNull);
          expect(await preferences.get('device.library.folders'), saved);
          expect(
            (await folders.discover(refresh: true)).single.locationId,
            'existing',
          );
        }
      }
    },
  );

  test(
    'pending listing and cleanup retry; Back rejects a late child page',
    () async {
      final directory = await Directory.systemTemp.createTemp('pending-retry');
      final store = await Store.open('${directory.path}/library.sqlite3');
      final provider = _FixtureProvider(directory.path);
      final folders = LibraryFolders(
        Preferences(store),
        Library(store, managedDirectory: '${directory.path}/books'),
        LibraryLocations(store),
        () async => '${directory.path}/unused',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      const sub = LocationEntry(key: 'sub', name: 'Books', isDirectory: true);
      final location = _PagedLocation('pending')
        ..pages[null] = [
          LocationPage([sub]),
        ]
        ..pages['sub'] = [LocationPage([])]
        ..beforeList = (_) async =>
            throw const LocationException(LocationFailure.offline);
      provider.locations['pending'] = location;
      final controller = FoldersController(
        folders: folders,
        setup: (_) async => null,
        setupGoogleDrive: (_) async => LibraryConnection(
          'pending',
          'Drive',
          'fixture',
          {'root': directory.path},
        ),
        confirmRemoval: (_) async => true,
      );
      addTearDown(() async {
        controller.dispose();
        await controller.drain();
        expect(provider.releaseCalls['pending'], 2);
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      controller.dispatch(const FoldersAddGoogleDriveRequested());
      await controller.drain();
      expect(controller.model.error, isA<LocationException>());
      controller.dispatch(const FoldersDirectorySaved());
      expect(await folders.list(), isEmpty);
      location.beforeList = null;
      controller.dispatch(const FoldersRetryRequested());
      await controller.drain();
      expect(controller.model.error, isNull);
      expect(controller.model.entries.single.key, 'sub');
      final started = Completer<void>();
      final finish = Completer<void>();
      location.beforeList = (directory) async {
        if (directory == 'sub') {
          started.complete();
          await finish.future;
        }
      };
      controller.dispatch(const FoldersEntryChosen(sub));
      await started.future;
      controller.dispatch(const FoldersBackRequested());
      finish.complete();
      await controller.drain();
      expect(controller.model.parents, isEmpty);
      expect(controller.model.entries.single.key, 'sub');
      expect(await folders.list(), isEmpty);
      provider.releaseFailures['pending'] = const LocationException(
        LocationFailure.offline,
      );
      controller.dispatch(const FoldersCancelRequested());
      await controller.drain();
      expect(controller.model.error, isA<LocationException>());
      expect(controller.model.pending?.id, 'pending');
      expect(provider.releaseCalls['pending'], 1);
      expect(await folders.list(), isEmpty);
      provider.releaseFailures.clear();
      controller.dispatch(const FoldersCancelRequested());
      await controller.drain();
      expect(controller.model.pending, isNull);
      expect(provider.releaseCalls['pending'], 2);
      expect(provider.released, contains('pending'));
      expect(await folders.list(), isEmpty);
    },
  );

  test(
    'confirmed adoption survives disposal; rejected adoption releases pending access',
    () async {
      final directory = await Directory.systemTemp.createTemp('cloud-adoption');
      final store = await Store.open('${directory.path}/library.sqlite3');
      final provider = _FixtureProvider(directory.path);
      final folders = LibraryFolders(
        Preferences(store),
        Library(store, managedDirectory: '${directory.path}/books'),
        LibraryLocations(store),
        () async => '${directory.path}/unused',
        BookFileCache(store, '${directory.path}/cache'),
        providers: [provider],
      );
      addTearDown(() async {
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      LibraryConnection grant(String id) => LibraryConnection(
        id,
        id,
        'fixture',
        {'root': directory.path, 'credential': id},
      );
      final existing = _PagedLocation('existing')
        ..pages[null] = [LocationPage([])];
      provider.locations['existing'] = existing;
      await folders.add(grant('existing'));
      FoldersController controller(String id) {
        provider.locations[id] = _PagedLocation(id)
          ..pages[null] = [LocationPage([])];
        return FoldersController(
          folders: folders,
          setup: (_) async => null,
          setupGoogleDrive: (_) async => grant(id),
          confirmRemoval: (_) async => true,
        )..dispatch(const FoldersAddGoogleDriveRequested());
      }

      final confirmed = controller('confirmed');
      await confirmed.drain();
      final started = Completer<void>();
      final finish = Completer<void>();
      existing.beforeList = (_) async {
        started.complete();
        await finish.future;
      };
      final blocked = folders.browse('existing');
      await started.future;
      confirmed.dispatch(const FoldersDirectorySaved());
      confirmed.dispose();
      finish.complete();
      await blocked;
      await confirmed.drain();
      expect((await folders.list()).map((g) => g.id), [
        'existing',
        'confirmed',
      ]);
      expect(provider.releaseCalls['confirmed'], isNull);
      // Rejection before the adoption boundary must retain pending ownership.
      for (var i = 2; i < 32; i++) {
        await folders.add(grant('saved-$i'));
      }
      final rejected = controller('rejected');
      await rejected.drain();
      rejected.dispatch(const FoldersDirectorySaved());
      await rejected.drain();
      expect(rejected.model.error, isA<CoreException>());
      expect(rejected.model.pending?.id, 'rejected');
      rejected.dispose();
      await rejected.drain();
      expect(await folders.list(), hasLength(32));
      expect(provider.releaseCalls['rejected'], 1);
      expect(provider.released, isNot(contains('confirmed')));
    },
  );

  for (final request in const <FoldersMessage>[
    FoldersAddRequested(),
    FoldersAddDropboxRequested(),
    FoldersAddGoogleDriveRequested(),
  ]) {
    test(
      'closing during ${request.runtimeType} setup releases an unadopted connection',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'shosai-folder-dispose',
        );
        final store = await Store.open('${directory.path}/library.sqlite3');
        final library = Library(
          store,
          managedDirectory: '${directory.path}/books',
        );
        final provider = _FixtureProvider(directory.path);
        final folders = LibraryFolders(
          Preferences(store),
          library,
          LibraryLocations(store),
          () async => '${directory.path}/unused',
          BookFileCache(store, '${directory.path}/cache'),
          providers: [provider],
        );
        addTearDown(() async {
          await folders.drain();
          await store.close();
          await directory.delete(recursive: true);
        });
        final picker = Completer<LibraryConnection?>();
        final controller = FoldersController(
          folders: folders,
          setup: (_) => picker.future,
          setupDropbox: (_) => picker.future,
          setupGoogleDrive: (_) => picker.future,
          confirmRemoval: (_) async => true,
        );
        controller.dispatch(request);
        controller.dispose();
        final connection = (await provider.setup('late'))!;
        picker.complete(connection);
        await controller.drain();
        expect(await folders.list(), isEmpty);
        expect((await library.page()).bookCount, 0);
        await expectLater(
          provider.open(connection),
          throwsA(isA<LocationException>()),
        );
      },
    );
  }
}
