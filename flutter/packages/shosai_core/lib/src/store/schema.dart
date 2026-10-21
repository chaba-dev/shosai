/// The Dart core's SQLite schema, as ordered migrations.
///
/// Written fresh for the Dart core (RFD 4, M3.0): databases written by the
/// retired Rust core are not migrated. Append a migration for every change;
/// never edit one that has merged.
library;

import 'store.dart';

/// Every migration, oldest first.
const schemaMigrations = <Migration>[
  Migration(1, 'preferences', '''
CREATE TABLE preferences (
    key        TEXT PRIMARY KEY NOT NULL,
    value      TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;
'''),
];
