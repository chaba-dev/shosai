CREATE INDEX annotation_document_versions_fingerprint_idx
    ON annotation_document_versions(
        format,
        fingerprint_algorithm,
        fingerprint_version,
        fingerprint,
        associated_at,
        id
    );

CREATE INDEX books_original_path_content_idx
    ON books(original_path, content_hash, id);

CREATE INDEX annotations_document_book_idx
    ON annotations(annotation_document_id, book_id);
