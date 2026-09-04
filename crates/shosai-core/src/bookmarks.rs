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
        page: usize,
        title: Option<&str>,
        note: Option<&str>,
        color: &str,
    ) -> Result<Bookmark> {
        self.add_at_async(file_path, page, None, title, note, color)
            .await
    }

    /// Add a bookmark at a page/chapter and optional character offset.
    pub async fn add_at_async(
        &self,
        file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
        note: Option<&str>,
        color: &str,
    ) -> Result<Bookmark> {
        let key = canonical_key(file_path);
        validate_bookmark_fields(&key, title, note, color)?;

        let id = sqlx::query(
            "INSERT INTO bookmarks (file_path, page, location_offset, title, note, color)
             SELECT ?, ?, ?, ?, ?, ?
             WHERE (SELECT COUNT(*) FROM bookmarks WHERE file_path = ?) < ?
             RETURNING id",
        )
        .bind(&key)
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
        page: usize,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        self.toggle_at_async(file_path, page, None, title).await
    }

    /// Toggle a bookmark at a page/chapter and optional character offset.
    pub async fn toggle_at_async(
        &self,
        file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let key = canonical_key(file_path);
        validate_bookmark_fields(&key, title, None, "yellow")?;
        let page_db = i64::try_from(page).context("bookmark page exceeds database range")?;
        let location_offset_db = location_offset
            .map(i64::try_from)
            .transpose()
            .context("bookmark location exceeds database range")?;

        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let existing = sqlx::query(
            "SELECT id FROM bookmarks
             WHERE file_path = ? AND page = ?
               AND location_offset IS ? AND note IS NULL",
        )
        .bind(&key)
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
            let count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM bookmarks WHERE file_path = ?")
                    .bind(&key)
                    .fetch_one(&mut *transaction)
                    .await
                    .context("failed to count bookmarks")?;
            if count >= MAX_BOOKMARKS_PER_BOOK as i64 {
                anyhow::bail!("bookmark count limit exceeded");
            }
            let row = sqlx::query(
                "INSERT INTO bookmarks (file_path, page, location_offset, title, note, color)
                 VALUES (?, ?, ?, ?, NULL, 'yellow')
                 RETURNING id, file_path, book_id, page, location_offset, title, note, color,
                           created_at",
            )
            .bind(&key)
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
        let current_path: String = sqlx::query_scalar("SELECT file_path FROM books WHERE id = ?")
            .bind(book_id)
            .fetch_optional(&mut *transaction)
            .await
            .context("failed to resolve bookmark book")?
            .with_context(|| format!("book {book_id} not found"))?;
        validate_bookmark_path(&current_path)?;
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
                    (file_path, book_id, page, location_offset, title, note, color)
                 VALUES (?, ?, ?, ?, ?, NULL, 'yellow')
                 RETURNING id, file_path, book_id, page, location_offset, title, note, color,
                           created_at",
            )
            .bind(current_path)
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
    pub async fn list_for_file_async(&self, file_path: &Path) -> Result<Vec<Bookmark>> {
        let key = canonical_key(file_path);
        validate_bookmark_path(&key)?;

        let rows = sqlx::query(
            "SELECT id, file_path, book_id, page, location_offset, title, note, color, created_at
             FROM bookmarks
             WHERE file_path = ?
             ORDER BY page ASC, COALESCE(location_offset, 0) ASC, created_at ASC
             LIMIT ?",
        )
        .bind(&key)
        .bind(MAX_BOOKMARKS_PER_BOOK as i64 + 1)
        .fetch_all(&self.pool)
        .await
        .context("failed to list bookmarks")?;

        if rows.len() > MAX_BOOKMARKS_PER_BOOK {
            anyhow::bail!("bookmark count limit exceeded");
        }
        Ok(rows.iter().filter_map(row_to_bookmark).collect())
    }

    pub async fn list_for_file_page_async(
        &self,
        file_path: &Path,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Bookmark>> {
        let key = canonical_key(file_path);
        validate_bookmark_path(&key)?;
        let rows = sqlx::query(
            "SELECT id, file_path, book_id, page, location_offset, title, note, color, created_at
             FROM bookmarks WHERE file_path = ?
             ORDER BY page ASC, COALESCE(location_offset, 0) ASC, created_at ASC
             LIMIT ? OFFSET ?",
        )
        .bind(key)
        .bind(i64::from(limit.clamp(1, MAX_BOOKMARK_PAGE_SIZE)))
        .bind(i64::from(offset))
        .fetch_all(&self.pool)
        .await
        .context("failed to list bookmark page")?;
        Ok(rows.iter().filter_map(row_to_bookmark).collect())
    }

    /// List bookmarks using a stable library book identity.
    pub async fn list_for_book_async(&self, book_id: i64) -> Result<Vec<Bookmark>> {
        let rows = sqlx::query(
            "SELECT id, file_path, book_id, page, location_offset, title, note, color, created_at
             FROM bookmarks
             WHERE book_id = ?
             ORDER BY page ASC, COALESCE(location_offset, 0) ASC, created_at ASC
             LIMIT ?",
        )
        .bind(book_id)
        .bind(MAX_BOOKMARKS_PER_BOOK as i64 + 1)
        .fetch_all(&self.pool)
        .await
        .context("failed to list bookmarks for book")?;
        if rows.len() > MAX_BOOKMARKS_PER_BOOK {
            anyhow::bail!("bookmark count limit exceeded");
        }
        Ok(rows.iter().filter_map(row_to_bookmark).collect())
    }

    /// Check if a specific page is bookmarked (has a no-note bookmark).
    pub async fn is_bookmarked_async(&self, file_path: &Path, page: usize) -> bool {
        self.is_bookmarked_at_async(file_path, page, None).await
    }

    /// Check whether a page/chapter and optional character offset is bookmarked.
    pub async fn is_bookmarked_at_async(
        &self,
        file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
    ) -> bool {
        let key = canonical_key(file_path);

        sqlx::query(
            "SELECT 1 FROM bookmarks
             WHERE file_path = ? AND page = ?
               AND location_offset IS ? AND note IS NULL
             LIMIT 1",
        )
        .bind(&key)
        .bind(page as i64)
        .bind(location_offset.map(|offset| offset as i64))
        .fetch_optional(&self.pool)
        .await
        .ok()
        .flatten()
        .is_some()
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
    pub async fn remove_all_for_file_async(&self, file_path: &Path) -> Result<()> {
        let key = canonical_key(file_path);
        sqlx::query("DELETE FROM bookmarks WHERE file_path = ?")
            .bind(&key)
            .execute(&self.pool)
            .await
            .context("failed to remove bookmarks")?;
        Ok(())
    }

    /// Get a single bookmark by ID.
    async fn get_by_id_async(&self, id: i64) -> Result<Option<Bookmark>> {
        let row = sqlx::query(
            "SELECT id, file_path, book_id, page, location_offset, title, note, color, created_at
             FROM bookmarks WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(&self.pool)
        .await
        .context("failed to get bookmark")?;

        Ok(row.as_ref().and_then(row_to_bookmark))
    }

    /// Export all bookmarks for a file as Markdown text.
    pub async fn export_markdown_async(&self, file_path: &Path) -> Result<String> {
        let bookmarks = self.list_for_file_async(file_path).await?;

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
        page: usize,
        title: Option<&str>,
        note: Option<&str>,
        color: &str,
    ) -> Result<Bookmark> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.add_async(file_path, page, title, note, color))
    }

    pub fn toggle(
        &self,
        file_path: &Path,
        page: usize,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.toggle_async(file_path, page, title))
    }

    pub fn toggle_at(
        &self,
        file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
        title: Option<&str>,
    ) -> Result<Option<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.toggle_at_async(file_path, page, location_offset, title))
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

    pub fn list_for_file(&self, file_path: &Path) -> Result<Vec<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.list_for_file_async(file_path))
    }

    pub fn list_for_book(&self, book_id: i64) -> Result<Vec<Bookmark>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.list_for_book_async(book_id))
    }

    pub fn is_bookmarked(&self, file_path: &Path, page: usize) -> bool {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.is_bookmarked_async(file_path, page))
    }

    pub fn is_bookmarked_at(
        &self,
        file_path: &Path,
        page: usize,
        location_offset: Option<usize>,
    ) -> bool {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.is_bookmarked_at_async(file_path, page, location_offset))
    }

    pub fn export_markdown(&self, file_path: &Path) -> Result<String> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.export_markdown_async(file_path))
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

fn validate_optional_bytes(value: Option<&str>, limit: usize, field: &str) -> Result<()> {
    if value.is_some_and(|value| value.len() > limit) {
        anyhow::bail!("{field} exceeds byte limit");
    }
    Ok(())
}

fn canonical_key(path: &Path) -> String {
    canonical_path_key(path)
}

fn row_to_bookmark(row: &sqlx::sqlite::SqliteRow) -> Option<Bookmark> {
    Some(Bookmark {
        id: row.try_get("id").ok()?,
        file_path: row.try_get("file_path").ok()?,
        book_id: row.try_get("book_id").ok()?,
        page: row.try_get::<i64, _>("page").ok()? as usize,
        location_offset: row
            .try_get::<Option<i64>, _>("location_offset")
            .ok()?
            .map(|offset| offset as usize),
        title: row.try_get("title").ok()?,
        note: row.try_get("note").ok()?,
        color: row.try_get("color").ok()?,
        created_at: row.try_get("created_at").ok()?,
    })
}
