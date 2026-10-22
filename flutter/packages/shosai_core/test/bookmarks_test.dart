import 'dart:convert';

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

  group('bookmarks', () {
    test('toggling adds and then removes a bookmark', () async {
      final bookmarks = Bookmarks(t.store);

      final added = await bookmarks.toggle(pdf.id, 3, title: 'Chapter 4');

      expect(added!.unit, 3);
      expect(added.offset, isNull);
      expect(added.title, 'Chapter 4');
      expect(added.note, isNull);
      expect(added.color, 'yellow');
      expect(added.createdAt, endsWith('Z'));
      expect(await bookmarks.list(pdf.id), [added]);

      expect(await bookmarks.toggle(pdf.id, 3), isNull);
      expect(await bookmarks.list(pdf.id), isEmpty);
    });

    test('a bookmark with a note is not toggled off', () async {
      final bookmarks = Bookmarks(t.store);
      final noted = await bookmarks.toggle(pdf.id, 0, note: 'Remember this');

      final plain = await bookmarks.toggle(pdf.id, 0);

      expect(noted!.note, 'Remember this');
      expect(plain, isNotNull);
      expect(await bookmarks.list(pdf.id), [noted, plain]);
    });

    test('EPUB bookmarks share a chapter at distinct offsets', () async {
      final bookmarks = Bookmarks(t.store);
      final later = await bookmarks.toggle(epub.id, 1, offset: 900);
      final earlier = await bookmarks.toggle(epub.id, 1, offset: 10);
      final chapter = await bookmarks.toggle(epub.id, 0);

      expect(await bookmarks.list(epub.id), [chapter, earlier, later]);

      expect(await bookmarks.toggle(epub.id, 1, offset: 10), isNull);
      expect(await bookmarks.list(epub.id), [chapter, later]);
    });

    test('bookmarks are listed only for their book', () async {
      final bookmarks = Bookmarks(t.store);
      await bookmarks.toggle(pdf.id, 0);

      expect(await bookmarks.list(epub.id), isEmpty);
      expect(await bookmarks.list(pdf.id), hasLength(1));
    });

    test(
      'notes are updated and cleared; missing bookmarks are reported',
      () async {
        final bookmarks = Bookmarks(t.store);
        final bookmark = (await bookmarks.toggle(pdf.id, 1))!;

        await bookmarks.updateNote(bookmark.id, 'Updated');
        expect((await bookmarks.list(pdf.id)).single.note, 'Updated');
        await bookmarks.updateNote(bookmark.id, null);
        expect((await bookmarks.list(pdf.id)).single.note, isNull);

        await bookmarks.delete(bookmark.id);
        expect(await bookmarks.list(pdf.id), isEmpty);
        await bookmarks.delete(bookmark.id);
        await expectLater(
          bookmarks.updateNote(bookmark.id, 'Gone'),
          throwsCoreError(CoreErrorKind.notFound),
        );
      },
    );

    test('a deleted bookmark id is never reused', () async {
      final bookmarks = Bookmarks(t.store);
      final a = (await bookmarks.toggle(pdf.id, 0, note: 'A'))!;
      await bookmarks.delete(a.id);

      final b = (await bookmarks.toggle(epub.id, 0, note: 'B'))!;

      expect(b.id, isNot(a.id));
      // Late requests for the deleted bookmark do not reach the new one.
      await expectLater(
        bookmarks.updateNote(a.id, 'late'),
        throwsCoreError(CoreErrorKind.notFound),
      );
      await bookmarks.delete(a.id);
      expect(await bookmarks.list(epub.id), [b]);
      expect(b.note, 'B');
    });

    test(
      'bookmarks follow the content through removal and re-import',
      () async {
        final bookmarks = Bookmarks(t.store);
        final bookmark = await bookmarks.toggle(epub.id, 1, offset: 5);

        await t.library.remove(epub.id);
        final again = await t.importBook(t.path('sample.epub'));

        expect(await bookmarks.list(again.id), [bookmark]);
      },
    );

    test('fields are bounded', () async {
      final bookmarks = Bookmarks(t.store);
      final bookmark = (await bookmarks.toggle(
        pdf.id,
        0,
        title: 't' * maxBookmarkTitleBytes,
        note: 'n' * maxBookmarkNoteBytes,
      ))!;

      await expectLater(
        bookmarks.toggle(pdf.id, 1, title: 't' * (maxBookmarkTitleBytes + 1)),
        throwsCoreError(CoreErrorKind.invalidRequest, contains('title')),
      );
      await expectLater(
        bookmarks.toggle(
          pdf.id,
          1,
          note: 'é' * (maxBookmarkNoteBytes ~/ 2 + 1),
        ),
        throwsCoreError(CoreErrorKind.invalidRequest, contains('note')),
      );
      await expectLater(
        bookmarks.updateNote(bookmark.id, 'n' * (maxBookmarkNoteBytes + 1)),
        throwsCoreError(CoreErrorKind.invalidRequest, contains('note')),
      );
      await expectLater(
        bookmarks.toggle(pdf.id, -1),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      await expectLater(
        bookmarks.toggle(pdf.id, 0, offset: -1),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
    });

    test('a book holds a bounded number of bookmarks', () async {
      final bookmarks = Bookmarks(t.store);
      await t.executeMany(
        'INSERT INTO bookmarks (content_hash, unit) VALUES (?, ?)',
        [
          for (var unit = 0; unit < 1023; unit++) [pdf.contentHash, unit],
        ],
      );

      // The 1,024th bookmark fits; the 1,025th does not.
      final last = await bookmarks.toggle(pdf.id, 1023);
      expect(last, isNotNull);
      await expectLater(
        bookmarks.toggle(pdf.id, 1024),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
      final listed = await bookmarks.list(pdf.id);
      expect(listed, hasLength(1024));
      expect(listed.last, last);
      // Removing one still works at the limit.
      expect(await bookmarks.toggle(pdf.id, 0), isNull);

      await t.executeMany(
        'INSERT INTO bookmarks (content_hash, unit) VALUES (?, ?)',
        [
          [pdf.contentHash, 0],
          [pdf.contentHash, 1],
        ],
      );
      await expectLater(
        bookmarks.list(pdf.id),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('concurrent toggles at one location are serialized', () async {
      final bookmarks = Bookmarks(t.store);

      final results = await Future.wait([
        bookmarks.toggle(pdf.id, 2),
        bookmarks.toggle(pdf.id, 2),
        bookmarks.toggle(pdf.id, 2),
      ]);

      expect(results.map((bookmark) => bookmark == null), [false, true, false]);
      expect(await bookmarks.list(pdf.id), [results.last]);
    });

    test('unknown books are reported', () async {
      final bookmarks = Bookmarks(t.store);
      final missing = pdf.id + 1;

      for (final request in [
        () => bookmarks.list(missing),
        () => bookmarks.toggle(missing, 0),
        () => bookmarks.exportMarkdown(missing),
      ]) {
        await expectLater(request(), throwsCoreError(CoreErrorKind.notFound));
      }
    });

    test('exports Markdown in reading order', () async {
      final bookmarks = Bookmarks(t.store);
      await bookmarks.toggle(
        epub.id,
        4,
        title: 'Key Concept',
        note: 'Important.',
      );
      await bookmarks.toggle(epub.id, 0, title: 'Introduction');

      final markdown = await bookmarks.exportMarkdown(epub.id);

      expect(markdown, startsWith('# Bookmarks: Sample Book\n\n'));
      expect(
        markdown.indexOf('## Page 1: Introduction'),
        lessThan(markdown.indexOf('## Page 5: Key Concept\n\nImportant.\n\n')),
      );
      expect(RegExp(r'\*Added: .+Z\*').allMatches(markdown), hasLength(2));
      expect(
        await bookmarks.exportMarkdown(pdf.id),
        '# Bookmarks: Sample PDF\n\n',
      );
    });

    test('the export is bounded', () async {
      final bookmarks = Bookmarks(t.store);
      final note = 'n' * maxBookmarkNoteBytes;
      await t.executeMany(
        'INSERT INTO bookmarks (content_hash, unit, note) VALUES (?, ?, ?)',
        [
          for (var unit = 0; unit < 65; unit++) [pdf.contentHash, unit, note],
        ],
      );

      await expectLater(
        bookmarks.exportMarkdown(pdf.id),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('an export of exactly 4 MiB succeeds; one byte more fails', () async {
      const limit = 4 * 1024 * 1024;
      const added = '2026-01-02T03:04:05.678Z';
      // A note of exactly [bytes] UTF-8 bytes, mostly three-byte characters.
      String noteOf(int bytes) =>
          '日' * (bytes ~/ 3) + const ['', 'a', 'é'][bytes % 3];
      String entry(int unit, String note) =>
          '## Page ${unit + 1}: Untitled\n\n$note\n\n'
          '*Added: $added*\n\n---\n\n';
      int size(String text) => utf8.encode(text).length;

      // Fill the export to the limit with notes of at most 64 KiB each.
      var expected = '# Bookmarks: Sample PDF\n\n';
      final notes = <String>[];
      while (size(expected) < limit) {
        final room = limit - size(expected) - size(entry(notes.length, ''));
        expect(room, greaterThan(0));
        final note = noteOf(room < 65536 ? room : 65536);
        expected += entry(notes.length, note);
        notes.add(note);
      }
      expect(size(expected), limit);
      await t.executeMany(
        '''INSERT INTO bookmarks (content_hash, unit, note, created_at)
           VALUES (?, ?, ?, ?)''',
        [
          for (final (unit, note) in notes.indexed)
            [pdf.contentHash, unit, note, added],
        ],
      );
      final bookmarks = Bookmarks(t.store);

      expect(await bookmarks.exportMarkdown(pdf.id), expected);

      // One more byte in the last note puts the export over the limit.
      expect(size(notes.last), lessThan(65536));
      await t.execute(
        "UPDATE bookmarks SET note = note || 'x' WHERE content_hash = ? "
        'AND unit = ?',
        [pdf.contentHash, notes.length - 1],
      );
      await expectLater(
        bookmarks.exportMarkdown(pdf.id),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });

    test('the schema rejects malformed rows', () async {
      for (final row in <List<Object?>>[
        ['a' * 63, 0, null, null, null, 'yellow'],
        [pdf.contentHash, -1, null, null, null, 'yellow'],
        [pdf.contentHash, 0, -1, null, null, 'yellow'],
        [pdf.contentHash, 0, null, 't' * 4097, null, 'yellow'],
        [pdf.contentHash, 0, null, null, 'n' * 65537, 'yellow'],
        [pdf.contentHash, 0, null, null, null, ''],
      ]) {
        await expectLater(
          t.execute('''INSERT INTO bookmarks
                 (content_hash, unit, location_offset, title, note, color)
               VALUES (?, ?, ?, ?, ?, ?)''', row),
          throwsCoreError(CoreErrorKind.storage),
          reason: '${row.take(3)}',
        );
      }
    });
  });
}
