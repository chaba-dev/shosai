//! Library management: import, browse, and manage a collection of books.
//!
//! Uses the same SQLite database as the reading state store.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};
use sqlx::QueryBuilder;
use sqlx::Row;
use sqlx::Transaction;
use sqlx::sqlite::{Sqlite, SqlitePool};

use crate::cbz::CbzDoc;
use crate::document::Document;
use crate::epub::EpubDoc;
use crate::pdf::PdfDoc;

pub const MANAGED_LIBRARY_DIR_PREFERENCE: &str = "library.managed_books_dir";

/// Supported book format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BookFormat {
    Pdf,
    Epub,
    Cbz,
}

/// Where Shosai expects a book's bytes to live.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageKind {
    Referenced,
    Managed,
}

impl StorageKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Referenced => "referenced",
            Self::Managed => "managed",
        }
    }

    fn from_db(value: &str) -> Option<Self> {
        match value {
            "referenced" => Some(Self::Referenced),
            "managed" => Some(Self::Managed),
            _ => None,
        }
    }
}

impl BookFormat {
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext.to_lowercase().as_str() {
            "pdf" => Some(Self::Pdf),
            "epub" => Some(Self::Epub),
            "cbz" => Some(Self::Cbz),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pdf => "pdf",
            Self::Epub => "epub",
            Self::Cbz => "cbz",
        }
    }

    fn from_db(s: &str) -> Option<Self> {
        match s {
            "pdf" => Some(Self::Pdf),
            "epub" => Some(Self::Epub),
            "cbz" => Some(Self::Cbz),
            _ => None,
        }
    }
}

/// A book entry in the library.
#[derive(Debug, Clone)]
pub struct Book {
    pub id: i64,
    pub title: String,
    pub author: Option<String>,
    pub format: BookFormat,
    pub file_path: String,
    pub storage_kind: StorageKind,
    pub original_path: Option<String>,
    pub content_hash: Option<String>,
    pub file_size: Option<u64>,
    pub cover: Option<Vec<u8>>,
    pub progress: f64,
    pub date_added: String,
    pub last_read: Option<String>,
}

/// One bounded batch of books for incrementally populated library views.
#[derive(Debug, Clone)]
pub struct BookPage {
    pub books: Vec<Book>,
    pub has_more: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManagedStorageSummary {
    pub book_count: u64,
    pub total_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedPathChange {
    pub book_id: i64,
    pub old_path: PathBuf,
    pub new_path: PathBuf,
}

struct FileFingerprint {
    hash: String,
    size: u64,
}

struct BookInspection {
    title: String,
    author: Option<String>,
    cover: Option<Vec<u8>>,
    fingerprint: FileFingerprint,
}

/// Library backed by SQLite.
#[derive(Debug, Clone)]
pub struct Library {
    pool: SqlitePool,
    managed_dir: PathBuf,
}

impl Library {
    /// Create a library handle from an existing connection pool.
    pub fn new(pool: SqlitePool, managed_dir: PathBuf) -> Self {
        Self { pool, managed_dir }
    }

    pub fn managed_dir(&self) -> &Path {
        &self.managed_dir
    }

    pub fn with_managed_dir(&self, managed_dir: PathBuf) -> Self {
        Self::new(self.pool.clone(), managed_dir)
    }

    pub async fn managed_storage_summary(&self) -> Result<ManagedStorageSummary> {
        let row = sqlx::query(
            "SELECT COUNT(*) AS book_count, COALESCE(SUM(file_size), 0) AS total_bytes
             FROM books WHERE storage_kind = 'managed'",
        )
        .fetch_one(&self.pool)
        .await
        .context("failed to summarize managed books")?;
        Ok(ManagedStorageSummary {
            book_count: row.get::<i64, _>("book_count") as u64,
            total_bytes: row.get::<i64, _>("total_bytes") as u64,
        })
    }

    /// Move all private book copies to a new managed directory.
    ///
    /// New copies are fully staged before paths are updated transactionally. Old copies are only
    /// removed after the database commit, so interruption may leave harmless duplicates but never
    /// database rows pointing at incomplete files.
    pub async fn relocate_managed_books(&self, new_dir: &Path) -> Result<Vec<ManagedPathChange>> {
        let new_dir = new_dir.to_path_buf();
        let create_dir = new_dir.clone();
        tokio::task::spawn_blocking(move || std::fs::create_dir_all(&create_dir))
            .await
            .context("managed library directory task failed")?
            .with_context(|| format!("failed to create {}", new_dir.display()))?;
        let new_dir = canonical_path(&new_dir);

        let rows = sqlx::query(
            "SELECT id, file_path, content_hash FROM books
             WHERE storage_kind = 'managed' ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await
        .context("failed to list managed books for relocation")?;
        let mut changes = Vec::with_capacity(rows.len());
        let mut created_destinations = Vec::new();

        for row in rows {
            let book_id = row.get::<i64, _>("id");
            let old_path = PathBuf::from(row.get::<String, _>("file_path"));
            let expected_hash = row.get::<Option<String>, _>("content_hash");
            let extension = old_path
                .extension()
                .map(|extension| extension.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            let source = old_path.clone();
            let destination_dir = new_dir.clone();
            let relocation = tokio::task::spawn_blocking(move || -> Result<(PathBuf, bool)> {
                let fingerprint = file_fingerprint(&source)?;
                if expected_hash
                    .as_ref()
                    .is_some_and(|expected| expected != &fingerprint.hash)
                {
                    bail!("managed book failed verification: {}", source.display());
                }
                let destination =
                    destination_dir.join(format!("{}.{}", fingerprint.hash, extension));
                let existed = destination.exists();
                let staged = stage_managed_file(&source, &destination_dir)?;
                publish_managed_file(&staged.path, &destination, &fingerprint.hash)?;
                Ok((canonical_path(&destination), !existed))
            })
            .await
            .context("managed book relocation task failed");
            let (new_path, created) = match relocation {
                Ok(Ok(relocation)) => relocation,
                Ok(Err(error)) | Err(error) => {
                    for path in created_destinations {
                        let _ = std::fs::remove_file(path);
                    }
                    return Err(error);
                }
            };
            if created {
                created_destinations.push(new_path.clone());
            }
            changes.push(ManagedPathChange {
                book_id,
                old_path,
                new_path,
            });
        }

        let database_result = async {
            let mut transaction = self.pool.begin().await?;
            for change in &changes {
                let old_path = change.old_path.to_string_lossy();
                let new_path = change.new_path.to_string_lossy();
                sqlx::query("UPDATE books SET file_path = ? WHERE id = ?")
                    .bind(new_path.as_ref())
                    .bind(change.book_id)
                    .execute(&mut *transaction)
                    .await
                    .context("failed to update managed book path")?;
                reconcile_identity(
                    &mut transaction,
                    change.book_id,
                    old_path.as_ref(),
                    new_path.as_ref(),
                )
                .await?;
            }
            sqlx::query(
                "INSERT INTO preferences (key, value, updated_at)
                 VALUES (?, ?, datetime('now'))
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            )
            .bind(MANAGED_LIBRARY_DIR_PREFERENCE)
            .bind(new_dir.to_string_lossy().as_ref())
            .execute(&mut *transaction)
            .await
            .context("failed to save managed library location")?;
            transaction
                .commit()
                .await
                .context("failed to commit managed library relocation")?;
            Ok::<(), anyhow::Error>(())
        }
        .await;
        if let Err(error) = database_result {
            for path in created_destinations {
                let _ = std::fs::remove_file(path);
            }
            return Err(error);
        }

        for change in &changes {
            if change.old_path != change.new_path
                && let Err(error) = std::fs::remove_file(&change.old_path)
            {
                eprintln!(
                    "warning: failed to remove old managed book {}: {error}",
                    change.old_path.display()
                );
            }
        }
        if self.managed_dir != new_dir {
            let _ = std::fs::remove_dir(&self.managed_dir);
        }
        Ok(changes)
    }

    /// Import a single book file into the library.
    ///
    /// Extracts metadata and cover image from the file. If the file
    /// already exists in the library, returns its existing book entry.
    pub async fn import_file(&self, path: &Path) -> Result<Book> {
        // Normalize paths so lookups and progress updates stay consistent.
        let path = canonical_path(path);
        let path_str = path.to_string_lossy().to_string();

        // Check if already imported.
        if let Some(book) = self.get_by_path(&path_str).await? {
            return Ok(book);
        }

        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();

        let format = BookFormat::from_extension(&ext)
            .with_context(|| format!("unsupported format: .{ext}"))?;

        // Parsing documents, decoding images, and rendering PDF covers are CPU-heavy. Keep that
        // work away from the async executor so imports do not stall the application UI.
        let metadata_path = path.clone();
        let inspection = tokio::task::spawn_blocking(move || {
            inspect_book(&metadata_path, &metadata_path, format)
        })
        .await
        .context("metadata extraction task failed")??;

        sqlx::query(
            "INSERT INTO books
                (title, author, format, file_path, cover_blob, storage_kind,
                 original_path, content_hash, file_size)
             VALUES (?, ?, ?, ?, ?, 'referenced', ?, ?, ?)",
        )
        .bind(&inspection.title)
        .bind(&inspection.author)
        .bind(format.as_str())
        .bind(&path_str)
        .bind(&inspection.cover)
        .bind(&path_str)
        .bind(&inspection.fingerprint.hash)
        .bind(inspection.fingerprint.size as i64)
        .execute(&self.pool)
        .await
        .context("failed to insert book")?;

        let book = self
            .get_by_path(&path_str)
            .await?
            .context("book not found after insert")?;
        self.attach_identity(book.id, &path_str, &path_str).await?;
        Ok(book)
    }

    /// Copy a book into Shosai's private data directory and add it to the library.
    pub async fn import_managed_file(&self, source: &Path) -> Result<Book> {
        let source = canonical_path(source);
        let source_str = source.to_string_lossy().to_string();
        let ext = source
            .extension()
            .map(|value| value.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let format = BookFormat::from_extension(&ext)
            .with_context(|| format!("unsupported format: .{ext}"))?;
        let stage_source = source.clone();
        let stage_dir = self.managed_dir.clone();
        let staged =
            tokio::task::spawn_blocking(move || stage_managed_file(&stage_source, &stage_dir))
                .await
                .context("managed book staging task failed")??;
        let inspection_path = staged.path.clone();
        let title_path = source.clone();
        let inspection = tokio::task::spawn_blocking(move || {
            inspect_book(&inspection_path, &title_path, format)
        })
        .await
        .context("book inspection task failed")??;

        let destination = self
            .managed_dir
            .join(format!("{}.{ext}", inspection.fingerprint.hash));
        let publish_stage = staged.path.clone();
        let copy_destination = destination.clone();
        let expected_hash = inspection.fingerprint.hash.clone();
        tokio::task::spawn_blocking(move || {
            publish_managed_file(&publish_stage, &copy_destination, &expected_hash)
        })
        .await
        .context("managed book publication task failed")??;
        let destination = canonical_path(&destination);
        let destination_str = destination.to_string_lossy().to_string();
        let existing_hash = self.get_by_hash(&inspection.fingerprint.hash).await?;

        if let Some(existing) = &existing_hash
            && existing.storage_kind == StorageKind::Managed
        {
            return Ok(existing.clone());
        }

        if let Some(existing) = self.get_by_path(&source_str).await?.or(existing_hash) {
            self.update_location(
                existing.id,
                &existing.file_path,
                &destination_str,
                StorageKind::Managed,
                Some(&source_str),
                &inspection.fingerprint,
            )
            .await?;
            return self
                .get(existing.id)
                .await?
                .context("managed book not found after update");
        }

        let insert_result = sqlx::query(
            "INSERT INTO books
                (title, author, format, file_path, cover_blob, storage_kind,
                 original_path, content_hash, file_size)
             VALUES (?, ?, ?, ?, ?, 'managed', ?, ?, ?)",
        )
        .bind(&inspection.title)
        .bind(&inspection.author)
        .bind(format.as_str())
        .bind(&destination_str)
        .bind(&inspection.cover)
        .bind(&source_str)
        .bind(&inspection.fingerprint.hash)
        .bind(inspection.fingerprint.size as i64)
        .execute(&self.pool)
        .await;
        if let Err(error) = insert_result {
            if let Some(winner) = self.get_by_path(&destination_str).await? {
                return Ok(winner);
            }
            return Err(error).context("failed to insert managed book");
        }
        let book = self
            .get_by_path(&destination_str)
            .await?
            .context("managed book not found after insert")?;
        self.attach_identity(book.id, &source_str, &destination_str)
            .await?;
        Ok(book)
    }

    /// Relink a missing referenced book while preserving its stable identity and reader data.
    pub async fn relink(&self, book_id: i64, replacement: &Path) -> Result<Book> {
        let book = self
            .get(book_id)
            .await?
            .with_context(|| format!("book {book_id} not found"))?;
        let replacement = canonical_path(replacement);
        let ext = replacement
            .extension()
            .map(|value| value.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        if BookFormat::from_extension(&ext) != Some(book.format) {
            bail!("selected file has a different book format");
        }
        let fingerprint_path = replacement.clone();
        let fingerprint = tokio::task::spawn_blocking(move || file_fingerprint(&fingerprint_path))
            .await
            .context("book fingerprint task failed")??;
        let Some(expected) = &book.content_hash else {
            bail!("cannot verify this legacy book; remove it and import it again");
        };
        if expected != &fingerprint.hash {
            bail!("selected file does not match this book");
        }
        let replacement_str = replacement.to_string_lossy().to_string();
        self.update_location(
            book.id,
            &book.file_path,
            &replacement_str,
            StorageKind::Referenced,
            Some(&replacement_str),
            &fingerprint,
        )
        .await?;
        self.get(book.id)
            .await?
            .context("book not found after relink")
    }

    /// Import all supported files from a directory (recursively).
    pub async fn import_directory(&self, dir: &Path) -> Result<Vec<Book>> {
        self.add_directory(dir, true).await
    }

    /// Add all supported files from a directory without copying them (recursively).
    pub async fn link_directory(&self, dir: &Path) -> Result<Vec<Book>> {
        self.add_directory(dir, false).await
    }

    async fn add_directory(&self, dir: &Path, managed: bool) -> Result<Vec<Book>> {
        let mut books = Vec::new();
        let mut dirs = vec![dir.to_path_buf()];

        while let Some(current) = dirs.pop() {
            let entries = std::fs::read_dir(&current)
                .with_context(|| format!("failed to read directory {}", current.display()))?;

            for entry in entries {
                let entry = entry?;
                let path = entry.path();

                if path.is_dir() {
                    dirs.push(path);
                    continue;
                }

                let ext = path
                    .extension()
                    .map(|e| e.to_string_lossy().to_lowercase())
                    .unwrap_or_default();

                if BookFormat::from_extension(&ext).is_some() {
                    let result = if managed {
                        self.import_managed_file(&path).await
                    } else {
                        self.import_file(&path).await
                    };
                    match result {
                        Ok(book) => books.push(book),
                        Err(e) => {
                            eprintln!("warning: failed to import {}: {e}", path.display());
                        }
                    }
                }
            }
        }

        Ok(books)
    }

    /// List all books, ordered by most recently read first, then by date added.
    pub async fn list_all(&self) -> Result<Vec<Book>> {
        let rows = sqlx::query(
            "SELECT id, title, author, format, file_path, storage_kind, original_path,
                    content_hash, file_size, cover_blob, progress,
                    date_added, last_read
             FROM books
             ORDER BY last_read DESC NULLS LAST, date_added DESC",
        )
        .fetch_all(&self.pool)
        .await
        .context("failed to list books")?;

        Ok(rows.iter().filter_map(row_to_book).collect())
    }

    /// Search books by title or author.
    pub async fn search(&self, query: &str) -> Result<Vec<Book>> {
        let pattern = format!("%{query}%");
        let rows = sqlx::query(
            "SELECT id, title, author, format, file_path, storage_kind, original_path,
                    content_hash, file_size, cover_blob, progress,
                    date_added, last_read
             FROM books
             WHERE title LIKE ? OR author LIKE ?
             ORDER BY last_read DESC NULLS LAST, date_added DESC",
        )
        .bind(&pattern)
        .bind(&pattern)
        .fetch_all(&self.pool)
        .await
        .context("failed to search books")?;

        Ok(rows.iter().filter_map(row_to_book).collect())
    }

    /// Filter books by format.
    pub async fn filter_by_format(&self, format: BookFormat) -> Result<Vec<Book>> {
        let rows = sqlx::query(
            "SELECT id, title, author, format, file_path, storage_kind, original_path,
                    content_hash, file_size, cover_blob, progress,
                    date_added, last_read
             FROM books
             WHERE format = ?
             ORDER BY last_read DESC NULLS LAST, date_added DESC",
        )
        .bind(format.as_str())
        .fetch_all(&self.pool)
        .await
        .context("failed to filter books")?;

        Ok(rows.iter().filter_map(row_to_book).collect())
    }

    /// Fetch a bounded page of books, optionally combining search and format filters.
    ///
    /// One extra row is fetched to report whether another page is available without a separate
    /// count query.
    pub async fn page(
        &self,
        query: Option<&str>,
        format: Option<BookFormat>,
        limit: u32,
        offset: u32,
    ) -> Result<BookPage> {
        let limit = limit.max(1);
        let mut builder = QueryBuilder::new(
            "SELECT id, title, author, format, file_path, storage_kind, original_path, \
             content_hash, file_size, cover_blob, progress, \
             date_added, last_read FROM books",
        );

        let query = query.filter(|query| !query.is_empty());
        if query.is_some() || format.is_some() {
            builder.push(" WHERE ");
        }
        if let Some(query) = query {
            let pattern = format!("%{query}%");
            builder.push("(title LIKE ");
            builder.push_bind(pattern.clone());
            builder.push(" OR author LIKE ");
            builder.push_bind(pattern);
            builder.push(")");
            if format.is_some() {
                builder.push(" AND ");
            }
        }
        if let Some(format) = format {
            builder.push("format = ");
            builder.push_bind(format.as_str());
        }
        builder.push(" ORDER BY last_read DESC NULLS LAST, date_added DESC, id DESC LIMIT ");
        builder.push_bind(i64::from(limit) + 1);
        builder.push(" OFFSET ");
        builder.push_bind(i64::from(offset));

        let rows = builder
            .build()
            .fetch_all(&self.pool)
            .await
            .context("failed to load library page")?;
        let mut books: Vec<_> = rows.iter().filter_map(row_to_book).collect();
        let has_more = books.len() > limit as usize;
        books.truncate(limit as usize);

        Ok(BookPage { books, has_more })
    }

    /// Snapshot the matching library order without loading cover blobs.
    pub async fn matching_ids(
        &self,
        query: Option<&str>,
        format: Option<BookFormat>,
    ) -> Result<Vec<i64>> {
        let mut builder = QueryBuilder::new("SELECT id FROM books");
        push_library_filters(&mut builder, query, format);
        builder.push(" ORDER BY last_read DESC NULLS LAST, date_added DESC, id DESC");

        let rows = builder
            .build()
            .fetch_all(&self.pool)
            .await
            .context("failed to snapshot library order")?;
        Ok(rows
            .iter()
            .filter_map(|row| row.try_get("id").ok())
            .collect())
    }

    /// Load books from a previously captured ordered ID snapshot.
    pub async fn books_by_ids(&self, ids: &[i64]) -> Result<Vec<Book>> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut builder = QueryBuilder::new(
            "SELECT id, title, author, format, file_path, storage_kind, original_path, \
             content_hash, file_size, cover_blob, progress, \
             date_added, last_read FROM books WHERE id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in ids {
            separated.push_bind(id);
        }
        separated.push_unseparated(")");

        let rows = builder
            .build()
            .fetch_all(&self.pool)
            .await
            .context("failed to load books from library snapshot")?;
        let mut books_by_id: HashMap<_, _> = rows
            .iter()
            .filter_map(row_to_book)
            .map(|book| (book.id, book))
            .collect();

        Ok(ids.iter().filter_map(|id| books_by_id.remove(id)).collect())
    }

    /// Update reading progress (0.0 to 1.0) and last_read timestamp.
    pub async fn update_progress(&self, book_id: i64, progress: f64) -> Result<()> {
        let progress = progress.clamp(0.0, 1.0);
        sqlx::query("UPDATE books SET progress = ?, last_read = datetime('now') WHERE id = ?")
            .bind(progress)
            .bind(book_id)
            .execute(&self.pool)
            .await
            .context("failed to update progress")?;
        Ok(())
    }

    /// Update reading progress using a file path (0.0 to 1.0).
    pub async fn update_progress_by_path(&self, path: &Path, progress: f64) -> Result<()> {
        // Use canonical paths so the reader and library always converge on one row.
        let progress = progress.clamp(0.0, 1.0);
        let key = canonical_path(path).to_string_lossy().to_string();

        sqlx::query(
            "UPDATE books SET progress = ?, last_read = datetime('now') WHERE file_path = ?",
        )
        .bind(progress)
        .bind(&key)
        .execute(&self.pool)
        .await
        .context("failed to update progress by path")?;
        Ok(())
    }

    /// Remove a book from the library and delete its private managed copy, if any.
    pub async fn remove(&self, book_id: i64) -> Result<()> {
        let book = self.get(book_id).await?;
        let mut transaction = self.pool.begin().await?;
        sqlx::query("UPDATE bookmarks SET book_id = NULL WHERE book_id = ?")
            .bind(book_id)
            .execute(&mut *transaction)
            .await
            .context("failed to detach book bookmarks")?;
        sqlx::query("UPDATE reading_state SET book_id = NULL WHERE book_id = ?")
            .bind(book_id)
            .execute(&mut *transaction)
            .await
            .context("failed to detach book reading state")?;
        sqlx::query("DELETE FROM books WHERE id = ?")
            .bind(book_id)
            .execute(&mut *transaction)
            .await
            .context("failed to remove book")?;
        transaction.commit().await?;
        if let Some(book) = book
            && book.storage_kind == StorageKind::Managed
        {
            self.remove_unreferenced_managed_file(&book.file_path).await;
        }
        Ok(())
    }

    /// Get a book by stable ID.
    pub async fn get(&self, book_id: i64) -> Result<Option<Book>> {
        let row = sqlx::query(
            "SELECT id, title, author, format, file_path, storage_kind, original_path,
                    content_hash, file_size, cover_blob, progress, date_added, last_read
             FROM books WHERE id = ?",
        )
        .bind(book_id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to query book by id")?;
        Ok(row.as_ref().and_then(row_to_book))
    }

    /// Get a book by file path.
    async fn get_by_path(&self, path: &str) -> Result<Option<Book>> {
        let row = sqlx::query(
            "SELECT id, title, author, format, file_path, storage_kind, original_path,
                    content_hash, file_size, cover_blob, progress, date_added, last_read
             FROM books WHERE file_path = ?",
        )
        .bind(path)
        .fetch_optional(&self.pool)
        .await
        .context("failed to query book by path")?;

        Ok(row.as_ref().and_then(row_to_book))
    }

    async fn get_by_hash(&self, content_hash: &str) -> Result<Option<Book>> {
        let row = sqlx::query(
            "SELECT id, title, author, format, file_path, storage_kind, original_path,
                    content_hash, file_size, cover_blob, progress, date_added, last_read
             FROM books WHERE content_hash = ? ORDER BY storage_kind = 'managed' DESC LIMIT 1",
        )
        .bind(content_hash)
        .fetch_optional(&self.pool)
        .await
        .context("failed to query book by fingerprint")?;
        Ok(row.as_ref().and_then(row_to_book))
    }

    async fn update_location(
        &self,
        book_id: i64,
        old_path: &str,
        new_path: &str,
        storage_kind: StorageKind,
        original_path: Option<&str>,
        fingerprint: &FileFingerprint,
    ) -> Result<()> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query(
            "UPDATE books SET file_path = ?, storage_kind = ?, original_path = ?,
                              content_hash = ?, file_size = ? WHERE id = ?",
        )
        .bind(new_path)
        .bind(storage_kind.as_str())
        .bind(original_path)
        .bind(&fingerprint.hash)
        .bind(fingerprint.size as i64)
        .bind(book_id)
        .execute(&mut *transaction)
        .await
        .context("failed to update book location")?;
        reconcile_identity(&mut transaction, book_id, old_path, new_path).await?;
        transaction.commit().await?;
        Ok(())
    }

    async fn attach_identity(&self, book_id: i64, old_path: &str, new_path: &str) -> Result<()> {
        let mut transaction = self.pool.begin().await?;
        reconcile_identity(&mut transaction, book_id, old_path, new_path).await?;
        transaction.commit().await?;
        Ok(())
    }

    async fn remove_unreferenced_managed_file(&self, file_path: &str) {
        let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM books WHERE file_path = ?")
            .bind(file_path)
            .fetch_one(&self.pool)
            .await
            .unwrap_or(1);
        if remaining != 0 {
            return;
        }
        let path = PathBuf::from(file_path);
        let Ok(managed_dir) = self.managed_dir.canonicalize() else {
            return;
        };
        let Ok(path) = path.canonicalize() else {
            return;
        };
        if path.parent() == Some(managed_dir.as_path())
            && let Err(error) = std::fs::remove_file(&path)
        {
            eprintln!(
                "warning: failed to remove managed book {}: {error}",
                path.display()
            );
        }
    }
}

async fn reconcile_identity(
    transaction: &mut Transaction<'_, Sqlite>,
    book_id: i64,
    old_path: &str,
    new_path: &str,
) -> Result<()> {
    let reading = sqlx::query(
        "SELECT page, location_offset, zoom, updated_at
         FROM reading_state
         WHERE book_id = ? OR file_path = ? OR file_path = ?
         ORDER BY updated_at DESC, rowid DESC LIMIT 1",
    )
    .bind(book_id)
    .bind(old_path)
    .bind(new_path)
    .fetch_optional(&mut **transaction)
    .await
    .context("failed to select reading state aliases")?;
    sqlx::query("DELETE FROM reading_state WHERE book_id = ? OR file_path = ? OR file_path = ?")
        .bind(book_id)
        .bind(old_path)
        .bind(new_path)
        .execute(&mut **transaction)
        .await
        .context("failed to remove reading state aliases")?;
    if let Some(reading) = reading {
        sqlx::query(
            "INSERT INTO reading_state
                (file_path, book_id, page, location_offset, zoom, updated_at)
             VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(new_path)
        .bind(book_id)
        .bind(reading.get::<i64, _>("page"))
        .bind(reading.get::<Option<i64>, _>("location_offset"))
        .bind(reading.get::<f64, _>("zoom"))
        .bind(reading.get::<String, _>("updated_at"))
        .execute(&mut **transaction)
        .await
        .context("failed to merge reading state aliases")?;
    }

    sqlx::query(
        "DELETE FROM bookmarks
         WHERE (book_id = ? OR file_path = ? OR file_path = ?)
           AND id NOT IN (
             SELECT MIN(id) FROM bookmarks
             WHERE book_id = ? OR file_path = ? OR file_path = ?
             GROUP BY page, location_offset, note
           )",
    )
    .bind(book_id)
    .bind(old_path)
    .bind(new_path)
    .bind(book_id)
    .bind(old_path)
    .bind(new_path)
    .execute(&mut **transaction)
    .await
    .context("failed to deduplicate bookmark aliases")?;
    sqlx::query(
        "UPDATE bookmarks SET file_path = ?, book_id = ?
         WHERE book_id = ? OR file_path = ? OR file_path = ?",
    )
    .bind(new_path)
    .bind(book_id)
    .bind(book_id)
    .bind(old_path)
    .bind(new_path)
    .execute(&mut **transaction)
    .await
    .context("failed to merge bookmark aliases")?;
    Ok(())
}

fn push_library_filters<'a>(
    builder: &mut QueryBuilder<'a, sqlx::Sqlite>,
    query: Option<&str>,
    format: Option<BookFormat>,
) {
    let query = query.filter(|query| !query.is_empty());
    if query.is_some() || format.is_some() {
        builder.push(" WHERE ");
    }
    if let Some(query) = query {
        let pattern = format!("%{query}%");
        builder.push("(title LIKE ");
        builder.push_bind(pattern.clone());
        builder.push(" OR author LIKE ");
        builder.push_bind(pattern);
        builder.push(")");
        if format.is_some() {
            builder.push(" AND ");
        }
    }
    if let Some(format) = format {
        builder.push("format = ");
        builder.push_bind(format.as_str());
    }
}

fn row_to_book(row: &sqlx::sqlite::SqliteRow) -> Option<Book> {
    let format_str: String = row.try_get("format").ok()?;
    let format = BookFormat::from_db(&format_str)?;
    let storage_kind = StorageKind::from_db(&row.try_get::<String, _>("storage_kind").ok()?)?;

    Some(Book {
        id: row.try_get("id").ok()?,
        title: row.try_get("title").ok()?,
        author: row.try_get("author").ok()?,
        format,
        file_path: row.try_get("file_path").ok()?,
        storage_kind,
        original_path: row.try_get("original_path").ok()?,
        content_hash: row.try_get("content_hash").ok()?,
        file_size: row
            .try_get::<Option<i64>, _>("file_size")
            .ok()?
            .map(|size| size as u64),
        cover: row.try_get("cover_blob").ok()?,
        progress: row.try_get("progress").ok()?,
        date_added: row.try_get("date_added").ok()?,
        last_read: row.try_get("last_read").ok()?,
    })
}

/// Best-effort canonicalization used for stable database keys.
fn canonical_path(path: &Path) -> PathBuf {
    path.canonicalize().unwrap_or_else(|_| path.to_path_buf())
}

// ---------------------------------------------------------------------------
// Cover & metadata extraction
// ---------------------------------------------------------------------------

const COVER_MAX_WIDTH: u32 = 300;
const COVER_MAX_HEIGHT: u32 = 400;

fn extract_metadata_and_cover(
    path: &Path,
    title_path: &Path,
    format: BookFormat,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    match format {
        BookFormat::Pdf => extract_pdf_metadata(path, title_path),
        BookFormat::Epub => extract_epub_metadata(path, title_path),
        BookFormat::Cbz => extract_cbz_metadata(path, title_path),
    }
}

fn inspect_book(path: &Path, title_path: &Path, format: BookFormat) -> Result<BookInspection> {
    let (title, author, cover) = extract_metadata_and_cover(path, title_path, format)?;
    Ok(BookInspection {
        title,
        author,
        cover,
        fingerprint: file_fingerprint(path)?,
    })
}

fn file_fingerprint(path: &Path) -> Result<FileFingerprint> {
    use std::io::Read;

    let mut file =
        std::fs::File::open(path).with_context(|| format!("failed to read {}", path.display()))?;
    let file_size = file.metadata()?.len();
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(FileFingerprint {
        hash: format!("{:x}", hasher.finalize()),
        size: file_size,
    })
}

struct ManagedStage {
    path: PathBuf,
}

impl Drop for ManagedStage {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn unique_managed_path(parent: &Path, label: &str) -> PathBuf {
    parent.join(format!(
        ".{label}.{}.{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ))
}

fn stage_managed_file(source: &Path, managed_dir: &Path) -> Result<ManagedStage> {
    use std::io::Write;

    std::fs::create_dir_all(managed_dir)
        .with_context(|| format!("failed to create {}", managed_dir.display()))?;
    let path = unique_managed_path(managed_dir, "import");
    let mut input = std::fs::File::open(source)
        .with_context(|| format!("failed to read {}", source.display()))?;
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .context("failed to create managed book staging file")?;
    let result = std::io::copy(&mut input, &mut output).and_then(|_| output.flush());
    if let Err(error) = result {
        let _ = std::fs::remove_file(&path);
        return Err(error).context("failed to stage managed book");
    }
    Ok(ManagedStage { path })
}

fn publish_managed_file(stage: &Path, destination: &Path, expected_hash: &str) -> Result<()> {
    if destination.exists() && file_fingerprint(destination)?.hash == expected_hash {
        std::fs::remove_file(stage).context("failed to discard duplicate managed book")?;
        return Ok(());
    }

    let quarantine = destination
        .exists()
        .then(|| unique_managed_path(destination.parent().unwrap_or(Path::new(".")), "corrupt"));
    if let Some(quarantine) = &quarantine {
        std::fs::rename(destination, quarantine)
            .context("failed to quarantine corrupt managed book")?;
    }

    match std::fs::rename(stage, destination) {
        Ok(()) => {
            if let Some(quarantine) = quarantine {
                let _ = std::fs::remove_file(quarantine);
            }
            Ok(())
        }
        Err(_error)
            if destination.exists()
                && file_fingerprint(destination)
                    .is_ok_and(|fingerprint| fingerprint.hash == expected_hash) =>
        {
            let _ = std::fs::remove_file(stage);
            if let Some(quarantine) = quarantine {
                let _ = std::fs::remove_file(quarantine);
            }
            Ok(())
        }
        Err(error) => {
            if let Some(quarantine) = quarantine
                && !destination.exists()
            {
                let _ = std::fs::rename(quarantine, destination);
            }
            Err(error).context("failed to publish managed book")
        }
    }
}

pub(crate) async fn backfill_missing_fingerprints(pool: &SqlitePool) -> Result<()> {
    let rows = sqlx::query("SELECT id, file_path FROM books WHERE content_hash IS NULL")
        .fetch_all(pool)
        .await
        .context("failed to load legacy books for fingerprinting")?;
    for row in rows {
        let id: i64 = row.get("id");
        let file_path: String = row.get("file_path");
        let path = PathBuf::from(&file_path);
        if !path.is_file() {
            continue;
        }
        let fingerprint = match tokio::task::spawn_blocking(move || file_fingerprint(&path)).await {
            Ok(Ok(fingerprint)) => fingerprint,
            Ok(Err(error)) => {
                eprintln!("warning: failed to fingerprint legacy book {file_path}: {error}");
                continue;
            }
            Err(error) => {
                eprintln!("warning: legacy book fingerprint task failed: {error}");
                continue;
            }
        };
        sqlx::query(
            "UPDATE books SET content_hash = ?, file_size = ?
             WHERE id = ? AND file_path = ? AND content_hash IS NULL",
        )
        .bind(fingerprint.hash)
        .bind(fingerprint.size as i64)
        .bind(id)
        .bind(file_path)
        .execute(pool)
        .await
        .context("failed to save legacy book fingerprint")?;
    }
    Ok(())
}

fn extract_pdf_metadata(
    path: &Path,
    title_path: &Path,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    let doc = PdfDoc::open(path)?;
    let meta = doc.metadata();
    let title = meta.title.unwrap_or_else(|| filename_title(title_path));
    let author = meta.author;

    // Render first page as cover thumbnail.
    let cover = doc
        .render_page(0, 0.5) // half-scale for thumbnail
        .ok()
        .and_then(|page| encode_cover_png(page.width, page.height, &page.pixels));

    Ok((title, author, cover))
}

fn extract_epub_metadata(
    path: &Path,
    title_path: &Path,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    let doc = EpubDoc::open(path)?;
    let meta = &doc.content().metadata;
    let title = meta
        .title
        .clone()
        .unwrap_or_else(|| filename_title(title_path));
    let author = meta.author.clone();

    // Extract cover image from manifest.
    let cover = meta
        .cover_image_id
        .as_ref()
        .and_then(|id| doc.content().manifest.get(id))
        .and_then(|item| doc.resource(&item.href))
        .and_then(|resource| resize_cover_image(resource.bytes()));

    Ok((title, author, cover))
}

fn extract_cbz_metadata(
    path: &Path,
    title_path: &Path,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    let doc = CbzDoc::open(path)?;
    let title = filename_title(title_path);

    // Use first page as cover.
    let cover = doc
        .page_image_bytes(0)
        .ok()
        .and_then(|data| resize_cover_image(&data));

    Ok((title, None, cover))
}

fn filename_title(path: &Path) -> String {
    path.file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "Unknown".to_string())
}

/// Resize an image to fit within cover thumbnail bounds and encode as PNG.
fn resize_cover_image(data: &[u8]) -> Option<Vec<u8>> {
    let img = image::load_from_memory(data).ok()?;
    let thumb = img.resize(
        COVER_MAX_WIDTH,
        COVER_MAX_HEIGHT,
        image::imageops::FilterType::Triangle,
    );
    let rgba = thumb.to_rgba8();
    encode_cover_png(rgba.width(), rgba.height(), rgba.as_raw())
}

/// Encode RGBA pixels as PNG bytes.
fn encode_cover_png(width: u32, height: u32, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut buf = Vec::new();
    let encoder = image::codecs::png::PngEncoder::new(&mut buf);
    image::ImageEncoder::write_image(
        encoder,
        rgba,
        width,
        height,
        image::ExtendedColorType::Rgba8,
    )
    .ok()?;
    Some(buf)
}
