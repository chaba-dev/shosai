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

use anyhow::{Context, Result};
use sqlx::Row;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePool, SqliteSynchronous};

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
/// The public API is synchronous — it bridges to async sqlx internally via
/// the tokio runtime that iced provides. Async methods are also available
/// for use in background tasks or future phases.
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
        let path = db_file_path()?;
        if is_development_profile() {
            prepare_development_data_directory(path.parent().context("database has no parent")?)?;
        }
        Self::open_at_async(&path).await
    }

    /// Open the default store without waiting for legacy book fingerprints to be backfilled.
    pub async fn open_async_deferred_backfill() -> Result<Self> {
        let path = db_file_path()?;
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
    pub fn get(&self, file_path: &Path) -> Option<FileReadingState> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.get_async(file_path))
    }

    /// Set the reading state for a file.
    pub fn set(&self, file_path: &Path, state: &FileReadingState) -> Result<()> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.set_async(file_path, state))
    }

    /// Async: get the reading state for a file.
    pub async fn get_async(&self, file_path: &Path) -> Option<FileReadingState> {
        let key = canonical_key(file_path);

        sqlx::query("SELECT page, location_offset, zoom FROM reading_state WHERE file_path = ?")
            .bind(&key)
            .fetch_optional(&self.pool)
            .await
            .ok()
            .flatten()
            .map(|row| FileReadingState {
                page: row.get::<i64, _>("page") as usize,
                location_offset: row
                    .get::<Option<i64>, _>("location_offset")
                    .map(|offset| offset as usize),
                zoom: row.get::<f64, _>("zoom") as f32,
            })
    }

    /// Async: set the reading state for a file.
    pub async fn set_async(&self, file_path: &Path, state: &FileReadingState) -> Result<()> {
        let key = canonical_key(file_path);

        sqlx::query(
            "INSERT INTO reading_state (file_path, page, location_offset, zoom, updated_at)
             VALUES (?, ?, ?, ?, datetime('now'))
             ON CONFLICT(file_path) DO UPDATE SET
                page = excluded.page,
                location_offset = excluded.location_offset,
                zoom = excluded.zoom,
                updated_at = excluded.updated_at",
        )
        .bind(&key)
        .bind(state.page as i64)
        .bind(state.location_offset.map(|offset| offset as i64))
        .bind(state.zoom as f64)
        .execute(&self.pool)
        .await
        .context("failed to save reading state")?;

        Ok(())
    }

    /// Get reading state using a stable library book identity.
    pub async fn get_for_book_async(&self, book_id: i64) -> Option<FileReadingState> {
        sqlx::query("SELECT page, location_offset, zoom FROM reading_state WHERE book_id = ?")
            .bind(book_id)
            .fetch_optional(&self.pool)
            .await
            .ok()
            .flatten()
            .map(|row| FileReadingState {
                page: row.get::<i64, _>("page") as usize,
                location_offset: row
                    .get::<Option<i64>, _>("location_offset")
                    .map(|offset| offset as usize),
                zoom: row.get::<f64, _>("zoom") as f32,
            })
    }

    pub fn get_for_book(&self, book_id: i64) -> Option<FileReadingState> {
        let rt = tokio::runtime::Handle::current();
        rt.block_on(self.get_for_book_async(book_id))
    }

    /// Save reading state using a stable library book identity.
    pub async fn set_for_book_async(
        &self,
        book_id: i64,
        file_path: &Path,
        state: &FileReadingState,
    ) -> Result<()> {
        let key = canonical_key(file_path);
        let mut transaction = self.pool.begin().await?;
        sqlx::query("DELETE FROM reading_state WHERE book_id = ? OR file_path = ?")
            .bind(book_id)
            .bind(&key)
            .execute(&mut *transaction)
            .await
            .context("failed to reconcile reading state aliases")?;
        sqlx::query(
            "INSERT INTO reading_state
                (file_path, book_id, page, location_offset, zoom, updated_at)
             VALUES (?, ?, ?, ?, ?, datetime('now'))",
        )
        .bind(&key)
        .bind(book_id)
        .bind(state.page as i64)
        .bind(state.location_offset.map(|offset| offset as i64))
        .bind(state.zoom as f64)
        .execute(&mut *transaction)
        .await
        .context("failed to save reading state for book")?;
        transaction.commit().await?;
        Ok(())
    }

    /// Get a stored preference value.
    pub async fn get_pref_async(&self, key: &str) -> Option<String> {
        sqlx::query("SELECT value FROM preferences WHERE key = ?")
            .bind(key)
            .fetch_optional(&self.pool)
            .await
            .ok()
            .flatten()
            .map(|row| row.get::<String, _>("value"))
    }

    /// Get all stored preferences in one query.
    pub async fn get_prefs_async(&self) -> HashMap<String, String> {
        sqlx::query("SELECT key, value FROM preferences")
            .fetch_all(&self.pool)
            .await
            .unwrap_or_default()
            .into_iter()
            .map(|row| (row.get::<String, _>("key"), row.get::<String, _>("value")))
            .collect()
    }

    /// Set a stored preference value.
    pub async fn set_pref_async(&self, key: &str, value: &str) -> Result<()> {
        sqlx::query(
            "INSERT INTO preferences (key, value, updated_at)
             VALUES (?, ?, datetime('now'))
             ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at",
        )
        .bind(key)
        .bind(value)
        .execute(&self.pool)
        .await
        .context("failed to save preference")?;

        Ok(())
    }

    /// Get a stored preference value as an integer.
    pub fn get_pref_int(&self, key: &str) -> Option<i64> {
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
    pub async fn get_pref_int_async(&self, key: &str) -> Option<i64> {
        self.get_pref_async(key)
            .await
            .and_then(|value| value.parse::<i64>().ok())
    }

    /// Async: set a preference value as an integer.
    pub async fn set_pref_int_async(&self, key: &str, value: i64) -> Result<()> {
        self.set_pref_async(key, &value.to_string()).await
    }

    /// Async: atomically set multiple integer preferences.
    pub async fn set_pref_ints_async(&self, values: &[(&str, i64)]) -> Result<()> {
        let mut transaction = self.pool.begin().await?;
        for (key, value) in values {
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
        transaction.commit().await?;

        Ok(())
    }
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

/// Convert a file path to a canonical string key.
fn canonical_key(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .to_string()
}

/// Get the path to the database file.
fn db_file_path() -> Result<PathBuf> {
    let data_dir = data_dir()?;
    Ok(data_dir.join(app_data_directory_name()).join(DB_FILE))
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
