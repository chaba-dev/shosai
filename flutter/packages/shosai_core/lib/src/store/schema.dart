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
  Migration(2, 'library', '''
CREATE TABLE books (
    id            INTEGER PRIMARY KEY,
    title         TEXT NOT NULL
                  CHECK (length(CAST(title AS BLOB)) BETWEEN 1 AND 4096),
    author        TEXT
                  CHECK (author IS NULL OR length(CAST(author AS BLOB)) BETWEEN 1 AND 4096),
    format        TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    file_path     TEXT NOT NULL UNIQUE
                  CHECK (length(CAST(file_path AS BLOB)) BETWEEN 1 AND 16384),
    storage_kind  TEXT NOT NULL CHECK (storage_kind IN ('referenced', 'managed')),
    original_path TEXT NOT NULL
                  CHECK (length(CAST(original_path AS BLOB)) BETWEEN 1 AND 16384),
    content_hash  TEXT NOT NULL UNIQUE
                  CHECK (length(content_hash) = 64 AND content_hash NOT GLOB '*[^0-9a-f]*'),
    file_size     INTEGER NOT NULL CHECK (file_size >= 0),
    cover         BLOB CHECK (cover IS NULL OR length(cover) BETWEEN 1 AND 524288),
    progress      REAL NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 1),
    date_added    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    last_read     TEXT
) STRICT;

CREATE INDEX books_library_order_idx
    ON books(last_read DESC, date_added DESC, id DESC);
CREATE INDEX books_format_library_order_idx
    ON books(format, last_read DESC, date_added DESC, id DESC);

-- A removed book's private copy whose deletion has not finished yet.
CREATE TABLE managed_file_deletion_debt (
    file_path   TEXT PRIMARY KEY NOT NULL
                CHECK (length(CAST(file_path AS BLOB)) BETWEEN 1 AND 16384),
    managed_dir TEXT NOT NULL
                CHECK (length(CAST(managed_dir AS BLOB)) BETWEEN 1 AND 16384),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0)
) STRICT;
'''),
  Migration(3, 'reading state', '''
-- Where the reader left each book. Keyed by content, so it survives removing
-- and re-importing the book.
CREATE TABLE reading_state (
    content_hash    TEXT PRIMARY KEY NOT NULL
                    CHECK (length(content_hash) = 64 AND content_hash NOT GLOB '*[^0-9a-f]*'),
    unit            INTEGER NOT NULL CHECK (unit >= 0),
    location_offset INTEGER CHECK (location_offset IS NULL OR location_offset >= 0),
    zoom            REAL NOT NULL CHECK (zoom > 0 AND zoom <= 1e300),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT, WITHOUT ROWID;
'''),
  Migration(4, 'bookmarks', '''
-- Point bookmarks, keyed by content like the reading state. AUTOINCREMENT
-- keeps a deleted bookmark's id from being reused, so a late request for it
-- cannot reach a newer bookmark.
CREATE TABLE bookmarks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    content_hash    TEXT NOT NULL
                    CHECK (length(content_hash) = 64 AND content_hash NOT GLOB '*[^0-9a-f]*'),
    unit            INTEGER NOT NULL CHECK (unit >= 0),
    location_offset INTEGER CHECK (location_offset IS NULL OR location_offset >= 0),
    title           TEXT CHECK (title IS NULL OR length(CAST(title AS BLOB)) <= 4096),
    note            TEXT CHECK (note IS NULL OR length(CAST(note AS BLOB)) <= 65536),
    color           TEXT NOT NULL DEFAULT 'yellow'
                    CHECK (length(CAST(color AS BLOB)) BETWEEN 1 AND 64),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT;

CREATE INDEX bookmarks_book_order_idx
    ON bookmarks(content_hash, unit, coalesce(location_offset, 0), created_at, id);
'''),
];
