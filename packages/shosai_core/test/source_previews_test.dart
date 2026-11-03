import 'dart:io';
import 'dart:typed_data';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

/// A location that serves one file's bytes and records the ranges read.
final class _Files implements LibraryLocation {
  _Files(this.files);

  final Map<String, Uint8List> files;
  final List<(String, int, int?)> reads = [];

  @override
  String get id => 'cloud';

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) async => LocationPage(const []);

  @override
  Future<LocationEntry> stat(
    String key, {
    CancellationToken? cancellation,
  }) async => LocationEntry(
    key: key,
    name: key,
    isDirectory: false,
    size: files[key]!.length,
  );

  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) async* {
    reads.add((key, start, end));
    final bytes = files[key]!;
    final stop = end == null || end > bytes.length ? bytes.length : end;
    // Two chunks, as a network body would arrive.
    final middle = start + (stop - start) ~/ 2;
    yield bytes.sublist(start, middle);
    yield bytes.sublist(middle, stop);
  }

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) => throw UnimplementedError();
}

LocationEntry _entry(String key, int size, {String revision = 'r1'}) =>
    LocationEntry(
      key: key,
      name: key,
      isDirectory: false,
      size: size,
      revision: revision,
    );

void main() {
  final epub = File(fixturePath('sample.epub')).readAsBytesSync();

  test(
    'previews an unopened EPUB through ranges, as import reads it',
    () async {
      final location = _Files({'book.epub': epub});
      // A cancellation token is in scope, as it is for every real preview;
      // nothing that holds one may be sent to the thumbnail's isolate.
      final preview = await previewEpub(
        location,
        _entry('book.epub', epub.length),
        cancellation: CancellationToken(),
      );
      final imported = await const EpubInspector().inspect(
        fixturePath('sample.epub'),
      );
      expect(preview.title, imported.title);
      expect(preview.author, imported.author);
      expect(preview.cover, imported.cover);
      expect(location.reads, isNotEmpty);
      expect(location.reads.every((read) => read.$3 != null), isTrue);
    },
  );

  test('an unknown size is asked of the location', () async {
    final location = _Files({'book.epub': epub});
    final preview = await previewEpub(
      location,
      const LocationEntry(
        key: 'book.epub',
        name: 'book.epub',
        isDirectory: false,
      ),
    );
    expect(preview.title, isNotNull);
  });

  test('a file that is not an EPUB fails as malformed', () async {
    final junk = Uint8List(1024);
    await expectLater(
      previewEpub(_Files({'x.epub': junk}), _entry('x.epub', junk.length)),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.malformed,
        ),
      ),
    );
  });

  test(
    'a preview lasts while its file is listed unchanged and unopened',
    () async {
      final t = await TempLibrary.create();
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('cloud', 'Cloud');
      final book = _entry('book.epub', epub.length);
      final other = _entry('other.epub', 10);
      await locations.scan('cloud', generation, [book, other]);
      const metadata = BookMetadata(title: '  A   Title ', author: 'Writer');

      expect(
        await locations.savePreview('cloud', generation, book, metadata),
        isNotNull,
      );
      final cover = Uint8List.fromList([1, 2, 3]);
      expect(
        await locations.savePreview(
          'cloud',
          generation,
          other,
          BookMetadata(cover: cover),
        ),
        isNotNull,
      );
      final previews = await locations.previews();
      final saved = previews[(locationId: 'cloud', key: 'book.epub')]!;
      expect(saved.title, 'A Title');
      expect(saved.author, 'Writer');
      expect(saved.hasCover, isFalse);
      expect(
        previews[(locationId: 'cloud', key: 'other.epub')]!.hasCover,
        isTrue,
      );
      expect(
        await locations.previewCover((locationId: 'cloud', key: 'other.epub')),
        cover,
      );

      // A changed file is read again; an unchanged one keeps its preview.
      await locations.scan('cloud', generation, [
        book,
        _entry('other.epub', 11, revision: 'r2'),
      ]);
      expect((await locations.previews()).keys, [
        (locationId: 'cloud', key: 'book.epub'),
      ]);

      // A preview read from bytes that are no longer listed is not kept.
      expect(
        await locations.savePreview('cloud', generation, other, metadata),
        isNull,
      );

      // Opening the file makes it a book; the preview goes.
      final imported = await t.importBook(
        t.copyFixture('sample.epub', 'book.epub'),
      );
      await locations.admit('cloud', generation, book, imported.contentHash);
      expect(await locations.previews(), isEmpty);
    },
  );

  test(
    'a preview from an old grant or a cleared catalog is not kept',
    () async {
      final t = await TempLibrary.create();
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('cloud', 'Cloud');
      final book = _entry('book.epub', epub.length);
      await locations.scan('cloud', generation, [book]);
      const metadata = BookMetadata(title: 'Title');

      final next = await locations.connect('cloud', 'Cloud');
      expect(
        await locations.savePreview('cloud', generation, book, metadata),
        isNull,
      );
      expect(
        await locations.savePreview('cloud', next, book, metadata),
        isNotNull,
      );

      await locations.clearCatalog('cloud');
      expect(await locations.previews(), isEmpty);

      await locations.scan('cloud', next, [book]);
      await locations.remove('cloud');
      expect(
        await locations.savePreview('cloud', next, book, metadata),
        isNull,
      );
    },
  );
}
