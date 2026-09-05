//! Persistence for per-file reading state (last page, zoom level, etc.).
//!
//! State is stored in a SQLite database in the user's data directory:
//!   - Linux:   `~/.local/share/shosai[-dev]/shosai.db`
//!   - macOS:   `~/Library/Application Support/shosai[-dev]/shosai.db`
//!
//! Uses sqlx with SQLite so the same database can be extended for library
//! management in future phases.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use sqlx::sqlite::{
    Sqlite, SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqliteSynchronous,
};
use sqlx::{Row, Transaction};

use crate::path_key::canonical_path_key;

#[derive(Debug, thiserror::Error)]
pub(crate) enum CurrentBookPathSaveError {
    #[error("book {0} no longer exists")]
    MissingBook(i64),
    #[error(transparent)]
    Persistence(#[from] anyhow::Error),
}

async fn next_reading_state_revision(transaction: &mut Transaction<'_, Sqlite>) -> Result<i64> {
    sqlx::query_scalar(
        "UPDATE reading_state_revision SET value = value + 1 WHERE singleton = 1
         RETURNING value",
    )
    .fetch_one(&mut **transaction)
    .await
    .context("failed to allocate reading state revision")
}

pub(crate) async fn reserve_reading_state_revision(pool: &SqlitePool) -> Result<i64> {
    let mut transaction = pool.begin().await?;
    let revision = next_reading_state_revision(&mut transaction).await?;
    transaction.commit().await?;
    Ok(revision)
}

async fn bounded_book_locator(
    transaction: &mut Transaction<'_, Sqlite>,
    book_id: i64,
) -> Result<Option<(String, Option<String>)>> {
    let row = sqlx::query(
        "SELECT
            CASE WHEN typeof(file_path) = 'text' AND length(CAST(file_path AS BLOB)) <= ?
                 THEN file_path END AS file_path,
            CASE WHEN content_hash IS NULL OR
                           (typeof(content_hash) = 'text' AND length(CAST(content_hash AS BLOB)) <= 64)
                 THEN content_hash END AS content_hash,
            CASE WHEN typeof(file_path) = 'text' AND length(CAST(file_path AS BLOB)) <= ?
                       AND (content_hash IS NULL OR
                            (typeof(content_hash) = 'text' AND length(CAST(content_hash AS BLOB)) <= 64))
                 THEN 1 ELSE 0 END AS fields_valid
         FROM books WHERE id = ?",
    )
    .bind(MAX_READING_STATE_PATH_BYTES as i64)
    .bind(MAX_READING_STATE_PATH_BYTES as i64)
    .bind(book_id)
    .fetch_optional(&mut **transaction)
    .await?;
    let Some(row) = row else { return Ok(None) };
    if row.try_get::<i64, _>("fields_valid")? != 1 {
        bail!("stored book locator is malformed or oversized");
    }
    Ok(Some((
        row.try_get::<Option<String>, _>("file_path")?
            .context("stored book path is invalid")?,
        row.try_get("content_hash")?,
    )))
}

pub(crate) async fn validate_preference_totals(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<()> {
    let row: (i64, i64) = sqlx::query_as(
        "SELECT COUNT(*),
                COALESCE(SUM(length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))), 0)
         FROM preferences",
    )
    .fetch_one(&mut **transaction)
    .await?;
    if usize::try_from(row.0)
        .ok()
        .is_none_or(|count| count > MAX_PREFERENCE_ROWS)
    {
        bail!("stored preferences exceed {MAX_PREFERENCE_ROWS} rows");
    }
    if usize::try_from(row.1)
        .ok()
        .is_none_or(|bytes| bytes > MAX_PREFERENCE_TOTAL_BYTES)
    {
        bail!("stored preferences exceed {MAX_PREFERENCE_TOTAL_BYTES} total bytes");
    }
    Ok(())
}

/// Data directory used by normal/release launches.
pub const RELEASE_APP_DIR: &str = "shosai";
/// Isolated data directory used when `SHOSAI_DEV_BUILD=1`.
pub const DEVELOPMENT_APP_DIR: &str = "shosai-dev";
/// File proving that an external managed-library directory belongs to the
/// development profile and may be removed by the development reset tool.
pub const STORAGE_PROFILE_MARKER_FILE: &str = ".shosai-storage-profile";
/// Exact marker contents required for development-owned external storage.
pub const DEVELOPMENT_STORAGE_PROFILE: &str = "shosai-development-v1";
const DB_FILE: &str = "shosai.db";
pub const MAX_READING_STATE_PATH_BYTES: usize = 16 * 1024;
pub const MAX_PREFERENCE_KEY_BYTES: usize = 1024;
pub const MAX_PREFERENCE_VALUE_BYTES: usize = 64 * 1024;
pub const MAX_PREFERENCE_ROWS: usize = 1024;
pub const MAX_PREFERENCE_TOTAL_BYTES: usize = 1024 * 1024;

/// Storage locations supplied by the platform host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplicationDataPaths {
    pub data_directory: PathBuf,
    pub database: PathBuf,
    pub managed_books: PathBuf,
}

impl ApplicationDataPaths {
    pub fn new(data_directory: impl Into<PathBuf>) -> Self {
        let data_directory = data_directory.into();
        Self {
            database: data_directory.join(DB_FILE),
            managed_books: data_directory.join("books"),
            data_directory,
        }
    }

    /// Resolve legacy desktop defaults. Platform hosts should normally inject
    /// their application-support directory with [`Self::new`].
    pub fn desktop_default() -> Result<Self> {
        Ok(Self::new(data_dir()?.join(app_data_directory_name())))
    }
}

fn select_development_profile(runtime: Option<&str>, compiled: Option<&str>, debug: bool) -> bool {
    match runtime {
        Some("1") => true,
        Some("0") => false,
        _ => compiled == Some("1") || debug,
    }
}

/// Whether this process uses isolated development storage and branding.
pub fn is_development_profile() -> bool {
    select_development_profile(
        std::env::var("SHOSAI_DEV_BUILD").ok().as_deref(),
        option_env!("SHOSAI_DEV_BUILD"),
        cfg!(debug_assertions),
    )
}

/// Return the managed application directory name for this process.
///
/// Debug builds default to development storage. `SHOSAI_DEV_BUILD=1` also
/// isolates release-mode development runs, while `0` permits explicit
/// production-profile testing.
pub fn app_data_directory_name() -> &'static str {
    if is_development_profile() {
        DEVELOPMENT_APP_DIR
    } else {
        RELEASE_APP_DIR
    }
}

/// Return the profile-specific folder created below a user-selected library parent.
pub fn managed_library_folder_name() -> &'static str {
    if is_development_profile() {
        "Shosai Dev"
    } else {
        "Shosai"
    }
}

/// Claim a user-selected managed-library directory for the current profile.
///
/// Development refuses to adopt a non-empty directory without its matching
/// marker so `make reset` can never infer ownership from a folder name alone.
pub fn prepare_managed_library_directory(path: &Path) -> Result<()> {
    if !is_development_profile() {
        std::fs::create_dir_all(path)
            .with_context(|| format!("failed to create managed library {}", path.display()))?;
        return Ok(());
    }

    if path.exists() {
        reject_symlink(path, "managed library")?;
        let marker = path.join(STORAGE_PROFILE_MARKER_FILE);
        if marker.symlink_metadata().is_ok() {
            return validate_managed_library_directory(path);
        }
        anyhow::bail!(
            "refusing to use existing directory without a Shosai development ownership marker"
        );
    } else {
        std::fs::create_dir_all(path)
            .with_context(|| format!("failed to create managed library {}", path.display()))?;
    }
    let marker = path.join(STORAGE_PROFILE_MARKER_FILE);
    use std::io::Write;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker)
        .with_context(|| format!("failed to create storage marker {}", marker.display()))?;
    writeln!(file, "{DEVELOPMENT_STORAGE_PROFILE}")
        .with_context(|| format!("failed to write storage marker {}", marker.display()))?;
    Ok(())
}

/// Verify that development-owned external storage still has its regular marker.
pub fn validate_managed_library_directory(path: &Path) -> Result<()> {
    if !is_development_profile() {
        return Ok(());
    }
    reject_symlink(path, "managed library")?;
    let marker = path.join(STORAGE_PROFILE_MARKER_FILE);
    reject_symlink(&marker, "managed library marker")?;
    let profile = std::fs::read_to_string(&marker)
        .with_context(|| format!("failed to read storage marker {}", marker.display()))?;
    if profile.trim() != DEVELOPMENT_STORAGE_PROFILE {
        anyhow::bail!("managed library belongs to a different Shosai profile");
    }
    Ok(())
}

fn reject_symlink(path: &Path, description: &str) -> Result<()> {
    let metadata = path
        .symlink_metadata()
        .with_context(|| format!("failed to inspect {description} {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        anyhow::bail!(
            "refusing to use symlinked {description}: {}",
            path.display()
        );
    }
    Ok(())
}

/// Per-file reading state.
#[derive(Debug, Clone)]
pub struct FileReadingState {
    /// Last viewed page index (0-based).
    pub page: usize,
    /// Character offset within an EPUB chapter. `None` for fixed-page formats.
    pub location_offset: Option<usize>,
    /// Last zoom scale (1.0 = 100%).
    pub zoom: f32,
}

/// SQLite-backed store for reading state (and future library data).
///
/// The public API is synchronous and bridges to async sqlx internally via the
/// current Tokio runtime. Async methods are also available for background tasks.
#[derive(Debug, Clone)]
pub struct ReadingStateStore {
    pool: SqlitePool,
    db_path: PathBuf,
}

impl ReadingStateStore {
    /// Get a reference to the underlying connection pool.
    ///
    /// This allows sharing the pool with other modules (e.g. the library)
    /// that use the same database.
    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    /// Directory used for book files copied into Shosai's managed library.
    pub fn managed_books_dir(&self) -> PathBuf {
        self.db_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("books")
    }

    /// Open (or create) the store at the default platform path.
    pub fn open() -> Result<Self> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(Self::open_async())
    }

    /// Open (or create) the store at a specific database path.
    pub fn open_at(db_path: &Path) -> Result<Self> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(Self::open_at_async(db_path))
    }

    /// Async: open at default platform path.
    pub async fn open_async() -> Result<Self> {
        let paths = ApplicationDataPaths::desktop_default()?;
        let path = paths.database;
        if is_development_profile() {
            prepare_development_data_directory(path.parent().context("database has no parent")?)?;
        }
        Self::open_at_async(&path).await
    }

    /// Open storage in a platform-provided application data directory.
    pub async fn open_in_data_directory_async(data_directory: &Path) -> Result<Self> {
        Self::open_at_async(&ApplicationDataPaths::new(data_directory).database).await
    }

    /// Open the default store without waiting for legacy book fingerprints to be backfilled.
    pub async fn open_async_deferred_backfill() -> Result<Self> {
        let paths = ApplicationDataPaths::desktop_default()?;
        let path = paths.database;
        if is_development_profile() {
            prepare_development_data_directory(path.parent().context("database has no parent")?)?;
        }
        Self::open_at_async_deferred_backfill(&path).await
    }

    /// Async: open at a specific database path.
    pub async fn open_at_async(db_path: &Path) -> Result<Self> {
        Self::open_at_inner(db_path, true).await
    }

    /// Open a specific store without waiting for legacy book fingerprints.
    pub async fn open_at_async_deferred_backfill(db_path: &Path) -> Result<Self> {
        Self::open_at_inner(db_path, false).await
    }

    async fn open_at_inner(db_path: &Path, backfill_fingerprints: bool) -> Result<Self> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create data dir {}", parent.display()))?;
        }

        let options = SqliteConnectOptions::new()
            .filename(db_path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Normal);

        let pool = SqlitePool::connect_with(options)
            .await
            .with_context(|| format!("failed to open database at {}", db_path.display()))?;

        let store = Self {
            pool,
            db_path: db_path.to_path_buf(),
        };
        store.migrate().await?;
        if backfill_fingerprints {
            store.backfill_missing_fingerprints().await?;
        }
        Ok(store)
    }

    /// Fill legacy library fingerprints after the store is available to the UI.
    pub async fn backfill_missing_fingerprints(&self) -> Result<()> {
        crate::library::backfill_missing_fingerprints(&self.pool).await
    }

    /// Run schema and query-index migrations from the `migrations/` directory.
    async fn migrate(&self) -> Result<()> {
        sqlx::migrate!("./migrations")
            .run(&self.pool)
            .await
            .context("failed to run database migrations")?;

        Ok(())
    }

    /// Get the reading state for a file.
    pub fn get(&self, file_path: &Path, content_hash: &str) -> Result<Option<FileReadingState>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.get_async(file_path, content_hash))
    }

    /// Set the reading state for a file.
    pub fn set(
        &self,
        file_path: &Path,
        content_hash: &str,
        state: &FileReadingState,
    ) -> Result<()> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.set_async(file_path, content_hash, state))
    }

    /// Async: get the reading state for a file.
    pub async fn get_async(
        &self,
        file_path: &Path,
        content_hash: &str,
    ) -> Result<Option<FileReadingState>> {
        let key = canonical_key(file_path);
        validate_path_key(&key)?;
        validate_content_hash(content_hash)?;

        let row = sqlx::query(
            "WITH owner AS (
                SELECT id FROM books WHERE content_hash = ? AND file_path = ?
                UNION ALL
                SELECT books.id
                FROM book_path_aliases
                JOIN books ON books.id = book_path_aliases.book_id
                WHERE book_path_aliases.content_hash = ? AND book_path_aliases.file_path = ?
                  AND books.content_hash = book_path_aliases.content_hash
                  AND NOT EXISTS (
                      SELECT 1 FROM books WHERE content_hash = ? AND file_path = ?
                  )
                LIMIT 1
             )
             SELECT page, location_offset, zoom FROM reading_state
             WHERE (book_id = (SELECT id FROM owner))
                OR ((SELECT id FROM owner) IS NULL AND file_path = ? AND content_hash = ?)",
        )
        .bind(content_hash)
        .bind(&key)
        .bind(content_hash)
        .bind(&key)
        .bind(content_hash)
        .bind(&key)
        .bind(&key)
        .bind(content_hash)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load reading state")?;
        row.as_ref().map(row_to_reading_state).transpose()
    }

    /// Async: set the reading state for a file.
    pub async fn set_async(
        &self,
        file_path: &Path,
        content_hash: &str,
        state: &FileReadingState,
    ) -> Result<()> {
        let key = canonical_key(file_path);
        self.set_key_async(&key, content_hash, state)
            .await
            .map(|_| ())
    }

    pub(crate) async fn resolve_path_owner_async(
        &self,
        key: &str,
        content_hash: &str,
    ) -> Result<Option<(i64, String)>> {
        validate_path_key(key)?;
        validate_content_hash(content_hash)?;
        if let Some(owner) = sqlx::query_as(
            "SELECT id, file_path FROM books WHERE content_hash = ? AND file_path = ?",
        )
        .bind(content_hash)
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .context("failed to resolve current reading state path owner")?
        {
            return Ok(Some(owner));
        }
        sqlx::query_as(
            "SELECT books.id, books.file_path
             FROM book_path_aliases
             JOIN books ON books.id = book_path_aliases.book_id
             WHERE book_path_aliases.content_hash = ? AND book_path_aliases.file_path = ?
               AND books.content_hash = book_path_aliases.content_hash",
        )
        .bind(content_hash)
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .context("failed to resolve historical reading state path owner")
    }

    pub(crate) async fn set_key_async(
        &self,
        key: &str,
        content_hash: &str,
        state: &FileReadingState,
    ) -> Result<Option<i64>> {
        self.set_key_at_revision_async(key, content_hash, state, None)
            .await
    }

    pub(crate) async fn set_key_at_revision_async(
        &self,
        key: &str,
        content_hash: &str,
        state: &FileReadingState,
        reserved_revision: Option<i64>,
    ) -> Result<Option<i64>> {
        validate_path_key(key)?;
        validate_content_hash(content_hash)?;
        let (page, location_offset, zoom) = reading_state_db_values(state)?;
        let mut transaction = self.pool.begin().await?;
        let revision = match reserved_revision {
            Some(revision) => revision,
            None => next_reading_state_revision(&mut transaction).await?,
        };
        // Imports and path-only saves are serialized by the revision write above. If the
        // import committed first, finish the already-admitted save against the stable identity;
        // if this save committed first, import reconciliation will claim it.
        let owner: Option<(i64, String)> = sqlx::query_as(
            "SELECT id, file_path FROM books WHERE content_hash = ? AND file_path = ?
             UNION ALL
             SELECT books.id, books.file_path
             FROM book_path_aliases
             JOIN books ON books.id = book_path_aliases.book_id
             WHERE book_path_aliases.content_hash = ? AND book_path_aliases.file_path = ?
               AND books.content_hash = book_path_aliases.content_hash
               AND NOT EXISTS (
                   SELECT 1 FROM books WHERE content_hash = ? AND file_path = ?
               )
             LIMIT 1",
        )
        .bind(content_hash)
        .bind(key)
        .bind(content_hash)
        .bind(key)
        .bind(content_hash)
        .bind(key)
        .fetch_optional(&mut *transaction)
        .await
        .context("failed to resolve reading state path owner")?;
        let owner_id = owner.as_ref().map(|(book_id, _)| *book_id);
        if let Some((book_id, current_key)) = owner {
            validate_path_key(&current_key)?;
            let newer_exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(
                    SELECT 1 FROM reading_state
                    WHERE (book_id = ? OR file_path = ?) AND revision > ?
                 )",
            )
            .bind(book_id)
            .bind(&current_key)
            .bind(revision)
            .fetch_one(&mut *transaction)
            .await
            .context("failed to check for newer promoted reading state")?;
            if newer_exists {
                transaction.commit().await?;
                return Ok(owner_id);
            }
            sqlx::query(
                "DELETE FROM reading_state
                 WHERE book_id = ? OR (book_id IS NULL AND
                    (file_path = ? OR (content_hash = ? AND file_path = ?)))",
            )
            .bind(book_id)
            .bind(&current_key)
            .bind(content_hash)
            .bind(key)
            .execute(&mut *transaction)
            .await
            .context("failed to reconcile promoted reading state")?;
            sqlx::query(
                "INSERT INTO reading_state
                    (file_path, content_hash, book_id, page, location_offset, zoom, updated_at, revision)
                 VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?)",
            )
            .bind(current_key)
            .bind(content_hash)
            .bind(book_id)
            .bind(page)
            .bind(location_offset)
            .bind(zoom)
            .bind(revision)
            .execute(&mut *transaction)
            .await
            .context("failed to save promoted reading state")?;
        } else {
            let newer_unowned_exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(
                    SELECT 1 FROM reading_state
                    WHERE file_path = ? AND book_id IS NULL AND revision > ?
                 )",
            )
            .bind(key)
            .bind(revision)
            .fetch_one(&mut *transaction)
            .await
            .context("failed to check for newer unowned reading state")?;
            if newer_unowned_exists {
                transaction.commit().await?;
                return Ok(None);
            }
            let result = sqlx::query(
                "INSERT INTO reading_state
                (file_path, content_hash, page, location_offset, zoom, updated_at, revision)
             VALUES (?, ?, ?, ?, ?, datetime('now'), ?)
             ON CONFLICT(file_path) DO UPDATE SET
                content_hash = excluded.content_hash,
                page = excluded.page,
                location_offset = excluded.location_offset,
                zoom = excluded.zoom,
                updated_at = excluded.updated_at,
                revision = excluded.revision
             WHERE reading_state.book_id IS NULL",
            )
            .bind(key)
            .bind(content_hash)
            .bind(page)
            .bind(location_offset)
            .bind(zoom)
            .bind(revision)
            .execute(&mut *transaction)
            .await
            .context("failed to save reading state")?;
            if result.rows_affected() == 0 {
                bail!("reading state path is owned by a different library book");
            }
        }
        transaction.commit().await?;
        Ok(owner_id)
    }

    /// Get reading state using a stable library book identity.
    pub async fn get_for_book_async(&self, book_id: i64) -> Result<Option<FileReadingState>> {
        let row =
            sqlx::query("SELECT page, location_offset, zoom FROM reading_state WHERE book_id = ?")
                .bind(book_id)
                .fetch_optional(&self.pool)
                .await
                .context("failed to load reading state for book")?;
        row.as_ref().map(row_to_reading_state).transpose()
    }

    pub fn get_for_book(&self, book_id: i64) -> Result<Option<FileReadingState>> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.get_for_book_async(book_id))
    }

    /// Save reading state using a stable library book identity.
    pub async fn set_for_book_async(&self, book_id: i64, state: &FileReadingState) -> Result<()> {
        let (page, location_offset, zoom) = reading_state_db_values(state)?;
        let mut transaction = self.pool.begin().await?;
        let current = bounded_book_locator(&mut transaction, book_id)
            .await
            .context("failed to resolve book path for reading state")?;
        let Some((current_key, content_hash)) = current else {
            bail!("book {book_id} not found");
        };
        let content_hash = content_hash.context("book has no stable content hash")?;
        validate_path_key(&current_key)?;
        validate_content_hash(&content_hash)?;
        let revision = next_reading_state_revision(&mut transaction).await?;
        sqlx::query(
            "DELETE FROM reading_state
             WHERE book_id = ?
                OR (file_path = ? AND book_id IS NULL)",
        )
        .bind(book_id)
        .bind(&current_key)
        .execute(&mut *transaction)
        .await
        .context("failed to reconcile reading state aliases")?;
        sqlx::query(
            "INSERT INTO reading_state
                (file_path, content_hash, book_id, page, location_offset, zoom, updated_at, revision)
             VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?)",
        )
        .bind(&current_key)
        .bind(&content_hash)
        .bind(book_id)
        .bind(page)
        .bind(location_offset)
        .bind(zoom)
        .bind(revision)
        .execute(&mut *transaction)
        .await
        .context("failed to save reading state for book")?;
        transaction.commit().await?;
        Ok(())
    }

    pub(crate) async fn set_for_book_current_path_at_revision_async(
        &self,
        book_id: i64,
        state: &FileReadingState,
        reserved_revision: Option<i64>,
    ) -> std::result::Result<String, CurrentBookPathSaveError> {
        let (page, location_offset, zoom) = reading_state_db_values(state)?;
        let mut transaction = self
            .pool
            .begin()
            .await
            .context("failed to begin reading state transaction")?;
        let revision = match reserved_revision {
            Some(revision) => revision,
            None => next_reading_state_revision(&mut transaction).await?,
        };
        let current = bounded_book_locator(&mut transaction, book_id)
            .await
            .context("failed to resolve current book path for reading state")?;
        let (key, content_hash) = current.ok_or(CurrentBookPathSaveError::MissingBook(book_id))?;
        let content_hash = content_hash.context("book has no stable content hash")?;
        validate_path_key(&key)?;
        validate_content_hash(&content_hash)?;
        let newer_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(
                SELECT 1 FROM reading_state
                WHERE (book_id = ? OR file_path = ?) AND revision > ?
             )",
        )
        .bind(book_id)
        .bind(&key)
        .bind(revision)
        .fetch_one(&mut *transaction)
        .await
        .context("failed to check for newer stable reading state")?;
        if newer_exists {
            transaction
                .commit()
                .await
                .context("failed to finish superseded stable reading state save")?;
            return Ok(key);
        }
        sqlx::query(
            "DELETE FROM reading_state
             WHERE book_id = ?
                OR (file_path = ? AND book_id IS NULL)",
        )
        .bind(book_id)
        .bind(&key)
        .execute(&mut *transaction)
        .await
        .context("failed to reconcile reading state aliases")?;
        sqlx::query(
            "INSERT INTO reading_state
                (file_path, content_hash, book_id, page, location_offset, zoom, updated_at, revision)
             VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?)",
        )
        .bind(&key)
        .bind(&content_hash)
        .bind(book_id)
        .bind(page)
        .bind(location_offset)
        .bind(zoom)
        .bind(revision)
        .execute(&mut *transaction)
        .await
        .context("failed to save reading state for current book path")?;
        transaction
            .commit()
            .await
            .context("failed to commit reading state transaction")?;
        Ok(key)
    }

    /// Get a stored preference value.
    pub async fn get_pref_async(&self, key: &str) -> Result<Option<String>> {
        validate_preference_key(key)?;
        let row = sqlx::query(
            "SELECT CASE
                 WHEN typeof(value) = 'text' AND length(CAST(value AS BLOB)) <= ? THEN value
             END AS bounded_value,
             length(CAST(value AS BLOB)) AS value_bytes
             FROM preferences WHERE key = ?",
        )
        .bind(MAX_PREFERENCE_VALUE_BYTES as i64)
        .bind(key)
        .fetch_optional(&self.pool)
        .await
        .context("failed to load preference")?;
        let Some(row) = row else {
            return Ok(None);
        };
        let value_bytes = row.try_get::<i64, _>("value_bytes")?;
        let value = row
            .try_get::<Option<String>, _>("bounded_value")?
            .context("stored preference value is malformed or exceeds its byte limit")?;
        let value_bytes = usize::try_from(value_bytes)
            .context("stored preference value has an invalid byte length")?;
        debug_assert!(value_bytes <= MAX_PREFERENCE_VALUE_BYTES);
        validate_preference(key, &value)?;
        Ok(Some(value))
    }

    /// Get all stored preferences in one query.
    pub async fn get_prefs_async(&self) -> Result<HashMap<String, String>> {
        let mut transaction = self.pool.begin().await?;
        let summary = sqlx::query(
            "SELECT COUNT(*) AS row_count,
                    COALESCE(SUM(length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))), 0)
                        AS total_bytes
             FROM preferences",
        )
        .fetch_one(&mut *transaction)
        .await
        .context("failed to summarize preferences")?;
        let row_count = usize::try_from(summary.try_get::<i64, _>("row_count")?)
            .context("stored preferences have an invalid row count")?;
        let total_bytes = usize::try_from(summary.try_get::<i64, _>("total_bytes")?)
            .context("stored preferences have an invalid byte count")?;
        if row_count > MAX_PREFERENCE_ROWS {
            bail!("stored preferences exceed {MAX_PREFERENCE_ROWS} rows");
        }
        if total_bytes > MAX_PREFERENCE_TOTAL_BYTES {
            bail!("stored preferences exceed {MAX_PREFERENCE_TOTAL_BYTES} total bytes");
        }
        let rows = sqlx::query(
            "SELECT CASE
                 WHEN typeof(key) = 'text' AND length(CAST(key AS BLOB)) <= ? THEN key
             END AS bounded_key,
             CASE
                 WHEN typeof(value) = 'text' AND length(CAST(value AS BLOB)) <= ? THEN value
             END AS bounded_value,
             length(CAST(key AS BLOB)) + length(CAST(value AS BLOB)) AS row_bytes
             FROM preferences LIMIT ?",
        )
        .bind(MAX_PREFERENCE_KEY_BYTES as i64)
        .bind(MAX_PREFERENCE_VALUE_BYTES as i64)
        .bind(MAX_PREFERENCE_ROWS as i64 + 1)
        .fetch_all(&mut *transaction)
        .await
        .context("failed to load preferences")?;
        if rows.len() > MAX_PREFERENCE_ROWS {
            bail!("stored preferences exceed {MAX_PREFERENCE_ROWS} rows");
        }
        let mut preferences = HashMap::with_capacity(rows.len());
        let mut loaded_bytes = 0_usize;
        for row in rows {
            let key = row
                .try_get::<Option<String>, _>("bounded_key")?
                .context("stored preference key is malformed or exceeds its byte limit")?;
            let value = row
                .try_get::<Option<String>, _>("bounded_value")?
                .context("stored preference value is malformed or exceeds its byte limit")?;
            let row_bytes = usize::try_from(row.try_get::<i64, _>("row_bytes")?)
                .context("stored preference has an invalid byte length")?;
            loaded_bytes = loaded_bytes
                .checked_add(row_bytes)
                .context("stored preference byte count overflowed")?;
            if loaded_bytes > MAX_PREFERENCE_TOTAL_BYTES {
                bail!("stored preferences exceed {MAX_PREFERENCE_TOTAL_BYTES} total bytes");
            }
            validate_preference(&key, &value)?;
            preferences.insert(key, value);
        }
        Ok(preferences)
    }

    /// Set a stored preference value.
    pub async fn set_pref_async(&self, key: &str, value: &str) -> Result<()> {
        validate_preference(key, value)?;
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        sqlx::query(
            "INSERT INTO preferences (key, value, updated_at)
             VALUES (?, ?, datetime('now'))
             ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at",
        )
        .bind(key)
        .bind(value)
        .execute(&mut *transaction)
        .await
        .context("failed to save preference")?;
        validate_preference_totals(&mut transaction).await?;
        transaction.commit().await?;
        Ok(())
    }

    /// Get a stored preference value as an integer.
    pub fn get_pref_int(&self, key: &str) -> Result<Option<i64>> {
        // Preferences are stored as strings to keep the table flexible.
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.get_pref_int_async(key))
    }

    /// Set a stored preference value as an integer.
    pub fn set_pref_int(&self, key: &str, value: i64) -> Result<()> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.set_pref_int_async(key, value))
    }

    /// Async: get a preference value as an integer.
    pub async fn get_pref_int_async(&self, key: &str) -> Result<Option<i64>> {
        self.get_pref_async(key)
            .await
            .map(|value| value.and_then(|value| value.parse::<i64>().ok()))
    }

    /// Async: set a preference value as an integer.
    pub async fn set_pref_int_async(&self, key: &str, value: i64) -> Result<()> {
        self.set_pref_async(key, &value.to_string()).await
    }

    /// Async: atomically set multiple integer preferences.
    pub async fn set_pref_ints_async(&self, values: &[(&str, i64)]) -> Result<()> {
        let mut transaction = self.pool.begin().await?;
        for (key, value) in values {
            validate_preference_key(key)?;
            sqlx::query(
                "INSERT INTO preferences (key, value, updated_at)
                 VALUES (?, ?, datetime('now'))
                 ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at",
            )
            .bind(key)
            .bind(value.to_string())
            .execute(&mut *transaction)
            .await
            .context("failed to save preference")?;
        }
        validate_preference_totals(&mut transaction).await?;
        transaction.commit().await?;

        Ok(())
    }
}

fn validate_path_key(key: &str) -> Result<()> {
    if key.len() > MAX_READING_STATE_PATH_BYTES {
        bail!("reading state path exceeds {MAX_READING_STATE_PATH_BYTES} bytes");
    }
    Ok(())
}

fn validate_content_hash(content_hash: &str) -> Result<()> {
    if content_hash.len() != 64 || !content_hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("reading state content hash must be a SHA-256 digest");
    }
    Ok(())
}

fn validate_preference_key(key: &str) -> Result<()> {
    if key.len() > MAX_PREFERENCE_KEY_BYTES {
        bail!("preference key exceeds {MAX_PREFERENCE_KEY_BYTES} bytes");
    }
    Ok(())
}

pub(crate) fn validate_preference(key: &str, value: &str) -> Result<()> {
    validate_preference_key(key)?;
    if value.len() > MAX_PREFERENCE_VALUE_BYTES {
        bail!("preference value exceeds {MAX_PREFERENCE_VALUE_BYTES} bytes");
    }
    Ok(())
}

fn reading_state_db_values(state: &FileReadingState) -> Result<(i64, Option<i64>, f64)> {
    let page = i64::try_from(state.page).context("reading state page exceeds database range")?;
    let location_offset = state
        .location_offset
        .map(i64::try_from)
        .transpose()
        .context("reading state location exceeds database range")?;
    if !state.zoom.is_finite() || state.zoom <= 0.0 {
        bail!("reading state zoom must be finite and positive");
    }
    Ok((page, location_offset, f64::from(state.zoom)))
}

fn row_to_reading_state(row: &sqlx::sqlite::SqliteRow) -> Result<FileReadingState> {
    let page = usize::try_from(row.try_get::<i64, _>("page")?)
        .context("stored reading state page is outside the supported range")?;
    let location_offset = row
        .try_get::<Option<i64>, _>("location_offset")?
        .map(usize::try_from)
        .transpose()
        .context("stored reading state location is outside the supported range")?;
    let zoom = row.try_get::<f64, _>("zoom")?;
    if !zoom.is_finite() || zoom <= 0.0 || zoom > f64::from(f32::MAX) {
        bail!("stored reading state zoom is outside the supported range");
    }
    Ok(FileReadingState {
        page,
        location_offset,
        zoom: zoom as f32,
    })
}

fn prepare_development_data_directory(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path)
        .with_context(|| format!("failed to create development data dir {}", path.display()))?;
    reject_symlink(path, "development data directory")?;
    let marker = path.join(STORAGE_PROFILE_MARKER_FILE);
    if marker.symlink_metadata().is_ok() {
        reject_symlink(&marker, "development data marker")?;
        let profile = std::fs::read_to_string(&marker)
            .with_context(|| format!("failed to read data marker {}", marker.display()))?;
        if profile.trim() != DEVELOPMENT_STORAGE_PROFILE {
            anyhow::bail!("development data directory belongs to a different Shosai profile");
        }
        return Ok(());
    }
    std::fs::write(&marker, format!("{DEVELOPMENT_STORAGE_PROFILE}\n"))
        .with_context(|| format!("failed to write data marker {}", marker.display()))
}

fn canonical_key(path: &Path) -> String {
    canonical_path_key(path)
}

/// Get the platform-specific data directory.
fn data_dir() -> Result<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        return Ok(PathBuf::from(xdg));
    }

    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .context("HOME environment variable not set")?;

    #[cfg(target_os = "macos")]
    {
        Ok(home.join("Library").join("Application Support"))
    }

    #[cfg(not(target_os = "macos"))]
    {
        Ok(home.join(".local").join("share"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn storage_profile_selection_honors_runtime_and_compiled_flags() {
        assert!(select_development_profile(Some("1"), None, false));
        assert!(!select_development_profile(Some("0"), Some("1"), true));
        assert!(select_development_profile(None, Some("1"), false));
        assert!(!select_development_profile(None, Some("0"), false));
        assert!(select_development_profile(None, None, true));
        assert!(!select_development_profile(None, None, false));
    }

    #[cfg(unix)]
    #[test]
    fn development_storage_rejects_symlinked_markers_and_directories() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let unrelated = directory.path().join("unrelated");
        std::fs::create_dir(&unrelated).unwrap();
        let profile = directory.path().join("profile");
        std::fs::write(&profile, DEVELOPMENT_STORAGE_PROFILE).unwrap();
        symlink(&profile, unrelated.join(STORAGE_PROFILE_MARKER_FILE)).unwrap();

        let marker_error = validate_managed_library_directory(&unrelated).unwrap_err();
        assert!(marker_error.to_string().contains("symlinked"));

        let linked = directory.path().join("linked");
        symlink(&unrelated, &linked).unwrap();
        let directory_error = validate_managed_library_directory(&linked).unwrap_err();
        assert!(directory_error.to_string().contains("symlinked"));
    }

    #[test]
    fn development_storage_does_not_claim_an_existing_unmarked_directory() {
        let directory = tempfile::tempdir().unwrap();
        let existing = directory.path().join("existing");
        std::fs::create_dir(&existing).unwrap();

        let error = prepare_managed_library_directory(&existing).unwrap_err();

        assert!(error.to_string().contains("existing directory"));
        assert!(!existing.join(STORAGE_PROFILE_MARKER_FILE).exists());
    }
}
