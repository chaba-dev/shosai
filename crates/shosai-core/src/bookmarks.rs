//! Bookmark and annotation management.
//!
//! Bookmarks are per-file, per-page markers with optional notes. They are
//! stored in the same SQLite database as the reading state and library.

use std::path::Path;

use anyhow::{Context, Result};
use sqlx::Row;
use sqlx::sqlite::SqlitePool;

use crate::path_key::canonical_path_key;

pub const MAX_BOOKMARKS_PER_BOOK: usize = 1_024;
pub const MAX_BOOKMARK_PATH_BYTES: usize = 32 * 1024;
pub const MAX_BOOKMARK_TITLE_BYTES: usize = 4 * 1024;
pub const MAX_BOOKMARK_NOTE_BYTES: usize = 64 * 1024;
pub const MAX_BOOKMARK_COLOR_BYTES: usize = 64;
pub const MAX_BOOKMARK_PAGE_SIZE: u32 = 500;
pub const MAX_BOOKMARK_EXPORT_BYTES: usize = 4 * 1024 * 1024;
const MAX_BOOKMARK_TIMESTAMP_BYTES: usize = 64;
const BOOKMARK_SELECT_COLUMNS: &str = "id,
    CASE WHEN typeof(file_path) = 'text' AND length(CAST(file_path AS BLOB)) <= 32768 THEN file_path END AS file_path,
    book_id, page, location_offset,
    CASE WHEN title IS NULL OR (typeof(title) = 'text' AND length(CAST(title AS BLOB)) <= 4096) THEN title END AS title,
    CASE WHEN note IS NULL OR (typeof(note) = 'text' AND length(CAST(note AS BLOB)) <= 65536) THEN note END AS note,
    CASE WHEN typeof(color) = 'text' AND length(CAST(color AS BLOB)) <= 64 THEN color END AS color,
    CASE WHEN typeof(created_at) = 'text' AND length(CAST(created_at AS BLOB)) <= 64 THEN created_at END AS created_at,
    CASE WHEN
        typeof(file_path) = 'text' AND length(CAST(file_path AS BLOB)) <= 32768
        AND (title IS NULL OR (typeof(title) = 'text' AND length(CAST(title AS BLOB)) <= 4096))
        AND (note IS NULL OR (typeof(note) = 'text' AND length(CAST(note AS BLOB)) <= 65536))
        AND typeof(color) = 'text' AND length(CAST(color AS BLOB)) <= 64
        AND typeof(created_at) = 'text' AND length(CAST(created_at AS BLOB)) <= 64
    THEN 1 ELSE 0 END AS fields_valid";

/// A single bookmark entry.
#[derive(Debug, Clone)]
pub struct Bookmark {
    pub id: i64,
    pub file_path: String,
    pub book_id: Option<i64>,
    pub page: usize,
    pub location_offset: Option<usize>,
    pub title: Option<String>,
    pub note: Option<String>,
    pub color: String,
    pub created_at: String,
}

/// Bookmark store backed by SQLite.
#[derive(Debug, Clone)]
pub struct BookmarkStore {
    pool: SqlitePool,
}

impl BookmarkStore {
    /// Create a bookmark store from an existing connection pool.
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    // -- Async API --

    /// Add a bookmark for a page. Returns the new bookmark.
    pub async fn add_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        title: Option<&str>,
        note: Option<&str>,
        color: &str,
    ) -> Result<Bookmark> {
        self.add_at_async(file_path, content_hash, page, None, title, note, color)
            .await
    }

    /// Add a bookmark at a page/chapter and optional character offset.
    #[allow(clippy::too_many_arguments)]
    pub async fn add_at_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
        note: Option<&str>,
        color: &str,
    ) -> Result<Bookmark> {
        let key = canonical_key(file_path);
        validate_bookmark_fields(&key, title, note, color)?;
        validate_content_hash(content_hash)?;

        let id = sqlx::query(
            "INSERT INTO bookmarks
                (file_path, content_hash, page, location_offset, title, note, color)
             SELECT ?, ?, ?, ?, ?, ?, ?
             WHERE (SELECT COUNT(*) FROM bookmarks
                    WHERE file_path = ? AND content_hash = ?) < ?
             RETURNING id",
        )
        .bind(&key)
        .bind(content_hash)
        .bind(i64::try_from(page).context("bookmark page exceeds database range")?)
        .bind(
            location_offset
                .map(i64::try_from)
                .transpose()
                .context("bookmark location exceeds database range")?,
        )
        .bind(title)
        .bind(note)
        .bind(color)
        .bind(&key)
        .bind(content_hash)
        .bind(MAX_BOOKMARKS_PER_BOOK as i64)
        .fetch_optional(&self.pool)
        .await
        .context("failed to add bookmark")?
        .context("bookmark count limit exceeded")?
        .get::<i64, _>("id");

        self.get_by_id_async(id)
            .await?
            .context("bookmark not found after insert")
    }

    /// Toggle a bookmark: if one exists at this page (with no note), remove it;
    /// otherwise, create one. Returns `Some(bookmark)` if created, `None` if removed.
    pub async fn toggle_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        self.toggle_at_async(file_path, content_hash, page, None, title)
            .await
    }

    /// Toggle a bookmark at a page/chapter and optional character offset.
    pub async fn toggle_at_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let key = canonical_key(file_path);
        validate_bookmark_fields(&key, title, None, "yellow")?;
        validate_content_hash(content_hash)?;
        let page_db = i64::try_from(page).context("bookmark page exceeds database range")?;
        let location_offset_db = location_offset
            .map(i64::try_from)
            .transpose()
            .context("bookmark location exceeds database range")?;

        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let existing = sqlx::query(
            "SELECT id FROM bookmarks
             WHERE file_path = ? AND content_hash = ? AND page = ?
               AND location_offset IS ? AND note IS NULL",
        )
        .bind(&key)
        .bind(content_hash)
        .bind(page_db)
        .bind(location_offset_db)
        .fetch_optional(&mut *transaction)
        .await
        .context("failed to check existing bookmark")?;

        if let Some(row) = existing {
            let id: i64 = row.get("id");
            sqlx::query("DELETE FROM bookmarks WHERE id = ?")
                .bind(id)
                .execute(&mut *transaction)
                .await
                .context("failed to remove bookmark")?;
            transaction.commit().await?;
            Ok(None)
        } else {
            let count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM bookmarks WHERE file_path = ? AND content_hash = ?",
            )
            .bind(&key)
            .bind(content_hash)
            .fetch_one(&mut *transaction)
            .await
            .context("failed to count bookmarks")?;
            if count >= MAX_BOOKMARKS_PER_BOOK as i64 {
                anyhow::bail!("bookmark count limit exceeded");
            }
            let row = sqlx::query(
                "INSERT INTO bookmarks
                    (file_path, content_hash, page, location_offset, title, note, color)
                 VALUES (?, ?, ?, ?, ?, NULL, 'yellow')
                 RETURNING id, file_path, book_id, page, location_offset, title, note, color,
                           created_at, 1 AS fields_valid",
            )
            .bind(&key)
            .bind(content_hash)
            .bind(page_db)
            .bind(location_offset_db)
            .bind(title)
            .fetch_one(&mut *transaction)
            .await
            .context("failed to add bookmark")?;
            let bookmark = row_to_bookmark(&row).context("invalid bookmark after insert")?;
            transaction.commit().await?;
            Ok(Some(bookmark))
        }
    }

    /// Toggle a bookmark using a stable library book identity.
    pub async fn toggle_for_book_at_async(
        &self,
        book_id: i64,
        _file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        validate_optional_bytes(title, MAX_BOOKMARK_TITLE_BYTES, "bookmark title")?;
        let page = i64::try_from(page).context("bookmark page exceeds database range")?;
        let location_offset = location_offset
            .map(i64::try_from)
            .transpose()
            .context("bookmark location exceeds database range")?;
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let book = sqlx::query(
            "SELECT
                CASE WHEN typeof(file_path) = 'text' AND length(CAST(file_path AS BLOB)) <= 32768
                     THEN file_path END AS file_path,
                CASE WHEN typeof(content_hash) = 'text' AND length(CAST(content_hash AS BLOB)) <= 64
                     THEN content_hash END AS content_hash
             FROM books WHERE id = ? AND content_hash IS NOT NULL",
        )
        .bind(book_id)
        .fetch_optional(&mut *transaction)
        .await
        .context("failed to resolve bookmark book")?
        .with_context(|| format!("book {book_id} not found"))?;
        let current_path = book
            .try_get::<Option<String>, _>("file_path")?
            .context("stored bookmark book path is malformed or oversized")?;
        let content_hash = book
            .try_get::<Option<String>, _>("content_hash")?
            .context("stored bookmark book hash is malformed or oversized")?;
        validate_bookmark_path(&current_path)?;
        validate_content_hash(&content_hash)?;

        // Claim path-only aliases while holding the write lock so lookup, counting, and the
        // mutation all observe one identity set. Rows belonging to another stable book are not
        // aliases even if that book currently happens to use the same path.
        sqlx::query(
            "UPDATE bookmarks SET book_id = ?
             WHERE book_id IS NULL AND file_path = ? AND content_hash = ?",
        )
        .bind(book_id)
        .bind(&current_path)
        .bind(&content_hash)
        .execute(&mut *transaction)
        .await
        .context("failed to reconcile bookmark aliases")?;
        let existing = sqlx::query(
            "SELECT id FROM bookmarks
             WHERE book_id = ? AND page = ?
               AND location_offset IS ? AND note IS NULL",
        )
        .bind(book_id)
        .bind(page)
        .bind(location_offset)
        .fetch_optional(&mut *transaction)
        .await
        .context("failed to check existing bookmark for book")?;

        if let Some(row) = existing {
            sqlx::query("DELETE FROM bookmarks WHERE id = ?")
                .bind(row.get::<i64, _>("id"))
                .execute(&mut *transaction)
                .await
                .context("failed to remove bookmark")?;
            transaction.commit().await?;
            Ok(None)
        } else {
            let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM bookmarks WHERE book_id = ?")
                .bind(book_id)
                .fetch_one(&mut *transaction)
                .await
                .context("failed to count bookmarks for book")?;
            if count >= MAX_BOOKMARKS_PER_BOOK as i64 {
                anyhow::bail!("bookmark count limit exceeded");
            }
            let row = sqlx::query(
                "INSERT INTO bookmarks
                    (file_path, content_hash, book_id, page, location_offset, title, note, color)
                 VALUES (?, ?, ?, ?, ?, ?, NULL, 'yellow')
                 RETURNING id, file_path, book_id, page, location_offset, title, note, color,
                           created_at, 1 AS fields_valid",
            )
            .bind(current_path)
            .bind(content_hash)
            .bind(book_id)
            .bind(page)
            .bind(location_offset)
            .bind(title)
            .fetch_one(&mut *transaction)
            .await
            .context("failed to add bookmark for book")?;
            let bookmark = row_to_bookmark(&row).context("invalid bookmark after insert")?;
            transaction.commit().await?;
            Ok(Some(bookmark))
        }
    }

    /// List all bookmarks for a file, ordered by page.
    pub async fn list_for_file_async(
        &self,
        file_path: &Path,
        content_hash: &str,
    ) -> Result<Vec<Bookmark>> {
        let key = canonical_key(file_path);
        validate_bookmark_path(&key)?;
        validate_content_hash(content_hash)?;

        let query = format!(
            "SELECT {BOOKMARK_SELECT_COLUMNS} FROM bookmarks
             WHERE file_path = ? AND content_hash = ?
             ORDER BY page ASC, COALESCE(location_offset, 0) ASC, created_at ASC
             LIMIT ?"
        );
        let rows = sqlx::query(&query)
            .bind(&key)
            .bind(content_hash)
            .bind(MAX_BOOKMARKS_PER_BOOK as i64 + 1)
            .fetch_all(&self.pool)
            .await
            .context("failed to list bookmarks")?;

        if rows.len() > MAX_BOOKMARKS_PER_BOOK {
            anyhow::bail!("bookmark count limit exceeded");
        }
        rows.iter().map(row_to_bookmark).collect()
    }

    pub async fn list_for_file_page_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Bookmark>> {
        let key = canonical_key(file_path);
        validate_bookmark_path(&key)?;
        validate_content_hash(content_hash)?;
        let query = format!(
            "SELECT {BOOKMARK_SELECT_COLUMNS} FROM bookmarks
             WHERE file_path = ? AND content_hash = ?
             ORDER BY page ASC, COALESCE(location_offset, 0) ASC, created_at ASC
             LIMIT ? OFFSET ?"
        );
        let rows = sqlx::query(&query)
            .bind(key)
            .bind(content_hash)
            .bind(i64::from(limit.clamp(1, MAX_BOOKMARK_PAGE_SIZE)))
            .bind(i64::from(offset))
            .fetch_all(&self.pool)
            .await
            .context("failed to list bookmark page")?;
        rows.iter().map(row_to_bookmark).collect()
    }

    /// List bookmarks using a stable library book identity.
    pub async fn list_for_book_async(&self, book_id: i64) -> Result<Vec<Bookmark>> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let book = sqlx::query(
            "SELECT
                CASE WHEN typeof(file_path) = 'text' AND length(CAST(file_path AS BLOB)) <= 32768
                     THEN file_path END AS file_path,
                CASE WHEN typeof(content_hash) = 'text' AND length(CAST(content_hash AS BLOB)) <= 64
                     THEN content_hash END AS content_hash
             FROM books WHERE id = ? AND content_hash IS NOT NULL",
        )
        .bind(book_id)
        .fetch_optional(&mut *transaction)
        .await
        .context("failed to resolve bookmark book")?
        .with_context(|| format!("book {book_id} not found"))?;
        let current_path = book
            .try_get::<Option<String>, _>("file_path")?
            .context("stored bookmark book path is malformed or oversized")?;
        let content_hash = book
            .try_get::<Option<String>, _>("content_hash")?
            .context("stored bookmark book hash is malformed or oversized")?;
        validate_bookmark_path(&current_path)?;
        validate_content_hash(&content_hash)?;

        sqlx::query(
            "UPDATE bookmarks SET book_id = ?
             WHERE book_id IS NULL AND file_path = ? AND content_hash = ?",
        )
        .bind(book_id)
        .bind(&current_path)
        .bind(&content_hash)
        .execute(&mut *transaction)
        .await
        .context("failed to reconcile bookmark aliases")?;
        let query = format!(
            "SELECT {BOOKMARK_SELECT_COLUMNS} FROM bookmarks
             WHERE book_id = ?
             ORDER BY page ASC, COALESCE(location_offset, 0) ASC, created_at ASC
             LIMIT ?"
        );
        let rows = sqlx::query(&query)
            .bind(book_id)
            .bind(MAX_BOOKMARKS_PER_BOOK as i64 + 1)
            .fetch_all(&mut *transaction)
            .await
            .context("failed to list bookmarks for book")?;
        if rows.len() > MAX_BOOKMARKS_PER_BOOK {
            anyhow::bail!("bookmark count limit exceeded");
        }
        transaction.commit().await?;
        rows.iter().map(row_to_bookmark).collect()
    }

    /// Check if a specific page is bookmarked (has a no-note bookmark).
    pub async fn is_bookmarked_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
    ) -> Result<bool> {
        self.is_bookmarked_at_async(file_path, content_hash, page, None)
            .await
    }

    /// Check whether a page/chapter and optional character offset is bookmarked.
    pub async fn is_bookmarked_at_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        location_offset: Option<usize>,
    ) -> Result<bool> {
        let key = canonical_key(file_path);
        validate_bookmark_path(&key)?;
        validate_content_hash(content_hash)?;
        let page = i64::try_from(page).context("bookmark page exceeds database range")?;
        let location_offset = location_offset
            .map(i64::try_from)
            .transpose()
            .context("bookmark location exceeds database range")?;

        Ok(sqlx::query(
            "SELECT 1 FROM bookmarks
             WHERE file_path = ? AND content_hash = ? AND page = ?
               AND location_offset IS ? AND note IS NULL
             LIMIT 1",
        )
        .bind(&key)
        .bind(content_hash)
        .bind(page)
        .bind(location_offset)
        .fetch_optional(&self.pool)
        .await
        .context("failed to check bookmark status")?
        .is_some())
    }

    /// Update the note on a bookmark.
    pub async fn update_note_async(&self, bookmark_id: i64, note: Option<&str>) -> Result<()> {
        validate_optional_bytes(note, MAX_BOOKMARK_NOTE_BYTES, "bookmark note")?;
        let result = sqlx::query("UPDATE bookmarks SET note = ? WHERE id = ?")
            .bind(note)
            .bind(bookmark_id)
            .execute(&self.pool)
            .await
            .context("failed to update bookmark note")?;
        if result.rows_affected() != 1 {
            anyhow::bail!("bookmark {bookmark_id} not found");
        }
        Ok(())
    }

    /// Update the title on a bookmark.
    pub async fn update_title_async(&self, bookmark_id: i64, title: Option<&str>) -> Result<()> {
        validate_optional_bytes(title, MAX_BOOKMARK_TITLE_BYTES, "bookmark title")?;
        let result = sqlx::query("UPDATE bookmarks SET title = ? WHERE id = ?")
            .bind(title)
            .bind(bookmark_id)
            .execute(&self.pool)
            .await
            .context("failed to update bookmark title")?;
        if result.rows_affected() != 1 {
            anyhow::bail!("bookmark {bookmark_id} not found");
        }
        Ok(())
    }

    /// Remove a bookmark by ID.
    pub async fn remove_async(&self, bookmark_id: i64) -> Result<()> {
        sqlx::query("DELETE FROM bookmarks WHERE id = ?")
            .bind(bookmark_id)
            .execute(&self.pool)
            .await
            .context("failed to remove bookmark")?;
        Ok(())
    }

    /// Remove all bookmarks for a file.
    pub async fn remove_all_for_file_async(
        &self,
        file_path: &Path,
        content_hash: &str,
    ) -> Result<()> {
        let key = canonical_key(file_path);
        validate_bookmark_path(&key)?;
        validate_content_hash(content_hash)?;
        sqlx::query("DELETE FROM bookmarks WHERE file_path = ? AND content_hash = ?")
            .bind(&key)
            .bind(content_hash)
            .execute(&self.pool)
            .await
            .context("failed to remove bookmarks")?;
        Ok(())
    }

    /// Get a single bookmark by ID.
    async fn get_by_id_async(&self, id: i64) -> Result<Option<Bookmark>> {
        let query = format!("SELECT {BOOKMARK_SELECT_COLUMNS} FROM bookmarks WHERE id = ?");
        let row = sqlx::query(&query)
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .context("failed to get bookmark")?;

        row.as_ref().map(row_to_bookmark).transpose()
    }

    /// Export all bookmarks for a file as Markdown text.
    pub async fn export_markdown_async(
        &self,
        file_path: &Path,
        content_hash: &str,
    ) -> Result<String> {
        let bookmarks = self.list_for_file_async(file_path, content_hash).await?;

        let filename = file_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "Unknown".to_string());

        let mut md = format!("# Bookmarks: {filename}\n\n");

        for bm in &bookmarks {
            let page_label = bm.page + 1;
            let title = bm.title.as_deref().unwrap_or("Untitled");
            md.push_str(&format!("## Page {page_label}: {title}\n\n"));

            if let Some(note) = &bm.note {
                md.push_str(note);
                md.push_str("\n\n");
            }

            md.push_str(&format!("*Added: {}*\n\n---\n\n", bm.created_at));
            if md.len() > MAX_BOOKMARK_EXPORT_BYTES {
                anyhow::bail!("bookmark Markdown export exceeds byte limit");
            }
        }

        Ok(md)
    }

    // -- Sync wrappers --

    pub fn add(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        title: Option<&str>,
        note: Option<&str>,
        color: &str,
    ) -> Result<Bookmark> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.add_async(file_path, content_hash, page, title, note, color))
    }

    pub fn toggle(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.toggle_async(file_path, content_hash, page, title))
    }

    pub fn toggle_at(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.toggle_at_async(file_path, content_hash, page, location_offset, title))
    }

    pub fn toggle_for_book_at(
        &self,
        book_id: i64,
        file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.toggle_for_book_at_async(book_id, file_path, page, location_offset, title))
    }

    pub fn list_for_file(&self, file_path: &Path, content_hash: &str) -> Result<Vec<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.list_for_file_async(file_path, content_hash))
    }

    pub fn list_for_book(&self, book_id: i64) -> Result<Vec<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.list_for_book_async(book_id))
    }

    pub fn is_bookmarked(&self, file_path: &Path, content_hash: &str, page: usize) -> Result<bool> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.is_bookmarked_async(file_path, content_hash, page))
    }

    pub fn is_bookmarked_at(
        &self,
        file_path: &Path,
        content_hash: &str,
        page: usize,
        location_offset: Option<usize>,
    ) -> Result<bool> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.is_bookmarked_at_async(file_path, content_hash, page, location_offset))
    }

    pub fn export_markdown(&self, file_path: &Path, content_hash: &str) -> Result<String> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.export_markdown_async(file_path, content_hash))
    }
}

fn validate_bookmark_fields(
    path: &str,
    title: Option<&str>,
    note: Option<&str>,
    color: &str,
) -> Result<()> {
    validate_bookmark_path(path)?;
    validate_optional_bytes(title, MAX_BOOKMARK_TITLE_BYTES, "bookmark title")?;
    validate_optional_bytes(note, MAX_BOOKMARK_NOTE_BYTES, "bookmark note")?;
    if color.len() > MAX_BOOKMARK_COLOR_BYTES {
        anyhow::bail!("bookmark color exceeds byte limit");
    }
    Ok(())
}

fn validate_bookmark_path(path: &str) -> Result<()> {
    if path.len() > MAX_BOOKMARK_PATH_BYTES {
        anyhow::bail!("bookmark path exceeds byte limit");
    }
    Ok(())
}

fn validate_content_hash(content_hash: &str) -> Result<()> {
    if content_hash.len() != 64 || !content_hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        anyhow::bail!("bookmark content hash must be a SHA-256 digest");
    }
    Ok(())
}

fn validate_optional_bytes(value: Option<&str>, limit: usize, field: &str) -> Result<()> {
    if value.is_some_and(|value| value.len() > limit) {
        anyhow::bail!("{field} exceeds byte limit");
    }
    Ok(())
}

fn canonical_key(path: &Path) -> String {
    canonical_path_key(path)
}

fn row_to_bookmark(row: &sqlx::sqlite::SqliteRow) -> Result<Bookmark> {
    if row.try_get::<i64, _>("fields_valid")? != 1 {
        anyhow::bail!("stored bookmark contains malformed or oversized fields");
    }
    let file_path = row
        .try_get::<Option<String>, _>("file_path")?
        .context("stored bookmark path is invalid")?;
    validate_bookmark_path(&file_path)?;
    crate::path_key::try_path_from_key(&file_path)
        .map_err(|_| anyhow::anyhow!("stored bookmark path is invalid"))?;
    let title = row.try_get::<Option<String>, _>("title")?;
    let note = row.try_get::<Option<String>, _>("note")?;
    let color = row
        .try_get::<Option<String>, _>("color")?
        .context("stored bookmark color is invalid")?;
    validate_bookmark_fields(&file_path, title.as_deref(), note.as_deref(), &color)?;
    let created_at = row
        .try_get::<Option<String>, _>("created_at")?
        .context("stored bookmark timestamp is invalid")?;
    if created_at.len() > MAX_BOOKMARK_TIMESTAMP_BYTES {
        anyhow::bail!("stored bookmark timestamp exceeds byte limit");
    }
    Ok(Bookmark {
        id: row.try_get("id")?,
        file_path,
        book_id: row.try_get("book_id")?,
        page: usize::try_from(row.try_get::<i64, _>("page")?)
            .context("stored bookmark page is outside the supported range")?,
        location_offset: row
            .try_get::<Option<i64>, _>("location_offset")?
            .map(usize::try_from)
            .transpose()
            .context("stored bookmark location is outside the supported range")?,
        title,
        note,
        color,
        created_at,
    })
}
