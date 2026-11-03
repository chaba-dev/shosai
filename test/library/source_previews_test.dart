import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shosai_core/shosai_core.dart' hide Row;
import 'package:shosai_flutter/core/bridge.dart';
import 'package:shosai_flutter/core/core_records.dart';
import 'package:shosai_flutter/core/library_connection.dart';
import 'package:shosai_flutter/core/library_folders.dart';
import 'package:shosai_flutter/library/controller.dart';
import 'package:shosai_flutter/reader/pdf/pdfrx_engine.dart';

import '../support/production_shell_harness.dart';

/// Serves a directory, optionally holding every ranged read at [gate] and
/// counting how many are in flight.
final class _Location implements LibraryLocation {
  _Location(this.folder);

  final FolderLocation folder;
  Completer<void>? gate;
  int active = 0;
  int mostActive = 0;
  int reads = 0;

  @override
  String get id => folder.id;

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) => folder.list(
    directory: directory,
    cursor: cursor,
    limit: limit,
    cancellation: cancellation,
  );

  @override
  Future<LocationEntry> stat(String key, {CancellationToken? cancellation}) =>
      folder.stat(key, cancellation: cancellation);

  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) async* {
    reads += 1;
    active += 1;
    if (active > mostActive) mostActive = active;
    try {
      if (gate case final gate?) await gate.future;
      yield* folder.read(
        key,
        start: start,
        end: end,
        cancellation: cancellation,
      );
    } finally {
      active -= 1;
    }
  }

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) => throw StateError('Previews never write');
}

final class _Provider implements ConnectionProvider {
  _Provider(this.location);

  final _Location location;

  @override
  String get id => 'fixture';

  @override
  Future<LibraryConnection?> setup(String connectionId) async => null;

  @override
  Future<LibraryConnection> refresh(LibraryConnection connection) async =>
      connection;

  @override
  Future<LibraryLocation> open(LibraryConnection connection) async => location;

  @override
  bool sameAccess(LibraryConnection first, LibraryConnection second) =>
      first.id == second.id;

  @override
  Future<void> release(LibraryConnection connection) async {}
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

/// A connected directory of books, served through [location].
final class _Fixture {
  _Fixture._(this.directory, this.store, this.location, this.folders);

  static Future<_Fixture> create(
    Map<String, String> files, {
    Map<BookFormat, BookPreviewer> previewers = const {
      BookFormat.epub: EpubPreviewer(),
    },
    Map<String, List<int>> bytes = const {},
  }) async {
    final directory = await Directory.systemTemp.createTemp('shosai-preview');
    final books = Directory('${directory.path}/source')..createSync();
    for (final MapEntry(key: name, value: fixture) in files.entries) {
      if (fixture.isEmpty) {
        File('${books.path}/$name').writeAsBytesSync(List.filled(2048, 1));
      } else {
        File(fixture).copySync('${books.path}/$name');
      }
    }
    for (final MapEntry(key: name, value: content) in bytes.entries) {
      File('${books.path}/$name').writeAsBytesSync(content);
    }
    final store = await Store.open('${directory.path}/library.sqlite3');
    final location = _Location(await FolderLocation.open('one', books.path));
    final folders = LibraryFolders(
      Preferences(store),
      Library(store, managedDirectory: '${directory.path}/books'),
      LibraryLocations(store),
      () async => '${directory.path}/unused',
      BookFileCache(store, '${directory.path}/cache'),
      providers: [_Provider(location)],
      previewers: previewers,
    );
    await folders.add(LibraryConnection('one', 'Books', 'fixture', const {}));
    final fixture = _Fixture._(directory, store, location, folders);
    addTearDown(fixture.close);
    return fixture;
  }

  final Directory directory;
  final Store store;
  final _Location location;
  final LibraryFolders folders;

  Future<void> close() async {
    location.gate?.complete();
    location.gate = null;
    await folders.close();
    await store.close();
    await directory.delete(recursive: true);
  }
}

/// A one-page PDF whose content stream is about 200 KiB.
List<int> _heavyPdf() {
  final content = StringBuffer('0.1 0.6 0.3 rg 0 0 300 400 re f\n');
  while (content.length < 200 * 1024) {
    content.write('% ${'x' * 76}\n');
  }
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n${content}endstream',
  ];
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(pdf.length);
    pdf.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return pdf.toString().codeUnits;
}

LibrarySourceFile _named(List<LibrarySourceFile> files, String name) =>
    files.singleWhere((file) => file.entry.name == name);

void main() {
  test('unopened EPUBs get their own title, author and cover', () async {
    final fixture = await _Fixture.create({
      'book.epub': 'fixtures/sample.epub',
      'Broken.epub': '',
      'paper.pdf': 'fixtures/sample.pdf',
    });
    final folders = fixture.folders;
    final discovered = await folders.discover();
    expect(
      {for (final file in discovered) file.entry.name: file.previewable},
      {'book.epub': true, 'Broken.epub': true, 'paper.pdf': true},
    );
    expect(_named(discovered, 'book.epub').title, 'book');

    final previewed = <LibrarySourceFile>[];
    await folders.previewSourceFiles(discovered, onPreviewed: previewed.add);
    expect(previewed.map((file) => file.entry.name).toSet(), {
      'book.epub',
      'Broken.epub',
    });
    final book = _named(previewed, 'book.epub');
    expect(book.title, 'Sample Book');
    expect(book.author, 'Test Author');
    expect(book.preview!.hasCover, isTrue);
    expect(await folders.sourceCover(book.locator), isNotEmpty);
    // A file that is not a readable EPUB keeps its name and is not read
    // again while it is unchanged.
    final broken = _named(previewed, 'Broken.epub');
    expect(broken.title, 'Broken');
    expect(broken.preview!.hasCover, isFalse);
    expect(broken.previewable, isFalse);

    // The previews come back with the catalog, and nothing is read twice.
    final again = await folders.discover(refresh: true);
    expect(_named(again, 'book.epub').title, 'Sample Book');
    // The PDF is left alone: these folders have no PDF previewer.
    expect(again.where((file) => file.previewable).map((f) => f.entry.name), [
      'paper.pdf',
    ]);
    final reads = fixture.location.reads;
    await folders.previewSourceFiles(again, onPreviewed: (_) => fail('read'));
    expect(fixture.location.reads, reads);
  });

  test('unopened PDFs get their first page and own title', () async {
    final fixture = await _Fixture.create(
      {'scan_0001.pdf': 'fixtures/sample.pdf'},
      previewers: {
        BookFormat.epub: const EpubPreviewer(),
        BookFormat.pdf: PdfEnginePreviewer(PdfrxPdfEngine(), budget: 64 * 1024),
      },
      // A first page heavier than the budget.
      bytes: {'heavy.pdf': _heavyPdf()},
    );
    final folders = fixture.folders;
    final previewed = <LibrarySourceFile>[];
    await folders.previewSourceFiles(
      await folders.discover(),
      onPreviewed: previewed.add,
    );
    final scan = _named(previewed, 'scan_0001.pdf');
    expect(scan.preview!.hasCover, isTrue);
    expect(await folders.sourceCover(scan.locator), isNotEmpty);
    // A file that needs more than the budget is recorded as read, with
    // nothing to show, and is not fetched again.
    final heavy = _named(previewed, 'heavy.pdf');
    expect(heavy.preview!.hasCover, isFalse);
    expect(heavy.title, 'heavy');
    expect(
      (await folders.discover()).where((file) => file.previewable),
      isEmpty,
    );
  });

  test('previews run a few at a time and stop with the pass', () async {
    final fixture = await _Fixture.create({
      for (var i = 0; i < 6; i++) 'book$i.epub': 'fixtures/sample.epub',
    });
    final folders = fixture.folders;
    final files = await folders.discover();
    final gate = fixture.location.gate = Completer<void>();
    final cancellation = CancellationToken();
    final previewed = <LibrarySourceFile>[];
    final pass = folders.previewSourceFiles(
      files,
      cancellation: cancellation,
      onPreviewed: previewed.add,
    );
    await pumpEventQueue();
    expect(fixture.location.active, sourcePreviewConcurrency);
    cancellation.cancel();
    fixture.location.gate = null;
    gate.complete();
    await pass;
    expect(fixture.location.mostActive, sourcePreviewConcurrency);
    expect(previewed, isEmpty);
    expect(
      (await folders.discover()).where((file) => file.previewable),
      hasLength(6),
    );
  });

  test('removing a connection cancels its previews', () async {
    final fixture = await _Fixture.create({
      'book.epub': 'fixtures/sample.epub',
    });
    final folders = fixture.folders;
    final files = await folders.discover();
    final gate = fixture.location.gate = Completer<void>();
    final previewed = <LibrarySourceFile>[];
    final pass = folders.previewSourceFiles(files, onPreviewed: previewed.add);
    await pumpEventQueue();
    await folders.remove('one');
    fixture.location.gate = null;
    gate.complete();
    await pass;
    expect(previewed, isEmpty);
    expect(await LibraryLocations(fixture.store).previews(), isEmpty);
  });

  test('the shelf shows previews as they land, without waiting', () async {
    final fixture = await _Fixture.create({
      'book.epub': 'fixtures/sample.epub',
    });
    final gate = fixture.location.gate = Completer<void>();
    final bridge = _SourceBridge(fixture.folders);
    final controller = LibraryController(
      bridge: bridge,
      confirmRemoval: (_) async => true,
      pickImport: () async => null,
      openBook: (_) async {},
      drainReaderSaves: (_) async {},
    );
    addTearDown(controller.dispose);
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(ready(), isTrue);
    }

    controller.dispatch(const LibraryStarted());
    // The shelf loads while the preview is still reading.
    await until(() => controller.model.loaded);
    final unread = controller.model.sourceFiles.single;
    expect(unread.title, 'book');
    expect(controller.model.loading, isFalse);
    expect(controller.requestSourceCover(unread.locator), isTrue);
    await until(() => controller.model.sourceCovers.isNotEmpty);
    expect(controller.model.sourceCovers[unread.locator], isEmpty);

    fixture.location.gate = null;
    gate.complete();
    await until(() => controller.model.sourceFiles.single.preview != null);
    final previewed = controller.model.sourceFiles.single;
    expect(previewed.title, 'Sample Book');
    expect(previewed.author, 'Test Author');

    // Searching finds the file by what its contents say.
    controller.dispatch(const LibraryQueryChanged('test author'));
    await until(
      () =>
          !controller.model.loading &&
          controller.model.query == 'test author' &&
          controller.model.sourceFiles.length == 1,
    );

    // The cover asked for before the file was read loads now.
    expect(controller.requestSourceCover(previewed.locator), isTrue);
    await until(
      () =>
          controller.model.sourceCovers[previewed.locator]?.isNotEmpty ?? false,
    );
  });
}
