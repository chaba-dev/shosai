/// Bounded key/value preferences stored with the library.
library;

import 'dart:convert';

import 'errors.dart';
import 'store/store.dart';

const maxPreferenceKeyBytes = 1024;
const maxPreferenceValueBytes = 64 * 1024;
const maxPreferenceRows = 1024;
const maxPreferenceTotalBytes = 1024 * 1024;

/// Application preferences, as UTF-8 strings.
///
/// Every key and value has a byte limit, and the table as a whole has a row
/// and a byte limit, so loading all preferences is bounded. A write that would
/// exceed the aggregate limit is rolled back.
final class Preferences {
  const Preferences(this._store);

  final Store _store;

  /// The value stored for [key], or null.
  Future<String?> get(String key) async {
    _validateKey(key);
    return _store.read((db) => _get(db, key));
  }

  /// Every stored preference, loaded in one bounded snapshot.
  Future<Map<String, String>> getAll() => _store.transaction(_getAll);

  /// Store [value] under [key].
  Future<void> set(String key, String value) => setAll({key: value});

  /// Store every entry of [values] atomically.
  Future<void> setAll(Map<String, String> values) async {
    values.forEach(_validate);
    final entries = [
      for (final entry in values.entries) (entry.key, entry.value),
    ];
    return _store.transaction((db) => _setAll(db, entries));
  }
}

String? _get(Database db, String key) {
  final rows = db.select('SELECT value FROM preferences WHERE key = ?', [key]);
  if (rows.isEmpty) return null;
  final value = rows.first.columnAt(0) as String;
  if (_bytes(value) > maxPreferenceValueBytes) {
    throw const CoreException.limitExceeded(
      'A stored preference exceeds its byte limit.',
    );
  }
  return value;
}

Map<String, String> _getAll(Database db) {
  _checkTotals(db);
  final preferences = <String, String>{};
  for (final row in db.select('SELECT key, value FROM preferences')) {
    final key = row.columnAt(0) as String;
    final value = row.columnAt(1) as String;
    _checkStored(key, value);
    preferences[key] = value;
  }
  return preferences;
}

void _setAll(Database db, List<(String, String)> entries) {
  final statement = db.prepare('''
    INSERT INTO preferences (key, value, updated_at)
    VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    ON CONFLICT(key) DO UPDATE SET
      value = excluded.value,
      updated_at = excluded.updated_at
  ''');
  try {
    for (final (key, value) in entries) {
      statement.execute([key, value]);
    }
  } finally {
    statement.close();
  }
  _checkTotals(db);
}

void _checkTotals(Database db) {
  final row = db.select('''
    SELECT COUNT(*),
           COALESCE(SUM(length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))), 0)
    FROM preferences
  ''').first;
  if ((row.columnAt(0) as int) > maxPreferenceRows) {
    throw const CoreException.limitExceeded(
      'Preferences exceed $maxPreferenceRows entries.',
    );
  }
  if ((row.columnAt(1) as int) > maxPreferenceTotalBytes) {
    throw const CoreException.limitExceeded(
      'Preferences exceed $maxPreferenceTotalBytes bytes.',
    );
  }
}

void _checkStored(String key, String value) {
  if (_bytes(key) > maxPreferenceKeyBytes ||
      _bytes(value) > maxPreferenceValueBytes) {
    throw const CoreException.limitExceeded(
      'A stored preference exceeds its byte limit.',
    );
  }
}

void _validate(String key, String value) {
  _validateKey(key);
  if (_bytes(value) > maxPreferenceValueBytes) {
    throw const CoreException.limitExceeded(
      'A preference value exceeds $maxPreferenceValueBytes bytes.',
    );
  }
}

void _validateKey(String key) {
  if (_bytes(key) > maxPreferenceKeyBytes) {
    throw const CoreException.limitExceeded(
      'A preference key exceeds $maxPreferenceKeyBytes bytes.',
    );
  }
}

int _bytes(String value) => utf8.encode(value).length;
