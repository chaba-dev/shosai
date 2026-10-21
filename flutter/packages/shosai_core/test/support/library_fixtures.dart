import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'temp_store.dart';

/// A library over a fresh store, with its managed copies in `books/` under
/// [directory].
final class TempLibrary {
  TempLibrary._(this.directory, this.store, this.library);

  final Directory directory;
  final Store store;
  final Library library;

  String get managedDirectory => library.managedDirectory;

  /// Entries of the managed directory, without the library's lock file.
  List<FileSystemEntity> managedEntries() => [
    for (final entry in Directory(managedDirectory).listSync())
      if (p.basename(entry.path) != '.shosai-lock') entry,
  ];

  static Future<TempLibrary> create({
    Map<BookFormat, BookInspector>? inspectors,
  }) async {
    final directory = tempDataDirectory();
    final store = await tempStore(directory: directory);
    final library = Library(
      store,
      managedDirectory: p.join(directory.path, 'books'),
      inspectors:
          inspectors ??
          const {
            BookFormat.epub: EpubInspector(),
            BookFormat.pdf: FakePdfInspector(title: 'Sample PDF'),
          },
    );
    return TempLibrary._(directory, store, library);
  }

  /// The absolute path of [name] under this library's directory.
  String path(String name) => p.join(directory.path, name);

  /// Copy fixture [fixture] to [name] under this library's directory.
  String copyFixture(String fixture, String name) {
    final target = File(path(name));
    target.parent.createSync(recursive: true);
    File(fixturePath(fixture)).copySync(target.path);
    return canonicalBookPath(target.path);
  }

  Future<Book> importBook(String path, {bool managed = false}) async {
    final item = await library.importFile(path, managed: managed);
    expect(item.error, isNull, reason: 'import of $path failed');
    return item.book!;
  }

  Future<int> count(String table) => countRows(store, table);

  /// Run one statement and return the last inserted row id.
  Future<int> execute(String sql, [List<Object?> arguments = const []]) =>
      executeSql(store, sql, [arguments]);

  /// Run one statement once per row of [arguments], in one transaction.
  Future<int> executeMany(String sql, List<List<Object?>> arguments) =>
      executeSql(store, sql, arguments);

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> arguments = const [],
  ]) => selectSql(store, sql, arguments);
}

/// Stands in for the host's PDF engine.
final class FakePdfInspector implements BookInspector {
  const FakePdfInspector({this.title});

  final String? title;

  @override
  Future<BookMetadata> inspect(
    String path, {
    CancellationToken? cancellation,
  }) async => BookMetadata(title: title);
}

String fixturePath(String name) => p.join('test', 'fixtures', name);

/// [bytes] of a ZIP archive with a [comment] appended, so the archive reads
/// the same but has different content.
Uint8List withZipComment(Uint8List bytes, String comment) {
  final changed = Uint8List.fromList([...bytes, ...comment.codeUnits]);
  final lengthOffset = bytes.length - 2;
  changed[lengthOffset] = comment.length & 0xff;
  changed[lengthOffset + 1] = comment.length >> 8;
  return changed;
}

Matcher throwsCoreError(CoreErrorKind kind, [Object? message]) => throwsA(
  isA<CoreException>()
      .having((e) => e.kind, 'kind', kind)
      .having((e) => e.message, 'message', message ?? anything),
);

// Store bodies are built in top-level functions so they capture only their
// parameters: a closure written inside a test can capture the test's
// libraries and tokens, which cannot be sent to the store's worker.

Future<int> countRows(Store store, String table) => store.read(
  (db) => db.select('SELECT COUNT(*) FROM $table').single.columnAt(0) as int,
);

Future<int> executeSql(
  Store store,
  String sql,
  List<List<Object?>> arguments,
) => store.transaction((db) {
  for (final row in arguments) {
    db.execute(sql, row);
  }
  return db.lastInsertRowId;
});

Future<List<Map<String, Object?>>> selectSql(
  Store store,
  String sql,
  List<Object?> arguments,
) => store.read(
  (db) => [for (final row in db.select(sql, arguments)) Map.of(row)],
);
