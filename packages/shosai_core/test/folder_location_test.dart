import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

void main() {
  test('pages metadata and reads only the requested range', () async {
    final root = tempDataDirectory();
    for (var i = 0; i < 5; i++) {
      File('${root.path}/$i.epub').writeAsBytesSync([2, 7, 11, 17, 23]);
    }
    final location = await FolderLocation.open('local', root.path);
    final names = <String>[];
    String? cursor;
    do {
      final page = await location.list(limit: 2, cursor: cursor);
      expect(page.entries.length, lessThanOrEqualTo(2));
      expect(page.entries.map((e) => e.size), everyElement(5));
      names.addAll(page.entries.map((e) => e.name));
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(names, unorderedEquals(List.generate(5, (i) => '$i.epub')));
    expect((await location.stat('1.epub')).size, 5);
    expect(
      await location.read('1.epub', start: 1, end: 4).expand((b) => b).toList(),
      [7, 11, 17],
    );
    expect(
      await location
          .read('1.epub', start: 4, end: 100)
          .expand((b) => b)
          .toList(),
      [23],
    );
    expect(await location.read('1.epub', start: 9).toList(), isEmpty);
    expect(await location.read('1.epub', start: 2, end: 2).toList(), isEmpty);
    expect(await location.read('1.epub').expand((b) => b).toList(), [
      2,
      7,
      11,
      17,
      23,
    ]);
  });

  test(
    'writes atomically and failed or cancelled streams retain the old book',
    () async {
      final root = tempDataDirectory();
      final location = await FolderLocation.open('local', root.path);
      await location.write('book.epub', Stream.value([3, 5, 7]));
      Stream<List<int>> failing() async* {
        yield [11, 13];
        throw const LocationException(LocationFailure.offline);
      }

      await expectLater(
        location.write('book.epub', failing()),
        throwsA(isA<LocationException>()),
      );
      expect(File('${root.path}/book.epub').readAsBytesSync(), [3, 5, 7]);
      final token = CancellationToken();
      Stream<List<int>> cancelled() async* {
        yield [17];
        token.cancel();
        yield [19];
      }

      await expectLater(
        location.write('book.epub', cancelled(), cancellation: token),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.cancelled,
          ),
        ),
      );
      expect(File('${root.path}/book.epub').readAsBytesSync(), [3, 5, 7]);
      final replacement = await location.write(
        'book.epub',
        Stream.value([23, 29]),
      );
      expect(replacement.key, 'book.epub');
      expect(replacement.size, 2);
      expect(File('${root.path}/book.epub').readAsBytesSync(), [23, 29]);
      expect(root.listSync().map((f) => f.uri.pathSegments.last), [
        'book.epub',
      ]);
    },
  );

  test(
    'missing files, traversal and redirected grants cannot escape the folder',
    () async {
      final parent = tempDataDirectory();
      final root = Directory('${parent.path}/books')..createSync();
      File('${parent.path}/outside.epub').writeAsBytesSync([37]);
      final location = await FolderLocation.open('local', root.path);
      await expectLater(
        location.stat('missing.epub'),
        throwsA(
          isA<LocationException>().having(
            (e) => e.failure,
            'failure',
            LocationFailure.missing,
          ),
        ),
      );
      await expectLater(
        location.read('../outside.epub').drain<void>(),
        throwsA(isA<CoreException>()),
      );
      Link(
        '${root.path}/escape.epub',
      ).createSync('${parent.path}/outside.epub');
      await expectLater(
        location.read('escape.epub').drain<void>(),
        throwsA(
          isA<LocationException>().having(
            (e) => e.failure,
            'failure',
            LocationFailure.revoked,
          ),
        ),
      );
      expect((await location.list()).entries, isEmpty);
      root.renameSync('${parent.path}/original');
      Link(root.path).createSync(parent.path);
      await expectLater(
        location.list(),
        throwsA(
          isA<LocationException>().having(
            (e) => e.failure,
            'failure',
            LocationFailure.revoked,
          ),
        ),
      );
      expect(File('${parent.path}/outside.epub').readAsBytesSync(), [37]);
    },
    skip: Platform.isWindows ? 'Requires symlink permission on Windows' : false,
  );
}
