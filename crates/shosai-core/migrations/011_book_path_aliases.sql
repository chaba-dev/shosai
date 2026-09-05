CREATE TABLE book_path_aliases (
    file_path    TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    book_id      INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,

    PRIMARY KEY(file_path, content_hash)
);

INSERT INTO book_path_aliases (file_path, content_hash, book_id)
SELECT file_path, content_hash, id
FROM books
WHERE content_hash IS NOT NULL;

INSERT INTO book_path_aliases (file_path, content_hash, book_id)
SELECT original_path, content_hash, id
FROM books
WHERE original_path IS NOT NULL AND content_hash IS NOT NULL
ON CONFLICT(file_path, content_hash) DO UPDATE SET book_id = excluded.book_id;

CREATE INDEX book_path_aliases_book_id_idx ON book_path_aliases(book_id);
