ALTER TABLE books ADD COLUMN storage_kind TEXT NOT NULL DEFAULT 'referenced';
ALTER TABLE books ADD COLUMN original_path TEXT;
ALTER TABLE books ADD COLUMN content_hash TEXT;
ALTER TABLE books ADD COLUMN file_size INTEGER;

ALTER TABLE reading_state ADD COLUMN book_id INTEGER REFERENCES books(id) ON DELETE CASCADE;
UPDATE reading_state
SET book_id = (SELECT id FROM books WHERE books.file_path = reading_state.file_path)
WHERE book_id IS NULL;
CREATE UNIQUE INDEX idx_reading_state_book_id
ON reading_state(book_id) WHERE book_id IS NOT NULL;

ALTER TABLE bookmarks ADD COLUMN book_id INTEGER REFERENCES books(id) ON DELETE CASCADE;
UPDATE bookmarks
SET book_id = (SELECT id FROM books WHERE books.file_path = bookmarks.file_path)
WHERE book_id IS NULL;
CREATE INDEX idx_bookmarks_book_id ON bookmarks(book_id);
