import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/library/view.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../support/protected_pdf.dart';

void main() {
  test(
    'unlock refreshes shelf metadata and cover while reader stays open',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-unlock-shelf-',
      );
      final core = await ShosaiCore.open(
        '${directory.path}/library',
        pdfEngine: PdfrxPdfEngine(passwords: TestPasswordStore()),
      );
      final owner = CoreOwner(core);
      final bridge = owner.bridge();
      final readerClosed = Completer<void>();
      final readerOpened = Completer<void>();
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => null,
        passwordPrompt: (_) async => 'fixture-password',
        openBook: (_) async {
          readerOpened.complete();
          await readerClosed.future;
        },
        drainReaderSaves: (_) async {},
      );
      addTearDown(() async {
        if (!readerClosed.isCompleted) readerClosed.complete();
        controller.dispose();
        await owner.close();
        await directory.delete(recursive: true);
      });
      Future<void> until(bool Function() condition) async {
        for (var attempt = 0; attempt < 500 && !condition(); attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(condition(), isTrue);
      }

      final pdf = await protectedPdf(directory);
      final cancellation = bridge.createCancellation();
      final imported = await bridge.importPaths(
        pathKeys: [pdf.path],
        managed: true,
        cancellationId: cancellation,
      );
      bridge.releaseCancellation(id: cancellation);
      final locked = imported.items.single.book!;
      controller.dispatch(const LibraryStarted());
      await until(() => controller.model.loaded && !controller.model.loading);
      expect(
        controller.model.books.single.protection,
        FlutterBookProtection.password,
      );
      controller.dispatch(LibraryCoverRequested(locked.bookId));
      await until(() => controller.model.covers.containsKey(locked.bookId));
      expect(controller.model.covers[locked.bookId], isEmpty);

      controller.dispatch(LibraryBookOpened(locked));
      await readerOpened.future.timeout(const Duration(seconds: 5));
      await until(
        () => controller.model.books.single.title == 'Unlocked fixture title',
      );
      final book = controller.model.books.single;
      expect(book.author, 'Fixture author');
      expect(book.protection, FlutterBookProtection.none);
      expect(
        controller.model.editions!.single.displayFile.title,
        'Unlocked fixture title',
      );
      controller.dispatch(LibraryCoverRequested(locked.bookId));
      await until(
        () => controller.model.covers[locked.bookId]?.isNotEmpty ?? false,
      );
      final coverCancellation = bridge.createCancellation();
      expect(
        controller.model.covers[locked.bookId],
        await bridge.libraryCover(
          bookId: locked.bookId,
          cancellationId: coverCancellation,
        ),
      );
      bridge.releaseCancellation(id: coverCancellation);
      expect(readerClosed.isCompleted, isFalse);
    },
  );

  test('schema18 books reclassify on their page or before reader navigation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'shosai-legacy-drm-',
    );
    final oldStore = await Store.open(
      '${directory.path}/library.sqlite3',
      migrations: schemaMigrations.where((m) => m.version <= 18).toList(),
    );
    for (var id = 1; id <= 3; id++) {
      final title = '$id legacy fixture';
      final archive = Archive();
      final entries = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml':
            '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
        'book.opf':
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>$title</dc:title></metadata><manifest/><spine/></package>',
        if (id < 3)
          'META-INF/encryption.xml':
              '<encryption><EncryptedData><EncryptionMethod Algorithm="urn:synthetic:encrypted"/></EncryptedData></encryption>',
      };
      for (final entry in entries.entries) {
        archive.addFile(ArchiveFile.string(entry.key, entry.value));
      }
      final file = await File(
        '${directory.path}/$id.epub',
      ).writeAsBytes(ZipEncoder().encode(archive));
      final fingerprint = await fingerprintFile(file.path);
      await oldStore.transaction(
        (db) => db.execute(
          '''INSERT INTO books (id, title, format, file_path, storage_kind,
             original_path, content_hash, file_size)
           VALUES (?, ?, 'epub', ?, 'referenced', ?, ?, ?)''',
          [id, title, file.path, file.path, fingerprint.hash, fingerprint.size],
        ),
      );
    }
    await oldStore.transaction((db) {
      db.execute(
        "INSERT INTO library_locations (id, label) VALUES ('fixture', 'Synthetic')",
      );
      db.execute(
        "INSERT INTO library_source_previews (location_id, locator_key, title) VALUES ('fixture', 'old.epub', 'Old preview')",
      );
    });
    await oldStore.close();
    var core = await ShosaiCore.open(
      directory.path,
      pdfEngine: PdfrxPdfEngine(passwords: TestPasswordStore()),
    );
    var owner = CoreOwner(core);
    addTearDown(() async {
      await owner.close();
      await directory.delete(recursive: true);
    });
    var bridge = owner.bridge();
    expect(await core.locations.previews(), isEmpty);
    expect((await core.library.get(1))!.protectionChecked, isFalse);
    var cancellation = bridge.createCancellation();
    final page = await bridge.libraryPage(
      sort: FlutterLibrarySort.title,
      limit: 1,
      offset: 0,
      cancellationId: cancellation,
    );
    expect(page.books.single.protection, FlutterBookProtection.drm);
    expect((await core.library.get(1))!.protectionChecked, isTrue);
    expect((await core.library.get(2))!.protectionChecked, isFalse);
    expect((await core.library.get(3))!.protectionChecked, isFalse);
    final shown = Completer<void>();
    var navigations = 0;
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {
        navigations++;
      },
      drainReaderSaves: (_) async {},
      showLockedBook: () async {
        shown.complete();
      },
    );
    addTearDown(controller.dispose);
    controller.dispatch(
      LibraryBookOpened(
        FlutterLibraryBook(
          bookId: 2,
          title: '2 legacy fixture',
          format: FlutterBookFormat.epub,
          pathKey: '${directory.path}/2.epub',
          managed: false,
          progress: 0,
          dateAdded: '2026-11-18',
        ),
      ),
    );
    await shown.future.timeout(const Duration(seconds: 5));
    expect(navigations, 0);
    expect((await core.library.get(2))!.protection, BookProtection.drm);
    expect((await core.library.get(2))!.protectionChecked, isTrue);
    controller.dispose();
    await owner.close();
    core = await ShosaiCore.open(
      directory.path,
      pdfEngine: PdfrxPdfEngine(passwords: TestPasswordStore()),
    );
    owner = CoreOwner(core);
    bridge = owner.bridge();
    cancellation = bridge.createCancellation();
    expect((await core.library.get(2))!.protectionChecked, isTrue);
    expect(
      await bridge.bookProtection(bookId: 2, cancellationId: cancellation),
      FlutterBookProtection.drm,
    );
    expect(
      await bridge.bookProtection(bookId: 3, cancellationId: cancellation),
      FlutterBookProtection.none,
    );
    bridge.releaseCancellation(id: cancellation);
  });

  test(
    'migrated grouped shelves classify visible files beyond raw page bounds',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-grouped-drm-',
      );
      final oldStore = await Store.open(
        '${directory.path}/library.sqlite3',
        migrations: schemaMigrations.where((m) => m.version <= 18).toList(),
      );
      for (var id = 1; id <= 52; id++) {
        final title =
            'Legacy pair ${((id - 1) ~/ 2).toString().padLeft(2, '0')}';
        final archive = Archive();
        for (final entry in {
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml':
              '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
          'META-INF/encryption.xml':
              '<encryption><EncryptedData><EncryptionMethod Algorithm="urn:synthetic:encrypted"/></EncryptedData></encryption>',
          // Deliberately different: classification must not reorder/regroup the
          // shelf by overwriting its existing publication facts.
          'book.opf':
              '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Other title $id</dc:title></metadata><manifest/><spine/></package>',
        }.entries) {
          archive.addFile(ArchiveFile.string(entry.key, entry.value));
        }
        final file = await File(
          '${directory.path}/$id.epub',
        ).writeAsBytes(ZipEncoder().encode(archive));
        final fingerprint = await fingerprintFile(file.path);
        await oldStore.transaction(
          (db) => db.execute(
            '''INSERT INTO books (id, title, author, format, file_path, storage_kind,
             original_path, content_hash, file_size, publication_metadata)
           VALUES (?, ?, 'Fixture author', 'epub', ?, 'referenced', ?, ?, ?, ?)''',
            [
              id,
              title,
              file.path,
              file.path,
              fingerprint.hash,
              fingerprint.size,
              PublicationMetadata(
                title: title,
                contributors: ['Fixture author'],
                edition: '1',
                language: 'en',
              ).encode(),
            ],
          ),
        );
      }
      await oldStore.close();
      final core = await ShosaiCore.open(
        directory.path,
        pdfEngine: PdfrxPdfEngine(passwords: TestPasswordStore()),
      );
      final owner = CoreOwner(core);
      addTearDown(() async {
        await owner.close();
        await directory.delete(recursive: true);
      });
      final bridge = owner.bridge();
      final cancellation = bridge.createCancellation();
      final first = await bridge.editionPage(
        sources: [],
        query: '',
        format: null,
        sort: LibrarySort.title,
        limit: 1,
        offset: 0,
        cancellationId: cancellation,
      );
      expect(first.editions.single.readingFile.protection, BookProtection.drm);
      final firstId = first.editions.single.readingFile.book!.id;
      expect((await core.library.get(firstId))!.title, 'Legacy pair 00');
      expect(
        (await core.library.get(firstId == 1 ? 2 : 1))!.protectionChecked,
        isFalse,
      );
      expect((await core.library.get(51))!.protectionChecked, isFalse);
      // A second bounded pass advances to another member, rather than spending
      // its budget checking the same already-classified raw-book page.
      await bridge.editionPage(
        sources: [],
        query: '',
        format: null,
        sort: LibrarySort.title,
        limit: 1,
        offset: 0,
        cancellationId: cancellation,
      );
      expect(
        (await core.library.get(firstId == 1 ? 2 : 1))!.protectionChecked,
        isTrue,
      );
      expect((await core.library.get(3))!.protectionChecked, isFalse);
      final grouped = await bridge.editions.page(
        sources: [],
        sort: LibrarySort.title,
      );
      final chosen = grouped.editions.singleWhere(
        (edition) => edition.files.any((file) => file.book!.id == 52),
      );
      await bridge.editions.prefer(
        chosen.id,
        chosen.files.singleWhere((file) => file.book!.id == 52).key,
      );
      bridge.releaseCancellation(id: cancellation);
      await core.librarySettings.saveSort(LibrarySort.title);
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => null,
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
      );
      addTearDown(controller.dispose);
      controller.dispatch(const LibraryStarted());
      for (var attempt = 0; attempt < 500; attempt++) {
        if (controller.model.loaded &&
            !controller.model.loading &&
            !controller.model.busy) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.model.loaded, isTrue, reason: controller.model.error);
      expect(controller.model.editions, hasLength(26));
      expect(controller.model.hasMore, isFalse);
      expect(
        controller.model.editions!
            .singleWhere((edition) => edition.id == chosen.id)
            .readingFile
            .book!
            .id,
        52,
      );
      for (final edition in controller.model.editions!) {
        expect(edition.files, hasLength(2));
        expect(edition.readingFile.protection, BookProtection.drm);
      }
      expect((await core.library.get(51))!.protectionChecked, isTrue);
      expect((await core.library.get(52))!.protectionChecked, isTrue);
    },
  );

  test(
    'locked imports preserve files and metadata, unlock, and reopen after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shosai-protected-library-',
      );
      final vault = TestPasswordStore();
      final dataPath = '${directory.path}/library';
      var core = await ShosaiCore.open(
        dataPath,
        pdfEngine: PdfrxPdfEngine(passwords: vault),
      );
      var owner = CoreOwner(core);
      var bridge = owner.bridge();
      addTearDown(() async {
        await owner.close();
        await directory.delete(recursive: true);
      });
      final pdf = await protectedPdf(directory);
      final originalBytes = await pdf.readAsBytes();
      final unsupported = File('${directory.path}/unsupported-security.pdf');
      final pdfSource = String.fromCharCodes(originalBytes);
      expect(pdfSource, contains('/Standard'));
      // Keep byte offsets valid while naming an unsupported security handler.
      await unsupported.writeAsBytes(
        pdfSource.replaceFirst('/Standard', '/UnknownX').codeUnits,
      );
      final permissions = await protectedPdf(
        directory,
        name: 'permissions-only',
        password: '',
      );
      final epub = File('${directory.path}/protected.epub');
      final entries = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml':
            '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
        'META-INF/encryption.xml':
            '<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData></encryption>',
        'book.opf':
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>DRM fixture title</dc:title><dc:creator>Fixture author</dc:creator></metadata><manifest/><spine/></package>',
      };
      final archive = Archive();
      for (final entry in entries.entries) {
        archive.addFile(ArchiveFile.string(entry.key, entry.value));
      }
      await epub.writeAsBytes(ZipEncoder().encode(archive));
      var cancellation = bridge.createCancellation();
      final imported = await bridge.importPaths(
        pathKeys: [epub.path, pdf.path, permissions.path, unsupported.path],
        managed: true,
        cancellationId: cancellation,
      );
      expect(imported.failed.toInt(), 0);
      expect(imported.imported.toInt(), 4);
      final drm = imported.items[0].book!;
      final locked = imported.items[1].book!;
      expect(
        (drm.title, drm.author, drm.protection),
        ('DRM fixture title', 'Fixture author', FlutterBookProtection.drm),
      );
      expect(
        (locked.title, locked.protection),
        ('password-sample', FlutterBookProtection.password),
      );
      expect(imported.items[2].book!.protection, FlutterBookProtection.none);
      expect(imported.items[3].book!.protection, FlutterBookProtection.drm);
      await expectLater(
        bridge.openLibraryBook(
          bookId: imported.items[3].book!.bookId,
          cancellationId: cancellation,
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (e) => e.kind,
            'kind',
            FlutterBridgeErrorKind.protected,
          ),
        ),
      );
      await expectLater(
        bridge.openLibraryBook(
          bookId: drm.bookId,
          cancellationId: cancellation,
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (e) => e.kind,
            'kind',
            FlutterBridgeErrorKind.protected,
          ),
        ),
      );
      await expectLater(
        bridge.openLibraryBook(
          bookId: locked.bookId,
          cancellationId: cancellation,
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (e) => e.kind,
            'kind',
            FlutterBridgeErrorKind.passwordRequired,
          ),
        ),
      );
      expect(
        await bridge.unlockPdf(
          bookId: locked.bookId,
          pathKey: locked.pathKey,
          password: 'wrong-fixture-password',
          cancellationId: cancellation,
        ),
        isFalse,
      );
      expect(vault.values, isEmpty);
      final managedPdf = File(locked.pathKey);
      await managedPdf.writeAsBytes(await permissions.readAsBytes());
      await expectLater(
        bridge.unlockPdf(
          bookId: locked.bookId,
          pathKey: locked.pathKey,
          password: 'fixture-password',
          cancellationId: cancellation,
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (e) => e.kind,
            'kind',
            FlutterBridgeErrorKind.invalidRequest,
          ),
        ),
      );
      expect(vault.values, isEmpty);
      await managedPdf.writeAsBytes(originalBytes);
      expect(
        await bridge.unlockPdf(
          bookId: locked.bookId,
          pathKey: locked.pathKey,
          password: 'fixture-password',
          cancellationId: cancellation,
        ),
        isTrue,
      );
      final updated = (await bridge.libraryPage(
        limit: 10,
        offset: 0,
        cancellationId: cancellation,
      )).books.singleWhere((b) => b.bookId == locked.bookId);
      expect(
        (updated.title, updated.author, updated.protection),
        (
          'Unlocked fixture title',
          'Fixture author',
          FlutterBookProtection.none,
        ),
      );
      expect(await File(locked.pathKey).readAsBytes(), originalBytes);
      expect(await pdf.readAsBytes(), originalBytes);
      bridge.releaseCancellation(id: cancellation);

      await owner.close();
      core = await ShosaiCore.open(
        dataPath,
        pdfEngine: PdfrxPdfEngine(passwords: vault),
      );
      owner = CoreOwner(core);
      bridge = owner.bridge();
      cancellation = bridge.createCancellation();
      final reopened = await bridge.openLibraryBook(
        bookId: locked.bookId,
        cancellationId: cancellation,
      );
      expect(reopened.logicalUnitCount.toInt(), 1);
      expect(reopened.title, 'Unlocked fixture title');
      expect(await File(reopened.contentPath!).readAsBytes(), originalBytes);
      bridge.releaseDocument(handle: reopened.handle);
      bridge.releaseCancellation(id: cancellation);
      final database = await File('$dataPath/library.sqlite3').readAsBytes();
      expect(
        String.fromCharCodes(database),
        isNot(contains('fixture-password')),
      );
    },
  );
}
