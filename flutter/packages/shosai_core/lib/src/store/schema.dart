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
  Migration(5, 'annotations', '''
-- A work that annotations belong to. Its versions are the contents (by hash)
-- it has been read in; annotations made on one version resolve against the
-- others by quote (RFD 6).
CREATE TABLE annotation_documents (
    id     TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    format TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    UNIQUE (id, format)
) STRICT;

CREATE TABLE annotation_document_versions (
    id                         TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    document_id                TEXT NOT NULL,
    format                     TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    content_hash               TEXT NOT NULL UNIQUE
                               CHECK (length(content_hash) = 64 AND content_hash NOT GLOB '*[^0-9a-f]*'),
    -- The book's title when this version was first annotated, to describe it
    -- after the book is gone.
    title                      TEXT NOT NULL
                               CHECK (length(CAST(title AS BLOB)) BETWEEN 1 AND 4096),
    associated_from_version_id TEXT REFERENCES annotation_document_versions(id),
    associated_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE (id, format),
    FOREIGN KEY (document_id, format) REFERENCES annotation_documents(id, format)
) STRICT;

CREATE INDEX annotation_document_versions_document_idx
    ON annotation_document_versions(document_id);

CREATE TABLE annotations (
    id                    TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    -- The version whose text and geometry the anchor was captured from; the
    -- annotation has that version's format.
    version_id            TEXT NOT NULL,
    format                TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    anchor_version        INTEGER NOT NULL CHECK (anchor_version = 1),
    original_quote        TEXT CHECK (original_quote IS NULL OR length(original_quote) <= 65536),
    normalization_profile TEXT CHECK (normalization_profile IS NULL
                                      OR normalization_profile = 'shosai-quote-v1'),
    normalized_exact      TEXT CHECK (normalized_exact IS NULL
                                      OR length(normalized_exact) BETWEEN 1 AND 65536),
    normalized_prefix     TEXT CHECK (normalized_prefix IS NULL OR length(normalized_prefix) <= 32),
    normalized_suffix     TEXT CHECK (normalized_suffix IS NULL OR length(normalized_suffix) <= 32),
    color                 TEXT NOT NULL
                          CHECK (color IN ('yellow', 'green', 'blue', 'pink', 'purple')),
    body                  TEXT CHECK (body IS NULL OR length(body) <= 65536),
    source_system         TEXT CHECK (source_system IS NULL
                                      OR length(CAST(source_system AS BLOB)) BETWEEN 1 AND 256),
    source_id             TEXT CHECK (source_id IS NULL
                                      OR length(CAST(source_id AS BLOB)) BETWEEN 1 AND 4096),
    epub_spine_index      INTEGER CHECK (epub_spine_index IS NULL OR epub_spine_index >= 0),
    epub_resource_path    TEXT CHECK (epub_resource_path IS NULL
                                      OR length(CAST(epub_resource_path AS BLOB)) BETWEEN 1 AND 4096),
    epub_scalar_start     INTEGER CHECK (epub_scalar_start IS NULL OR epub_scalar_start >= 0),
    epub_scalar_end       INTEGER,
    pdf_page              INTEGER CHECK (pdf_page IS NULL OR pdf_page >= 0),
    pdf_char_start        INTEGER CHECK (pdf_char_start IS NULL OR pdf_char_start >= 0),
    pdf_char_end          INTEGER,
    -- Little-endian float32 (left, top, right, bottom) quadruples in page space.
    pdf_rectangles        BLOB CHECK (pdf_rectangles IS NULL
                                      OR (length(pdf_rectangles) BETWEEN 16 AND 262144
                                          AND length(pdf_rectangles) % 16 = 0)),
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    modified_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at            TEXT,
    -- A CHECK that evaluates to NULL passes, so nullable columns are tested
    -- with IS NOT NULL before they are compared.
    CHECK (
        (format = 'epub'
         AND epub_spine_index IS NOT NULL AND epub_resource_path IS NOT NULL
         AND epub_scalar_start IS NOT NULL AND epub_scalar_end IS NOT NULL
         AND epub_scalar_end > epub_scalar_start
         AND normalized_exact IS NOT NULL
         AND pdf_page IS NULL AND pdf_char_start IS NULL AND pdf_char_end IS NULL
         AND pdf_rectangles IS NULL)
        OR
        (format = 'pdf'
         AND pdf_page IS NOT NULL AND pdf_rectangles IS NOT NULL
         AND epub_spine_index IS NULL AND epub_resource_path IS NULL
         AND epub_scalar_start IS NULL AND epub_scalar_end IS NULL
         AND ((pdf_char_start IS NULL AND pdf_char_end IS NULL AND normalized_exact IS NULL)
              OR (pdf_char_start IS NOT NULL AND pdf_char_end IS NOT NULL
                  AND pdf_char_end > pdf_char_start AND normalized_exact IS NOT NULL)))
    ),
    CHECK (
        (normalization_profile IS NULL AND normalized_exact IS NULL
         AND normalized_prefix IS NULL AND normalized_suffix IS NULL AND original_quote IS NULL)
        OR
        (normalization_profile IS NOT NULL AND normalized_exact IS NOT NULL
         AND normalized_prefix IS NOT NULL AND normalized_suffix IS NOT NULL)
    ),
    CHECK (source_id IS NULL OR source_system IS NOT NULL),
    FOREIGN KEY (version_id, format) REFERENCES annotation_document_versions(id, format)
) STRICT;

CREATE INDEX annotations_version_live_idx
    ON annotations(version_id, deleted_at, created_at, id);
'''),
  Migration(6, 'page and book notes', '''
-- Page notes and book notes are annotations too (RFD 6, Notes and search): a
-- page note is anchored at a place (an EPUB spine item's scalar offset or a
-- PDF page) and a book note at nothing. Neither has a color or a quote, and
-- both have a note. SQLite cannot change a table's CHECK, so the table is
-- rebuilt with the same rows, all highlights.
CREATE TABLE annotations_v6 (
    id                    TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
    version_id            TEXT NOT NULL,
    format                TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    kind                  TEXT NOT NULL CHECK (kind IN ('highlight', 'page', 'book')),
    anchor_version        INTEGER NOT NULL CHECK (anchor_version = 1),
    original_quote        TEXT CHECK (original_quote IS NULL OR length(original_quote) <= 65536),
    normalization_profile TEXT CHECK (normalization_profile IS NULL
                                      OR normalization_profile = 'shosai-quote-v1'),
    normalized_exact      TEXT CHECK (normalized_exact IS NULL
                                      OR length(normalized_exact) BETWEEN 1 AND 65536),
    normalized_prefix     TEXT CHECK (normalized_prefix IS NULL OR length(normalized_prefix) <= 32),
    normalized_suffix     TEXT CHECK (normalized_suffix IS NULL OR length(normalized_suffix) <= 32),
    color                 TEXT CHECK (color IS NULL
                                      OR color IN ('yellow', 'green', 'blue', 'pink', 'purple')),
    body                  TEXT CHECK (body IS NULL OR length(body) <= 65536),
    source_system         TEXT CHECK (source_system IS NULL
                                      OR length(CAST(source_system AS BLOB)) BETWEEN 1 AND 256),
    source_id             TEXT CHECK (source_id IS NULL
                                      OR length(CAST(source_id AS BLOB)) BETWEEN 1 AND 4096),
    epub_spine_index      INTEGER CHECK (epub_spine_index IS NULL OR epub_spine_index >= 0),
    epub_resource_path    TEXT CHECK (epub_resource_path IS NULL
                                      OR length(CAST(epub_resource_path AS BLOB)) BETWEEN 1 AND 4096),
    -- A highlight's range, or a page note's place (start alone).
    epub_scalar_start     INTEGER CHECK (epub_scalar_start IS NULL OR epub_scalar_start >= 0),
    epub_scalar_end       INTEGER,
    pdf_page              INTEGER CHECK (pdf_page IS NULL OR pdf_page >= 0),
    pdf_char_start        INTEGER CHECK (pdf_char_start IS NULL OR pdf_char_start >= 0),
    pdf_char_end          INTEGER,
    -- Little-endian float32 (left, top, right, bottom) quadruples in page space.
    pdf_rectangles        BLOB CHECK (pdf_rectangles IS NULL
                                      OR (length(pdf_rectangles) BETWEEN 16 AND 262144
                                          AND length(pdf_rectangles) % 16 = 0)),
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    modified_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at            TEXT,
    -- A CHECK that evaluates to NULL passes, so nullable columns are tested
    -- with IS NOT NULL before they are compared.
    CHECK (
        (kind = 'highlight' AND color IS NOT NULL
         AND ((format = 'epub'
               AND epub_spine_index IS NOT NULL AND epub_resource_path IS NOT NULL
               AND epub_scalar_start IS NOT NULL AND epub_scalar_end IS NOT NULL
               AND epub_scalar_end > epub_scalar_start
               AND normalized_exact IS NOT NULL
               AND pdf_page IS NULL AND pdf_char_start IS NULL AND pdf_char_end IS NULL
               AND pdf_rectangles IS NULL)
              OR
              (format = 'pdf'
               AND pdf_page IS NOT NULL AND pdf_rectangles IS NOT NULL
               AND epub_spine_index IS NULL AND epub_resource_path IS NULL
               AND epub_scalar_start IS NULL AND epub_scalar_end IS NULL
               AND ((pdf_char_start IS NULL AND pdf_char_end IS NULL AND normalized_exact IS NULL)
                    OR (pdf_char_start IS NOT NULL AND pdf_char_end IS NOT NULL
                        AND pdf_char_end > pdf_char_start AND normalized_exact IS NOT NULL)))))
        OR
        (kind IN ('page', 'book') AND color IS NULL
         AND body IS NOT NULL AND length(body) > 0
         AND normalization_profile IS NULL
         AND epub_scalar_end IS NULL AND pdf_char_start IS NULL AND pdf_char_end IS NULL
         AND pdf_rectangles IS NULL
         AND ((kind = 'book'
               AND epub_spine_index IS NULL AND epub_resource_path IS NULL
               AND epub_scalar_start IS NULL AND pdf_page IS NULL)
              OR
              (kind = 'page' AND format = 'epub'
               AND epub_spine_index IS NOT NULL AND epub_scalar_start IS NOT NULL
               AND pdf_page IS NULL)
              OR
              (kind = 'page' AND format = 'pdf'
               AND pdf_page IS NOT NULL AND epub_spine_index IS NULL
               AND epub_resource_path IS NULL AND epub_scalar_start IS NULL)))
    ),
    CHECK (
        (normalization_profile IS NULL AND normalized_exact IS NULL
         AND normalized_prefix IS NULL AND normalized_suffix IS NULL AND original_quote IS NULL)
        OR
        (normalization_profile IS NOT NULL AND normalized_exact IS NOT NULL
         AND normalized_prefix IS NOT NULL AND normalized_suffix IS NOT NULL)
    ),
    CHECK (source_id IS NULL OR source_system IS NOT NULL),
    FOREIGN KEY (version_id, format) REFERENCES annotation_document_versions(id, format)
) STRICT;

INSERT INTO annotations_v6 (id, version_id, format, kind, anchor_version,
    original_quote, normalization_profile, normalized_exact, normalized_prefix,
    normalized_suffix, color, body, source_system, source_id,
    epub_spine_index, epub_resource_path, epub_scalar_start, epub_scalar_end,
    pdf_page, pdf_char_start, pdf_char_end, pdf_rectangles,
    created_at, modified_at, deleted_at)
  SELECT id, version_id, format, 'highlight', anchor_version,
    original_quote, normalization_profile, normalized_exact, normalized_prefix,
    normalized_suffix, color, body, source_system, source_id,
    epub_spine_index, epub_resource_path, epub_scalar_start, epub_scalar_end,
    pdf_page, pdf_char_start, pdf_char_end, pdf_rectangles,
    created_at, modified_at, deleted_at
  FROM annotations ORDER BY rowid;

DROP TABLE annotations;
ALTER TABLE annotations_v6 RENAME TO annotations;

CREATE INDEX annotations_version_live_idx
    ON annotations(version_id, deleted_at, created_at, id);
'''),
  Migration(7, 'book texts', '''
-- Each book's text as library search reads it, saved the first time the book
-- is searched so later searches need not open it. Keyed by content like the
-- reading state; text_version names the extraction that produced it, and a
-- book whose extraction changed is read again.
CREATE TABLE book_texts (
    content_hash TEXT PRIMARY KEY NOT NULL
                 CHECK (length(content_hash) = 64 AND content_hash NOT GLOB '*[^0-9a-f]*'),
    text_version TEXT NOT NULL CHECK (length(CAST(text_version AS BLOB)) BETWEEN 1 AND 256),
    unit_count   INTEGER NOT NULL CHECK (unit_count >= 0),
    -- UTF-8 bytes of the text kept, at most what one search covers.
    text_bytes   INTEGER NOT NULL CHECK (text_bytes BETWEEN 0 AND 8388608),
    -- Whether the book has more text than was kept.
    truncated    INTEGER NOT NULL CHECK (truncated IN (0, 1)),
    indexed_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
) STRICT, WITHOUT ROWID;

-- One unit's text, zlib-compressed UTF-8. Units without text have no row.
CREATE TABLE book_text_units (
    content_hash TEXT NOT NULL REFERENCES book_texts(content_hash) ON DELETE CASCADE,
    unit         INTEGER NOT NULL CHECK (unit >= 0),
    text         BLOB NOT NULL CHECK (length(text) BETWEEN 1 AND 16777216),
    PRIMARY KEY (content_hash, unit)
) STRICT;
'''),
  Migration(8, 'bookmark notes become page notes', '''
-- Bookmarks are places without notes (RFD 6, Notes and search): each
-- bookmark note becomes a page note where the bookmark is, and the bookmark
-- stays. A content without an annotation document gets one, described by
-- its library book; a note whose content is in neither is dropped with the
-- column. An EPUB bookmark never recorded its chapter's path, so its note
-- follows the spine index alone.
CREATE TEMP TABLE noted_contents AS
  SELECT DISTINCT b.content_hash, k.format, k.title
  FROM bookmarks b JOIN books k ON k.content_hash = b.content_hash
  WHERE b.note IS NOT NULL AND length(b.note) > 0
    AND NOT EXISTS (SELECT 1 FROM annotation_document_versions v
                    WHERE v.content_hash = b.content_hash);
ALTER TABLE noted_contents ADD COLUMN document_id TEXT;
ALTER TABLE noted_contents ADD COLUMN version_id TEXT;
UPDATE noted_contents SET document_id = $_uuid, version_id = $_uuid;

INSERT INTO annotation_documents (id, format)
  SELECT document_id, format FROM noted_contents;
INSERT INTO annotation_document_versions
    (id, document_id, format, content_hash, title)
  SELECT version_id, document_id, format, content_hash, title
  FROM noted_contents;
DROP TABLE noted_contents;

INSERT INTO annotations (id, version_id, format, kind, anchor_version, body,
    epub_spine_index, epub_scalar_start, pdf_page, created_at, modified_at)
  SELECT $_uuid, v.id, v.format, 'page', 1, b.note,
    CASE v.format WHEN 'epub' THEN b.unit END,
    CASE v.format WHEN 'epub' THEN coalesce(b.location_offset, 0) END,
    CASE v.format WHEN 'pdf' THEN b.unit END,
    b.created_at, b.created_at
  FROM bookmarks b
  JOIN annotation_document_versions v ON v.content_hash = b.content_hash
  WHERE b.note IS NOT NULL AND length(b.note) > 0
  ORDER BY b.id;

ALTER TABLE bookmarks DROP COLUMN note;
'''),
];

/// A random version 4 UUID, evaluated once per row.
const _uuid = '''lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4'
    || substr(hex(randomblob(2)), 2) || '-'
    || substr('89ab', 1 + (abs(random()) % 4), 1)
    || substr(hex(randomblob(2)), 2) || '-' || hex(randomblob(6)))''';
