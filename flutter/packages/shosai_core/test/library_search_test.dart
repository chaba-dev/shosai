import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

const _chapter = 'OEBPS/chapter1.xhtml';

/// A book's unit texts, as a format engine would supply them.
final class _Text implements UnitTextSource {
  _Text(this.units);

  final List<String?> units;

  @override
  int get unitCount => units.length;

  @override
  Future<UnitText?> unitText(
    int unit, {
    CancellationToken? cancellation,
  }) async => switch (units[unit]) {
    final text? => UnitText(text, resourcePath: _chapter),
    null => null,
  };
}

void main() {
  late TempLibrary t;
  late Annotations annotations;
  late LibrarySearch search;
  var books = 0;

  /// Each book's text by id, and the books [reader] opened.
  final texts = <int, List<String?>>{};
  final opened = <int>[];
  final failing = <int, Exception>{};

  Future<void> reader(Book book, Future<void> Function(UnitTextSource) read) {
    opened.add(book.id);
    if (failing[book.id] case final error?) return Future.error(error);
    return read(_Text(texts[book.id]!));
  }

  Future<int> book(
    String format,
    List<String?> text, {
    String title = 'Book',
    String? lastRead,
  }) async {
    final hash = (++books).toRadixString(16).padLeft(64, 'c');
    final path = '/books/$hash.$format';
    final id = await t.execute(
      '''INSERT INTO books (title, format, file_path, storage_kind,
           original_path, content_hash, file_size, last_read)
         VALUES (?, ?, ?, 'referenced', ?, ?, 0, ?)''',
      [title, format, path, path, hash, lastRead],
    );
    texts[id] = text;
    return id;
  }

  Future<List<BookTextHits>> searchText(String query, {int? bookId}) =>
      search.text(query, bookId: bookId, read: reader).toList();

  setUp(() async {
    t = await TempLibrary.create();
    annotations = Annotations(t.store);
    search = LibrarySearch(
      t.store,
      textVersions: const {BookFormat.epub: 'epub-1', BookFormat.pdf: 'pdf-1'},
    );
    texts.clear();
    opened.clear();
    failing.clear();
  });

  group('notes', () {
    test('finds quotes and bodies across books, recent first', () async {
      const text = 'The STRASSE runs north.';
      final older = await book(
        'epub',
        [text],
        title: 'Older',
        lastRead: '2026-01-01T00:00:00.000Z',
      );
      final newer = await book(
        'pdf',
        ['page'],
        title: 'Newer',
        lastRead: '2026-02-01T00:00:00.000Z',
      );
      final highlight = await annotations.create(
        older,
        const EpubTextSelection(
          spineIndex: 0,
          resourcePath: _chapter,
          text: text,
          start: 4,
          end: 11,
        ),
        body: 'Look up the straße',
      );
      final whole = await annotations.createNote(
        older,
        const BookAnchor(),
        'A Straße novel',
      );
      final page = await annotations.createNote(
        newer,
        const PdfPageAnchor(0),
        'Map of the strasse',
      );
      await annotations.createNote(newer, const BookAnchor(), 'Unrelated');
      final gone = await annotations.createNote(
        newer,
        const PdfPageAnchor(1),
        'strasse, deleted',
      );
      await annotations.delete(newer, gone.id);

      final found = await search.notes('straße');

      expect(found.map((b) => b.book.title), ['Newer', 'Older']);
      expect(found[0].hits.map((h) => h.note.id), [page.id]);
      expect(found[0].hits.single.matches, [
        const NoteMatch(NoteField.body, 11, 7),
      ]);
      // The book note first, then the highlight.
      expect(found[1].hits.map((h) => h.note.id), [whole.id, highlight.id]);
      expect(found[1].hits[1].matches, [
        const NoteMatch(NoteField.quote, 0, 7),
        const NoteMatch(NoteField.body, 12, 6),
      ]);

      final scoped = await search.notes('strasse', bookId: older);
      expect(scoped.single.book.id, older);
      expect(await search.notes(''), isEmpty);
      expect(await search.notes('nowhere'), isEmpty);
    });

    test('a query over its limit is refused', () async {
      await expectLater(
        search.notes('x' * 5000),
        throwsCoreError(CoreErrorKind.limitExceeded),
      );
    });
  });

  group('text', () {
    test('reads a book once, then searches its saved text', () async {
      final epub = await book('epub', [
        'Café one',
        null,
        'two CAFÉ',
      ], lastRead: '2026-01-01T00:00:00.000Z');
      final pdf = await book('pdf', [
        'no match here',
        'café',
      ], lastRead: '2026-02-01T00:00:00.000Z');
      await book('epub', ['nothing']);

      final first = await searchText('café');

      expect(first.map((b) => b.book.id), [pdf, epub]);
      expect(first[0].matches.map((m) => (m.unit, m.offset, m.length)), [
        (1, 0, 4),
      ]);
      expect(first[1].matches.map((m) => (m.unit, m.offset)), [(0, 0), (2, 4)]);
      expect(first[1].more, isFalse);
      expect(first[1].partial, isFalse);
      expect(opened, hasLength(3));
      expect(await t.count('book_texts'), 3);

      opened.clear();
      final second = await searchText('two');
      expect(opened, isEmpty);
      expect(second.single.book.id, epub);
      expect(second.single.matches.single.context, 'two CAFÉ');

      final scoped = await searchText('café', bookId: epub);
      expect(scoped.single.book.id, epub);
    });

    test('a changed text version reads the book again', () async {
      await book('epub', ['words']);
      await searchText('words');
      opened.clear();

      final updated = LibrarySearch(
        t.store,
        textVersions: const {BookFormat.epub: 'epub-2'},
      );
      final found = await updated.text('words', read: reader).toList();

      expect(found, hasLength(1));
      expect(opened, hasLength(1));
      expect(await t.count('book_texts'), 1);
    });

    test('a book that cannot be read is reported and skipped', () async {
      final missing = await book('epub', [
        'word',
      ], lastRead: '2026-02-01T00:00:00.000Z');
      final kept = await book('epub', ['word']);
      failing[missing] = const CoreException.notFound('The file is missing.');

      final found = await searchText('word');

      expect(found.map((b) => (b.book.id, b.error?.kind)), [
        (missing, CoreErrorKind.notFound),
        (kept, null),
      ]);
      expect(await t.count('book_texts'), 1);

      failing[kept] = Exception('engine failure');
      failing[missing] = Exception('engine failure');
      final again = await searchText('word');
      // The kept book's text is saved; the other still fails.
      expect(again.map((b) => (b.book.id, b.error?.kind)), [
        (missing, CoreErrorKind.inaccessible),
        (kept, null),
      ]);
    });

    test('keeps the first matches and what one search covers', () async {
      final many = await book('epub', [
        List.filled(maxLibraryTextMatchesPerBook + 1, 'a').join(' '),
      ]);
      final large = await book('pdf', [
        'needle ${'x' * (maxLibraryTextBytes - 100)}',
        'needle ${'y' * 200}',
      ]);

      final found = await searchText('a', bookId: many);
      expect(found.single.matches, hasLength(maxLibraryTextMatchesPerBook));
      expect(found.single.more, isTrue);

      final partial = await searchText('needle', bookId: large);
      expect(partial.single.matches.map((m) => m.unit), [0]);
      expect(partial.single.partial, isTrue);
      final saved = await searchText('needle', bookId: large);
      expect(saved.single.partial, isTrue);
    });

    test('a removed book forgets its saved text', () async {
      final removed = await book('epub', ['gone']);
      await book('epub', ['kept']);
      await searchText('gone');
      await t.execute('DELETE FROM books WHERE id = ?', [removed]);

      await searchText('kept');

      expect(await t.count('book_texts'), 1);
      expect(await t.count('book_text_units'), 1);
    });

    test('observes cancellation', () async {
      await book('epub', ['word']);
      final cancellation = CancellationToken()..cancel();

      await expectLater(
        search.text('word', read: reader, cancellation: cancellation).toList(),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      expect(opened, isEmpty);
    });

    test('text versions are checked', () {
      expect(
        () => LibrarySearch(t.store, textVersions: const {BookFormat.pdf: ''}),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
    });
  });
}
