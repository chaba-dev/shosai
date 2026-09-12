CREATE TABLE managed_file_deletion_debt (
    file_path TEXT PRIMARY KEY NOT NULL,
    managed_dir TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK (length(CAST(file_path AS BLOB)) <= 16384),
    CHECK (length(CAST(managed_dir AS BLOB)) <= 16384)
);
