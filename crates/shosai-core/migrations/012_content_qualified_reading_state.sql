CREATE TABLE reading_state_content_qualified (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path       TEXT NOT NULL,
    page            INTEGER NOT NULL DEFAULT 0,
    zoom            REAL NOT NULL DEFAULT 1.0,
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    location_offset INTEGER,
    book_id         INTEGER REFERENCES books(id) ON DELETE CASCADE,
    revision        INTEGER NOT NULL DEFAULT 0,
    content_hash    TEXT
);

INSERT INTO reading_state_content_qualified
    (file_path, page, zoom, updated_at, location_offset, book_id, revision, content_hash)
SELECT file_path, page, zoom, updated_at, location_offset, book_id, revision, content_hash
FROM reading_state;

DROP TABLE reading_state;
ALTER TABLE reading_state_content_qualified RENAME TO reading_state;

CREATE UNIQUE INDEX idx_reading_state_book_id
ON reading_state(book_id) WHERE book_id IS NOT NULL;

CREATE UNIQUE INDEX reading_state_path_content_idx
ON reading_state(file_path, content_hash) WHERE book_id IS NULL;
