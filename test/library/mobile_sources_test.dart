import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart' hide Row;
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';
import 'package:shosai_flutter/library/folders_controller.dart';
import 'package:shosai_flutter/library/folders_view.dart';
import 'package:shosai_flutter/library/view.dart';

import '../support/production_shell_harness.dart';

/// A folder-backed adapter registered under [id], so one fixture stands in
/// for a device folder (`folder`) and a storage account (`dropbox`).
final class _Provider implements ConnectionProvider {
  _Provider(this.id);

  @override
  final String id;

  int setups = 0;

  @override
  Future<LibraryConnection?> setup(String connectionId) async {
    setups += 1;
    return null;
  }

  @override
  Future<LibraryConnection> refresh(LibraryConnection connection) async =>
      connection;

  @override
  Future<LibraryLocation> open(LibraryConnection connection) =>
      FolderLocation.open(connection.id, connection.configuration['root']!);

  @override
  bool sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.configuration['root'] == second.configuration['root'];

  @override
  Future<void> release(LibraryConnection connection) async {}
}

Future<({LibraryFolders folders, Directory directory, Store store})> _folders(
  WidgetTester? tester, {
  required bool folderSources,
}) async {
  final directory = await Directory.systemTemp.createTemp('shosai-mobile');
  final store = await Store.open('${directory.path}/library.sqlite3');
  for (final name in ['device', 'account']) {
    await Directory('${directory.path}/$name').create();
    await File('${directory.path}/$name/$name book.epub').writeAsString('x');
  }
  final folders = LibraryFolders(
    Preferences(store),
    Library(store, managedDirectory: '${directory.path}/books'),
    LibraryLocations(store),
    () async => '${directory.path}/unused',
    BookFileCache(store, '${directory.path}/cache'),
    providers: [
      _Provider(FolderConnectionProvider.providerId),
      _Provider('dropbox'),
    ],
    folderSources: folderSources,
  );
  await folders.add(
    LibraryConnection('device', 'Device', FolderConnectionProvider.providerId, {
      'root': '${directory.path}/device',
    }),
  );
  await folders.add(
    LibraryConnection('account', 'Dropbox', 'dropbox', {
      'root': '${directory.path}/account',
    }),
  );
  return (folders: folders, directory: directory, store: store);
}

void main() {
  setUpAll(loadHarnessFonts);

  test('phones and tablets never scan a device folder', () async {
    final (:folders, :directory, :store) = await _folders(
      null,
      folderSources: false,
    );
    addTearDown(() async {
      await folders.close();
      await store.close();
      await directory.delete(recursive: true);
    });

    final found = await folders.discover();
    expect(found.map((file) => file.title), ['account book']);
    // The old folder connection is kept, so Settings can disconnect it.
    expect((await folders.list()).map((grant) => grant.id), [
      'device',
      'account',
    ]);
    await expectLater(
      folders.setup(FolderConnectionProvider.providerId, 'new'),
      throwsA(
        isA<CoreException>().having(
          (error) => error.kind,
          'kind',
          CoreErrorKind.unsupported,
        ),
      ),
    );
  });

  test('desktop scans folders and accounts alike', () async {
    final (:folders, :directory, :store) = await _folders(
      null,
      folderSources: true,
    );
    addTearDown(() async {
      await folders.close();
      await store.close();
      await directory.delete(recursive: true);
    });

    final found = await folders.discover();
    expect(found.map((file) => file.title).toSet(), {
      'device book',
      'account book',
    });
  });

  test('a mobile connections dialog offers no folder and starts the '
      'connection Add books asked for', () async {
    final (:folders, :directory, :store) = await _folders(
      null,
      folderSources: false,
    );
    var folderSetups = 0;
    var dropboxSetups = 0;
    final controller = FoldersController(
      folders: folders,
      supportsFolders: false,
      setup: (_) async {
        folderSetups += 1;
        return null;
      },
      setupDropbox: (_) async {
        dropboxSetups += 1;
        return null;
      },
      confirmRemoval: (_) async => false,
    );
    addTearDown(() async {
      controller.dispose();
      await controller.drain();
      await folders.close();
      await store.close();
      await directory.delete(recursive: true);
    });

    controller.dispatch(
      const FoldersStarted(then: FoldersAddDropboxRequested()),
    );
    await controller.drain();
    expect(dropboxSetups, 1, reason: 'the dialog opened on Dropbox');

    controller.dispatch(const FoldersAddRequested());
    await controller.drain();
    expect(folderSetups, 0, reason: 'no folder is connected on mobile');
  });

  testWidgets('the mobile connections dialog lists an old folder only to '
      'disconnect it', (tester) async {
    late final LibraryFolders folders;
    late final Directory directory;
    late final Store store;
    await tester.runAsync(() async {
      final opened = await _folders(tester, folderSources: false);
      folders = opened.folders;
      directory = opened.directory;
      store = opened.store;
    });
    final controller = FoldersController(
      folders: folders,
      supportsFolders: false,
      setup: (_) async => null,
      setupDropbox: (_) async => null,
      confirmRemoval: (_) async => false,
    );
    addTearDown(() async {
      controller.dispose();
      await tester.runAsync(() async {
        await controller.drain();
        await folders.close();
        await store.close();
        await directory.delete(recursive: true);
      });
    });

    await tester.pumpWidget(
      productionShell(
        home: Scaffold(body: LibraryFoldersDialog(controller: controller)),
      ),
    );
    await tester.runAsync(() async {
      controller.dispatch(const FoldersStarted());
      await controller.drain();
    });
    await tester.pumpAndSettle();

    expect(find.text('Connect folder'), findsNothing);
    expect(find.text('Connect Dropbox'), findsOneWidget);
    expect(find.text('Folders aren’t read on phones and tablets'), findsOne);
    expect(find.byTooltip('Disconnect folder'), findsNWidgets(2));
    final device = tester.widget<ListTile>(
      find.ancestor(of: find.text('Device'), matching: find.byType(ListTile)),
    );
    expect(device.onTap, isNull, reason: 'its folder cannot be browsed');
  });

  group('controller', () {
    LibraryController controllerFor(
      HarnessBridge bridge, {
      LibraryImportPicker? pickImport,
      LibraryConnectionsManager? manageConnections,
      DateTime Function()? now,
    }) => LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: pickImport ?? () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
      manageConnections: manageConnections,
      now: now ?? DateTime.now,
    );

    Future<void> idle(LibraryController controller) async {
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(Duration.zero);
        if (!controller.model.busy && !controller.model.loading) return;
      }
      fail('the controller never settled');
    }

    test('returning to the app rescans at most once a minute', () async {
      final bridge = HarnessBridge();
      var clock = DateTime(2026, 11, 3, 9);
      final controller = controllerFor(bridge, now: () => clock);
      addTearDown(controller.dispose);
      controller.dispatch(const LibraryStarted());
      await idle(controller);
      final started = bridge.libraryCalls;

      clock = clock.add(const Duration(seconds: 30));
      controller.dispatch(const LibraryResumed());
      await idle(controller);
      expect(bridge.libraryCalls, started, reason: 'it scanned a moment ago');

      clock = clock.add(const Duration(minutes: 1));
      controller.dispatch(const LibraryResumed());
      await idle(controller);
      expect(bridge.libraryCalls, started + 1);
    });

    test('Add books can open the connections on an account', () async {
      final bridge = HarnessBridge();
      final starts = <LibraryConnectionKind?>[];
      final controller = controllerFor(
        bridge,
        pickImport: () async => const LibraryImportSelection.connect(
          LibraryConnectionKind.googleDrive,
        ),
        manageConnections: (start) async => starts.add(start),
      );
      addTearDown(controller.dispose);
      controller.dispatch(const LibraryStarted());
      await idle(controller);

      controller.dispatch(const LibraryImportRequested());
      await idle(controller);
      await idle(controller);
      expect(starts, [LibraryConnectionKind.googleDrive]);
      expect(controller.model.importing, isFalse);
    });
  });
}
