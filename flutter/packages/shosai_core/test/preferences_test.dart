import 'package:shosai_core/shosai_core.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

Matcher _limitExceeded() => throwsA(
  isA<CoreException>().having(
    (e) => e.kind,
    'kind',
    CoreErrorKind.limitExceeded,
  ),
);

void main() {
  test('preferences persist across opens', () async {
    final directory = tempDataDirectory();
    final path = '${directory.path}/library.sqlite3';
    final first = await Store.open(path);
    await Preferences(first).set('library.cards_per_row', '6');
    await Preferences(first).set('language', 'ja');
    await first.close();

    final second = await Store.open(path);
    addTearDown(second.close);
    final preferences = Preferences(second);

    expect(await preferences.get('library.cards_per_row'), '6');
    expect(await preferences.get('language'), 'ja');
    expect(await preferences.get('missing'), isNull);
  });

  test('all preferences are loaded together', () async {
    final preferences = Preferences(await tempStore());
    await preferences.set('first', 'one');
    await preferences.set('second', '2');

    expect(await preferences.getAll(), {'first': 'one', 'second': '2'});
  });

  test('a write replaces the previous value', () async {
    final preferences = Preferences(await tempStore());
    await preferences.set('theme', 'paper');
    await preferences.set('theme', 'night');

    expect(await preferences.getAll(), {'theme': 'night'});
  });

  test('several preferences are saved atomically', () async {
    final preferences = Preferences(await tempStore());
    await preferences.setAll({'window.width': '900', 'window.height': '700'});

    expect(await preferences.get('window.width'), '900');
    expect(await preferences.get('window.height'), '700');

    await expectLater(
      preferences.setAll({
        'window.width': '1',
        'x' * (maxPreferenceKeyBytes + 1): 'rejected',
      }),
      _limitExceeded(),
    );
    expect(await preferences.get('window.width'), '900');
  });

  test(
    'keys and values are bounded in UTF-8 bytes at the write boundary',
    () async {
      final preferences = Preferences(await tempStore());
      // 'é' is two bytes, so this key is exactly at the limit.
      final key = 'é' * (maxPreferenceKeyBytes ~/ 2);
      final value = 'x' * maxPreferenceValueBytes;

      await preferences.set(key, value);
      expect(await preferences.get(key), value);

      await expectLater(preferences.set('${key}x', 'v'), _limitExceeded());
      await expectLater(preferences.set('k', '${value}x'), _limitExceeded());
      await expectLater(preferences.get('${key}x'), _limitExceeded());
    },
  );

  test('stored rows over a limit are reported, not truncated', () async {
    final store = await tempStore();
    await store.transaction(
      (db) => db.execute(
        "INSERT INTO preferences (key, value) VALUES ('oversized', ?)",
        ['x' * (maxPreferenceValueBytes + 1)],
      ),
    );
    final preferences = Preferences(store);

    await expectLater(preferences.get('oversized'), _limitExceeded());
    await expectLater(preferences.getAll(), _limitExceeded());
  });

  test('loading enforces the row and aggregate limits', () async {
    final store = await tempStore();
    final preferences = Preferences(store);
    await store.transaction((db) {
      for (var index = 0; index <= maxPreferenceRows; index++) {
        db.execute("INSERT INTO preferences (key, value) VALUES (?, 'x')", [
          'key-$index',
        ]);
      }
    });
    await expectLater(preferences.getAll(), _limitExceeded());

    await store.transaction((db) {
      db.execute('DELETE FROM preferences');
      for (var index = 0; index < 17; index++) {
        db.execute('INSERT INTO preferences (key, value) VALUES (?, ?)', [
          'large-$index',
          'x' * maxPreferenceValueBytes,
        ]);
      }
    });
    await expectLater(preferences.getAll(), _limitExceeded());
  });

  test('writes keep the aggregate within what the loader accepts', () async {
    final preferences = Preferences(await tempStore());
    final value = 'x' * maxPreferenceValueBytes;
    Object? rejection;
    for (var index = 0; index <= 16 && rejection == null; index++) {
      try {
        await preferences.set('large-$index', value);
      } on CoreException catch (error) {
        rejection = error;
      }
    }

    expect(rejection, isA<CoreException>());
    expect((await preferences.getAll()).length, 15);
  });
}
