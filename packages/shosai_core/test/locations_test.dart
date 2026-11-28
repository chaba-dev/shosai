import 'dart:async';
import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';
import 'support/temp_store.dart';

void main() {
  test(
    'revalidation clears only failed links with identical full contents',
    () async {
      final t = await TempLibrary.create();
      final path = t.copyFixture('sample.epub', 'book.epub');
      final bytes = File(path).readAsBytesSync();
      final book = await t.importBook(path);
      final locations = LibraryLocations(t.store);
      var generation = await locations.connect('remote', 'Remote books');
      const keys = [
        'a-match',
        'b-changed',
        'c-short',
        'd-long',
        'e-missing',
        'f-offline',
        'g-denied',
      ];
      for (final key in keys) {
        await locations.locate(book.contentHash, (
          locationId: 'remote',
          key: key,
        ), generation: generation);
      }
      await locations.remove('remote');
      generation = await locations.connect('remote', 'Remote books');
      await locations.locate(book.contentHash, (
        locationId: 'remote',
        key: 'healthy',
      ), generation: generation);
      final otherGeneration = await locations.connect('other', 'Other books');
      await locations.locate(book.contentHash, (
        locationId: 'other',
        key: 'other',
      ), generation: otherGeneration);
      await locations.failed(
        book.contentHash,
        (locationId: 'other', key: 'other'),
        generation: otherGeneration,
        failure: LocationFailure.missing,
      );
      final changed = List<int>.of(bytes);
      changed[bytes.length ~/ 2] ^= 1;
      final adapter = _Location()
        ..contents.addAll({
          'a-match': bytes,
          'b-changed': changed,
          'c-short': bytes.sublist(0, bytes.length - 1),
          'd-long': [...bytes, 91],
        })
        ..failures.addAll({
          'e-missing': LocationFailure.missing,
          'f-offline': LocationFailure.offline,
          'g-denied': LocationFailure.revoked,
        });
      expect(await locations.revalidate(adapter, generation), (
        verified: 1,
        unavailable: 6,
      ));
      expect(
        {
          for (final copy in await locations.copies(book.contentHash))
            copy.locator: copy.failure,
        },
        {
          for (final key in keys)
            (locationId: 'remote', key: key): key == 'a-match'
                ? null
                : LocationFailure.revoked,
          (locationId: 'remote', key: 'healthy'): null,
          (locationId: 'other', key: 'other'): LocationFailure.missing,
        },
      );
      // A denied file must not invalidate the working connection, and a retry
      // must exclude the links already verified or healthy.
      adapter.failures.clear();
      for (final key in keys) {
        adapter.contents[key] = bytes;
      }
      expect(await locations.revalidate(adapter, generation), (
        verified: 6,
        unavailable: 0,
      ));
      expect(await locations.revalidate(adapter, generation), (
        verified: 0,
        unavailable: 0,
      ));
    },
  );

  for (final interruption in ['cancel', 'reconnect', 'remove']) {
    test(
      'revalidation cannot publish after $interruption during a read',
      () async {
        final t = await TempLibrary.create();
        final path = t.copyFixture('sample.epub', 'book.epub');
        final book = await t.importBook(path);
        final locations = LibraryLocations(t.store);
        final generation = await locations.connect('remote', 'Remote books');
        await locations.locate(book.contentHash, (
          locationId: 'remote',
          key: 'book',
        ), generation: generation);
        await locations.unavailable(
          'remote',
          generation,
          LocationFailure.offline,
        );
        final cancellation = CancellationToken();
        final adapter = _Location()
          ..contents['book'] = File(path).readAsBytesSync()
          ..started = Completer<void>()
          ..gate = Completer<void>();
        final pending = locations.revalidate(
          adapter,
          generation,
          cancellation: cancellation,
        );
        await adapter.started!.future;
        expect(
          (await locations.copies(book.contentHash)).single.failure,
          LocationFailure.offline,
        );
        if (interruption == 'cancel') cancellation.cancel();
        if (interruption == 'reconnect') {
          await locations.connect('remote', 'Remote books');
        }
        if (interruption == 'remove') await locations.remove('remote');
        final rejected = expectLater(
          pending,
          throwsA(
            isA<CoreException>().having(
              (e) => e.kind,
              'kind',
              CoreErrorKind.cancelled,
            ),
          ),
        );
        adapter.gate!.complete();
        await rejected;
        expect(
          (await locations.copies(book.contentHash)).single.failure,
          interruption == 'remove'
              ? LocationFailure.revoked
              : LocationFailure.offline,
        );
      },
    );
  }

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

  test('a removed book stays hidden by content wherever it moves', () async {
    final t = await TempLibrary.create();
    final path = t.copyFixture('sample.epub', 'book.epub');
    final bytes = File(path).readAsBytesSync();
    final book = await t.importBook(path);
    final locations = LibraryLocations(t.store);
    final location = _Location();
    final generation = await locations.connect('remote', 'Remote books');
    final original = location.file('books/book.epub', 'r1', bytes.length);
    await locations.admit('remote', generation, original, book.contentHash);
    await Annotations(t.store).createNote(
      book.id,
      const BookAnchor(),
      'Keep this note across a removal.',
    );
    expect((await t.library.remove(book.id)).removed, true);

    // The same bytes moved, rewritten in place under a new revision, listed
    // without a size, and listed by a provider that reports their digest.
    final moved = location.file('archive/book.epub', 'r1', bytes.length);
    final touched = location.file('books/book.epub', 'r2', bytes.length);
    final unsized = location.file('elsewhere/book.epub', 'n1', null);
    final digested = location.file(
      'drive/book.epub',
      'd1',
      bytes.length,
      sha: book.contentHash.toUpperCase(),
    );
    // Other bytes of the same size, one unreadable now, and another size.
    final other = location.file('books/other.epub', 'o1', bytes.length);
    final unreadable = location.file('books/offline.epub', 'u1', bytes.length);
    final larger = location.file('books/larger.epub', 'l1', bytes.length + 1);
    location.contents
      ..[moved.key] = bytes
      ..[touched.key] = bytes
      ..[unsized.key] = bytes
      ..[other.key] = [...bytes.take(bytes.length - 1), bytes.last ^ 1]
      ..[larger.key] = [...bytes, 0];
    location.failures[unreadable.key] = LocationFailure.offline;
    final listing = [
      moved,
      touched,
      unsized,
      digested,
      other,
      unreadable,
      larger,
    ];

    expect(await locations.scan('remote', generation, listing), {digested.key});
    // Files that may be the removed content are not offered before they are
    // read.
    expect(
      (await locations.catalog()).map((file) => file.entry.key),
      unorderedEquals([larger.key]),
    );
    expect(await locations.hideRemovedCopies(location, generation), {
      moved.key,
      touched.key,
      unsized.key,
      unreadable.key,
    });
    expect(
      location.reads,
      unorderedEquals([
        moved.key,
        touched.key,
        unsized.key,
        other.key,
        unreadable.key,
      ]),
    );
    expect(
      (await locations.catalog()).map((file) => file.entry.key),
      unorderedEquals([other.key, larger.key]),
    );
    expect(
      {
        for (final hidden in await locations.hidden())
          hidden.entry.key: hidden.contentHash,
      },
      {
        moved.key: book.contentHash,
        touched.key: book.contentHash,
        unsized.key: book.contentHash,
        digested.key: book.contentHash,
      },
    );

    // The next scan reads only what it could not read before.
    location
      ..reads.clear()
      ..failures.clear()
      ..contents[unreadable.key] = bytes;
    expect(await locations.scan('remote', generation, listing), {
      moved.key,
      touched.key,
      unsized.key,
      digested.key,
    });
    expect(await locations.hideRemovedCopies(location, generation), {
      unreadable.key,
    });
    expect(location.reads, [unreadable.key]);

    // A digest the provider reports now outranks the one read before.
    final reported = location.file(
      other.key,
      other.revision!,
      bytes.length,
      sha: book.contentHash,
    );
    final relisted = [...listing.where((e) => e != other), reported];
    expect(
      await locations.scan('remote', generation, relisted),
      contains(other.key),
    );
    expect((await locations.catalog()).map((file) => file.entry.key), [
      larger.key,
    ]);

    // Added again, the content brings its notes back and is no longer
    // removed: a new copy is offered without being read.
    final again = await t.importBook(
      t.copyFixture('sample.epub', 'again.epub'),
    );
    expect(again.contentHash, book.contentHash);
    expect(
      (await Annotations(t.store).summary(again.id)).latest,
      'Keep this note across a removal.',
    );
    final copy = location.file('books/copy.epub', 'c1', bytes.length);
    location.reads.clear();
    await locations.scan('remote', generation, [...relisted, copy]);
    expect(await locations.hideRemovedCopies(location, generation), isEmpty);
    expect(location.reads, isEmpty);
    expect(
      (await locations.catalog()).map((file) => file.entry.key),
      contains(copy.key),
    );
  });

  test(
    'removed content replacing an admitted file retires that admission',
    () async {
      final t = await TempLibrary.create();
      final kept = await t.importBook(t.copyFixture('sample.epub', 'a.epub'));
      final pdf = t.copyFixture('sample.pdf', 'b.pdf');
      final pdfBytes = File(pdf).readAsBytesSync();
      final removed = await t.importBook(pdf);
      final locations = LibraryLocations(t.store);
      final location = _Location();
      final generation = await locations.connect('remote', 'Remote books');
      final first = location.file('shelf/book', 'r1', kept.fileSize);
      await locations.admit('remote', generation, first, kept.contentHash);
      await locations.locate(kept.contentHash, (
        locationId: 'remote',
        key: first.key,
      ), generation: generation);
      await t.library.remove(removed.id);

      // The removed book's bytes now sit where the kept one was admitted.
      final replaced = location.file(first.key, 'r2', pdfBytes.length);
      location.contents[replaced.key] = pdfBytes;
      await locations.scan('remote', generation, [replaced]);
      expect(await locations.hideRemovedCopies(location, generation), {
        replaced.key,
      });
      expect(
        (await locations.hidden()).single.contentHash,
        removed.contentHash,
      );
      // The kept book stays, missing at that key, and the file is not read
      // again while it is unchanged.
      expect(
        (await locations.copies(kept.contentHash)).single.failure,
        LocationFailure.missing,
      );
      expect((await t.library.get(kept.id))!.title, kept.title);
      location.reads.clear();
      expect(await locations.scan('remote', generation, [replaced]), {
        replaced.key,
      });
      expect(await locations.hideRemovedCopies(location, generation), isEmpty);
      expect(location.reads, isEmpty);
    },
  );

  test('unhiding offers one file and keeps its other copies hidden', () async {
    final t = await TempLibrary.create();
    final path = t.copyFixture('sample.epub', 'book.epub');
    final bytes = File(path).readAsBytesSync();
    final book = await t.importBook(path);
    final locations = LibraryLocations(t.store);
    final location = _Location();
    final generation = await locations.connect('remote', 'Remote books');
    await t.library.remove(book.id);
    final first = location.file('a.epub', 'a1', bytes.length);
    final second = location.file('b.epub', 'b1', bytes.length);
    location.contents
      ..[first.key] = bytes
      ..[second.key] = bytes;
    Future<List<String>> offered(List<LocationEntry> listing) async {
      await locations.scan('remote', generation, listing);
      await locations.hideRemovedCopies(location, generation);
      return [for (final file in await locations.catalog()) file.entry.key];
    }

    expect(await offered([first, second]), isEmpty);
    await locations.unhide((locationId: 'remote', key: first.key));
    expect(await offered([first, second]), [first.key]);
    expect((await locations.hidden()).single.entry.key, second.key);
    // Moved, the unhidden file is a copy like any other.
    final moved = location.file('c.epub', 'c1', bytes.length);
    location.contents[moved.key] = bytes;
    expect(await offered([moved, second]), isEmpty);
  });

  test('reading removed copies stops once the connection goes', () async {
    final t = await TempLibrary.create();
    final path = t.copyFixture('sample.epub', 'book.epub');
    final bytes = File(path).readAsBytesSync();
    final book = await t.importBook(path);
    final locations = LibraryLocations(t.store);
    final location = _Location();
    final generation = await locations.connect('remote', 'Remote books');
    await t.library.remove(book.id);
    final first = location.file('a.epub', 'a1', bytes.length);
    final second = location.file('b.epub', 'b1', bytes.length);
    location.contents
      ..[first.key] = bytes
      ..[second.key] = bytes;
    await locations.scan('remote', generation, [first, second]);
    // The first file goes while it is read, so it fails to verify.
    location.stats.remove(first.key);
    location
      ..gate = Completer<void>()
      ..started = Completer<void>();
    final reading = locations.hideRemovedCopies(location, generation);
    await location.started!.future;
    await locations.remove('remote');
    location.gate!.complete();
    await expectLater(
      reading,
      throwsA(
        isA<LocationException>().having(
          (error) => error.failure,
          'failure',
          LocationFailure.revoked,
        ),
      ),
    );
    expect(location.reads, [first.key]);
  });

  test('a revisionless hidden copy is read again, not trusted', () async {
    final t = await TempLibrary.create();
    final path = t.copyFixture('sample.epub', 'book.epub');
    final bytes = File(path).readAsBytesSync();
    final book = await t.importBook(path);
    final locations = LibraryLocations(t.store);
    final location = _Location();
    final generation = await locations.connect('remote', 'Remote books');
    await t.library.remove(book.id);
    final copy = LocationEntry(
      key: 'copy.epub',
      name: 'copy.epub',
      isDirectory: false,
      size: bytes.length,
    );
    location.stats[copy.key] = copy;
    location.contents[copy.key] = bytes;
    Future<List<String>> offered() async {
      await locations.scan('remote', generation, [copy]);
      await locations.hideRemovedCopies(location, generation);
      return [for (final file in await locations.catalog()) file.entry.key];
    }

    expect(await offered(), isEmpty);
    expect((await locations.hidden()).single.entry.key, copy.key);
    // Other bytes of the same length at the same key, still without a
    // revision, are offered once read.
    location.contents[copy.key] = [
      ...bytes.take(bytes.length - 1),
      bytes.last ^ 1,
    ];
    expect(await offered(), [copy.key]);
    expect(await locations.hidden(), isEmpty);
  });

  test(
    'a file unhidden before a re-add is hidden by the next removal',
    () async {
      final t = await TempLibrary.create();
      final path = t.copyFixture('sample.epub', 'book.epub');
      final bytes = File(path).readAsBytesSync();
      final book = await t.importBook(path);
      final locations = LibraryLocations(t.store);
      final location = _Location();
      final generation = await locations.connect('remote', 'Remote books');
      final copy = location.file('copy.epub', 'c1', bytes.length);
      location.contents[copy.key] = bytes;
      await t.library.remove(book.id);
      await locations.scan('remote', generation, [copy]);
      await locations.hideRemovedCopies(location, generation);
      expect(await locations.catalog(), isEmpty);

      // Added again from a local file, the folder copy is still hidden; the
      // reader unhides it, then removes the book once more.
      final again = await t.importBook(
        t.copyFixture('sample.epub', 'again.epub'),
      );
      await locations.unhide((locationId: 'remote', key: copy.key));
      await t.library.remove(again.id);
      await locations.scan('remote', generation, [copy]);
      await locations.hideRemovedCopies(location, generation);
      expect(await locations.catalog(), isEmpty);
      expect((await locations.hidden()).single.entry.key, copy.key);
    },
  );

  test(
    'a hidden file taken over from a removed connection retires the admission at its key',
    () async {
      final t = await TempLibrary.create();
      final kept = await t.importBook(t.copyFixture('sample.epub', 'a.epub'));
      final removed = await t.importBook(t.copyFixture('sample.pdf', 'b.pdf'));
      final locations = LibraryLocations(t.store);
      final old = await locations.connect('old', 'Old drive');
      final removedFile = LocationEntry(
        key: 'shelf/book',
        name: 'book',
        isDirectory: false,
        size: removed.fileSize,
        revision: 'r9',
      );
      await locations.admit('old', old, removedFile, removed.contentHash);
      await t.library.remove(removed.id);
      await locations.remove('old');

      final current = await locations.connect('new', 'New drive');
      final keptFile = LocationEntry(
        key: removedFile.key,
        name: 'book',
        isDirectory: false,
        size: kept.fileSize,
        revision: 'r1',
      );
      await locations.admit('new', current, keptFile, kept.contentHash);
      await locations.locate(kept.contentHash, (
        locationId: 'new',
        key: keptFile.key,
      ), generation: current);

      // The file at that key is now the removed connection's hidden one.
      expect(await locations.scan('new', current, [removedFile]), {
        removedFile.key,
      });
      final hidden = (await locations.hidden()).single;
      expect(hidden.locationId, 'new');
      expect(hidden.contentHash, removed.contentHash);
      expect(
        (await locations.copies(kept.contentHash)).single.failure,
        LocationFailure.missing,
      );
      // No admission names the kept book at that key any more.
      expect(await locations.scan('new', current, [keptFile]), isEmpty);
    },
  );

  test(
    'a file unhidden here is not taken over hidden from a removed connection',
    () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'book.epub'),
      );
      final locations = LibraryLocations(t.store);
      final first = await locations.connect('first', 'First');
      final second = await locations.connect('second', 'Second');
      final copy = LocationEntry(
        key: 'a',
        name: 'a.epub',
        isDirectory: false,
        size: book.fileSize,
        revision: 'r1',
        sha256: book.contentHash,
      );
      await t.library.remove(book.id);
      expect(await locations.scan('first', first, [copy]), {copy.key});
      expect(await locations.scan('second', second, [copy]), {copy.key});
      await locations.unhide((locationId: 'first', key: copy.key));
      await locations.remove('second');

      expect(await locations.scan('first', first, [copy]), isEmpty);
      expect(
        [for (final file in await locations.catalog()) file.locationId],
        ['first'],
      );
      // The removed connection keeps its own hidden record.
      expect(
        await t.store.read(
          (db) => db
              .select('SELECT location_id FROM library_hidden_source_files')
              .map((row) => row.columnAt(0))
              .toList(),
        ),
        ['second'],
      );
    },
  );

  test('a listed negative size is an unknown size', () async {
    final t = await TempLibrary.create();
    final path = t.copyFixture('sample.epub', 'book.epub');
    final bytes = File(path).readAsBytesSync();
    final book = await t.importBook(path);
    final locations = LibraryLocations(t.store);
    final location = _Location();
    final generation = await locations.connect('remote', 'Remote books');
    await t.library.remove(book.id);
    final copy = location.file('copy.epub', 'c1', -1);
    location.contents[copy.key] = bytes;
    await locations.scan('remote', generation, [copy]);
    expect(await locations.catalog(), isEmpty);
    expect(await locations.hideRemovedCopies(location, generation), {copy.key});
    expect((await locations.hidden()).single.entry.key, copy.key);
  });

  test(
    'removed contents carry over every hidden file of an older store',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      final before = await Store.open(
        path,
        migrations: schemaMigrations.where((m) => m.version <= 20).toList(),
      );
      final kept = 'd' * 64;
      await before.transaction((db) {
        db.execute(
          "INSERT INTO library_locations (id, label) VALUES ('l', 'L')",
        );
        db.execute(
          'INSERT INTO books (title, format, file_path, storage_kind, '
          'original_path, content_hash, file_size) '
          "VALUES ('Kept', 'epub', '/kept.epub', 'referenced', '/kept.epub', ?, 5)",
          [kept],
        );
        for (final (key, hash, size) in [
          ('unsized', 'a' * 64, null),
          ('invalid', 'b' * 64, -1),
          ('sized', 'c' * 64, 10),
          ('sized-again', 'c' * 64, 10),
          ('conflicting', 'e' * 64, 100),
          ('conflicting-again', 'e' * 64, 101),
          ('conflicting-invalid', 'e' * 64, -1),
          ('kept', kept, 5),
        ]) {
          db.execute(
            'INSERT INTO library_hidden_source_files '
            '(location_id, locator_key, content_hash, size, revision) '
            "VALUES ('l', ?, ?, ?, 'r')",
            [key, hash, size],
          );
        }
      });
      await before.close();

      final store = await Store.open(path);
      addTearDown(store.close);
      expect(
        await store.read(
          (db) => {
            for (final row in db.select(
              'SELECT content_hash, size FROM library_removed_contents',
            ))
              row.columnAt(0) as String: row.columnAt(1) as int?,
          },
        ),
        {'a' * 64: null, 'b' * 64: null, 'c' * 64: 10, 'e' * 64: null},
      );
    },
  );
}

final class _Location implements LibraryLocation {
  LocationFailure? failure;
  final contents = <String, List<int>>{};
  final failures = <String, LocationFailure>{};
  final reads = <String>[];
  final stats = <String, LocationEntry>{};
  Completer<void>? gate;

  /// A listed file, which [stat] reports as listed.
  LocationEntry file(String key, String revision, int? size, {String? sha}) =>
      stats[key] = LocationEntry(
        key: key,
        name: key.split('/').last,
        isDirectory: false,
        size: size,
        revision: revision,
        sha256: sha,
      );
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
    reads.add(key);
    if (failures[key] ?? failure case final failure?) {
      throw LocationException(failure);
    }
    if (started?.isCompleted == false) started!.complete();
    await gate?.future;
    yield (contents[key] ?? [3, 7, 11, 19, 23]).sublist(start, end);
  }

  @override
  Future<LocationPage> list({
    String? directory,
    String? cursor,
    int limit = 100,
    CancellationToken? cancellation,
  }) => throw UnimplementedError();

  @override
  Future<LocationEntry> stat(
    String key, {
    CancellationToken? cancellation,
  }) async =>
      stats[key] ?? (throw const LocationException(LocationFailure.missing));

  @override
  Future<LocationEntry> write(
    String name,
    Stream<List<int>> bytes, {
    String? directory,
    CancellationToken? cancellation,
  }) => throw UnimplementedError();
}
