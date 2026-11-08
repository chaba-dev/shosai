import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shosai_core/shosai_core.dart' as core;
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_editions.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';

import '../support/production_shell_harness.dart';

final class _UnusedPdf implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) => throw UnimplementedError();
}

void main() {
  late Directory directory;
  late ShosaiCore data;
  late core.LibraryEditions shelf;
  var dataClosed = false;
  setUpAll(loadHarnessFonts);
  setUp(() async {
    dataClosed = false;
    directory = Directory.systemTemp.createTempSync('edition_picker_');
    data = await ShosaiCore.open(directory.path, pdfEngine: _UnusedPdf());
    shelf = core.LibraryEditions(data.store);
    await data.store.transaction((db) {
      for (var i = 1; i <= 4; i++) {
        final format = i == 1 || i == 4 ? 'epub' : 'pdf';
        final name =
            'AI_Agents_and_Applications${i == 3 ? '_print' : ''}.$format';
        db.execute(
          '''INSERT INTO books(title, author, format, file_path, storage_kind,
          original_path, content_hash, file_size, publication_metadata, display_name)
          VALUES (?, 'Ada Lee', ?, ?, 'referenced', ?, ?, ?, ?, ?)''',
          [
            i == 4
                ? 'AI Agents and Applications — Second Edition'
                : 'AI Agents and Applications',
            format,
            '/books/$i.$format',
            '/books/$name',
            '$i'.padLeft(64, '0'),
            i * 1024 * 1024,
            core.PublicationMetadata(
              title: 'AI Agents and Applications',
              contributors: ['Ada Lee'],
              language: 'en',
              edition: i == 4 ? '2' : '1',
            ).encode(),
            name,
          ],
        );
      }
    });
  });
  tearDown(() async {
    if (!dataClosed) await data.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'controller resumes chosen file and removes only that copy without getting stuck',
    () async {
      final opened = <int>[];
      var choices = 0;
      var action = EditionAction.read;
      final controller = LibraryController(
        bridge: ApplicationBridge(data),
        confirmRemoval: (_) async => true,
        pickImport: () async => null,
        openBook: (book) async {
          opened.add(book.bookId);
        },
        drainReaderSaves: (_) async {},
        pickEdition: (edition, _) async {
          choices++;
          return EditionChoice(action, edition.files[2].key);
        },
      );
      addTearDown(controller.dispose);
      Future<void> ready() async {
        for (var attempt = 0; attempt < 200; attempt++) {
          if (controller.model.loaded &&
              !controller.model.loading &&
              !controller.model.busy) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        fail('Library did not become ready');
      }

      controller.dispatch(const LibraryStarted());
      await ready();
      expect(controller.model.bookCount, 2);
      var edition = controller.model.editions!.singleWhere(
        (e) => e.files.length == 3,
      );
      controller.dispatch(LibraryEditionOpened(edition));
      for (var i = 0; opened.isEmpty && i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await ready();
      expect(opened, [3]);
      expect(choices, 1);
      edition = (await shelf.page(
        sources: [],
      )).editions.singleWhere((e) => e.files.length == 3);
      controller.dispatch(LibraryEditionOpened(edition));
      for (var i = 0; opened.length < 2 && i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(opened, [3, 3]);
      expect(choices, 1);
      await ready();
      action = EditionAction.remove;
      controller.dispatch(LibraryEditionOpened(edition, choose: true));
      for (var i = 0; i < 200 && await data.library.get(3) != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await ready();
      expect(await data.library.get(3), isNull, reason: controller.model.error);
      expect(await data.library.get(1), isNotNull);
      expect(await data.library.get(2), isNotNull);
      expect(controller.model.bookCount, 2);
      expect(
        controller.model.editions!
            .singleWhere((e) => e.files.length == 2)
            .files
            .length,
        2,
      );
    },
  );

  test(
    'cancelled edition opening reloads committed changes without navigation',
    () async {
      final picker = Completer<EditionChoice?>();
      final opened = <int>[];
      final controller = LibraryController(
        bridge: ApplicationBridge(data),
        confirmRemoval: (_) async => true,
        pickImport: () async => null,
        openBook: (book) async => opened.add(book.bookId),
        drainReaderSaves: (_) async {},
        pickEdition: (_, _) => picker.future,
      );
      addTearDown(controller.dispose);
      controller.dispatch(const LibraryStarted());
      for (var i = 0; i < 200 && !controller.model.loaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.model.bookCount, 2);
      final edition = controller.model.editions!.first;
      controller.dispatch(LibraryEditionOpened(edition, choose: true));
      expect(controller.model.busy, isTrue);
      // A cancelled operation may already have committed an admission. Its
      // completion must still refresh the shelf, but may never open the reader.
      final imported = await data.library.importFile(
        'packages/shosai_core/test/fixtures/sample.epub',
        managed: false,
      );
      expect(imported.error, isNull);
      controller.dispatch(const LibraryOperationCancelled());
      picker.complete(null);
      for (var i = 0; i < 200 && controller.model.bookCount != 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.model.bookCount, 3);
      expect(controller.model.busy, isFalse);
      expect(opened, isEmpty);
    },
  );

  testWidgets('an unavailable file can be retried after its source returns', (
    tester,
  ) async {
    HarnessView(size: const Size(1024, 900)).apply(tester);
    final bridge = ApplicationBridge(data);
    final result = (await tester.runAsync(() async {
      final source = Directory('${directory.path}/source')..createSync();
      final file = File(
        'packages/shosai_core/test/fixtures/sample.epub',
      ).copySync('${source.path}/chosen.epub');
      final bytes = file.readAsBytesSync();
      await data.folders.add(
        LibraryConnection('source', 'Books', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      final entry = (await data.folders.browse('source')).entries.single;
      final book = await data.folders.importEntry('source', entry);
      await data.fileCache.discardUnkept(book.contentHash, book.format);
      file.deleteSync();
      await expectLater(
        bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(anything),
      );
      file.writeAsBytesSync(bytes);
      final edition = (await shelf.page(
        sources: [],
      )).editions.singleWhere((e) => e.files.any((f) => f.book?.id == book.id));
      expect(edition.files.single.unavailable, isTrue);
      return (edition, book.id);
    }))!;
    final (edition, bookId) = result;
    EditionChoice? choice;
    await tester.pumpWidget(
      productionShell(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                choice = await showShadDialog<EditionChoice>(
                  context: context,
                  builder: (_) => LibraryQuickPicker(edition: edition),
                );
              },
              child: const Text('Retry file'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Retry file'));
    await tester.pumpAndSettle();
    await captureHarnessArtifact(tester, 'editions-unavailable-retry');
    await tester.tap(find.text('chosen.epub'));
    await tester.pumpAndSettle();
    expect(choice?.action, EditionAction.read);
    expect(choice?.fileKey, edition.files.single.key);
    await tester.runAsync(() async {
      final opened = await bridge.openLibraryBook(
        bookId: bookId,
        cancellationId: bridge.createCancellation(),
      );
      expect(opened.bookId, bookId);
      bridge.releaseDocument(handle: opened.handle);
      expect((await data.library.get(bookId))!.locationFailure, isNull);
      bridge.dispose();
      await bridge.drain();
    });
  });

  for (final state in [
    (390.0, false),
    (1024.0, false),
    (1440.0, false),
    (1024.0, true),
  ]) {
    final (width, dark) = state;
    final suffix = '${width.toInt()}${dark ? '-dark' : ''}';
    testWidgets('production grouped shelf and Quick picker at $suffix', (
      tester,
    ) async {
      HarnessView(size: Size(width, 900)).apply(tester);
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.runAsync(() async {
        await data.library.updateProgress(1, .23);
        await data.library.updateProgress(2, .68);
        final edition = (await shelf.page(
          sources: [],
        )).editions.singleWhere((e) => e.files.length == 3);
        await shelf.prefer(
          edition.id,
          core.contentEditionKey('1'.padLeft(64, '0')),
        );
      });
      final actions = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('edition-read-as-'),
      );
      await renderHarnessState(
        tester,
        productionApp(bridgeFactory: () => ApplicationBridge(data)),
        ready: () => actions.evaluate().length == 2,
      );
      await captureHarnessArtifact(tester, 'editions-shelf-$suffix');
      expect(actions, findsNWidgets(2));
      final grouped = tester
          .widget<LibraryCollection>(find.byType(LibraryCollection))
          .model
          .editions!
          .singleWhere((edition) => edition.files.length == 3);
      await tester.tap(find.byKey(ValueKey('edition-read-as-${grouped.id}')));
      // The library deliberately keeps its busy indicator while its owned
      // picker is open, so this state has no animation-free settle point.
      await pumpHarnessFrames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LibraryQuickPicker), findsOneWidget);
      expect(find.text('AI_Agents_and_Applications.epub'), findsOneWidget);
      expect(find.text('AI_Agents_and_Applications.pdf'), findsOneWidget);
      expect(find.text('AI_Agents_and_Applications_print.pdf'), findsOneWidget);
      await captureHarnessArtifact(tester, 'editions-picker-$suffix');
      expect(tester.takeException(), isNull);
      if (width == 1024 && !dark) {
        // A legacy file without edition metadata needs explicit confirmation.
        // The known second edition must never be offered as a valid target.
        await tester.runAsync(
          () => data.store.transaction((db) {
            db.execute(
              '''INSERT INTO books(title, format, file_path, storage_kind,
              original_path, content_hash, file_size, display_name)
              VALUES ('AI Agents and Applications', 'pdf', '/books/5.pdf',
              'referenced', '/books/AI_Agents_and_Applications_ebook.pdf', ?, 1024,
              'AI_Agents_and_Applications_ebook.pdf')''',
              ['5'.padLeft(64, '0')],
            );
          }),
        );
        await tester.tap(find.text('Group with…'));
        final target = find.widgetWithText(
          ListTile,
          'AI Agents and Applications',
        );
        for (
          var attempt = 0;
          attempt < 8 && target.evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)),
          );
          await pumpHarnessFrames(tester, frames: 4);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(target, findsOneWidget);
        expect(
          find.widgetWithText(
            ListTile,
            'AI Agents and Applications — Second Edition',
          ),
          findsNothing,
        );
        expect(find.byType(ShadInput), findsWidgets);
        await captureHarnessArtifact(tester, 'editions-group-dialog-1024');
        expect(tester.takeException(), isNull);
        await tester.tap(target);
        for (var attempt = 0; attempt < 20; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await pumpHarnessFrames(tester, frames: 4);
          final model = tester
              .widget<LibraryCollection>(find.byType(LibraryCollection))
              .model;
          if (!model.busy && model.editions!.any((e) => e.files.length == 4)) {
            break;
          }
        }
        final model = tester
            .widget<LibraryCollection>(find.byType(LibraryCollection))
            .model;
        expect(model.error, isNull);
        expect(model.busy, isFalse);
        expect(
          model.editions!.map((e) => e.files.length),
          unorderedEquals([4, 1]),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      // Drain callbacks created in the fake clock before leaving it; teardown
      // alone cannot advance their microtasks after a grouping reload.
      var closed = false;
      unawaited(data.close().then((_) => closed = true));
      for (var attempt = 0; attempt < 30 && !closed; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(closed, isTrue);
      dataClosed = closed;
    });
  }

  testWidgets('Quick picker returns the distinct PDF and allows separation', (
    tester,
  ) async {
    HarnessView(size: const Size(1024, 900)).apply(tester);
    final edition = await tester.runAsync(() async {
      final locations = core.LibraryLocations(data.store);
      final generation = await locations.connect('dropbox', 'Dropbox');
      final entries = [
        for (final key in ['id:original', 'id:backup'])
          core.LocationEntry(
            key: key,
            name: 'AI_Agents_and_Applications.epub',
            isDirectory: false,
            size: 1024,
            revision: 'r1',
          ),
      ];
      await locations.scan('dropbox', generation, entries);
      for (final entry in entries) {
        await locations.admit(
          'dropbox',
          generation,
          entry,
          '1'.padLeft(64, '0'),
        );
        await locations.locate('1'.padLeft(64, '0'), (
          locationId: 'dropbox',
          key: entry.key,
        ), generation: generation);
      }
      return (await shelf.page(
        sources: [],
      )).editions.singleWhere((e) => e.files.length == 3);
    });
    EditionChoice? choice;
    await tester.pumpWidget(
      productionShell(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                choice = await showShadDialog<EditionChoice>(
                  context: context,
                  builder: (_) => LibraryQuickPicker(edition: edition!),
                );
              },
              child: const Text('Choose file'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 locations'));
    await tester.pumpAndSettle();
    expect(find.text('id:original'), findsOneWidget);
    expect(find.text('id:backup'), findsOneWidget);
    await captureHarnessArtifact(tester, 'editions-locations-1024');
    await tester.tap(find.text('2 locations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI_Agents_and_Applications_print.pdf'));
    await tester.pumpAndSettle();
    expect(choice?.action, EditionAction.read);
    expect(choice?.fileKey, core.contentEditionKey('3'.padLeft(64, '0')));
    await tester.tap(find.text('Choose file'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('File actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Separate from group'));
    await tester.pumpAndSettle();
    expect(choice?.action, EditionAction.separate);
    expect(choice?.fileKey, core.contentEditionKey('1'.padLeft(64, '0')));
  });

  for (final (width, dark) in [
    (390.0, false),
    (1024.0, false),
    (1440.0, false),
    (1024.0, true),
  ]) {
    testWidgets('uncertain matches require confirmation at $width dark=$dark', (
      tester,
    ) async {
      HarnessView(size: Size(width, 900)).apply(tester);
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.runAsync(
        () => data.store.transaction((db) {
          db.execute('DELETE FROM books');
          for (var i = 1; i <= 3; i++) {
            final pdf = i == 2;
            final title = pdf
                ? 'Elixir.book'
                : i == 3
                ? 'Elixir in Action, Second Edition'
                : 'Elixir in Action';
            final name = i == 3
                ? 'Elixir_in_Action_Second_Edition.epub'
                : 'Elixir_in_Action.${pdf ? 'pdf' : 'epub'}';
            db.execute(
              '''INSERT INTO books(title, author, format, file_path, storage_kind,
            original_path, content_hash, file_size, publication_metadata, display_name, source_folder)
            VALUES (?, ?, ?, ?, 'referenced', ?, ?, 1024, ?, ?, ?)''',
              [
                title,
                pdf ? 'Dottie' : 'Saša Jurić',
                pdf ? 'pdf' : 'epub',
                '/books/$i',
                '/books/$name',
                '$i'.padLeft(64, '0'),
                core.PublicationMetadata(
                  title: title,
                  contributors: [pdf ? 'Dottie' : 'Saša Jurić'],
                  edition: pdf
                      ? null
                      : i == 3
                      ? '2'
                      : '1',
                ).encode(),
                name,
                i == 3
                    ? 'Elixir in Action, Second Edition'
                    : 'Elixir in Action, First Edition',
              ],
            );
          }
        }),
      );
      await renderHarnessState(
        tester,
        productionApp(bridgeFactory: () => ApplicationBridge(data)),
        ready: () =>
            find
                .byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key as ValueKey<String>).value.startsWith(
                        'edition-read-as-',
                      ),
                )
                .evaluate()
                .length ==
            3,
      );
      // A normal first open surfaces uncertainty; reading remains an option.
      await tester.tap(find.text('Elixir in Action').last);
      await pumpHarnessFrames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LibraryQuickPicker), findsOneWidget);
      expect(find.text('Review possible matches (1)'), findsOneWidget);
      final suffix = '${width.toInt()}${dark ? '-dark' : ''}';
      await captureHarnessArtifact(
        tester,
        'automatic-uncertain-picker-$suffix',
      );
      await tester.tap(find.text('Review possible matches (1)'));
      final target = find.widgetWithText(ListTile, 'Elixir.book');
      for (
        var attempt = 0;
        attempt < 12 && target.evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await pumpHarnessFrames(tester, frames: 4);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Possible matches'), findsOneWidget);
      expect(target, findsOneWidget);
      expect(find.textContaining('Matching filename'), findsOneWidget);
      expect(find.textContaining('Title or author differs'), findsOneWidget);
      expect(
        find.widgetWithText(ListTile, 'Elixir in Action, Second Edition'),
        findsNothing,
      );
      expect(
        (await tester.runAsync(() => shelf.page(sources: [])))!.bookCount,
        3,
      );
      await captureHarnessArtifact(tester, 'automatic-review-$suffix');
      expect(tester.takeException(), isNull);
      await tester.tap(target);
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await pumpHarnessFrames(tester, frames: 4);
        final model = tester
            .widget<LibraryCollection>(find.byType(LibraryCollection))
            .model;
        if (!model.busy && model.bookCount == 2) break;
      }
      expect(
        tester
            .widget<LibraryCollection>(find.byType(LibraryCollection))
            .model
            .bookCount,
        2,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      var closed = false;
      unawaited(data.close().then((_) => closed = true));
      for (var attempt = 0; attempt < 30 && !closed; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(closed, isTrue);
      dataClosed = closed;
    });
  }
}
