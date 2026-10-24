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
