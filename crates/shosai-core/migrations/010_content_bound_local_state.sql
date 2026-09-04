ALTER TABLE reading_state ADD COLUMN content_hash TEXT;
ALTER TABLE bookmarks ADD COLUMN content_hash TEXT;

UPDATE reading_state
SET content_hash = (SELECT content_hash FROM books WHERE books.id = reading_state.book_id)
WHERE book_id IS NOT NULL;

UPDATE bookmarks
SET content_hash = (SELECT content_hash FROM books WHERE books.id = bookmarks.book_id)
WHERE book_id IS NOT NULL;

CREATE TABLE bookmarks_content_bound (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path       TEXT    NOT NULL,
    page            INTEGER NOT NULL,
    location_offset INTEGER,
    title           TEXT,
    note            TEXT,
    color           TEXT    NOT NULL DEFAULT 'yellow',
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    book_id         INTEGER REFERENCES books(id) ON DELETE CASCADE,
    content_hash    TEXT,

    UNIQUE(file_path, content_hash, page, location_offset, note)
);

INSERT INTO bookmarks_content_bound
    (id, file_path, page, location_offset, title, note, color, created_at, book_id, content_hash)
SELECT id, file_path, page, location_offset, title, note, color, created_at, book_id, content_hash
FROM bookmarks;

DROP TABLE bookmarks;
ALTER TABLE bookmarks_content_bound RENAME TO bookmarks;
CREATE INDEX idx_bookmarks_file_path ON bookmarks(file_path);
CREATE INDEX idx_bookmarks_book_id ON bookmarks(book_id);

CREATE INDEX reading_state_path_content_idx
ON reading_state(file_path, content_hash) WHERE book_id IS NULL;

CREATE INDEX bookmarks_path_content_idx
ON bookmarks(file_path, content_hash) WHERE book_id IS NULL;
