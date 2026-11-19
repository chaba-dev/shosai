import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shosai_core/shosai_core.dart';

/// Run on a disposable iOS Simulator. Never uses the installed library.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS SQLite keeps migrations, POSIX locks and WAL isolation', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('sqlite-privacy-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/library.sqlite3';
    final old = await Store.open(
      path,
      migrations: schemaMigrations.take(1).toList(),
    );
    await Preferences(old).set('preserved', 'before migration');
    await old.close();

    final writer = await Store.open(path);
    addTearDown(writer.close);
    final reader = await Store.open(path);
    addTearDown(reader.close);
    expect(writer.schemaVersion, schemaMigrations.last.version);
    expect(await Preferences(reader).get('preserved'), 'before migration');
    final configuration = await writer.read(
      (db) => [
        db.select('SELECT sqlite_version()').single.columnAt(0),
        db.select('PRAGMA journal_mode').single.columnAt(0),
        db
            .select('PRAGMA compile_options')
            .map((row) => row.columnAt(0))
            .toList(),
      ],
    );
    expect(configuration[0], '3.53.4');
    expect(configuration[1], 'wal');
    if (Platform.isIOS) {
      expect(configuration[2], contains('TEMP_STORE=3'));
      expect(configuration[2], contains('ENABLE_LOCKING_STYLE=0'));
    }

    // Leave a write uncommitted on one worker, then use the other worker.
    await writer.read(
      (db) => db.execute('''
BEGIN IMMEDIATE;
UPDATE preferences SET value='not committed' WHERE key='preserved';
'''),
    );
    try {
      expect(await Preferences(reader).get('preserved'), 'before migration');
      await expectLater(
        reader.read((db) => db.execute('BEGIN IMMEDIATE')),
        throwsA(
          isA<CoreException>().having(
            (error) => error.message,
            'message',
            contains('locked'),
          ),
        ),
      );
    } finally {
      await writer.read((db) => db.execute('ROLLBACK'));
    }
    expect(await Preferences(reader).get('preserved'), 'before migration');

    await reader.read((db) => db.execute('BEGIN; SELECT * FROM preferences;'));
    try {
      await Preferences(writer).set('preserved', 'committed');
      expect(await Preferences(reader).get('preserved'), 'before migration');
      expect(
        await writer.read(
          (db) =>
              db.select('PRAGMA wal_checkpoint(TRUNCATE)').single.columnAt(0),
        ),
        1,
      );
    } finally {
      await reader.read((db) => db.execute('COMMIT'));
    }
    expect(await Preferences(reader).get('preserved'), 'committed');
    expect(
      await writer.read(
        (db) => db.select('PRAGMA wal_checkpoint(TRUNCATE)').single.columnAt(0),
      ),
      0,
    );
    await reader.close();
    await writer.read((db) => db.execute('VACUUM'));
    expect(
      await writer.read(
        (db) => db.select('PRAGMA integrity_check').single.columnAt(0),
      ),
      'ok',
    );
    await writer.close();
    final reopened = await Store.open(path);
    addTearDown(reopened.close);
    expect(await Preferences(reopened).get('preserved'), 'committed');
  });

  testWidgets('iOS SQLite refuses paths outside its private container', (
    tester,
  ) async {
    if (!Platform.isIOS) return;
    // /tmp is writable to an unsandboxed Simulator process. Its spelling is
    // not under the simulated app's NSHomeDirectory, even though both are
    // physically on the cloud Mac's local APFS filesystem.
    final path =
        '/tmp/shosai-forbidden-${DateTime.now().microsecondsSinceEpoch}.sqlite3';
    final file = File(path);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    await expectLater(Store.open(path), throwsA(isA<CoreException>()));
    expect(file.existsSync(), isFalse);

    final directory = Directory.systemTemp.createTempSync('sqlite-admission-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final link = Link('${directory.path}/external');
    link.createSync('/tmp');
    await expectLater(
      Store.open('${link.path}/${file.uri.pathSegments.last}'),
      throwsA(isA<CoreException>()),
    );
    expect(file.existsSync(), isFalse);
    final store = await Store.open('${directory.path}/private.sqlite3');
    addTearDown(store.close);
    await expectLater(
      store.read((db) => db.execute('ATTACH DATABASE ? AS external', [path])),
      throwsA(isA<CoreException>()),
    );
    expect(file.existsSync(), isFalse);

    final dangling = Link('${directory.path}/dangling.sqlite3');
    dangling.createSync(path);
    await expectLater(Store.open(dangling.path), throwsA(isA<CoreException>()));
    expect(file.existsSync(), isFalse);

    // A link that remains on private APFS is valid, including when its
    // database leaf does not exist yet. Do not reject all symlinks.
    final inside = Link('${directory.path}/inside');
    inside.createSync(directory.path);
    final aliased = await Store.open('${inside.path}/aliased.sqlite3');
    addTearDown(aliased.close);
    await Preferences(aliased).set('alias', 'private');
    final direct = await Store.open('${directory.path}/aliased.sqlite3');
    addTearDown(direct.close);
    expect(await Preferences(direct).get('alias'), 'private');
  });
}
