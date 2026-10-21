import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shosai_core/shosai_core.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';

import 'support/temp_store.dart';

const _testMigrations = [
  Migration(
    1,
    'notes',
    'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT;',
  ),
];

void main() {
  test(
    'opening creates parent directories and configures the connection',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/nested/data/library.sqlite3';

      final store = await Store.open(path);
      addTearDown(store.close);

      expect(File(path).existsSync(), isTrue);
      expect(store.schemaVersion, schemaMigrations.last.version);
      final pragmas = await store.read(
        (db) => [
          db.select('PRAGMA journal_mode').first.columnAt(0),
          db.select('PRAGMA foreign_keys').first.columnAt(0),
          db.select('PRAGMA application_id').first.columnAt(0),
          db.select('PRAGMA user_version').first.columnAt(0),
        ],
      );
      expect(pragmas, [
        'wal',
        1,
        shosaiApplicationId,
        schemaMigrations.last.version,
      ]);
    },
  );

  test('migrations are idempotent and data survives reopening', () async {
    final directory = tempDataDirectory();
    final path = '${directory.path}/library.sqlite3';
    final first = await Store.open(path);
    await first.transaction(
      (db) => db.execute(
        "INSERT INTO preferences (key, value) VALUES ('kept', 'yes')",
      ),
    );
    await first.close();

    final second = await Store.open(path);
    addTearDown(second.close);

    expect(second.schemaVersion, first.schemaVersion);
    expect(await Preferences(second).get('kept'), 'yes');
  });

  test('later migrations apply in order on an older database', () async {
    final directory = tempDataDirectory();
    final path = '${directory.path}/library.sqlite3';
    await (await Store.open(path, migrations: _testMigrations)).close();

    final store = await Store.open(
      path,
      migrations: [
        ..._testMigrations,
        const Migration(2, 'tags', 'ALTER TABLE notes ADD COLUMN tag TEXT;'),
      ],
    );
    addTearDown(store.close);

    expect(store.schemaVersion, 2);
    await store.transaction(
      (db) => db.execute("INSERT INTO notes (body, tag) VALUES ('a', 'b')"),
    );
  });

  test(
    'a failed migration rolls back and keeps the previous version',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      await (await Store.open(path, migrations: _testMigrations)).close();

      await expectLater(
        Store.open(
          path,
          migrations: [
            ..._testMigrations,
            const Migration(2, 'broken', '''
            CREATE TABLE half_done (id INTEGER PRIMARY KEY);
            THIS IS NOT SQL;
          '''),
          ],
        ),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.storage,
          ),
        ),
      );

      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(db.select('PRAGMA user_version').first.columnAt(0), 1);
      expect(
        db.select("SELECT name FROM sqlite_schema WHERE name = 'half_done'"),
        isEmpty,
      );
    },
  );

  test(
    'a database from another application is refused and left untouched',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/shosai.db';
      final foreign = sqlite3.open(path);
      foreign.execute('CREATE TABLE _sqlx_migrations (version INTEGER)');
      foreign.close();
      final before = File(path).readAsBytesSync();

      await expectLater(
        Store.open(path),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.malformed,
          ),
        ),
      );

      expect(File(path).readAsBytesSync(), before);
    },
  );

  test(
    'a database from a newer schema is refused and left untouched',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      await (await Store.open(path)).close();
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute('PRAGMA user_version = 999');
      db.close();
      final before = File(path).readAsBytesSync();

      await expectLater(
        Store.open(path),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.malformed,
          ),
        ),
      );

      expect(File(path).readAsBytesSync(), before);
      final after = sqlite3.open(path);
      addTearDown(after.close);
      expect(after.select('PRAGMA journal_mode').first.columnAt(0), 'delete');
    },
  );

  test('a failed first migration leaves a fresh file unclaimed', () async {
    final directory = tempDataDirectory();
    final path = '${directory.path}/library.sqlite3';

    await expectLater(
      Store.open(
        path,
        migrations: const [
          Migration(1, 'broken', '''
            CREATE TABLE half_done (id INTEGER PRIMARY KEY);
            THIS IS NOT SQL;
          '''),
        ],
      ),
      throwsA(isA<CoreException>()),
    );

    final db = sqlite3.open(path);
    expect(db.select('PRAGMA application_id').first.columnAt(0), 0);
    expect(db.select('PRAGMA user_version').first.columnAt(0), 0);
    expect(db.select('SELECT name FROM sqlite_schema'), isEmpty);
    db.close();
    final store = await Store.open(path, migrations: _testMigrations);
    addTearDown(store.close);
    expect(store.schemaVersion, 1);
  });

  test(
    'two instances opening an older database apply a migration once',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      await (await Store.open(path, migrations: _testMigrations)).close();
      final migrations = [
        ..._testMigrations,
        const Migration(
          2,
          'seed',
          "INSERT INTO notes (body) VALUES ('migrated');",
        ),
      ];
      // Hold the write lock so both instances are admitted at version 1 and
      // then queue for the migration's lock.
      final holder = sqlite3.open(path);
      holder.execute('BEGIN IMMEDIATE');
      final opening = [
        Store.open(path, migrations: migrations),
        Store.open(path, migrations: migrations),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 500));
      holder.execute('COMMIT');
      holder.close();

      final stores = await Future.wait(opening);
      for (final store in stores) {
        addTearDown(store.close);
        expect(store.schemaVersion, 2);
      }
      expect(
        await stores.first.read(
          (db) => db.select('SELECT COUNT(*) FROM notes').first.columnAt(0),
        ),
        1,
      );
    },
  );

  test('instances racing to create a fresh database all open it', () async {
    final directory = tempDataDirectory();
    for (var round = 0; round < 40; round++) {
      final path = '${directory.path}/race-$round.sqlite3';
      final stores = await Future.wait([
        for (var i = 0; i < 3; i++) Store.open(path),
      ]);
      for (final store in stores) {
        expect(store.schemaVersion, schemaMigrations.last.version);
        await store.close();
      }
    }
  });

  test(
    'a database locked by another writer is inaccessible, not malformed',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      await (await Store.open(path)).close();
      final holder = sqlite3.open(path);
      addTearDown(holder.close);
      holder.execute('PRAGMA journal_mode = DELETE');
      holder.execute('BEGIN EXCLUSIVE');
      addTearDown(() {
        if (!holder.autocommit) holder.execute('ROLLBACK');
      });

      await expectLater(
        Store.open(path),
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.inaccessible,
          ),
        ),
      );
    },
  );

  test('a write whose commit fails reports it and keeps nothing', () async {
    final directory = tempDataDirectory();
    final store = await Store.open(
      '${directory.path}/library.sqlite3',
      migrations: [
        ..._testMigrations,
        const Migration(2, 'links', '''
          CREATE TABLE links (
            note_id INTEGER NOT NULL
              REFERENCES notes (id) DEFERRABLE INITIALLY DEFERRED
          ) STRICT;
        '''),
      ],
    );
    addTearDown(store.close);

    // The deferred foreign key fails at COMMIT, after the result was staged.
    await expectLater(
      store.transaction((db) {
        db.execute('INSERT INTO links (note_id) VALUES (42)');
        return 'staged';
      }),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.storage,
        ),
      ),
    );
    expect(
      await store.read(
        (db) => db.select('SELECT COUNT(*) FROM links').first.columnAt(0),
      ),
      0,
    );
    expect(await store.transaction((db) => 'next'), 'next');
  });

  test('a file that is not SQLite is refused', () async {
    final directory = tempDataDirectory();
    final path = '${directory.path}/library.sqlite3';
    File(
      path,
    ).writeAsStringSync('not a database, just text that is long enough' * 20);

    await expectLater(
      Store.open(path),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.malformed,
        ),
      ),
    );
  });

  test(
    'a throwing transaction rolls back and rethrows core errors unchanged',
    () async {
      final store = await tempStore();

      await expectLater(
        store.transaction((db) {
          db.execute(
            "INSERT INTO preferences (key, value) VALUES ('lost', 'x')",
          );
          throw const CoreException.limitExceeded('too much');
        }),
        throwsA(const CoreException.limitExceeded('too much')),
      );

      expect(await Preferences(store).get('lost'), isNull);
    },
  );

  test('SQLite failures surface as storage errors', () async {
    final store = await tempStore();

    await expectLater(
      store.read((db) => db.select('SELECT * FROM missing_table')),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.storage,
        ),
      ),
    );
    // The connection stays usable after a failed statement.
    expect(
      await store.read((db) => db.select('SELECT 1').first.columnAt(0)),
      1,
    );
  });

  test('requests run one at a time in the order they were sent', () async {
    final store = await tempStore();
    final writes = [
      for (var index = 0; index < 50; index++)
        store.transaction(
          (db) => db.execute(
            'INSERT INTO preferences (key, value) VALUES (?, ?)',
            ['key-$index', '$index'],
          ),
        ),
    ];
    final read = store.read(
      (db) => db.select('SELECT COUNT(*) FROM preferences').first.columnAt(0),
    );

    await Future.wait(writes);
    expect(await read, 50);
  });

  test('a body may capture the store and plain data', () async {
    final store = await tempStore();
    final preferences = Preferences(store);
    const key = 'captured';

    await store.transaction((db) {
      // Referencing the facade checks that it can be sent with the body.
      final sent = preferences.runtimeType.toString();
      db.execute('INSERT INTO preferences (key, value) VALUES (?, ?)', [
        key,
        '$sent ${store.path}',
      ]);
    });

    expect(await preferences.get(key), 'Preferences ${store.path}');
  });

  test('a result that cannot be sent is reported instead of hanging', () async {
    final store = await tempStore();

    await expectLater(
      store.read((db) => ReceivePortHolder()),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.storage,
        ),
      ),
    );
  });

  test('a write whose result cannot be sent is rolled back', () async {
    final store = await tempStore();

    await expectLater(
      store.transaction((db) {
        db.execute("INSERT INTO preferences (key, value) VALUES ('lost', 'x')");
        return ReceivePortHolder();
      }),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.storage,
        ),
      ),
    );

    expect(await Preferences(store).get('lost'), isNull);
  });

  test(
    'an async body is refused, persists nothing and stops the store',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      final store = await Store.open(path);

      final refused = store.transaction((db) async {
        db.execute(
          "INSERT INTO preferences (key, value) VALUES ('before', 'x')",
        );
        await Future<void>.delayed(Duration.zero);
        db.execute(
          "INSERT INTO preferences (key, value) VALUES ('after', 'x')",
        );
      });
      final queued = store.read((db) => 1);

      await expectLater(
        refused,
        throwsA(
          isA<CoreException>().having(
            (e) => e.kind,
            'kind',
            CoreErrorKind.storage,
          ),
        ),
      );
      await expectLater(queued, throwsA(isA<CoreException>()));
      await store.close();

      final reopened = await Store.open(path);
      addTearDown(reopened.close);
      expect(await Preferences(reopened).getAll(), isEmpty);
    },
  );

  test('concurrent and repeated closes all settle', () async {
    final directory = tempDataDirectory();
    final store = await Store.open('${directory.path}/library.sqlite3');

    await Future.wait([store.close(), store.close()]);
    await store.close();
  });

  test('closing finishes queued work and then refuses new requests', () async {
    final directory = tempDataDirectory();
    final store = await Store.open('${directory.path}/library.sqlite3');
    final queued = store.transaction(
      (db) => db.execute(
        "INSERT INTO preferences (key, value) VALUES ('queued', 'x')",
      ),
    );

    await store.close();
    await queued;

    await expectLater(
      store.read((db) => 1),
      throwsA(
        isA<CoreException>().having(
          (e) => e.kind,
          'kind',
          CoreErrorKind.storage,
        ),
      ),
    );
    final reopened = await Store.open(store.path);
    addTearDown(reopened.close);
    expect(await Preferences(reopened).get('queued'), 'x');
  });

  test(
    'a killed writer leaves committed data, discards its open transaction and no lock',
    () async {
      final directory = tempDataDirectory();
      final path = '${directory.path}/library.sqlite3';
      await (await Store.open(path)).close();

      final writer = await Process.start(_python!, [
        'test/support/crash_writer.py',
        path,
      ]);
      final stderr = StringBuffer();
      writer.stderr.transform(utf8.decoder).listen(stderr.write);
      await writer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line == 'in-transaction')
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw StateError('writer did not start: $stderr'),
          );
      expect(File('$path-wal').lengthSync(), greaterThan(0));

      writer.kill(ProcessSignal.sigkill);
      await writer.exitCode;

      final store = await Store.open(path);
      addTearDown(store.close);
      final preferences = Preferences(store);
      expect(await preferences.getAll(), {'committed': 'yes'});
      await preferences.set('after-recovery', 'ok');
      expect(await preferences.get('after-recovery'), 'ok');
    },
    skip: _python == null || Platform.isWindows
        ? 'needs python3 and POSIX signals'
        : false,
  );
}

/// A Python 3 interpreter for the out-of-process writer, if one is installed.
final String? _python = () {
  for (final name in ['python3', 'python']) {
    try {
      final result = Process.runSync(name, ['-c', 'import sqlite3']);
      if (result.exitCode == 0) return name;
    } on ProcessException {
      // Try the next name.
    }
  }
  return null;
}();

/// A value that cannot cross an isolate boundary.
@pragma('vm:isolate-unsendable')
final class ReceivePortHolder {}
