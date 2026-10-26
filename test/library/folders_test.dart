import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_core/shosai_core.dart' hide Row;
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/folders_controller.dart';
import 'package:shosai_flutter/library/folders_view.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../support/production_shell_harness.dart';

/// A local test adapter whose configuration has no folder-grant fields. This
/// exercises the Settings/service contract, not a pretend cloud integration.
final class _FixtureProvider implements ConnectionProvider {
  _FixtureProvider(this.root);
  final String root;
  bool released = false;
  final refreshFailures = <String, Object>{};
  final refreshedConfiguration = <String, Map<String, String>>{};

  @override
  String get id => 'fixture';

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
    if (released) throw const LocationException(LocationFailure.revoked);
    return FolderLocation.open(
      connection.id,
      connection.configuration['root']!,
    );
  }

  @override
  bool sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.configuration['root'] == second.configuration['root'];

  @override
  Future<void> release(LibraryConnection connection) async {
    released = true;
  }
}

void main() {
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

  testWidgets('settings manages multiple independent connections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
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

  for (final locale in [const Locale('en'), const Locale('ja')]) {
    testWidgets(
      'connection configures a source directory without importing books (${locale.languageCode})',
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
          final provider = _FixtureProvider(source.path);
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
        final controller = FoldersController(
          folders: folders,
          setup: (id) => folders.setup('fixture', id),
          confirmRemoval: (_) async => true,
        )..dispatch(const FoldersStarted());
        addTearDown(controller.dispose);
        tester.view.physicalSize = locale.languageCode == 'ja'
            ? const Size(390, 844)
            : const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final l10n = await AppLocalizations.delegate.load(locale);
        await tester.pumpWidget(
          ShadApp(
            locale: locale,
            theme: shosaiShadTheme(
              locale.languageCode == 'ja' ? Brightness.dark : Brightness.light,
            ),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalShadLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: LibraryFoldersDialog(controller: controller),
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
        await tester.tap(find.text(l10n.locationAddFolder));
        await settle();
        await tester.tap(find.text('Books'));
        await settle();
        expect(find.text(l10n.locationSourceFolder), findsOneWidget);
        expect(find.text('chosen.epub'), findsNothing);
        await tester.tap(find.text(l10n.locationChooseFolder));
        await settle();
        expect(find.text('unopened.pdf'), findsNothing);
        await tester.tap(find.text('Reading'));
        await settle();
        expect(find.text('chosen.epub'), findsNothing);
        await tester.tap(find.text(l10n.locationUseFolder));
        await settle();
        expect(find.text(l10n.locationSourceFolder), findsOneWidget);
        expect(find.text('Reading'), findsOneWidget);
        expect((await tester.runAsync(library.page))!.bookCount, 0);
        final files = (await tester.runAsync(folders.discover))!;
        expect(files.map((file) => file.entry.name), ['chosen.epub']);
        final connection = controller.model.grants.single;
        expect(connection.provider, 'fixture');
        expect(connection.configuration, {'root': source.path});
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
    'closing during provider setup releases an unadopted connection',
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
        confirmRemoval: (_) async => true,
      );
      controller.dispatch(const FoldersAddRequested());
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
