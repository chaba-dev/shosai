import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart'
    show
        BookAnchor,
        FolderLocation,
        LocationFailure,
        Preferences,
        maxPreferenceRows,
        maxPreferenceValueBytes,
        maxPreferenceTotalBytes;
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/reader_text.dart';
import 'package:shosai_flutter/core/records.dart';
import 'package:shosai_flutter/reader/pdf/engine.dart';
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/library/controller.dart';

const _epubFixture = 'packages/shosai_core/test/fixtures/sample.epub';
const _pdfFixture = 'packages/shosai_core/test/fixtures/sample.pdf';

/// A PDF engine whose documents have a title and a one-colour first page.
final class _PdfEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _PdfDocument();
}

final class _PdfDocument implements PdfEngineDocument {
  @override
  int get pageCount => 2;

  @override
  Future<PdfDocumentInfo> info() async =>
      const PdfDocumentInfo(title: 'Engine Title', author: 'Engine Author');

  @override
  PdfPageSize pageSize(int page) => const PdfPageSize(600, 800);

  @override
  Future<PdfRenderedPage> render(int page, double scale) async {
    final width = (600 * scale).round();
    final height = (800 * scale).round();
    return PdfRenderedPage(
      width: width,
      height: height,
      pixels: Uint8List(width * height * 4)
        ..fillRange(0, width * height * 4, 200),
    );
  }

  @override
  Future<String> pageText(int page) async => 'Page $page text';

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A PDF engine that opens documents whose metadata read and disposal fail
/// the way an initialised-but-broken PDFium does: with plain exceptions.
final class _FailingPdfEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> open(String path) async => _FailingPdfDocument();
}

final class _FailingPdfDocument extends _PdfDocument {
  @override
  Future<PdfDocumentInfo> info() async => throw Exception('PDFium failed');

  @override
  Future<void> dispose() async => throw Exception('PDFium failed again');
}

/// A PDF engine whose documents read their file lazily, as PDFium does:
/// each page's text is the file's content when the text is asked for. Tests
/// gate opens, text reads and disposal with completers.
final class _FilePdfEngine implements PdfEngine {
  /// Runs before each open with the path being opened.
  FutureOr<void> Function(String path)? onOpen;

  /// When set, a text read waits for it.
  Completer<void>? textGate;

  /// Completes when a text read is waiting at [textGate].
  Completer<void> textRequested = Completer<void>();

  var failDispose = false;

  /// When set, a disposal waits for it.
  Completer<void>? disposeGate;
  final opened = <String>[];
  final documents = <_FilePdfDocument>[];

  @override
  Future<PdfEngineDocument> open(String path) async {
    await onOpen?.call(path);
    opened.add(path);
    final document = _FilePdfDocument(this, path);
    documents.add(document);
    return document;
  }
}

final class _FilePdfDocument extends _PdfDocument {
  _FilePdfDocument(this._engine, this.path);

  final _FilePdfEngine _engine;
  final String path;
  var disposals = 0;

  @override
  int get pageCount => 1;

  @override
  Future<String> pageText(int page) async {
    if (_engine.textGate case final gate?) {
      if (!_engine.textRequested.isCompleted) _engine.textRequested.complete();
      await gate.future;
    }
    return File(path).readAsStringSync();
  }

  @override
  Future<void> dispose() async {
    disposals += 1;
    await _engine.disposeGate?.future;
    if (_engine.failDispose) throw Exception('PDFium failed to close');
  }
}

FlutterSelectionSurface _surface(
  String text, {
  String? resourcePath,
  bool copyEligible = true,
  List<FlutterSelectionEndpoint> endpoints = const [],
}) => FlutterSelectionSurface(
  width: 680,
  height: 900,
  text: text,
  copyEligible: copyEligible,
  resourcePath: resourcePath,
  endpoints: endpoints,
  graphemeBoundaries: Uint32List(0),
  wordBoundaries: Uint32List(0),
  visualLines: const [],
);

void main() {
  late Directory directory;
  late ShosaiCore core;
  late ApplicationBridge bridge;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('shosai_records');
    core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
    bridge = ApplicationBridge(core);
  });

  tearDown(() async {
    await core.close();
    directory.deleteSync(recursive: true);
  });

  Future<FlutterLibraryBook> import(String fixture) async {
    final name = fixture.split('/').last;
    final path = '${directory.path}/$name';
    File(fixture).copySync(path);
    final cancellation = bridge.createCancellation();
    final report = await bridge.importPaths(
      pathKeys: [path],
      managed: false,
      cancellationId: cancellation,
    );
    expect(report.items.single.error, isNull);
    return report.items.single.book!;
  }

  test(
    'large source catalogs survive restart without preference-size limits',
    () async {
      final source = Directory('${directory.path}/source')..createSync();
      for (var i = 0; i < 600; i++) {
        File('${source.path}/book-$i.epub').writeAsStringSync('metadata only');
      }
      await core.folders.add(
        LibraryConnection('large', 'Large', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      expect(await core.folders.discover(), hasLength(600));
      await core.close();
      core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
      bridge = ApplicationBridge(core);
      expect(await core.folders.discover(), hasLength(600));
      await core.folders.remove('large');
      expect(await core.folders.discover(), isEmpty);
    },
  );

  test(
    'an incomplete source scan preserves prior metadata and other sources',
    () async {
      final broken = Directory('${directory.path}/broken')..createSync();
      final healthy = Directory('${directory.path}/healthy')..createSync();
      File('${broken.path}/old.epub').writeAsStringSync('metadata only');
      File('${healthy.path}/good.pdf').writeAsStringSync('metadata only');
      await core.folders.add(
        LibraryConnection('broken', 'Broken', 'folder', {
          'kind': 'path',
          'grant': broken.path,
        }),
      );
      await core.folders.add(
        LibraryConnection('healthy', 'Healthy', 'folder', {
          'kind': 'path',
          'grant': healthy.path,
        }),
      );
      expect(await core.folders.discover(), hasLength(2));
      var deep = broken;
      for (var i = 0; i < 34; i++) {
        deep = Directory('${deep.path}/nested')..createSync();
      }
      File('${deep.path}/too-deep.epub').writeAsStringSync('metadata only');
      final files = await core.folders.discover(refresh: true);
      expect(files.map((file) => file.entry.name).toSet(), {
        'old.epub',
        'good.pdf',
      });
      expect(core.folders.scanWarnings, ['Broken']);
      expect(await core.folders.discover(), hasLength(2));
      expect(core.folders.scanWarnings, ['Broken']);
      await core.folders.remove('broken');
      expect((await core.folders.discover()).single.entry.name, 'good.pdf');
      expect(core.folders.scanWarnings, isEmpty);
    },
  );

  test(
    'source warnings retain healthy results and retry a repaired source',
    () async {
      final broken = Directory('${directory.path}/broken')..createSync();
      final healthy = Directory('${directory.path}/healthy')..createSync();
      var deep = broken;
      for (var i = 0; i < 34; i++) {
        deep = Directory('${deep.path}/nested')..createSync();
      }
      File('${deep.path}/hidden.epub').writeAsStringSync('metadata only');
      File('${healthy.path}/good.pdf').writeAsStringSync('metadata only');
      await core.folders.add(
        LibraryConnection('broken', 'Deep books', 'folder', {
          'kind': 'path',
          'grant': broken.path,
        }),
      );
      await core.folders.add(
        LibraryConnection('healthy', 'Healthy', 'folder', {
          'kind': 'path',
          'grant': healthy.path,
        }),
      );
      final controller = LibraryController(
        bridge: bridge,
        confirmRemoval: (_) async => true,
        pickImport: () async => null,
        openBook: (_) async {},
        drainReaderSaves: (_) async {},
      );
      addTearDown(controller.dispose);
      Future<void> loaded() async {
        for (
          var i = 0;
          i < 400 && (controller.model.loading || !controller.model.loaded);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(controller.model.loading, isFalse);
        expect(controller.model.loaded, isTrue);
      }

      controller.dispatch(const LibraryStarted());
      await loaded();
      expect(controller.model.sourceFiles.single.entry.name, 'good.pdf');
      expect(controller.model.sourceWarning, contains('Deep books'));
      expect(controller.model.sourceWarning, contains('Settings'));
      expect(controller.model.loadError, isNull);
      expect(controller.model.error, isNull);
      controller.dispatch(const LibraryFormatChanged(FlutterBookFormat.epub));
      await loaded();
      expect(controller.model.sourceFiles, isEmpty);
      expect(controller.model.displayError, contains('Deep books'));
      Directory('${broken.path}/nested').deleteSync(recursive: true);
      File('${broken.path}/repaired.epub').writeAsStringSync('metadata only');
      controller.dispatch(const LibraryRetryRequested());
      await loaded();
      expect(controller.model.sourceFiles.single.entry.name, 'repaired.epub');
      expect(controller.model.sourceWarning, isNull);
      expect(controller.model.loadError, isNull);
    },
  );

  test(
    'changed admitted files return as candidates without changing old notes',
    () async {
      final source = Directory('${directory.path}/source')..createSync();
      final file = File(_epubFixture).copySync('${source.path}/chosen.epub');
      await core.folders.add(
        LibraryConnection('changed', 'Books', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      final candidate = (await core.folders.discover()).single;
      final original = await core.folders.importEntry(
        'changed',
        candidate.entry,
      );
      await core.annotations.createNote(
        original.id,
        const BookAnchor(),
        'Old content note',
      );
      expect(await core.folders.discover(refresh: true), isEmpty);
      file.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
      expect(
        (await core.folders.discover(refresh: true)).single.entry.size,
        original.fileSize + 3,
      );
      expect(
        (await core.library.get(original.id))!.contentHash,
        original.contentHash,
      );
      expect(
        (await core.annotations.summary(original.id)).latest,
        'Old content note',
      );
    },
  );

  test(
    'configured sources discover metadata, admit on open and preserve missing books',
    () async {
      final source = Directory('${directory.path}/source')..createSync();
      final selected = Directory('${source.path}/Reading')..createSync();
      final nested = Directory('${selected.path}/History')..createSync();
      final chosen = File(_epubFixture).copySync('${nested.path}/chosen.epub');
      // An unopened file need not even be parseable: scanning must not admit it.
      File('${selected.path}/unopened.pdf').writeAsStringSync('not a PDF');
      File(
        '${source.path}/excluded.epub',
      ).writeAsStringSync('outside selected root');
      for (var i = 0; i < 110; i++) {
        File('${selected.path}/ignore-$i.txt').writeAsStringSync('ignored');
      }
      await core.folders.add(
        LibraryConnection('source', 'My books', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      final root = (await core.folders.browse(
        'source',
      )).entries.singleWhere((entry) => entry.isDirectory);
      await core.folders.configure(
        'source',
        directory: root.key,
        label: 'Reading',
      );
      var files = await core.folders.discover();
      expect(files.map((file) => file.entry.name).toSet(), {
        'chosen.epub',
        'unopened.pdf',
      });
      expect((await core.library.page()).bookCount, 0);
      final admitted = await bridge.admitSourceFile(
        files.singleWhere((file) => file.entry.name == 'chosen.epub'),
      );
      expect(admitted.located, isTrue);
      await core.annotations.createNote(
        admitted.bookId,
        const BookAnchor(),
        'Retain this note',
      );
      files = await core.folders.discover();
      expect(files.single.entry.name, 'unopened.pdf');
      final opened = await bridge.openLibraryBook(
        bookId: admitted.bookId,
        cancellationId: bridge.createCancellation(),
      );
      bridge.releaseDocument(handle: opened.handle);
      await core.close();
      core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
      bridge = ApplicationBridge(core);
      expect((await core.folders.list()).single.directory, root.key);
      expect((await core.folders.discover()).single.entry.name, 'unopened.pdf');
      // A valid cached copy remains readable even if its source disappears.
      // Evict that automatic copy to exercise source-only unavailability.
      final identified = (await core.library.get(admitted.bookId))!;
      await core.fileCache.discardUnkept(
        identified.contentHash,
        identified.format,
      );
      chosen.deleteSync();
      await core.folders.discover(refresh: true);
      expect(
        (await core.library.get(admitted.bookId))!.locationFailure?.name,
        'missing',
      );
      expect(
        (await core.annotations.summary(admitted.bookId)).latest,
        'Retain this note',
      );
      await core.folders.remove('source');
      expect(await core.folders.discover(), isEmpty);
      expect(
        (await core.library.get(admitted.bookId))!.locationFailure?.name,
        'revoked',
      );
      expect(
        (await core.annotations.summary(admitted.bookId)).latest,
        'Retain this note',
      );
    },
  );

  for (final atCapacity in [false, true]) {
    test(
      'legacy folder connections migrate without reconnecting or losing content (at capacity: $atCapacity)',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        var nativeGrant = 'opaque-device-grant';
        const channel = MethodChannel('dev.shosai/library_folders');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'refresh') return nativeGrant;
          expect(call.method, 'release');
          expect(call.arguments, {'grant': nativeGrant});
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final source = Directory('${directory.path}/legacy')..createSync();
        final selected = Directory('${source.path}/Reading')..createSync();
        final chosen = File(
          _epubFixture,
        ).copySync('${selected.path}/chosen.epub');
        File(
          '${selected.path}/unopened.pdf',
        ).writeAsStringSync('metadata only');
        File(
          '${source.path}/excluded.pdf',
        ).writeAsStringSync('outside selection');
        final adapter = await FolderLocation.open(
          'folder-original',
          source.path,
        );
        final root = (await adapter.list()).entries.singleWhere(
          (entry) => entry.isDirectory,
        );
        final entries = (await adapter.list(directory: root.key)).entries;
        final entry = entries.singleWhere(
          (entry) => entry.name == 'chosen.epub',
        );
        final generation = await core.locations.connect(
          'folder-original',
          'Original',
        );
        await core.locations.scan('folder-original', generation, entries);
        final book = (await core.library.importFile(
          chosen.path,
          managed: false,
        )).book!;
        await core.locations.admit(
          'folder-original',
          generation,
          entry,
          book.contentHash,
        );
        await core.locations.locate(book.contentHash, (
          locationId: 'folder-original',
          key: entry.key,
        ), generation: generation);
        await core.annotations.createNote(
          book.id,
          const BookAnchor(),
          'Pre-upgrade note',
        );
        await core.fileCache.withFile(
          book,
          chosen.openRead,
          (_) async {},
          keep: true,
        );
        await core.locations.unavailable(
          'folder-original',
          generation,
          LocationFailure.offline,
        );
        final catalog = [
          for (final file in await core.locations.catalog())
            (
              file.locationId,
              file.entry.key,
              file.entry.name,
              file.entry.size,
              file.entry.revision,
            ),
        ];
        final copies = await core.locations.copies(book.contentHash);
        final legacy = [
          {
            'id': 'folder-original',
            'label': 'Original',
            'kind': 'path',
            'grant': source.path,
            'directory': root.key,
            'directoryLabel': 'Reading',
          },
          {
            'id': 'folder-native',
            'label': 'Native',
            'kind': 'platform',
            'grant': nativeGrant,
            'directory': 'opaque-directory',
            'directoryLabel': 'Books/Reading',
          },
        ];
        final preferences = Preferences(core.store);
        var raw = jsonEncode(legacy);
        if (atCapacity) {
          nativeGrant +=
              'x' * (maxPreferenceValueBytes - utf8.encode(raw).length);
          legacy[1]['grant'] = nativeGrant;
          raw = jsonEncode(legacy);
          expect(utf8.encode(raw).length, maxPreferenceValueBytes);
          final values = {
            ...await preferences.getAll(),
            'device.library.folders': raw,
          };
          for (var index = 0; values.length < maxPreferenceRows; index++) {
            values['padding-$index'] = '';
          }
          var remaining =
              maxPreferenceTotalBytes -
              values.entries.fold<int>(
                0,
                (size, entry) =>
                    size +
                    utf8.encode(entry.key).length +
                    utf8.encode(entry.value).length,
              );
          for (final key in values.keys.where(
            (key) => key.startsWith('padding-'),
          )) {
            final length = remaining > maxPreferenceValueBytes
                ? maxPreferenceValueBytes
                : remaining;
            values[key] = 'x' * length;
            remaining -= length;
          }
          expect(remaining, 0);
          await preferences.setAll(values);
          expect((await preferences.getAll()).length, maxPreferenceRows);
        } else {
          await preferences.set('device.library.folders', raw);
        }
        bridge.dispose();
        await bridge.drain();
        await core.close();
        core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
        bridge = ApplicationBridge(core);
        final connections = await core.folders.list();
        expect(connections.map((connection) => connection.id), [
          'folder-original',
          'folder-native',
        ]);
        for (var index = 0; index < legacy.length; index++) {
          expect(connections[index].provider, 'folder');
          expect(connections[index].configuration, {
            'kind': legacy[index]['kind'],
            'grant': legacy[index]['grant'],
          });
          expect(connections[index].directory, legacy[index]['directory']);
          expect(
            connections[index].directoryLabel,
            legacy[index]['directoryLabel'],
          );
        }
        expect([
          for (final file in await core.locations.catalog())
            (
              file.locationId,
              file.entry.key,
              file.entry.name,
              file.entry.size,
              file.entry.revision,
            ),
        ], catalog);
        expect(await core.locations.copies(book.contentHash), copies);
        expect((await core.library.get(book.id))!.keptOnDevice, isTrue);
        expect(
          (await core.library.get(book.id))!.locationFailure,
          isNull,
          reason:
              'a kept copy remains readable despite the retained offline locator',
        );
        expect(
          (await core.annotations.summary(book.id)).latest,
          'Pre-upgrade note',
        );
        final persisted =
            jsonDecode(
                  (await Preferences(
                    core.store,
                  ).get('device.library.folders'))!,
                )
                as List;
        expect(persisted, [
          for (final connection in connections) connection.toJson(),
        ]);
        if (atCapacity) {
          expect(
            (await Preferences(core.store).getAll()).length,
            maxPreferenceRows,
          );
        }
        // Native permission cleanup remains provider-owned, not a filesystem path.
        await core.folders.remove('folder-native');
        expect(
          (await core.folders.discover()).single.entry.name,
          'unopened.pdf',
        );
        await source.delete(recursive: true);
        expect(
          (await core.folders.discover(refresh: true)).single.entry.name,
          'unopened.pdf',
        );
        final opened = await bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        );
        expect(opened.bookId, book.id);
        bridge.releaseDocument(handle: opened.handle);
        await core.folders.remove('folder-original');
        bridge.dispose();
        await bridge.drain();
        await core.close();
        core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
        bridge = ApplicationBridge(core);
        expect(
          await core.folders.list(),
          isEmpty,
          reason: 'removed legacy grants never resurrect',
        );
        expect((await core.library.get(book.id))!.keptOnDevice, isTrue);
        expect(
          (await core.annotations.summary(book.id)).latest,
          'Pre-upgrade note',
        );
      },
    );
  }

  for (final managed in [false, true]) {
    test('duplicate folder import preserves a local book ($managed)', () async {
      final source = Directory('${directory.path}/source')..createSync();
      final file = File(_epubFixture).copySync('${source.path}/chosen.epub');
      final imported = await core.library.importFile(
        file.path,
        managed: managed,
      );
      final original = imported.book!;
      await core.folders.add(
        LibraryConnection('duplicate', 'My books', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      final page = await core.folders.browse('duplicate');
      final duplicate = await core.folders.importEntry(
        'duplicate',
        page.entries.single,
      );
      expect(duplicate.id, original.id);
      expect(await core.folders.discover(refresh: true), isEmpty);
      await core.close();
      core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
      bridge = ApplicationBridge(core);
      expect(await core.folders.discover(), isEmpty);
      await core.folders.remove('duplicate');
      expect((await core.library.get(original.id))!.locationFailure, isNull);
      final opened = await bridge.openLibraryBook(
        bookId: original.id,
        cancellationId: bridge.createCancellation(),
      );
      expect(opened.title, original.title);
      bridge.releaseDocument(handle: opened.handle);
      expect((await core.library.page()).bookCount, 1);
    });
  }

  test(
    'folder books open on demand after restart and reconnect without losing notes',
    () async {
      final source = Directory('${directory.path}/source')..createSync();
      final chosen = File(_epubFixture).copySync('${source.path}/chosen.epub');
      File(_pdfFixture).copySync('${source.path}/unopened.pdf');
      final original = chosen.readAsBytesSync();
      await core.folders.add(
        LibraryConnection('device-folder', 'My books', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      final entries = await core.folders.browse('device-folder');
      expect(
        entries.entries.map((entry) => entry.name),
        containsAll(['chosen.epub', 'unopened.pdf']),
      );
      expect(
        (await core.library.page()).bookCount,
        0,
        reason: 'listing never imports an entire library',
      );
      final selected = entries.entries.singleWhere(
        (entry) => entry.name == 'chosen.epub',
      );
      final book = await core.folders.importEntry('device-folder', selected);
      expect((await core.library.page()).bookCount, 1);
      expect(
        File(book.path).existsSync(),
        isFalse,
        reason: 'the transient staging file is released',
      );
      expect(chosen.existsSync(), isTrue);
      await core.annotations.createNote(
        book.id,
        const BookAnchor(),
        'These notes follow content, not its grant.',
      );

      bridge.dispose();
      await bridge.drain();
      await core.close();
      core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
      bridge = ApplicationBridge(core);
      final opened = await bridge.openLibraryBook(
        bookId: book.id,
        cancellationId: bridge.createCancellation(),
      );
      expect(opened.bookId, book.id);
      expect(opened.logicalUnitCount, greaterThan(BigInt.zero));
      expect(bridge.releaseDocument(handle: opened.handle), isTrue);

      chosen.deleteSync();
      final cached = await bridge.openLibraryBook(
        bookId: book.id,
        cancellationId: bridge.createCancellation(),
      );
      expect(
        cached.bookId,
        book.id,
        reason: 'a cached book opens without its source',
      );
      bridge.releaseDocument(handle: cached.handle);
      await core.fileCache.discardUnkept(book.contentHash, book.format);
      await expectLater(
        bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.kind,
            'kind',
            FlutterBridgeErrorKind.notFound,
          ),
        ),
      );
      expect(
        (await bridge.libraryPage(
          limit: 10,
          offset: 0,
          cancellationId: bridge.createCancellation(),
        )).books.single.unavailable,
        isTrue,
      );
      chosen.writeAsBytesSync(original);
      final restored = await bridge.openLibraryBook(
        bookId: book.id,
        cancellationId: bridge.createCancellation(),
      );
      bridge.releaseDocument(handle: restored.handle);
      expect(
        (await bridge.libraryPage(
          limit: 10,
          offset: 0,
          cancellationId: bridge.createCancellation(),
        )).books.single.unavailable,
        isFalse,
      );

      chosen.writeAsBytesSync([...original, 11]);
      await core.fileCache.discardUnkept(book.contentHash, book.format);
      await expectLater(
        bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(isA<FlutterBridgeError>()),
      );
      expect(
        (await bridge.libraryPage(
          limit: 10,
          offset: 0,
          cancellationId: bridge.createCancellation(),
        )).books.single.unavailable,
        isTrue,
        reason: 'replacement bytes are not the old content identity',
      );
      chosen.writeAsBytesSync(original);
      await core.folders.remove('device-folder');
      await expectLater(
        bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(isA<FlutterBridgeError>()),
      );
      expect(
        chosen.existsSync(),
        isTrue,
        reason: 'disconnect never deletes a source book',
      );
      await core.folders.add(
        LibraryConnection('new-device-grant', 'Reconnected', 'folder', {
          'kind': 'path',
          'grant': source.path,
        }),
      );
      final same = await core.folders.importEntry('new-device-grant', selected);
      expect(same.id, book.id);
      expect(
        (await core.annotations.summary(book.id)).latest,
        'These notes follow content, not its grant.',
      );
      expect((await core.library.page()).bookCount, 1);

      await core.folders.setKept(book.id, true);
      expect((await core.library.get(book.id))!.keptOnDevice, isTrue);
      await core.folders.remove('new-device-grant');
      chosen.deleteSync();
      bridge.dispose();
      await bridge.drain();
      await core.close();
      core = await ShosaiCore.open(directory.path, pdfEngine: _PdfEngine());
      bridge = ApplicationBridge(core);
      final offline = await bridge.openLibraryBook(
        bookId: book.id,
        cancellationId: bridge.createCancellation(),
      );
      expect(
        offline.bookId,
        book.id,
        reason: 'an explicitly kept copy survives disconnect and restart',
      );
      bridge.releaseDocument(handle: offline.handle);
      await core.folders.setKept(book.id, false);
      expect((await core.library.get(book.id))!.keptOnDevice, isFalse);
      expect((await core.library.get(book.id))!.locationFailure, isNotNull);
      await expectLater(
        bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(isA<FlutterBridgeError>()),
      );
      expect(
        (await core.annotations.summary(book.id)).latest,
        'These notes follow content, not its grant.',
      );
    },
  );

  test(
    'a removed location retains its book and notes as unavailable',
    () async {
      final imported = await import(_epubFixture);
      final book = (await core.library.get(imported.bookId))!;
      final generation = await core.locations.connect('folder', 'My books');
      await core.locations.locate(book.contentHash, (
        locationId: 'folder',
        key: 'book.epub',
      ), generation: generation);
      await core.annotations.createNote(
        book.id,
        const BookAnchor(),
        'A note that outlives the folder.',
      );
      await core.locations.remove('folder');

      final page = await bridge.libraryPage(
        limit: 10,
        offset: 0,
        cancellationId: bridge.createCancellation(),
      );
      expect(page.books.single.bookId, book.id);
      expect(page.books.single.unavailable, isTrue);
      final notes = await bridge.libraryNotes(
        limit: 10,
        offset: 0,
        cancellationId: bridge.createCancellation(),
      );
      expect(
        notes.books.single.notes.single.body,
        'A note that outlives the folder.',
      );
      expect(notes.books.single.book.unavailable, isTrue);
      final hits = <FlutterBookTextHits>[];
      await bridge.searchLibraryText(
        query: 'book',
        onBook: hits.add,
        cancellationId: bridge.createCancellation(),
      );
      expect(hits.single.matches, isEmpty);
      expect(hits.single.error, contains('location is unavailable'));
      await expectLater(
        bridge.openLibraryBook(
          bookId: book.id,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.kind,
            'kind',
            FlutterBridgeErrorKind.notFound,
          ),
        ),
      );
    },
  );

  test('library books import, list, open and remove', () async {
    final epub = await import(_epubFixture);
    final pdf = await import(_pdfFixture);

    expect(pdf.title, 'Engine Title');
    expect(pdf.author, 'Engine Author');
    expect(epub.managed, isFalse);
    final page = await bridge.libraryPage(
      limit: 10,
      offset: 0,
      cancellationId: bridge.createCancellation(),
    );
    expect(
      page.books.map((book) => book.bookId),
      unorderedEquals([epub.bookId, pdf.bookId]),
    );
    expect(page.hasMore, isFalse);
    expect(
      await bridge.libraryCover(
        bookId: pdf.bookId,
        cancellationId: bridge.createCancellation(),
      ),
      isNotNull,
    );

    final opened = await bridge.openLibraryBook(
      bookId: epub.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(opened.bookId, epub.bookId);
    expect(opened.title, epub.title);
    expect(opened.format, FlutterBookFormat.epub);
    final book = await bridge.epubBook(
      document: opened.handle,
      cancellationId: bridge.createCancellation(),
    );
    expect(opened.logicalUnitCount, BigInt.from(book.chapters.length));
    expect(bridge.releaseDocument(handle: opened.handle), isTrue);
    expect(bridge.releaseDocument(handle: opened.handle), isFalse);

    final removed = await bridge.removeLibraryBook(bookId: epub.bookId);
    expect(removed.removed, isTrue);
    await expectLater(
      bridge.openLibraryBook(
        bookId: epub.bookId,
        cancellationId: bridge.createCancellation(),
      ),
      throwsA(
        isA<FlutterBridgeError>().having(
          (error) => error.kind,
          'kind',
          FlutterBridgeErrorKind.notFound,
        ),
      ),
    );
  });

  test('a cancelled import reports what it finished', () async {
    final cancellation = bridge.createCancellation();
    expect(bridge.cancel(id: cancellation), isTrue);
    final path = '${directory.path}/sample.epub';
    File(_epubFixture).copySync(path);

    final report = await bridge.importPaths(
      pathKeys: [path],
      managed: false,
      cancellationId: cancellation,
    );

    expect(report.cancelled, isTrue);
    expect(report.imported, BigInt.zero);
  });

  test('a PDF engine failure fails only its own import item', () async {
    final failing = Directory.systemTemp.createTempSync('shosai_records');
    addTearDown(() => failing.deleteSync(recursive: true));
    final failingCore = await ShosaiCore.open(
      failing.path,
      pdfEngine: _FailingPdfEngine(),
    );
    addTearDown(failingCore.close);
    final failingBridge = ApplicationBridge(failingCore);
    final paths = [
      for (final (fixture, name) in [
        (_epubFixture, 'first.epub'),
        (_pdfFixture, 'broken.pdf'),
        (_epubFixture, 'second.epub'),
      ])
        (File(fixture).copySync('${failing.path}/$name')).path,
    ];

    final report = await failingBridge.importPaths(
      pathKeys: paths,
      managed: false,
      cancellationId: failingBridge.createCancellation(),
    );

    expect(report.imported, BigInt.two);
    expect(report.failed, BigInt.one);
    expect(report.items[1].error, contains('PDFium failed'));
    expect(report.items[2].book, isNotNull);
  });

  test('reading state, bookmarks and settings round trip', () async {
    final book = await import(_epubFixture);

    await bridge.saveReadingState(
      bookId: book.bookId,
      value: FlutterReadingState(
        unit: BigInt.one,
        offset: BigInt.from(7),
        zoom: 1.5,
      ),
      unitCount: BigInt.from(4),
    );
    final state = await bridge.loadReadingState(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(
      state,
      FlutterReadingState(unit: BigInt.one, offset: BigInt.from(7), zoom: 1.5),
    );

    final bookmark = await bridge.toggleBookmark(
      bookId: book.bookId,
      unit: BigInt.two,
      title: 'Chapter 3',
    );
    expect(bookmark!.unit, BigInt.two);
    expect(bookmark.bookId, book.bookId);
    final [listed] = await bridge.listBookmarks(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.title, 'Chapter 3');
    expect(
      await bridge.exportBookmarks(bookId: book.bookId),
      contains('Chapter 3'),
    );
    await bridge.deleteBookmark(id: bookmark.id);
    expect(
      await bridge.listBookmarks(
        bookId: book.bookId,
        cancellationId: bridge.createCancellation(),
      ),
      isEmpty,
    );

    expect(
      (await bridge.loadReaderSettings(
        cancellationId: bridge.createCancellation(),
      )).animations,
      isTrue,
    );
    const settings = FlutterReaderSettings(
      continuous: true,
      theme: 'sepia',
      epubFontSize: 20,
      epubLineSpacing: 1.8,
      pdfZoom: -1,
      twoPages: false,
      animations: false,
      progress: FlutterReaderProgress.percent,
      zonesHintDismissed: true,
      librarySort: FlutterLibrarySort.title,
    );
    await bridge.saveReaderSettings(value: settings);
    expect(
      await bridge.loadReaderSettings(
        cancellationId: bridge.createCancellation(),
      ),
      settings,
    );
    await expectLater(
      bridge.saveReaderSettings(
        value: const FlutterReaderSettings(
          continuous: false,
          theme: 'neon',
          epubFontSize: 16,
          epubLineSpacing: 1.6,
          pdfZoom: 0,
        ),
      ),
      throwsA(isA<FlutterBridgeError>()),
    );
  });

  test('EPUB annotations resolve against the reader text', () async {
    final book = await import(_epubFixture);
    final document = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    const chapter = 'The lead Café text tail.';
    const path = 'OEBPS/chapter.xhtml';
    final records = bridge.records;

    final created = await records.createAnnotation(
      document: document,
      surface: _surface(chapter, resourcePath: path),
      unit: BigInt.one,
      start: BigInt.from(9),
      end: BigInt.from(13),
      displayScale: 2,
      color: FlutterHighlightColor.green,
      body: 'Note',
      cancellationId: bridge.createCancellation(),
    );
    expect(created.resolution, FlutterAnnotationResolution.exact);
    expect(
      created.textRange,
      FlutterAnnotationTextRange(start: BigInt.from(9), end: BigInt.from(13)),
    );
    expect(created.quote, 'Café');
    expect(created.color, FlutterHighlightColor.green);
    expect(created.body, 'Note');

    final text = EpubReaderText(
      unitCount: 3,
      text: (unit) async => unit == 1 ? 'Inserted. $chapter' : '',
      resourcePath: (unit) async => unit == 1 ? path : 'other.xhtml',
    );
    final [listed] = await records.listAnnotations(
      document: document,
      text: text,
      scale: 1,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.resolution, FlutterAnnotationResolution.recovered);
    expect(
      listed.textRange,
      FlutterAnnotationTextRange(start: BigInt.from(19), end: BigInt.from(23)),
    );

    expect(
      await records.updateAnnotation(
        document: document,
        id: created.id,
        color: FlutterHighlightColor.pink,
      ),
      isTrue,
    );
    expect(
      await records.deleteAnnotation(document: document, id: created.id),
      isTrue,
    );
    expect(
      await records.listAnnotations(
        document: document,
        text: text,
        scale: 1,
        cancellationId: bridge.createCancellation(),
      ),
      isEmpty,
    );

    final matches = await records.searchDocument(
      document: document,
      text: text,
      query: 'CAFÉ',
      cancellationId: bridge.createCancellation(),
    );
    expect(matches.single.unit, BigInt.one);
    expect(matches.single.offset, BigInt.from(19));
  });

  test('page notes and book notes are listed apart from highlights', () async {
    final book = await import(_epubFixture);
    final document = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    const chapter = 'The lead Café text tail.';
    const path = 'OEBPS/chapter.xhtml';
    final text = EpubReaderText(
      unitCount: 3,
      text: (unit) async => unit == 1 ? chapter : '',
      resourcePath: (unit) async => unit == 1 ? path : 'other.xhtml',
    );
    final records = bridge.records;
    await records.createAnnotation(
      document: document,
      surface: _surface(chapter, resourcePath: path),
      unit: BigInt.one,
      start: BigInt.from(9),
      end: BigInt.from(13),
      displayScale: 1,
      color: FlutterHighlightColor.green,
      cancellationId: bridge.createCancellation(),
    );

    final page = await records.createNote(
      document: document,
      text: text,
      unit: BigInt.one,
      offset: BigInt.from(4),
      body: 'The lead matters.',
      cancellationId: bridge.createCancellation(),
    );
    expect(page.kind, FlutterNoteKind.page);
    expect(page.unit, BigInt.one);
    expect(page.offset, BigInt.from(4));
    final whole = await records.createNote(
      document: document,
      text: text,
      body: 'Reading group pick.',
      cancellationId: bridge.createCancellation(),
    );
    expect(whole.kind, FlutterNoteKind.book);
    expect(whole.unit, isNull);

    expect(
      await records.updateNote(
        document: document,
        id: page.id,
        body: 'The lead matters most.',
      ),
      isTrue,
    );
    final listed = await records.listNotes(
      document: document,
      text: text,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.map((note) => (note.kind, note.body)), [
      (FlutterNoteKind.book, 'Reading group pick.'),
      (FlutterNoteKind.page, 'The lead matters most.'),
    ]);
    expect(listed.last.resolution, FlutterAnnotationResolution.exact);
    final [highlight] = await records.listAnnotations(
      document: document,
      text: text,
      scale: 1,
      cancellationId: bridge.createCancellation(),
    );
    expect(highlight.quote, 'Café');

    expect(
      await records.deleteAnnotation(document: document, id: whole.id),
      isTrue,
    );
    expect(
      await records.listNotes(
        document: document,
        text: text,
        cancellationId: bridge.createCancellation(),
      ),
      hasLength(1),
    );

    // The library's notes list the book's highlight and page note in
    // reading order, from the store alone.
    final library = await records.libraryNotes(
      limit: 20,
      offset: 0,
      cancellationId: bridge.createCancellation(),
    );
    expect(library.hasMore, isFalse);
    final [listedBook] = library.books;
    expect(listedBook.book.bookId, book.bookId);
    expect(
      listedBook.notes.map(
        (note) => (note.kind, note.unit, note.offset, note.quote, note.body),
      ),
      [
        (FlutterNoteEntryKind.page, 1, 4, null, 'The lead matters most.'),
        (FlutterNoteEntryKind.highlight, 1, 9, 'Café', null),
      ],
    );
    expect(listedBook.notes.last.color, FlutterHighlightColor.green);
  });

  test(
    'a file opened directly lists its highlights without its notes',
    () async {
      final book = await import(_epubFixture);
      final library = await bridge.openLibraryBook(
        bookId: book.bookId,
        cancellationId: bridge.createCancellation(),
      );
      final highlight = await bridge.createAnnotation(
        document: library.handle,
        unit: BigInt.zero,
        start: BigInt.zero,
        end: BigInt.from(4),
        displayScale: 1,
        color: FlutterHighlightColor.blue,
        cancellationId: bridge.createCancellation(),
      );
      for (final unit in [BigInt.zero, null]) {
        await bridge.createNote(
          document: library.handle,
          unit: unit,
          offset: unit == null ? null : BigInt.one,
          body: 'Note',
          cancellationId: bridge.createCancellation(),
        );
      }

      final direct = await bridge.openDocument(
        request: FlutterOpenRequest(
          localId: 'direct',
          pathKey: '${directory.path}/sample.epub',
        ),
        cancellationId: bridge.createCancellation(),
      );
      expect(direct.bookId, isNull);

      final listed = await bridge.listAnnotations(
        document: direct.handle,
        scale: 1,
        cancellationId: bridge.createCancellation(),
      );
      expect(listed.map((a) => a.id), [highlight.id]);
    },
  );
  test('library search finds notes and book text across the library', () async {
    final epub = await import(_epubFixture);
    final pdf = await import(_pdfFixture);
    final document = await bridge.openLibraryBook(
      bookId: epub.bookId,
      cancellationId: bridge.createCancellation(),
    );
    final records = bridge.records;
    await records.createNote(
      document: document,
      text: EpubReaderText(
        unitCount: 1,
        text: (_) async => 'Chapter text.',
        resourcePath: (_) async => 'OEBPS/chapter.xhtml',
      ),
      unit: BigInt.zero,
      offset: BigInt.zero,
      body: 'The lead matters.',
      cancellationId: bridge.createCancellation(),
    );

    final [notes] = await records.searchLibraryNotes(
      query: 'LEAD',
      cancellationId: bridge.createCancellation(),
    );
    expect(notes.book.bookId, epub.bookId);
    final [hit] = notes.hits;
    expect(hit.note.kind, FlutterNoteEntryKind.page);
    expect(hit.matches, const [
      FlutterNoteMatch(field: FlutterNoteField.body, offset: 4, length: 4),
    ]);

    // The PDF is opened, its text read and saved, then released.
    final found = <FlutterBookTextHits>[];
    await records.searchLibraryText(
      query: 'PAGE 1',
      bookId: pdf.bookId,
      onBook: found.add,
      cancellationId: bridge.createCancellation(),
    );
    final [text] = found;
    expect(text.book.bookId, pdf.bookId);
    expect(text.error, isNull);
    expect(text.matches.single.unit, BigInt.one);
    expect(text.matches.single.offset, BigInt.zero);
  });

  test('PDF annotations keep page rectangles in page points', () async {
    final book = await import(_pdfFixture);
    final document = await bridge.openLibraryBook(
      bookId: book.bookId,
      cancellationId: bridge.createCancellation(),
    );
    FlutterSelectionEndpoint endpoint(int character, double left) =>
        FlutterSelectionEndpoint(
          offset: BigInt.from(character),
          rangeStart: BigInt.from(character),
          rangeEnd: BigInt.from(character + 1),
          rect: FlutterSelectionRect(
            left: left,
            top: 20,
            right: left + 10,
            bottom: 40,
          ),
        );
    final surface = _surface(
      'Page 0 text',
      copyEligible: false,
      endpoints: [for (var c = 0; c < 4; c++) endpoint(c, c * 10.0)],
    );

    final created = await bridge.records.createAnnotation(
      document: document,
      surface: surface,
      unit: BigInt.zero,
      start: BigInt.one,
      end: BigInt.from(3),
      displayScale: 2,
      color: FlutterHighlightColor.yellow,
      cancellationId: bridge.createCancellation(),
    );

    // Geometry only: the page text did not map to its characters.
    expect(created.textRange, isNull);
    expect(created.rectangles, const [
      FlutterSelectionRect(left: 10, top: 20, right: 20, bottom: 40),
      FlutterSelectionRect(left: 20, top: 20, right: 30, bottom: 40),
    ]);
    final [listed] = await bridge.records.listAnnotations(
      document: document,
      text: PdfReaderText(_PdfDocument()),
      scale: 4,
      cancellationId: bridge.createCancellation(),
    );
    expect(listed.resolution, FlutterAnnotationResolution.exact);
    expect(
      listed.rectangles!.first,
      const FlutterSelectionRect(left: 20, top: 40, right: 40, bottom: 80),
    );
  });

  test('a file opened directly keeps its annotations across close, a store '
      'reopen and reopening the file', () async {
    final data = Directory.systemTemp.createTempSync('shosai_records');
    addTearDown(() => data.deleteSync(recursive: true));
    final file = File(_epubFixture).copySync('${data.path}/direct.epub');
    final request = FlutterOpenRequest(localId: 'd', pathKey: file.path);
    final firstOwner = CoreOwner(
      await ShosaiCore.open(data.path, pdfEngine: _PdfEngine()),
    );
    final first = firstOwner.bridge();
    final document = await first.openDocument(
      request: request,
      cancellationId: first.createCancellation(),
    );
    expect(document.bookId, isNull);
    final created = await first.createAnnotation(
      document: document.handle,
      unit: BigInt.zero,
      start: BigInt.zero,
      end: BigInt.from(4),
      displayScale: 1,
      color: FlutterHighlightColor.blue,
      body: 'Direct note',
      cancellationId: first.createCancellation(),
    );
    expect(created.resolution, FlutterAnnotationResolution.exact);
    expect(
      await first.updateAnnotation(
        document: document.handle,
        id: created.id,
        color: FlutterHighlightColor.green,
        body: 'Direct note',
      ),
      isTrue,
    );
    expect(first.releaseDocument(handle: document.handle), isTrue);
    first.dispose();
    await firstOwner.close();

    final owner = CoreOwner(
      await ShosaiCore.open(data.path, pdfEngine: _PdfEngine()),
    );
    addTearDown(owner.close);
    final reopenedBridge = owner.bridge();
    final reopened = await reopenedBridge.openDocument(
      request: request,
      cancellationId: reopenedBridge.createCancellation(),
    );
    final [listed] = await reopenedBridge.listAnnotations(
      document: reopened.handle,
      scale: 1,
      cancellationId: reopenedBridge.createCancellation(),
    );
    expect(listed.id, created.id);
    expect(listed.resolution, FlutterAnnotationResolution.exact);
    expect(listed.color, FlutterHighlightColor.green);
    expect(listed.body, 'Direct note');

    // Other bytes are another content, with none of these annotations.
    final other = File('${data.path}/other.epub')
      ..writeAsBytesSync([...file.readAsBytesSync(), 0]);
    final otherDocument = await reopenedBridge.openDocument(
      request: FlutterOpenRequest(localId: 'o', pathKey: other.path),
      cancellationId: reopenedBridge.createCancellation(),
    );
    expect(
      await reopenedBridge.listAnnotations(
        document: otherDocument.handle,
        scale: 1,
        cancellationId: reopenedBridge.createCancellation(),
      ),
      isEmpty,
    );

    expect(
      await reopenedBridge.deleteAnnotation(
        document: reopened.handle,
        id: created.id,
      ),
      isTrue,
    );
    expect(
      await reopenedBridge.listAnnotations(
        document: reopened.handle,
        scale: 1,
        cancellationId: reopenedBridge.createCancellation(),
      ),
      isEmpty,
    );
  });

  test('managed books and their open tabs survive the data directory '
      'moving, as iOS moves it on every install', () async {
    final parent = Directory.systemTemp.createTempSync('shosai_records');
    addTearDown(() => parent.deleteSync(recursive: true));
    final before = Directory('${parent.path}/before')..createSync();
    final firstOwner = CoreOwner(
      await ShosaiCore.open(before.path, pdfEngine: _PdfEngine()),
    );
    final first = firstOwner.bridge();
    final books = <FlutterLibraryBook>[];
    for (final fixture in [_epubFixture, _pdfFixture]) {
      final source = File(
        fixture,
      ).copySync('${parent.path}/${fixture.split('/').last}');
      final report = await first.importPaths(
        pathKeys: [source.path],
        managed: true,
        cancellationId: first.createCancellation(),
      );
      books.add(report.items.single.book!);
    }
    await recordsOf(first).saveOpenBooks((
      books: [
        for (final book in books)
          (book: book, path: book.pathKey, bookId: book.bookId),
      ],
      current: books.last.bookId,
      reading: true,
    ));
    first.dispose();
    await firstOwner.close();

    final after = before.renameSync('${parent.path}/after');
    final owner = CoreOwner(
      await ShosaiCore.open(after.path, pdfEngine: _PdfEngine()),
    );
    addTearDown(owner.close);
    final bridge = owner.bridge();

    final restored = (await recordsOf(bridge).loadOpenBooks())!;
    expect(restored.reading, isTrue);
    expect(restored.current, books.last.bookId);
    for (final (index, open) in restored.books.indexed) {
      expect(open.book.bookId, books[index].bookId);
      expect(open.path, open.book.pathKey);
      expect(open.path, startsWith(after.resolveSymbolicLinksSync()));
      final bytes = File(open.path).readAsBytesSync();
      final opened = await bridge.openLibraryBook(
        bookId: open.book.bookId,
        cancellationId: bridge.createCancellation(),
      );
      expect(opened.bookId, open.book.bookId);
      // Moving the managed path must not weaken verified snapshots: an
      // already-open PDF keeps its bytes, and another open rejects damage.
      File(open.path).writeAsBytesSync(List.filled(bytes.length, 0));
      if (open.book.format == FlutterBookFormat.pdf) {
        expect(opened.contentPath, isNotNull);
        expect(opened.contentPath, isNot(open.path));
        expect(File(opened.contentPath!).readAsBytesSync(), bytes);
      }
      bridge.releaseDocument(handle: opened.handle);
      await bridge.drain();
      await expectLater(
        bridge.openLibraryBook(
          bookId: open.book.bookId,
          cancellationId: bridge.createCancellation(),
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.message,
            'message',
            contains('no longer match'),
          ),
        ),
      );
      expect(bridge.openDocumentCount, 0);
    }
  });

  group('snapshots', () {
    late Directory data;
    late _FilePdfEngine engine;
    late CoreOwner owner;
    late ApplicationBridge pdfBridge;
    late File file;
    const original = '%PDF-1.4 original text';
    const replacement = '%PDF-1.4 replaced text';

    setUp(() async {
      data = Directory.systemTemp.createTempSync('shosai_snapshots');
      engine = _FilePdfEngine();
      owner = CoreOwner(await ShosaiCore.open(data.path, pdfEngine: engine));
      pdfBridge = owner.bridge();
      file = File('${data.path}/book.pdf')..writeAsStringSync(original);
    });

    tearDown(() async {
      await owner.close();
      data.deleteSync(recursive: true);
    });

    Future<int> importBook() async {
      final report = await pdfBridge.importPaths(
        pathKeys: [file.path],
        managed: false,
        cancellationId: pdfBridge.createCancellation(),
      );
      expect(report.items.single.error, isNull);
      return report.items.single.book!.bookId;
    }

    Future<int> matches(FlutterDocumentSummary document, String query) async =>
        (await pdfBridge.searchDocument(
          document: document.handle,
          query: query,
          cancellationId: pdfBridge.createCancellation(),
        )).length;

    void replace() => file.writeAsStringSync(replacement);

    /// The snapshots left in the process's directory, without its lock file.
    Future<List<String>> snapshotFiles() async => [
      for (final entry
          in (await owner.core.snapshots.directory)?.listSync() ?? const [])
        if (!entry.path.endsWith('/.lock')) entry.path,
    ];

    test('a library PDF reads the bytes it verified though its file is '
        'replaced as the engine opens it', () async {
      final bookId = await importBook();
      engine.onOpen = (_) {
        engine.onOpen = null;
        replace();
      };

      final document = await pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: pdfBridge.createCancellation(),
      );

      expect(document.bookId, bookId);
      expect(document.contentPath, isNot(file.path));
      expect(File(document.contentPath!).readAsStringSync(), original);
      expect(await matches(document, 'original'), 1);
      expect(await matches(document, 'replaced'), 0);
      expect(engine.opened.skip(1), everyElement(document.contentPath));
      final snapshots = (await owner.core.snapshots.directory)!;
      expect(
        snapshots.parent.path,
        await Directory('${data.path}/snapshots').resolveSymbolicLinks(),
      );
      if (!Platform.isWindows) {
        expect(snapshots.statSync().mode & 0x3f, 0, reason: 'owner-only');
      }
    });

    test(
      'a sweep deletes only snapshot directories no running process holds',
      () async {
        final bookId = await importBook();
        await pdfBridge.openLibraryBook(
          bookId: bookId,
          cancellationId: pdfBridge.createCancellation(),
        );
        final own = (await owner.core.snapshots.directory)!;
        final parent = own.parent.path;
        Directory directory(String name) {
          final directory = Directory('$parent/$name')..createSync();
          File('${directory.path}/.lock').createSync();
          File('${directory.path}/snapshot-1').writeAsStringSync(original);
          return directory;
        }

        final live = directory('process-live');
        final left = directory('process-left');
        final unlocked = Directory('$parent/process-unlocked')..createSync();

        // Another instance holds its directory's lock until its input closes.
        final script = File('${data.path}/hold_lock.dart')
          ..writeAsStringSync("""
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final file = await File(arguments.single).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
  await file.close();
}
""");
        final holder = await Process.start('dart', [
          script.path,
          '${live.path}/.lock',
        ]);
        await holder.stdout
            .transform(const SystemEncoding().decoder)
            .firstWhere((line) => line.contains('locked'));

        // Every directory looks long untouched; age decides nothing.
        for (final path in [own.path, live.path, left.path, unlocked.path]) {
          final touch = await Process.run('touch', ['-d', '2 days ago', path]);
          expect(touch.exitCode, 0);
        }
        await owner.core.snapshots.sweep();

        expect(own.existsSync(), isTrue, reason: 'this process holds it');
        expect(live.existsSync(), isTrue, reason: 'another process holds it');
        expect(left.existsSync(), isFalse);
        expect(unlocked.existsSync(), isFalse);

        await holder.stdin.close();
        expect(await holder.exitCode, 0);
        await Process.run('touch', ['-d', '2 days ago', live.path]);
        await owner.core.snapshots.sweep();
        expect(live.existsSync(), isFalse);
        expect(own.existsSync(), isTrue);

        // A directory without a lock file is an earlier version's, and goes
        // only once it is old; one still being set up is never swept.
        final fresh = Directory('$parent/process-fresh')..createSync();
        final staging = Directory('$parent/staging-old')..createSync();
        await Process.run('touch', ['-d', '2 days ago', staging.path]);
        await owner.core.snapshots.sweep();
        expect(fresh.existsSync(), isTrue);
        expect(staging.existsSync(), isTrue);
      },
      skip: Platform.isWindows ? 'needs touch and POSIX locks' : false,
    );

    test('a second instance naming the data directory differently keeps '
        'the first one\'s snapshots', () async {
      final bookId = await importBook();
      final document = await pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: pdfBridge.createCancellation(),
      );
      final own = (await owner.core.snapshots.directory)!;
      final alias = Directory('${data.path}-alias');
      Link(alias.path).createSync(data.path);
      addTearDown(() => Link(alias.path).deleteSync());
      for (final spelling in ['${data.path}/.', alias.path]) {
        await Process.run('touch', ['-d', '2 days ago', own.path]);
        // Opening a core sweeps its snapshot parent.
        final other = await ShosaiCore.open(spelling, pdfEngine: engine);
        await other.close();
        expect(own.existsSync(), isTrue, reason: spelling);
      }
      expect(File(document.contentPath!).readAsStringSync(), original);
      expect(await matches(document, 'original'), 1);
    }, skip: Platform.isWindows ? 'needs touch and links' : false);

    test('a library PDF replaced after it opened keeps the verified text '
        'until it is released, and its snapshot is then deleted', () async {
      final bookId = await importBook();
      final document = await pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: pdfBridge.createCancellation(),
      );
      replace();

      expect(await matches(document, 'original'), 1);
      expect(await matches(document, 'replaced'), 0);

      final snapshot = File(document.contentPath!);
      expect(pdfBridge.releaseDocument(handle: document.handle), isTrue);
      await pdfBridge.drain();
      expect(snapshot.existsSync(), isFalse);
      expect(engine.documents.last.disposals, 1);
    });

    test('a library book whose file was replaced is rejected without a '
        'document or records', () async {
      final bookId = await importBook();
      replace();
      final opens = engine.opened.length;

      await expectLater(
        pdfBridge.openLibraryBook(
          bookId: bookId,
          cancellationId: pdfBridge.createCancellation(),
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.message,
            'message',
            contains('no longer match'),
          ),
        ),
      );
      expect(engine.opened.length, opens, reason: 'nothing was parsed');
      expect(pdfBridge.openDocumentCount, 0);
      expect(
        await pdfBridge.loadReadingState(
          bookId: bookId,
          cancellationId: pdfBridge.createCancellation(),
        ),
        isNull,
      );
      expect(await snapshotFiles(), isEmpty);
    });

    test('an EPUB is parsed from the bytes its hash was checked on', () async {
      final epub = File(_epubFixture).copySync('${data.path}/book.epub');
      final report = await pdfBridge.importPaths(
        pathKeys: [epub.path],
        managed: false,
        cancellationId: pdfBridge.createCancellation(),
      );
      final bookId = report.items.single.book!.bookId;
      epub.writeAsBytesSync([...epub.readAsBytesSync(), 0]);

      await expectLater(
        pdfBridge.openLibraryBook(
          bookId: bookId,
          cancellationId: pdfBridge.createCancellation(),
        ),
        throwsA(isA<FlutterBridgeError>()),
      );
      expect(pdfBridge.openDocumentCount, 0);
    });

    test('disposing the bridge during an open rejects and releases the '
        'document', () async {
      final bookId = await importBook();
      final gate = Completer<void>();
      final entered = Completer<void>();
      engine.onOpen = (_) {
        entered.complete();
        return gate.future;
      };
      final opening = pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: pdfBridge.createCancellation(),
      );
      await entered.future;

      pdfBridge.dispose();
      var drained = false;
      unawaited(pdfBridge.drain().then((_) => drained = true));
      await pumpEventQueue();
      expect(drained, isFalse, reason: 'the open is still running');
      gate.complete();

      await expectLater(
        opening,
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.kind,
            'kind',
            FlutterBridgeErrorKind.cancelled,
          ),
        ),
      );
      await pdfBridge.drain();
      expect(drained, isTrue);
      expect(pdfBridge.openDocumentCount, 0);
      expect(engine.documents.last.disposals, 1);
      expect(await snapshotFiles(), isEmpty);
      await expectLater(
        pdfBridge.openLibraryBook(
          bookId: bookId,
          cancellationId: pdfBridge.createCancellation(),
        ),
        throwsA(isA<FlutterBridgeError>()),
      );
      expect(engine.documents, hasLength(2), reason: 'import and one open');
    });

    test('disposing the bridge during PDF use releases the document after '
        'the use finishes', () async {
      final bookId = await importBook();
      final document = await pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: pdfBridge.createCancellation(),
      );
      final gate = engine.textGate = Completer<void>();
      final cancellation = pdfBridge.createCancellation();
      final search = pdfBridge.searchDocument(
        document: document.handle,
        query: 'original',
        cancellationId: cancellation,
      );
      await engine.textRequested.future;
      final reading = engine.documents.last;

      pdfBridge.dispose();
      var drained = false;
      unawaited(pdfBridge.drain().then((_) => drained = true));
      await pumpEventQueue();
      expect(reading.disposals, 0, reason: 'the text read is still running');
      expect(File(document.contentPath!).existsSync(), isTrue);
      expect(drained, isFalse);

      gate.complete();
      await expectLater(
        search,
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.kind,
            'kind',
            FlutterBridgeErrorKind.cancelled,
          ),
        ),
      );
      await pdfBridge.drain();
      expect(drained, isTrue);
      expect(reading.disposals, 1);
      expect(File(document.contentPath!).existsSync(), isFalse);
    });

    test('a failing engine disposal still deletes the snapshot', () async {
      final bookId = await importBook();
      final document = await pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: pdfBridge.createCancellation(),
      );
      expect(await matches(document, 'original'), 1);
      engine.failDispose = true;
      final gate = engine.disposeGate = Completer<void>();

      expect(pdfBridge.releaseDocument(handle: document.handle), isTrue);
      var drained = false;
      unawaited(pdfBridge.drain().then((_) => drained = true));
      await pumpEventQueue();
      expect(drained, isFalse, reason: 'the drain observes the release');
      expect(File(document.contentPath!).existsSync(), isTrue);
      gate.complete();
      await pdfBridge.drain();
      expect(drained, isTrue);

      expect(engine.documents.last.disposals, 1);
      expect(File(document.contentPath!).existsSync(), isFalse);
    });

    test('the core owner closes the shared core once its bridges have '
        'drained; one bridge closing leaves it open', () async {
      final bookId = await importBook();
      final second = owner.bridge();
      pdfBridge.dispose();
      await pdfBridge.drain();
      await second.saveReadingState(
        bookId: bookId,
        value: FlutterReadingState(unit: BigInt.zero, zoom: 2),
        unitCount: BigInt.one,
      );
      final document = await second.openLibraryBook(
        bookId: bookId,
        cancellationId: second.createCancellation(),
      );
      final snapshots = (await owner.core.snapshots.directory)!;

      await owner.close();

      expect(second.isDisposed, isTrue);
      expect(second.openDocumentCount, 0);
      expect(File(document.contentPath!).existsSync(), isFalse);
      expect(snapshots.existsSync(), isFalse);
      expect(() => owner.bridge(), throwsStateError);

      final reopened = CoreOwner(
        await ShosaiCore.open(data.path, pdfEngine: engine),
      );
      addTearDown(reopened.close);
      expect(
        await reopened.bridge().loadReadingState(
          bookId: bookId,
          cancellationId: BigInt.one,
        ),
        FlutterReadingState(unit: BigInt.zero, zoom: 2),
      );
    });

    test('disposing a bridge cancels the operations it owns', () async {
      final bookId = await importBook();
      final cancellation = pdfBridge.createCancellation();
      final gate = Completer<void>();
      final entered = Completer<void>();
      engine.onOpen = (_) {
        entered.complete();
        return gate.future;
      };
      final opening = pdfBridge.openLibraryBook(
        bookId: bookId,
        cancellationId: cancellation,
      );
      await entered.future;

      pdfBridge.dispose();
      gate.complete();

      await expectLater(opening, throwsA(isA<FlutterBridgeError>()));
      expect(pdfBridge.cancel(id: cancellation), isFalse, reason: 'forgotten');
      await expectLater(
        pdfBridge.libraryPage(
          limit: 1,
          offset: 0,
          cancellationId: cancellation,
        ),
        throwsA(
          isA<FlutterBridgeError>().having(
            (error) => error.kind,
            'kind',
            FlutterBridgeErrorKind.cancelled,
          ),
        ),
      );
    });
  });

  test('documents open by extension or content, and release', () async {
    final pdf = await bridge.openDocument(
      request: const FlutterOpenRequest(localId: 'p', pathKey: _pdfFixture),
      cancellationId: bridge.createCancellation(),
    );
    expect(pdf.format, FlutterBookFormat.pdf);
    expect(pdf.title, 'Engine Title');
    expect(pdf.logicalUnitCount, BigInt.two);
    await expectLater(
      bridge.epubBook(
        document: pdf.handle,
        cancellationId: bridge.createCancellation(),
      ),
      throwsA(isA<FlutterBridgeError>()),
    );

    // No extension: the leading `mimetype` entry names the EPUB.
    final bare = '${directory.path}/book';
    File(_epubFixture).copySync(bare);
    final epub = await bridge.openDocument(
      request: FlutterOpenRequest(localId: 'e', pathKey: bare),
      cancellationId: bridge.createCancellation(),
    );
    expect(epub.format, FlutterBookFormat.epub);
    expect(epub.bookId, isNull);

    bridge.dispose();
    expect(bridge.isDisposed, isTrue);
    expect(bridge.releaseDocument(handle: epub.handle), isFalse);
  });

  test('a document that cannot be opened reports why', () async {
    Future<FlutterBridgeErrorKind> failure(String path) async {
      try {
        await bridge.openDocument(
          request: FlutterOpenRequest(localId: path, pathKey: path),
          cancellationId: bridge.createCancellation(),
        );
      } on FlutterBridgeError catch (error) {
        return error.kind;
      }
      fail('$path opened');
    }

    expect(
      await failure('${directory.path}/missing.epub'),
      FlutterBridgeErrorKind.notFound,
    );
    final broken = File('${directory.path}/broken.epub')
      ..writeAsStringSync('not a zip');
    expect(await failure(broken.path), FlutterBridgeErrorKind.malformed);
    final text = File('${directory.path}/notes')..writeAsStringSync('notes');
    expect(await failure(text.path), FlutterBridgeErrorKind.unsupported);

    final cancelled = bridge.createCancellation();
    bridge.cancel(id: cancelled);
    await expectLater(
      bridge.openDocument(
        request: const FlutterOpenRequest(localId: 'e', pathKey: _epubFixture),
        cancellationId: cancelled,
      ),
      throwsA(
        isA<FlutterBridgeError>().having(
          (error) => error.kind,
          'kind',
          FlutterBridgeErrorKind.cancelled,
        ),
      ),
    );
  });
}
