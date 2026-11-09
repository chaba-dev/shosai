import 'dart:async';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

void main() {
  test(
    'removal keeps the content, reading state and notes across restart',
    () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'book.epub'),
      );
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('files', 'My books');
      await locations.locate(book.contentHash, (
        locationId: 'files',
        key: 'opaque-document-id',
      ), generation: generation);
      await Bookmarks(t.store).toggle(book.id, 2, title: 'Read again');
      await ReadingState(t.store).save(
        book.id,
        const ReadingPosition(unit: 0, offset: 17, zoom: 1),
        unitCount: 1,
      );
      await Annotations(t.store).createNote(
        book.id,
        const BookAnchor(),
        'Keep this note when the folder is gone.',
      );
      await locations.remove('files');

      final unavailable = (await t.library.page()).books.single;
      expect(unavailable.id, book.id);
      expect(unavailable.contentHash, book.contentHash);
      expect(unavailable.locationFailure, LocationFailure.revoked);
      expect(
        (await Bookmarks(t.store).list(book.id)).single.title,
        'Read again',
      );
      expect(
        (await locations.copies(book.contentHash)).single.failure,
        LocationFailure.revoked,
      );
      final databasePath = t.store.path;
      await t.store.close();
      final reopened = await Store.open(databasePath);
      addTearDown(reopened.close);
      expect(
        (await LibraryLocations(
          reopened,
        ).copies(book.contentHash)).single.failure,
        LocationFailure.revoked,
      );
      expect(
        (await Bookmarks(reopened).list(book.id)).single.title,
        'Read again',
      );
      expect((await ReadingState(reopened).load(book.id))!.offset, 17);
      expect(
        (await Annotations(reopened).summary(book.id)).latest,
        'Keep this note when the folder is gone.',
      );
    },
  );

  test(
    'reads ranges and failures affect locators, never content identity',
    () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'book.epub'),
      );
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('remote', 'Remote books');
      for (final key in ['a', 'b']) {
        await locations.locate(book.contentHash, (
          locationId: 'remote',
          key: key,
        ), generation: generation);
      }
      final adapter = _Location();
      expect(
        await locations
            .read(adapter, generation, book.contentHash, 'a', start: 1, end: 4)
            .expand((chunk) => chunk)
            .toList(),
        [7, 11, 19],
      );
      for (final failure in [
        LocationFailure.missing,
        LocationFailure.offline,
      ]) {
        adapter.failure = failure;
        await expectLater(
          locations
              .read(adapter, generation, book.contentHash, 'a')
              .drain<void>(),
          throwsA(
            isA<LocationException>().having(
              (e) => e.failure,
              'failure',
              failure,
            ),
          ),
        );
        final copies = await locations.copies(book.contentHash);
        expect(copies.first.failure, failure);
        expect(copies.last.failure, isNull);
        expect((await t.library.get(book.id))!.locationFailure, isNull);
      }
      await locations.unavailable(
        'remote',
        generation,
        LocationFailure.missing,
      );
      expect(
        (await locations.copies(book.contentHash)).map((copy) => copy.failure),
        everyElement(LocationFailure.missing),
      );
      adapter.failure = null;
      await locations
          .read(adapter, generation, book.contentHash, 'b')
          .drain<void>();
      expect(
        (await locations.copies(book.contentHash)).first.failure,
        LocationFailure.missing,
      );
      expect((await locations.copies(book.contentHash)).last.failure, isNull);
      adapter.failure = LocationFailure.revoked;
      await expectLater(
        locations
            .read(adapter, generation, book.contentHash, 'a')
            .drain<void>(),
        throwsA(isA<LocationException>()),
      );
      expect(
        (await locations.copies(book.contentHash)).map((e) => e.failure),
        everyElement(LocationFailure.revoked),
      );
      final unavailable = (await t.library.get(book.id))!;
      expect(unavailable.contentHash, book.contentHash);
      expect(unavailable.locationFailure, LocationFailure.revoked);
    },
  );

  test('old reads cannot restore a removed or reconnected grant', () async {
    final t = await TempLibrary.create();
    final book = await t.importBook(t.copyFixture('sample.epub', 'book.epub'));
    final locations = LibraryLocations(t.store);
    final oldGeneration = await locations.connect('remote', 'Remote books');
    await locations.locate(book.contentHash, (
      locationId: 'remote',
      key: 'a',
    ), generation: oldGeneration);
    final gate = Completer<void>();
    final started = Completer<void>();
    final adapter = _Location()
      ..gate = gate
      ..started = started;
    final reading = locations
        .read(adapter, oldGeneration, book.contentHash, 'a')
        .drain<void>();
    await started.future;
    await locations.remove('remote');
    final generation = await locations.connect('remote', 'Reconnected');
    gate.complete();
    await reading;
    expect(
      (await locations.copies(book.contentHash)).single.failure,
      LocationFailure.revoked,
    );
    await expectLater(
      locations.locate(book.contentHash, (
        locationId: 'remote',
        key: 'b',
      ), generation: oldGeneration),
      throwsA(isA<LocationException>()),
    );
    adapter.gate = null;
    await locations
        .read(adapter, generation, book.contentHash, 'a')
        .drain<void>();
    expect((await locations.copies(book.contentHash)).single.failure, isNull);

    final revokedGate = Completer<void>();
    final revokedStarted = Completer<void>();
    adapter
      ..gate = revokedGate
      ..started = revokedStarted;
    final staleSuccess = locations
        .read(adapter, generation, book.contentHash, 'a')
        .drain<void>();
    await revokedStarted.future;
    await expectLater(
      locations
          .read(
            _Location()..failure = LocationFailure.revoked,
            generation,
            book.contentHash,
            'a',
          )
          .drain<void>(),
      throwsA(isA<LocationException>()),
    );
    revokedGate.complete();
    await staleSuccess;
    expect(
      (await locations.copies(book.contentHash)).single.failure,
      LocationFailure.revoked,
    );
  });

  test('a reconnected folder lists its opened books as books again', () async {
    final t = await TempLibrary.create();
    final book = await t.importBook(t.copyFixture('sample.epub', 'book.epub'));
    final locations = LibraryLocations(t.store);
    const copy = LocationEntry(
      key: 'id:book',
      name: 'book.epub',
      isDirectory: false,
      size: 1234,
      revision: '3',
    );
    const other = LocationEntry(
      key: 'id:other',
      name: 'other.epub',
      isDirectory: false,
      size: 99,
      revision: '1',
    );
    final first = await locations.connect('first', 'Google Drive');
    await locations.scan('first', first, [copy, other]);
    await locations.admit('first', first, copy, book.contentHash);
    await locations.locate(book.contentHash, (
      locationId: 'first',
      key: copy.key,
    ), generation: first);
    await locations.remove('first');
    await locations.clearCatalog('first');
    expect(
      (await t.library.get(book.id))!.locationFailure,
      LocationFailure.revoked,
    );

    // The same file, unchanged, under a new grant is the book, not a new
    // candidate beside an unavailable book.
    final second = await locations.connect('second', 'Google Drive');
    expect(await locations.scan('second', second, [copy, other]), {copy.key});
    expect((await locations.catalog()).single.entry.key, other.key);
    expect((await t.library.get(book.id))!.locationFailure, isNull);
    final located = (await locations.copies(book.contentHash)).single;
    expect(located.locator, (locationId: 'second', key: copy.key));
    expect(located.failure, isNull);

    // A file changed since it was opened is a candidate again; the book stays
    // unavailable until its bytes are read.
    await locations.remove('second');
    await locations.clearCatalog('second');
    final changed = LocationEntry(
      key: copy.key,
      name: copy.name,
      isDirectory: false,
      size: copy.size,
      revision: '4',
    );
    final third = await locations.connect('third', 'Google Drive');
    expect(await locations.scan('third', third, [changed]), isEmpty);
    expect((await locations.catalog()).single.entry.key, copy.key);
    expect(
      (await t.library.get(book.id))!.locationFailure,
      LocationFailure.revoked,
    );
    expect(
      (await locations.copies(book.contentHash)).single.locator.locationId,
      'second',
    );
  });

  test(
    'a reconnected folder does not locate a book it only admitted',
    () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'book.epub'),
      );
      final locations = LibraryLocations(t.store);
      const copy = LocationEntry(
        key: 'id:book',
        name: 'book.epub',
        isDirectory: false,
        size: 1234,
        revision: '3',
      );
      // A local import owns its content: the folder copy is admitted as a
      // duplicate, never located.
      final first = await locations.connect('first', 'Google Drive');
      await locations.scan('first', first, [copy]);
      await locations.admit('first', first, copy, book.contentHash);
      expect(await locations.copies(book.contentHash), isEmpty);
      await locations.remove('first');
      await locations.clearCatalog('first');

      final second = await locations.connect('second', 'Google Drive');
      expect(await locations.scan('second', second, [copy]), {copy.key});
      expect(await locations.catalog(), isEmpty);
      expect(await locations.copies(book.contentHash), isEmpty);
      final kept = (await t.library.get(book.id))!;
      expect(kept.located, false);
      expect(kept.locationFailure, isNull);
    },
  );

  test('a reconnected folder keeps its removed books off the shelf', () async {
    final t = await TempLibrary.create();
    final book = await t.importBook(t.copyFixture('sample.epub', 'book.epub'));
    final locations = LibraryLocations(t.store);
    const copy = LocationEntry(
      key: 'id:book',
      name: 'book.epub',
      isDirectory: false,
      size: 1234,
      revision: '3',
    );
    final first = await locations.connect('first', 'Google Drive');
    await locations.admit('first', first, copy, book.contentHash);
    expect((await t.library.remove(book.id)).removed, true);
    await locations.remove('first');
    await locations.clearCatalog('first');
    expect(await locations.hidden(), isEmpty);

    final second = await locations.connect('second', 'Google Drive');
    expect(await locations.scan('second', second, [copy]), {copy.key});
    expect(await locations.catalog(), isEmpty);
    final hidden = (await locations.hidden()).single;
    expect(hidden.locationId, 'second');
    expect(hidden.entry.key, copy.key);
    expect(hidden.contentHash, book.contentHash);

    // Unhidden, the file is offered again from its new connection.
    await locations.unhide((locationId: 'second', key: copy.key));
    expect((await locations.catalog()).single.entry.key, copy.key);
  });

  test('changing a connection’s folder keeps its opened books known', () async {
    final t = await TempLibrary.create();
    final book = await t.importBook(t.copyFixture('sample.epub', 'book.epub'));
    final locations = LibraryLocations(t.store);
    const copy = LocationEntry(
      key: 'id:book',
      name: 'book.epub',
      isDirectory: false,
      size: 1234,
      revision: '3',
    );
    final generation = await locations.connect('drive', 'Google Drive');
    await locations.scan('drive', generation, [copy]);
    await locations.admit('drive', generation, copy, book.contentHash);
    await locations.locate(book.contentHash, (
      locationId: 'drive',
      key: copy.key,
    ), generation: generation);
    // The listing is forgotten with the folder; the book is not.
    await locations.clearCatalog('drive');
    expect(await locations.scan('drive', generation, [copy]), {copy.key});
    expect(await locations.catalog(), isEmpty);
    expect((await t.library.get(book.id))!.locationFailure, isNull);
    // A folder without the file loses its admission and marks it missing.
    expect(await locations.scan('drive', generation, []), isEmpty);
    expect(
      (await t.library.get(book.id))!.locationFailure,
      LocationFailure.missing,
    );
  });

  test(
    'a removed source book stays off the shelf until its file changes',
    () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'book.epub'),
      );
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('remote', 'Remote books');
      const copy = LocationEntry(
        key: 'books/copy.epub',
        name: 'copy.epub',
        isDirectory: false,
        size: 1234,
        revision: 'r1',
      );
      const spare = LocationEntry(
        key: 'books/spare.epub',
        name: 'spare.epub',
        isDirectory: false,
        size: 1234,
        revision: 'r7',
      );
      await locations.admit('remote', generation, copy, book.contentHash);
      await locations.admit('remote', generation, spare, book.contentHash);
      await locations.locate(book.contentHash, (
        locationId: 'remote',
        key: copy.key,
      ), generation: generation);
      await Annotations(t.store).createNote(
        book.id,
        const BookAnchor(),
        'Keep this note across a removal.',
      );

      expect((await t.library.remove(book.id)).removed, true);
      expect((await t.library.page()).books, isEmpty);
      // The next complete scan sees both files unchanged and offers neither.
      expect(await locations.scan('remote', generation, [copy, spare]), {
        copy.key,
        spare.key,
      });
      expect(await locations.catalog(), isEmpty);
      expect(
        (await locations.hidden()).map((file) => file.entry.key),
        unorderedEquals([copy.key, spare.key]),
      );

      // Changed bytes at a hidden key are a new candidate; a file that is
      // gone is forgotten.
      final replaced = LocationEntry(
        key: copy.key,
        name: copy.name,
        isDirectory: false,
        size: 2345,
        revision: 'r2',
      );
      expect(await locations.scan('remote', generation, [replaced]), isEmpty);
      expect((await locations.catalog()).single.entry.key, copy.key);
      expect(await locations.hidden(), isEmpty);

      // Admitting the content again from the candidate brings the notes back.
      final again = await t.importBook(
        t.copyFixture('sample.epub', 'again.epub'),
      );
      expect(again.contentHash, book.contentHash);
      expect(
        (await Annotations(t.store).summary(again.id)).latest,
        'Keep this note across a removal.',
      );
      await locations.admit('remote', generation, replaced, again.contentHash);
      expect(await locations.catalog(), isEmpty);

      // Removing again hides the spare too once it is admitted, and unhiding
      // puts it back on the shelf as a candidate.
      await locations.admit('remote', generation, spare, again.contentHash);
      await t.library.remove(again.id);
      expect(await locations.scan('remote', generation, [replaced, spare]), {
        replaced.key,
        spare.key,
      });
      await locations.unhide((locationId: 'remote', key: spare.key));
      expect((await locations.catalog()).single.entry.key, spare.key);
      expect((await locations.hidden()).single.entry.key, copy.key);
      expect(await locations.scan('remote', generation, [replaced, spare]), {
        replaced.key,
      });
      expect((await locations.catalog()).single.entry.key, spare.key);
    },
  );
}

final class _Location implements LibraryLocation {
  LocationFailure? failure;
  Completer<void>? gate;
  Completer<void>? started;

  @override
  String get id => 'remote';

  @override
  Stream<List<int>> read(
    String key, {
    int start = 0,
    int? end,
    CancellationToken? cancellation,
  }) async* {
    if (failure case final failure?) throw LocationException(failure);
    if (started?.isCompleted == false) started!.complete();
    await gate?.future;
    yield [3, 7, 11, 19, 23].sublist(start, end);
  }

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) => throw UnimplementedError();

  @override
  Future<LocationEntry> stat(String key, {CancellationToken? cancellation}) =>
      throw UnimplementedError();

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) => throw UnimplementedError();
}
