CREATE TABLE annotations (
    id                    TEXT PRIMARY KEY NOT NULL,
    book_id               INTEGER REFERENCES books(id) ON DELETE SET NULL,
    local_path            TEXT,
    format                TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    anchor_version        INTEGER NOT NULL CHECK (anchor_version > 0),
    fingerprint_algorithm TEXT NOT NULL,
    fingerprint_version   INTEGER NOT NULL CHECK (fingerprint_version > 0),
    fingerprint           BLOB NOT NULL,
    original_quote        TEXT,
    normalization_profile TEXT,
    normalized_exact      TEXT,
    normalized_prefix     TEXT,
    normalized_suffix     TEXT,
    color                 TEXT NOT NULL CHECK (color IN ('yellow', 'green', 'blue', 'pink', 'purple')),
    body                  TEXT,
    source_system         TEXT,
    source_id             TEXT,
    epub_spine_occurrence INTEGER,
    epub_resource_path    TEXT,
    epub_scalar_start     INTEGER,
    epub_scalar_end       INTEGER,
    pdf_page              INTEGER,
    pdf_char_start        INTEGER,
    pdf_char_end          INTEGER,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    modified_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at            TEXT,
    CHECK (length(fingerprint) > 0),
    CHECK (length(fingerprint) <= 1024),
    CHECK (length(CAST(fingerprint_algorithm AS BLOB)) BETWEEN 1 AND 64),
    CHECK (local_path IS NULL OR length(CAST(local_path AS BLOB)) BETWEEN 1 AND 32768),
    CHECK (original_quote IS NULL OR length(original_quote) <= 65536),
    CHECK (normalized_exact IS NULL OR length(normalized_exact) BETWEEN 1 AND 65536),
    CHECK (normalized_prefix IS NULL OR length(normalized_prefix) <= 32),
    CHECK (normalized_suffix IS NULL OR length(normalized_suffix) <= 32),
    CHECK (body IS NULL OR length(body) <= 65536),
    CHECK (source_system IS NULL OR length(CAST(source_system AS BLOB)) BETWEEN 1 AND 256),
    CHECK (source_id IS NULL OR length(CAST(source_id AS BLOB)) BETWEEN 1 AND 4096),
    CHECK (epub_resource_path IS NULL OR length(CAST(epub_resource_path AS BLOB)) BETWEEN 1 AND 4096),
    CHECK (
        (format = 'epub'
         AND epub_spine_occurrence IS NOT NULL
         AND epub_resource_path IS NOT NULL
         AND epub_scalar_start IS NOT NULL
         AND epub_scalar_end IS NOT NULL
         AND pdf_page IS NULL AND pdf_char_start IS NULL AND pdf_char_end IS NULL)
        OR
        (format = 'pdf'
         AND pdf_page IS NOT NULL
         AND epub_spine_occurrence IS NULL
         AND epub_resource_path IS NULL
         AND epub_scalar_start IS NULL
         AND epub_scalar_end IS NULL)
    ),
    CHECK (
        (normalization_profile IS NULL AND normalized_exact IS NULL
         AND normalized_prefix IS NULL AND normalized_suffix IS NULL)
        OR
        (normalization_profile IS NOT NULL AND normalized_exact IS NOT NULL
         AND normalized_prefix IS NOT NULL AND normalized_suffix IS NOT NULL)
    ),
    CHECK ((pdf_char_start IS NULL AND pdf_char_end IS NULL)
           OR (pdf_char_start IS NOT NULL AND pdf_char_end IS NOT NULL))
);

CREATE TABLE annotation_pdf_rectangles (
    annotation_id TEXT NOT NULL REFERENCES annotations(id) ON DELETE CASCADE,
    rect_index    INTEGER NOT NULL CHECK (rect_index >= 0 AND rect_index < 16384),
    left          REAL NOT NULL,
    bottom        REAL NOT NULL,
    right         REAL NOT NULL,
    top           REAL NOT NULL,
    PRIMARY KEY (annotation_id, rect_index)
);

CREATE INDEX annotations_book_active_idx
    ON annotations(book_id, deleted_at, created_at);
CREATE INDEX annotations_path_active_idx
    ON annotations(local_path, deleted_at, created_at);
