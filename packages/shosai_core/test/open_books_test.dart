import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

void main() {
  late TempLibrary t;
  late Book epub;
  late Book pdf;

  setUp(() async {
    t = await TempLibrary.create();
    epub = await t.importBook(t.copyFixture('sample.epub', 'sample.epub'));
    pdf = await t.importBook(t.copyFixture('sample.pdf', 'sample.pdf'));
  });

  OpenBooksStore store() => OpenBooksStore(t.store, t.library);

  test(
    'a located active book restores from a kept copy, not its staging path',
    () async {
      final locations = LibraryLocations(t.store);
      final generation = await locations.connect('folder', 'Books');
      await locations.locate(epub.contentHash, (
        locationId: 'folder',
        key: 'sample.epub',
      ), generation: generation);
      final cache = BookFileCache(t.store, t.path('cache'));
      await cache.withFile(
        epub,
        () => File(epub.path).openRead(),
        (_) async {},
        keep: true,
      );
      await store().save(
        OpenBooksSession(
          books: [(bookId: epub.id, path: epub.path, openBookId: epub.id)],
          current: epub.id,
          reading: true,
        ),
      );
      File(epub.path).deleteSync();
      await locations.remove('folder');
      expect((await store().load())!.reading, isTrue);
      await cache.release(epub);
      await cache.discardUnkept(epub.contentHash, epub.format);
      final unavailable = (await store().load())!;
      expect(unavailable.current, epub.id);
      expect(unavailable.reading, isFalse);
    },
  );

  test('nothing is open until saved, then the books round-trip with the '
      "library's records", () async {
    expect(await store().load(), isNull);

    await store().save(
      OpenBooksSession(
        books: [
          (bookId: pdf.id, path: pdf.path, openBookId: pdf.id),
          (bookId: epub.id, path: '${epub.path}#later', openBookId: null),
        ],
        current: epub.id,
        reading: true,
      ),
    );

    final loaded = (await store().load())!;
    expect([for (final open in loaded.books) open.book.id], [pdf.id, epub.id]);
    expect(loaded.books.first.book.title, pdf.title);
    expect(loaded.books.last.path, '${epub.path}#later');
    expect(loaded.books.last.openBookId, isNull);
    expect(loaded.current, epub.id);
    expect(loaded.reading, isTrue);
  });

  test('a removed book is left out, and the current one with it', () async {
    await store().save(
      OpenBooksSession(
        books: [
          (bookId: pdf.id, path: pdf.path, openBookId: pdf.id),
          (bookId: epub.id, path: epub.path, openBookId: epub.id),
        ],
        current: epub.id,
        reading: true,
      ),
    );
    await t.library.remove(epub.id);

    final loaded = (await store().load())!;
    expect([for (final open in loaded.books) open.book.id], [pdf.id]);
    expect(loaded.current, isNull);
    expect(loaded.reading, isFalse);
  });

  test(
    'a book whose file is gone stays open but is not read on start',
    () async {
      await store().save(
        OpenBooksSession(
          books: [(bookId: epub.id, path: epub.path, openBookId: epub.id)],
          current: epub.id,
          reading: true,
        ),
      );
      File(epub.path).deleteSync();

      final loaded = (await store().load())!;
      expect([for (final open in loaded.books) open.book.id], [epub.id]);
      expect(loaded.current, epub.id);
      expect(loaded.reading, isFalse);
    },
  );

  test('an unreadable saved value reads as nothing open, and an entry '
      'without an id is skipped', () async {
    final preferences = Preferences(t.store);
    for (final value in ['not json', '[]', '{"books": 3}']) {
      await preferences.set('shell.openBooks', value);
      expect(await store().load(), isNull, reason: value);
    }

    await preferences.set(
      'shell.openBooks',
      '{"books": [{"openPath": "/x"}, '
          '{"id": ${pdf.id}, "openPath": "${pdf.path}", "title": "old"}], '
          '"current": ${pdf.id}}',
    );
    final loaded = (await store().load())!;
    expect([for (final open in loaded.books) open.book.id], [pdf.id]);
    expect(loaded.books.single.openBookId, isNull);
    expect(loaded.reading, isFalse);
  });

  test("a tab showing its own book opens it at the library's path, which "
      'may have moved since it was saved', () async {
    await store().save(
      OpenBooksSession(
        books: [
          (
            bookId: pdf.id,
            path: '/old/container/books/sample.pdf',
            openBookId: pdf.id,
          ),
          (bookId: epub.id, path: '/elsewhere/other.epub', openBookId: null),
        ],
        current: pdf.id,
      ),
    );

    final loaded = (await store().load())!;
    expect(
      [for (final open in loaded.books) open.path],
      [pdf.path, '/elsewhere/other.epub'],
    );
  });
}
