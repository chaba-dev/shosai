import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

void main() {
  group('import', () {
    test('reads the EPUB title, author and cover', () async {
      final t = await TempLibrary.create();
      final path = t.copyFixture('sample.epub', 'sample.epub');

      final book = await t.importBook(path);

      expect(book.format, BookFormat.epub);
      expect(book.title, 'Sample Book');
      expect(book.author, 'Test Author');
      expect(book.storageKind, StorageKind.referenced);
      expect(book.path, path);
      expect(book.originalPath, path);
      expect(
        book.contentHash,
        sha256.convert(File(path).readAsBytesSync()).toString(),
      );
      expect(book.fileSize, File(path).lengthSync());
      expect(book.progress, 0);
      expect(book.lastRead, isNull);
      expect(book.hasCover, isTrue);
      final cover = (await t.library.cover(book.id))!;
      expect(cover.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
      expect(await t.library.get(book.id), book);
    });

    test(
      'takes PDF metadata from the host inspector, else the file name',
      () async {
        final withInspector = await TempLibrary.create();
        final pdf = withInspector.copyFixture('sample.pdf', 'Field Notes.pdf');
        expect((await withInspector.importBook(pdf)).title, 'Sample PDF');

        final without = await TempLibrary.create(
          inspectors: const {BookFormat.epub: EpubInspector()},
        );
        final book = await without.importBook(
          without.copyFixture('sample.pdf', 'Field Notes.pdf'),
        );
        expect(book.format, BookFormat.pdf);
        expect(book.title, 'Field Notes');
        expect(book.author, isNull);
        expect(book.hasCover, isFalse);
      },
    );

    test(
      'detects the format from content when there is no extension',
      () async {
        final t = await TempLibrary.create();
        final pdf = await t.importBook(t.copyFixture('sample.pdf', 'scan'));
        final epub = await t.importBook(t.copyFixture('sample.epub', 'novel'));

        expect(pdf.format, BookFormat.pdf);
        expect(epub.format, BookFormat.epub);
      },
    );

    test('importing the same content returns the existing book', () async {
      final t = await TempLibrary.create();
      final first = t.copyFixture('sample.epub', 'first.epub');
      final second = t.copyFixture('sample.epub', 'second.epub');
      final book = await t.importBook(first);

      final again = await t.library.importFile(first, managed: false);
      final copy = await t.library.importFile(second, managed: false);

      expect(again.duplicate, isTrue);
      expect(again.book, book);
      expect(copy.duplicate, isTrue);
      expect(copy.book, book);
      expect(await t.count('books'), 1);
    });

    test('follows content that moved to a new path', () async {
      final t = await TempLibrary.create();
      final before = t.copyFixture('sample.epub', 'before.epub');
      final book = await t.importBook(before);
      await t.library.updateProgress(book.id, 0.4);
      final after = t.path('after.epub');
      File(before).renameSync(after);

      final moved = await t.library.importFile(after, managed: false);

      expect(moved.duplicate, isTrue);
      expect(moved.book!.id, book.id);
      expect(moved.book!.path, canonicalBookPath(after));
      expect(moved.book!.progress, 0.4);
      expect(await t.library.verifiedPath(book.id), canonicalBookPath(after));
    });

    test('rejects replaced content at an imported path', () async {
      final t = await TempLibrary.create();
      final path = t.copyFixture('sample.epub', 'book.epub');
      await t.importBook(path);
      File(
        path,
      ).writeAsBytesSync(withZipComment(File(path).readAsBytesSync(), 'x'));

      final item = await t.library.importFile(path, managed: false);

      expect(item.book, isNull);
      expect(item.error, contains('no longer match'));
    });

    test('opening checks that the file still holds the book', () async {
      final t = await TempLibrary.create();
      final path = t.copyFixture('sample.epub', 'book.epub');
      final book = await t.importBook(path);
      expect(await t.library.verifiedPath(book.id), path);

      File(
        path,
      ).writeAsBytesSync(withZipComment(File(path).readAsBytesSync(), 'x'));
      await expectLater(
        t.library.verifiedPath(book.id),
        throwsCoreError(CoreErrorKind.conflict, contains('no longer match')),
      );

      File(path).deleteSync();
      await expectLater(
        t.library.verifiedPath(book.id),
        throwsCoreError(CoreErrorKind.notFound, contains('missing')),
      );
      await expectLater(
        t.library.verifiedPath(book.id + 1),
        throwsCoreError(CoreErrorKind.notFound),
      );
    });

    test('reports unsupported and unreadable files', () async {
      final t = await TempLibrary.create();
      final text = t.path('notes.txt');
      File(text).writeAsStringSync('plain text');
      final broken = t.path('broken.epub');
      File(broken).writeAsStringSync('not a zip');

      final unsupported = await t.library.importFile(text, managed: false);
      final malformed = await t.library.importFile(broken, managed: false);
      final missing = await t.library.importFile(
        t.path('missing.pdf'),
        managed: false,
      );

      expect(unsupported.error, 'Unsupported format: .txt');
      expect(malformed.error, contains('cannot be read'));
      expect(missing.error, contains('does not exist'));
      expect(await t.count('books'), 0);
    });

    test('a batch continues after a failure and reports it', () async {
      final t = await TempLibrary.create();
      final missing = t.path('missing.epub');
      final good = t.copyFixture('sample.epub', 'good.epub');

      final report = await t.library.importPaths([
        missing,
        good,
      ], managed: false);

      expect(report.imported, 1);
      expect(report.failed, 1);
      expect(report.cancelled, isFalse);
      expect(report.items.map((item) => item.path), [missing, good]);
      expect(report.items.first.error, isNotNull);
      expect(report.items.last.book!.title, 'Sample Book');
    });

    test('a batch is bounded and rejects bad paths up front', () async {
      final t = await TempLibrary.create();

      await expectLater(
        t.library.importPaths(
          List.filled(maxSelectedImportPaths + 1, t.path('a.epub')),
          managed: false,
        ),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      await expectLater(
        t.library.importPaths([''], managed: false),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      await expectLater(
        t.library.importPaths(['x' * (maxBookPathBytes + 1)], managed: false),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
    });

    test('cancellation stops before the next file', () async {
      final t = await TempLibrary.create();
      final path = t.copyFixture('sample.epub', 'book.epub');
      final cancellation = CancellationToken()..cancel();

      final report = await t.library.importPaths(
        [path],
        managed: false,
        cancellation: cancellation,
      );

      expect(report.cancelled, isTrue);
      expect(report.imported, 0);
      expect(report.items, isEmpty);
      expect(await t.count('books'), 0);
    });

    test(
      'a managed import cancelled before its commit leaves nothing',
      () async {
        final cancellation = CancellationToken();
        final t = await TempLibrary.create(
          inspectors: {BookFormat.epub: _CancellingInspector(cancellation)},
        );
        final path = t.copyFixture('sample.epub', 'book.epub');

        final report = await t.library.importPaths(
          [path],
          managed: true,
          cancellation: cancellation,
        );

        expect(report.cancelled, isTrue);
        expect(await t.count('books'), 0);
        expect(Directory(t.managedDirectory).listSync(), isEmpty);
      },
    );

    test('rejects oversized metadata', () async {
      final t = await TempLibrary.create(
        inspectors: {
          BookFormat.pdf: FakePdfInspector(
            title: 'x' * (maxBookMetadataBytes + 1),
          ),
        },
      );

      final item = await t.library.importFile(
        t.copyFixture('sample.pdf', 'book.pdf'),
        managed: false,
      );

      expect(item.error, contains('exceeds'));
    });
  });

  group('directory import', () {
    test('imports nested books and skips other files', () async {
      final t = await TempLibrary.create();
      t.copyFixture('sample.epub', 'shelf/novel.epub');
      t.copyFixture('sample.pdf', 'shelf/papers/paper.pdf');
      File(t.path('shelf/readme.txt')).writeAsStringSync('skip me');

      final report = await t.library.importDirectory(
        t.path('shelf'),
        managed: false,
      );

      expect(report.imported, 2);
      expect(report.failed, 0);
      expect(report.items.map((item) => p.basename(item.path)), [
        'novel.epub',
        'paper.pdf',
      ]);
    });

    test('does not follow directory cycles', () async {
      final t = await TempLibrary.create();
      t.copyFixture('sample.epub', 'shelf/a/book.epub');
      Link(t.path('shelf/a/loop')).createSync(t.path('shelf/a'));
      Link(t.path('shelf/a/root')).createSync(t.path('shelf'));

      final report = await t.library.importDirectory(
        t.path('shelf'),
        managed: false,
      );

      expect(report.imported, 1);
      expect(report.failed, 0);
    });

    test('follows symlinks only inside the selected folder', () async {
      final t = await TempLibrary.create();
      final outside = t.copyFixture('sample.pdf', 'outside/paper.pdf');
      t.copyFixture('sample.epub', 'shelf/book.epub');
      Link(t.path('shelf/outside.pdf')).createSync(outside);
      Link(t.path('shelf/outside-dir')).createSync(t.path('outside'));
      Link(t.path('shelf/alias.epub')).createSync(t.path('shelf/book.epub'));

      final report = await t.library.importDirectory(
        t.path('shelf'),
        managed: false,
      );

      expect(report.imported, 1);
      expect(
        report.items.single.path,
        canonicalBookPath(t.path('shelf/book.epub')),
      );
    });

    test('skips files that are not regular files', () async {
      final t = await TempLibrary.create();
      Directory(t.path('shelf')).createSync();
      final fifo = Process.runSync('mkfifo', [t.path('shelf/pipe.epub')]);
      if (fifo.exitCode != 0) markTestSkipped('mkfifo is unavailable');
      t.copyFixture('sample.pdf', 'shelf/paper.pdf');

      final report = await t.library.importDirectory(
        t.path('shelf'),
        managed: false,
      );

      expect(report.imported, 1);
      expect(report.failed, 0);
    });

    test('reports each failing book and keeps the rest', () async {
      final t = await TempLibrary.create();
      t.copyFixture('sample.epub', 'shelf/good.epub');
      File(t.path('shelf/bad.epub')).writeAsStringSync('not a zip');

      final report = await t.library.importDirectory(
        t.path('shelf'),
        managed: false,
      );

      expect(report.imported, 1);
      expect(report.failed, 1);
      expect(report.items.first.path, endsWith('bad.epub'));
      expect(report.items.first.error, isNotNull);
    });

    test('a missing folder or one cancelled before any book throws', () async {
      final t = await TempLibrary.create();
      t.copyFixture('sample.epub', 'shelf/good.epub');

      await expectLater(
        t.library.importDirectory(t.path('missing'), managed: false),
        throwsCoreError(CoreErrorKind.notFound),
      );
      await expectLater(
        t.library.importDirectory(
          t.path('shelf'),
          managed: false,
          cancellation: CancellationToken()..cancel(),
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      expect(await t.count('books'), 0);
    });
  });

  group('page', () {
    late TempLibrary t;
    late Book epub;
    late Book pdf;

    setUp(() async {
      t = await TempLibrary.create();
      epub = await t.importBook(t.copyFixture('sample.epub', 'a.epub'));
      pdf = await t.importBook(t.copyFixture('sample.pdf', 'b.pdf'));
    });

    Future<List<int>> ids({
      String? query,
      BookFormat? format,
      int limit = 100,
      int offset = 0,
    }) async => [
      for (final book in (await t.library.page(
        query: query,
        format: format,
        limit: limit,
        offset: offset,
      )).books)
        book.id,
    ];

    test('orders by last read, then most recently added', () async {
      expect(await ids(), [pdf.id, epub.id]);

      await t.library.updateProgress(epub.id, 0.5);

      expect(await ids(), [epub.id, pdf.id]);
    });

    test('searches title and author, case-insensitively', () async {
      expect(await ids(query: 'sample book'), [epub.id]);
      expect(await ids(query: 'TEST AUTHOR'), [epub.id]);
      expect(await ids(query: 'sample'), [pdf.id, epub.id]);
      expect(await ids(query: '%'), isEmpty);
      expect(await ids(query: '_'), isEmpty);
      expect(await ids(query: ''), [pdf.id, epub.id]);
    });

    test('filters by format and combines filters', () async {
      expect(await ids(format: BookFormat.epub), [epub.id]);
      expect(await ids(format: BookFormat.pdf), [pdf.id]);
      expect(await ids(query: 'book', format: BookFormat.pdf), isEmpty);
    });

    test('pages are bounded', () async {
      final first = await t.library.page(limit: 1);
      final second = await t.library.page(limit: 1, offset: 1);

      expect(first.books.single.id, pdf.id);
      expect(first.hasMore, isTrue);
      expect(second.books.single.id, epub.id);
      expect(second.hasMore, isFalse);
    });

    test('caps the page size and rejects bad requests', () async {
      await t.executeMany(
        '''INSERT INTO books (title, format, file_path, storage_kind,
             original_path, content_hash, file_size)
           VALUES (?, 'pdf', ?, 'referenced', ?, ?, 1)''',
        [
          for (var i = 0; i < maxLibraryPageSize + 5; i++)
            [
              'Book $i',
              '/books/$i.pdf',
              '/books/$i.pdf',
              '$i'.padLeft(64, '0'),
            ],
        ],
      );

      final page = await t.library.page(limit: maxLibraryPageSize * 2);

      expect(page.books, hasLength(maxLibraryPageSize));
      expect(page.hasMore, isTrue);
      await expectLater(
        t.library.page(query: 'x' * (maxLibraryQueryBytes + 1)),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      await expectLater(
        t.library.page(limit: 0),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
      await expectLater(
        t.library.page(offset: -1),
        throwsCoreError(CoreErrorKind.invalidRequest),
      );
    });

    test('library order uses an index', () async {
      final plan = (await t.select(
        '''EXPLAIN QUERY PLAN SELECT id FROM books WHERE format = 'pdf'
           ORDER BY last_read DESC, date_added DESC, id DESC LIMIT 10''',
      )).map((row) => row['detail'] as String).join('\n');

      expect(plan, contains('books_format_library_order_idx'));
      expect(plan, isNot(contains('TEMP B-TREE')));
    });
  });

  group('progress', () {
    test('records clamped progress and the reading time', () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(t.copyFixture('sample.epub', 'a.epub'));

      await t.library.updateProgress(book.id, 0.25);
      final read = (await t.library.get(book.id))!;
      await t.library.updateProgress(book.id, 7);

      expect(read.progress, 0.25);
      expect(read.lastRead, isNotNull);
      expect((await t.library.get(book.id))!.progress, 1);
    });

    test('rejects non-finite values and unknown books', () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(t.copyFixture('sample.epub', 'a.epub'));

      for (final value in [double.nan, double.infinity, -double.infinity]) {
        await expectLater(
          t.library.updateProgress(book.id, value),
          throwsCoreError(CoreErrorKind.invalidRequest),
        );
      }
      await expectLater(
        t.library.updateProgress(book.id + 1, 0.5),
        throwsCoreError(CoreErrorKind.notFound),
      );
      expect((await t.library.get(book.id))!.progress, 0);
    });
  });

  group('managed copies', () {
    // The managed directory may not exist yet, so its existing parent is
    // resolved instead (macOS's /tmp is a symlink to /private/tmp).
    String managedPath(TempLibrary t, String source, String extension) =>
        p.join(
          canonicalBookPath(p.dirname(t.managedDirectory)),
          p.basename(t.managedDirectory),
          '${sha256.convert(File(source).readAsBytesSync())}.$extension',
        );

    test('survive the source being removed', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final expected = managedPath(t, source, 'epub');

      final book = await t.importBook(source, managed: true);
      File(source).deleteSync();

      expect(book.storageKind, StorageKind.managed);
      expect(book.path, expected);
      expect(book.originalPath, source);
      expect(book.title, 'Sample Book');
      expect(await t.library.verifiedPath(book.id), expected);
      expect(
        Directory(
          t.managedDirectory,
        ).listSync().map((e) => canonicalBookPath(e.path)),
        [expected],
      );
    });

    test('use the source file name for fallback metadata', () async {
      final t = await TempLibrary.create(
        inspectors: const {BookFormat.pdf: FakePdfInspector()},
      );

      final book = await t.importBook(
        t.copyFixture('sample.pdf', 'Field Notes.pdf'),
        managed: true,
      );

      expect(book.title, 'Field Notes');
    });

    test('a managed import adopts a referenced book', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final referenced = await t.importBook(source);
      await t.library.updateProgress(referenced.id, 0.3);

      final item = await t.library.importFile(source, managed: true);

      expect(item.duplicate, isTrue);
      expect(item.book!.id, referenced.id);
      expect(item.book!.storageKind, StorageKind.managed);
      expect(item.book!.path, managedPath(t, source, 'epub'));
      expect(item.book!.progress, 0.3);
      expect(File(source).existsSync(), isTrue);
    });

    test('a corrupt existing copy is repaired', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final book = await t.importBook(source, managed: true);
      File(book.path).writeAsStringSync('corrupt');

      final again = await t.importBook(source, managed: true);

      expect(again.id, book.id);
      expect(
        File(again.path).readAsBytesSync(),
        File(source).readAsBytesSync(),
      );
      expect(Directory(t.managedDirectory).listSync(), hasLength(1));
    });

    test(
      'a copy location owned by a referenced book is not replaced',
      () async {
        final t = await TempLibrary.create();
        final source = t.copyFixture('sample.epub', 'source.epub');
        final destination = managedPath(t, source, 'epub');
        Directory(t.managedDirectory).createSync();
        File(source).copySync(destination);
        final referenced = await t.importBook(destination);
        File(destination).writeAsStringSync('referenced owner bytes');

        final item = await t.library.importFile(source, managed: true);

        expect(item.error, contains('belongs to another library book'));
        expect(File(destination).readAsStringSync(), 'referenced owner bytes');
        expect(
          (await t.library.get(referenced.id))!.storageKind,
          StorageKind.referenced,
        );
        expect(Directory(t.managedDirectory).listSync(), hasLength(1));
      },
    );

    test('concurrent identical imports return the same book', () async {
      final t = await TempLibrary.create();
      final sources = [
        for (final name in ['first', 'second', 'third', 'fourth'])
          t.copyFixture('sample.epub', '$name.epub'),
      ];

      final items = await Future.wait([
        for (final source in sources)
          t.library.importFile(source, managed: true),
      ]);

      expect(items.map((item) => item.book?.id).toSet(), hasLength(1));
      expect(items.where((item) => !item.duplicate), hasLength(1));
      expect(await t.count('books'), 1);
      expect(Directory(t.managedDirectory).listSync(), hasLength(1));
    });

    test('removing a managed book deletes its copy', () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'source.epub'),
        managed: true,
      );

      final outcome = await t.library.remove(book.id);

      expect(outcome.removed, isTrue);
      expect(outcome.managedFileDeletionPending, isFalse);
      expect(await t.library.get(book.id), isNull);
      expect(Directory(t.managedDirectory).listSync(), isEmpty);
      expect(await t.count('managed_file_deletion_debt'), 0);
      expect((await t.library.remove(book.id)).removed, isFalse);
    });

    test('removing a referenced book never deletes the original', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final book = await t.importBook(source);

      final outcome = await t.library.remove(book.id);

      expect(outcome.removed, isTrue);
      expect(File(source).existsSync(), isTrue);
      expect(await t.count('managed_file_deletion_debt'), 0);
    });

    test('a failed deletion is reported and retried durably', () async {
      final t = await TempLibrary.create();
      final book = await t.importBook(
        t.copyFixture('sample.epub', 'source.epub'),
        managed: true,
      );
      _blockDeletion(book.path);

      final outcome = await t.library.remove(book.id);

      expect(outcome.removed, isTrue);
      expect(outcome.managedFileDeletionPending, isTrue);
      expect(await t.library.get(book.id), isNull);
      expect(await t.count('managed_file_deletion_debt'), 1);
      expect(await t.library.retryManagedFileDeletions(), (
        cleared: 0,
        pending: 1,
      ));

      // A new process picks up the debt.
      await t.store.close();
      final reopened = await Store.open(t.store.path);
      addTearDown(reopened.close);
      final library = Library(reopened, managedDirectory: t.managedDirectory);
      Directory(book.path).deleteSync(recursive: true);
      File(t.path('source.epub')).copySync(book.path);

      expect(await library.retryManagedFileDeletions(), (
        cleared: 1,
        pending: 0,
      ));
      expect(Directory(t.managedDirectory).listSync(), isEmpty);
      expect(await countRows(reopened, 'managed_file_deletion_debt'), 0);
    });

    test('a deletion never removes a path a book uses again', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final managed = await t.importBook(source, managed: true);
      _blockDeletion(managed.path);
      await t.library.remove(managed.id);
      Directory(managed.path).deleteSync(recursive: true);
      File(source).copySync(managed.path);
      final shared = await t.execute(
        '''INSERT INTO books (title, format, file_path, storage_kind,
             original_path, content_hash, file_size)
           VALUES ('Shared', 'epub', ?, 'referenced', ?, ?, 1)''',
        [managed.path, managed.path, 'a' * 64],
      );

      expect(await t.library.retryManagedFileDeletions(), (
        cleared: 0,
        pending: 1,
      ));
      expect(File(managed.path).existsSync(), isTrue);

      await t.library.remove(shared);
      expect(await t.library.retryManagedFileDeletions(), (
        cleared: 1,
        pending: 0,
      ));
      expect(File(managed.path).existsSync(), isFalse);
    });

    test('reimporting a removed copy reclaims it', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final first = await t.importBook(source, managed: true);
      _blockDeletion(first.path);
      await t.library.remove(first.id);
      Directory(first.path).deleteSync(recursive: true);

      final again = await t.importBook(source, managed: true);

      expect(again.path, first.path);
      expect(await t.count('managed_file_deletion_debt'), 0);
      expect(await t.library.retryManagedFileDeletions(), (
        cleared: 0,
        pending: 0,
      ));
      expect(await t.library.verifiedPath(again.id), first.path);
    });

    test('deletion removes a symlink without following it', () async {
      final t = await TempLibrary.create();
      final source = t.copyFixture('sample.epub', 'source.epub');
      final book = await t.importBook(source, managed: true);
      final target = t.copyFixture('sample.pdf', 'target.pdf');
      File(book.path).deleteSync();
      Link(book.path).createSync(target);

      final outcome = await t.library.remove(book.id);

      expect(outcome.managedFileDeletionPending, isFalse);
      expect(Directory(t.managedDirectory).listSync(), isEmpty);
      expect(File(target).existsSync(), isTrue);
    });

    test(
      'deletion debt outside the managed directory is never acted on',
      () async {
        final t = await TempLibrary.create();
        final outside = t.copyFixture('sample.epub', 'outside.epub');
        Directory(t.managedDirectory).createSync();
        await t.execute(
          '''INSERT INTO managed_file_deletion_debt (file_path, managed_dir)
             VALUES (?, ?)''',
          [outside, canonicalBookPath(t.managedDirectory)],
        );

        expect(await t.library.retryManagedFileDeletions(), (
          cleared: 0,
          pending: 1,
        ));
        expect(File(outside).existsSync(), isTrue);
      },
    );
  });

  group('schema', () {
    test('rejects malformed book rows', () async {
      final t = await TempLibrary.create();
      Future<void> insert(Map<String, Object?> overrides) {
        final values = {
          'title': 'Book',
          'format': 'pdf',
          'file_path': '/books/book.pdf',
          'storage_kind': 'referenced',
          'original_path': '/books/book.pdf',
          'content_hash': 'a' * 64,
          'file_size': 1,
          ...overrides,
        };
        return t.execute(
          'INSERT INTO books (${values.keys.join(', ')}) '
          'VALUES (${List.filled(values.length, '?').join(', ')})',
          values.values.toList(),
        );
      }

      for (final malformed in <Map<String, Object?>>[
        {'title': ''},
        {'format': 'cbz'},
        {'storage_kind': 'cloud'},
        {'content_hash': 'A' * 64},
        {'content_hash': 'a' * 63},
        {'content_hash': 'g' * 64},
        {'file_size': -1},
        {'progress': 1.5},
        {'cover': List.filled(maxCoverBytes + 1, 0)},
      ]) {
        await expectLater(
          insert(malformed),
          throwsCoreError(CoreErrorKind.storage),
          reason: '$malformed',
        );
      }
      await insert({});
      await expectLater(
        insert({'file_path': '/books/other.pdf'}),
        throwsCoreError(CoreErrorKind.storage),
        reason: 'duplicate content',
      );
    });
  });
}

/// Replace the file at [path] with a non-empty directory, which deletion
/// refuses to remove.
void _blockDeletion(String path) {
  File(path).deleteSync();
  Directory(path).createSync();
  File(p.join(path, 'blocker')).writeAsStringSync('block deletion');
}

/// Cancels [token] while inspecting, as if the person cancelled mid-import.
final class _CancellingInspector implements BookInspector {
  const _CancellingInspector(this.token);

  final CancellationToken token;

  @override
  Future<BookMetadata> inspect(
    String path, {
    CancellationToken? cancellation,
  }) async {
    token.cancel();
    return const BookMetadata(title: 'Cancelled');
  }
}
