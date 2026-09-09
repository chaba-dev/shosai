CREATE TABLE annotation_documents (
    id      TEXT PRIMARY KEY NOT NULL,
    format  TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    UNIQUE (id, format),
    CHECK (length(id) = 36)
);

CREATE TABLE annotation_document_versions (
    id                          TEXT PRIMARY KEY NOT NULL,
    document_id                 TEXT NOT NULL,
    format                      TEXT NOT NULL CHECK (format IN ('epub', 'pdf')),
    local_path                  TEXT NOT NULL,
    fingerprint_algorithm       TEXT NOT NULL,
    fingerprint_version         INTEGER NOT NULL CHECK (fingerprint_version > 0),
    fingerprint                 BLOB NOT NULL,
    associated_from_version_id  TEXT REFERENCES annotation_document_versions(id),
    associated_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE (local_path, format, fingerprint_algorithm, fingerprint_version, fingerprint),
    FOREIGN KEY (document_id, format) REFERENCES annotation_documents(id, format) ON DELETE CASCADE,
    CHECK (length(id) = 36),
    CHECK (length(CAST(local_path AS BLOB)) BETWEEN 1 AND 32768),
    CHECK (length(CAST(fingerprint_algorithm AS BLOB)) BETWEEN 1 AND 64),
    CHECK (length(fingerprint) BETWEEN 1 AND 1024)
);

ALTER TABLE annotations ADD COLUMN annotation_document_id TEXT
    REFERENCES annotation_documents(id);

CREATE TEMP TABLE initial_annotation_documents AS
SELECT MIN(id) AS id,
       format,
       local_path,
       fingerprint_algorithm,
       fingerprint_version,
       fingerprint
FROM annotations
WHERE book_id IS NULL AND local_path IS NOT NULL
GROUP BY format, local_path, fingerprint_algorithm, fingerprint_version, fingerprint;

INSERT INTO annotation_documents (id, format)
SELECT id, format FROM initial_annotation_documents;

INSERT INTO annotation_document_versions (
    id,
    document_id,
    format,
    local_path,
    fingerprint_algorithm,
    fingerprint_version,
    fingerprint
)
SELECT id,
       id,
       format,
       local_path,
       fingerprint_algorithm,
       fingerprint_version,
       fingerprint
FROM initial_annotation_documents;

UPDATE annotations
SET annotation_document_id = (
    SELECT initial.id
    FROM initial_annotation_documents AS initial
    WHERE initial.format = annotations.format
      AND initial.local_path = annotations.local_path
      AND initial.fingerprint_algorithm = annotations.fingerprint_algorithm
      AND initial.fingerprint_version = annotations.fingerprint_version
      AND initial.fingerprint = annotations.fingerprint
)
WHERE book_id IS NULL AND local_path IS NOT NULL;

DROP TABLE initial_annotation_documents;

CREATE INDEX annotations_document_active_idx
    ON annotations(annotation_document_id, deleted_at, created_at);

CREATE INDEX annotation_document_versions_document_idx
    ON annotation_document_versions(document_id, associated_at, id);

CREATE INDEX annotation_document_versions_format_id_idx
    ON annotation_document_versions(format, id);
