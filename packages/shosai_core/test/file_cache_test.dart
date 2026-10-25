import 'dart:async';
import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/library_fixtures.dart';

void main() {
  Future<Book> book(TempLibrary t, int size) async {
    final file = File(
      t.path('$size.pdf'),
    )..writeAsBytesSync([...'%PDF-'.codeUnits, ...List.filled(size - 5, size)]);
    return t.importBook(file.path);
  }

  Future<List<int>> read(BookFileCache cache, Book book, {bool keep = false}) =>
      cache.withFile(
        book,
        () => File(book.path).openRead(),
        (path) => File(path).readAsBytes(),
        keep: keep,
      );

  test(
    'byte-bounded eviction is LRU, not import order; a hit survives offline',
    () async {
      final t = await TempLibrary.create();
      final a = await book(t, 10), b = await book(t, 20), c = await book(t, 30);
      final cache = BookFileCache(t.store, t.path('cache'), capacity: 50);
      await read(cache, a);
      await read(cache, b);
      await read(cache, a); // b, not a, is now the oldest.
      await read(cache, c);
      File(a.path).deleteSync();
      File(b.path).deleteSync();
      expect(await read(cache, a), hasLength(10));
      await expectLater(read(cache, b), throwsA(isA<FileSystemException>()));
      expect((await t.library.page()).bookCount, 3);
    },
  );

  test(
    'kept bytes survive restart and pressure, releasing never removes notes',
    () async {
      final t = await TempLibrary.create();
      final a = await book(t, 30), b = await book(t, 20);
      var cache = BookFileCache(t.store, t.path('cache'), capacity: 20);
      await Annotations(
        t.store,
      ).createNote(a.id, const BookAnchor(), 'Keep my note');
      await read(cache, a, keep: true); // larger than the automatic budget
      await read(cache, b);
      File(a.path).deleteSync();
      cache = BookFileCache(t.store, t.path('cache'), capacity: 0);
      expect(await read(cache, a), hasLength(30));
      await cache.release(a);
      await expectLater(read(cache, a), throwsA(isA<FileSystemException>()));
      expect((await Annotations(t.store).summary(a.id)).latest, 'Keep my note');
      expect((await t.library.get(a.id))!.contentHash, a.contentHash);
    },
  );

  test(
    'oversized files are transient and cancelled or changed bytes never publish',
    () async {
      final t = await TempLibrary.create();
      final a = await book(t, 30);
      final cache = BookFileCache(t.store, t.path('cache'), capacity: 20);
      expect(await read(cache, a), hasLength(30));
      expect(
        Directory(cache.directory).listSync().whereType<File>(),
        hasLength(1),
      ); // lock only
      final cancellation = CancellationToken();
      Stream<List<int>> cancelled() async* {
        yield [1, 2];
        cancellation.cancel();
        yield [3];
      }

      await expectLater(
        cache.withFile(
          a,
          cancelled,
          (_) async => fail('consumed cancelled bytes'),
          keep: true,
          cancellation: cancellation,
        ),
        throwsCoreError(CoreErrorKind.cancelled),
      );
      await expectLater(
        cache.withFile(
          a,
          () => Stream.value(List.filled(30, 0)),
          (_) async => fail('consumed changed bytes'),
          keep: true,
        ),
        throwsA(isA<LocationException>()),
      );
      expect(
        Directory(cache.directory).listSync().whereType<File>(),
        hasLength(1),
      );
    },
  );

  test(
    'an active consumer keeps its file until completion; missing/corrupt files refetch',
    () async {
      final t = await TempLibrary.create();
      final a = await book(t, 10), b = await book(t, 20);
      final cache = BookFileCache(t.store, t.path('cache'), capacity: 20);
      final entered = Completer<String>(), done = Completer<void>();
      final first = cache.withFile(a, () => File(a.path).openRead(), (
        path,
      ) async {
        entered.complete(path);
        await done.future;
        expect(await File(path).length(), 10);
      });
      final path = await entered.future;
      final second = read(cache, b);
      expect(await File(path).exists(), isTrue);
      done.complete();
      await first;
      await second;
      await read(cache, a, keep: true);
      File(path).writeAsBytesSync(List.filled(10, 0));
      expect(await read(cache, a), File(a.path).readAsBytesSync());
      final noAutomaticCache = BookFileCache(
        t.store,
        cache.directory,
        capacity: 0,
      );
      final source = File(a.path).readAsBytesSync();
      File(a.path).deleteSync();
      expect(
        await read(noAutomaticCache, a),
        source,
        reason: 'repairing a kept copy must not silently unpin it',
      );
      File(a.path).writeAsBytesSync(source);
      File(path).deleteSync();
      expect(await read(cache, a), File(a.path).readAsBytesSync());
    },
  );
}
