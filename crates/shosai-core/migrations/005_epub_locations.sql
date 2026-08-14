ALTER TABLE reading_state ADD COLUMN location_offset INTEGER;

CREATE TABLE bookmarks_with_locations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path       TEXT    NOT NULL,
    page            INTEGER NOT NULL,
    location_offset INTEGER,
    title           TEXT,
    note            TEXT,
    color           TEXT    NOT NULL DEFAULT 'yellow',
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),

    UNIQUE(file_path, page, location_offset, note)
);

INSERT INTO bookmarks_with_locations
    (id, file_path, page, title, note, color, created_at)
SELECT id, file_path, page, title, note, color, created_at
FROM bookmarks;

DROP TABLE bookmarks;
ALTER TABLE bookmarks_with_locations RENAME TO bookmarks;
CREATE INDEX idx_bookmarks_file_path ON bookmarks(file_path);
