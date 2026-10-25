import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_core/shosai_core.dart' hide Row;
import 'package:shosai_flutter/app_theme.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/core/platform_folder_location.dart';
import 'package:shosai_flutter/l10n/app_localizations.dart';
import 'package:shosai_flutter/library/folders_controller.dart';
import 'package:shosai_flutter/library/folders_view.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../support/production_shell_harness.dart';

void main() {
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
          FolderGrant(id, 'Books $id', 'path', source.path),
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
      // The controller owns the settings effect until the dialog closes, so
      // its activity indicator intentionally keeps scheduling frames.
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
      reason: 'connection management preserves unsaved reader settings',
    );
    await tester.tap(find.text('Save'));
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
          final folders = LibraryFolders(
            Preferences(store),
            library,
            LibraryLocations(store),
            () async => '$stagingPath/stage-${serial++}',
            BookFileCache(store, '${directory.path}/cache'),
          );
          return (directory, store, library, folders, source);
        }))!;
        final (directory, store, library, folders, source) = setup;
        addTearDown(() async {
          await tester.runAsync(() async {
            await store.close();
            await directory.delete(recursive: true);
          });
        });
        final controller = FoldersController(
          folders: folders,
          pick: (id) async => FolderGrant(id, 'Books', 'path', source.path),
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
        await tester.tap(find.widgetWithText(ShadButton, l10n.locationRemove));
        await settle();
        expect(find.text('Books'), findsNothing);
        expect((await tester.runAsync(library.page))!.bookCount, 0);
        expect(File('${source.path}/Reading/chosen.epub').existsSync(), isTrue);
      },
    );
  }

  test('closing during a folder picker cannot persist a late grant', () async {
    final directory = await Directory.systemTemp.createTemp(
      'shosai-folder-dispose',
    );
    final store = await Store.open('${directory.path}/library.sqlite3');
    final library = Library(store, managedDirectory: '${directory.path}/books');
    final folders = LibraryFolders(
      Preferences(store),
      library,
      LibraryLocations(store),
      () async => '${directory.path}/unused',
      BookFileCache(store, '${directory.path}/cache'),
    );
    addTearDown(() async {
      await folders.drain();
      await store.close();
      await directory.delete(recursive: true);
    });
    final picker = Completer<FolderGrant?>();
    final controller = FoldersController(
      folders: folders,
      pick: (_) => picker.future,
      confirmRemoval: (_) async => true,
    );
    controller.dispatch(const FoldersAddRequested());
    controller.dispose();
    picker.complete(FolderGrant('late', 'Too late', 'path', directory.path));
    await pumpEventQueue();
    expect(await folders.list(), isEmpty);
    expect((await library.page()).bookCount, 0);
  });
}
