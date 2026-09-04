//! Library management: import, browse, and manage a collection of books.
//!
//! Uses the same SQLite database as the reading state store.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};
use sqlx::QueryBuilder;
use sqlx::Row;
use sqlx::Transaction;
use sqlx::sqlite::{Sqlite, SqlitePool};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;

use crate::application::{DeviceFileLocator, OpenDocument, OpenDocumentPlan};
use crate::cbz::{CbzDoc, CbzLimits};
use crate::document::Document;
use crate::epub::{EpubDoc, EpubLimits};
use crate::path_key::{canonical_path_key, path_from_key};
use crate::pdf::{MAX_PDF_INPUT_BYTES, PdfDoc};

pub const MANAGED_LIBRARY_DIR_PREFERENCE: &str = "library.managed_books_dir";
const DISCOVERY_HASH_CONCURRENCY: usize = 4;
const IMPORT_WORK_CONCURRENCY: usize = 4;
const MAX_IMPORT_DISCOVERY_RESULTS: usize = 10_000;
const MAX_IMPORT_ROOTS: usize = 10_000;
const MAX_IMPORT_TRAVERSAL_ENTRIES: usize = 50_000;
const MAX_LIBRARY_PAGE_SIZE: u32 = 500;
const MAX_LIBRARY_SNAPSHOT_SIZE: usize = 10_000;
const MAX_LIBRARY_QUERY_BYTES: usize = 4 * 1024;
const MAX_IMPORT_PATH_BYTES: usize = 16 * 1024;
const MAX_IMPORT_METADATA_BYTES: usize = 4 * 1024;
const MAX_IMPORT_COVER_BYTES: usize = 512 * 1024;
const MAX_IMPORT_ERROR_BYTES: usize = 4 * 1024;
const MAX_IMPORT_DETAILS: usize = 256;
const MAX_IMPORT_FAILURE_DETAILS: usize = 32;
const MAX_IMPORT_DETAIL_BYTES: usize = 512 * 1024;
const MAX_IMPORT_FAILURE_DETAIL_BYTES: usize = 64 * 1024;
const SQLITE_ID_CHUNK_SIZE: usize = 500;

fn scanner_admission() -> &'static Arc<tokio::sync::Semaphore> {
    static ADMISSION: OnceLock<Arc<tokio::sync::Semaphore>> = OnceLock::new();
    ADMISSION.get_or_init(|| Arc::new(tokio::sync::Semaphore::new(1)))
}

async fn acquire_scanner(
    cancellation: &ImportCancellation,
) -> Option<tokio::sync::OwnedSemaphorePermit> {
    tokio::select! {
        permit = scanner_admission().clone().acquire_owned() => {
            Some(permit.expect("scanner semaphore closed"))
        }
        () = cancellation.cancelled() => None,
    }
}

fn fingerprint_admission() -> &'static Arc<tokio::sync::Semaphore> {
    static ADMISSION: OnceLock<Arc<tokio::sync::Semaphore>> = OnceLock::new();
    ADMISSION.get_or_init(|| Arc::new(tokio::sync::Semaphore::new(DISCOVERY_HASH_CONCURRENCY)))
}

fn import_work_admission() -> &'static Arc<tokio::sync::Semaphore> {
    static ADMISSION: OnceLock<Arc<tokio::sync::Semaphore>> = OnceLock::new();
    ADMISSION.get_or_init(|| Arc::new(tokio::sync::Semaphore::new(IMPORT_WORK_CONCURRENCY)))
}

async fn acquire_import_work(
    cancellation: Option<&ImportCancellation>,
) -> Result<tokio::sync::OwnedSemaphorePermit> {
    if let Some(cancellation) = cancellation {
        if cancellation.is_cancelled() {
            bail!("import cancelled");
        }
        tokio::select! {
            biased;
            () = cancellation.cancelled() => bail!("import cancelled"),
            permit = import_work_admission().clone().acquire_owned() => {
                permit.context("import work admission closed")
            }
        }
    } else {
        import_work_admission()
            .clone()
            .acquire_owned()
            .await
            .context("import work admission closed")
    }
}

fn managed_storage_lock() -> &'static tokio::sync::Mutex<()> {
    static LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

async fn acquire_managed_storage(
    cancellation: Option<&ImportCancellation>,
) -> Result<tokio::sync::MutexGuard<'static, ()>> {
    if let Some(cancellation) = cancellation {
        if cancellation.is_cancelled() {
            bail!("import cancelled");
        }
        tokio::select! {
            biased;
            () = cancellation.cancelled() => bail!("import cancelled"),
            guard = managed_storage_lock().lock() => Ok(guard),
        }
    } else {
        Ok(managed_storage_lock().lock().await)
    }
}

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

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Pdf => "PDF",
            Self::Epub => "EPUB",
            Self::Cbz => "CBZ",
        }
    }

    pub(crate) fn max_input_bytes(self) -> u64 {
        match self {
            Self::Pdf => MAX_PDF_INPUT_BYTES,
            Self::Epub => EpubLimits::default().max_input_bytes,
            Self::Cbz => CbzLimits::default().max_archive_bytes,
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

impl std::fmt::Display for BookFormat {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.display_name())
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

#[derive(Debug, Clone)]
pub struct ImportFailure {
    pub path: PathBuf,
    pub error: String,
}

impl ImportFailure {
    pub fn new(path: PathBuf, error: impl Into<String>) -> Self {
        Self {
            path: compact_path(path),
            error: truncate_utf8(error.into(), MAX_IMPORT_ERROR_BYTES),
        }
    }

    fn compacted(self) -> Self {
        Self {
            path: compact_path(self.path),
            error: truncate_utf8(self.error, MAX_IMPORT_ERROR_BYTES),
        }
    }

    fn retained_byte_len(&self) -> usize {
        self.path.capacity().saturating_add(self.error.capacity())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportDuplicate {
    ExistingBook { book_id: i64, title: String },
    SelectedFile { path: PathBuf },
}

#[derive(Debug, Clone)]
pub struct ImportCandidate {
    pub path: PathBuf,
    pub title: String,
    pub group_key: String,
    pub format: BookFormat,
    pub file_size: u64,
    pub content_hash: String,
    pub duplicate: Option<ImportDuplicate>,
}

#[derive(Debug, Clone, Default)]
pub struct ImportDiscovery {
    pub candidates: Vec<ImportCandidate>,
    pub failures: Vec<ImportFailure>,
}

#[derive(Debug, Default)]
struct ImportCancellationInner {
    cancelled: AtomicBool,
    notify: tokio::sync::Notify,
}

#[derive(Debug, Clone, Default)]
pub struct ImportCancellation(Arc<ImportCancellationInner>);

impl ImportCancellation {
    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Release);
        self.0.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }

    async fn cancelled(&self) {
        loop {
            let notified = self.0.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImportDiscoveryProgressSnapshot {
    pub enumerating: bool,
    pub hashed_files: u64,
    pub completed_files: u64,
    pub total_files: u64,
}

#[derive(Debug, Clone)]
pub struct ImportDiscoveryProgress(Arc<ImportDiscoveryProgressInner>);

#[derive(Debug)]
struct ImportDiscoveryProgressInner {
    enumerating: AtomicBool,
    hashed_files: AtomicU64,
    completed_files: AtomicU64,
    total_files: AtomicU64,
}

impl Default for ImportDiscoveryProgress {
    fn default() -> Self {
        Self(Arc::new(ImportDiscoveryProgressInner {
            enumerating: AtomicBool::new(true),
            hashed_files: AtomicU64::new(0),
            completed_files: AtomicU64::new(0),
            total_files: AtomicU64::new(0),
        }))
    }
}

impl ImportDiscoveryProgress {
    pub fn snapshot(&self) -> ImportDiscoveryProgressSnapshot {
        ImportDiscoveryProgressSnapshot {
            enumerating: self.0.enumerating.load(Ordering::Acquire),
            hashed_files: self.0.hashed_files.load(Ordering::Acquire),
            completed_files: self.0.completed_files.load(Ordering::Acquire),
            total_files: self.0.total_files.load(Ordering::Acquire),
        }
    }

    fn found_file(&self) {
        self.0.total_files.fetch_add(1, Ordering::AcqRel);
    }

    fn completed_file(&self) {
        self.0.completed_files.fetch_add(1, Ordering::AcqRel);
    }

    fn hashed_file(&self) {
        self.0.hashed_files.fetch_add(1, Ordering::AcqRel);
    }

    fn finish_enumerating(&self) {
        self.0.enumerating.store(false, Ordering::Release);
    }
}

/// Minimal successful-import detail retained by batch reports and frontends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedBook {
    book_id: i64,
    source_path: PathBuf,
    library_path: PathBuf,
    content_hash: String,
}

#[derive(Debug, Clone)]
pub enum ImportCompletion {
    Cancelled,
    Completed(Result<ImportedBook, ImportFailure>),
}

impl ImportedBook {
    fn from_book(source_path: PathBuf, book: &Book) -> Self {
        Self {
            book_id: book.id,
            source_path: compact_path(source_path),
            library_path: compact_path(path_from_key(&book.file_path)),
            content_hash: compact_string(book.content_hash.as_deref().unwrap_or_default()),
        }
    }

    pub fn new(
        book_id: i64,
        source_path: PathBuf,
        library_path: PathBuf,
        content_hash: String,
    ) -> Option<Self> {
        if source_path.as_os_str().as_encoded_bytes().len() > MAX_IMPORT_PATH_BYTES
            || library_path.as_os_str().as_encoded_bytes().len() > MAX_IMPORT_PATH_BYTES
            || content_hash.len() > 128
        {
            return None;
        }
        Some(Self {
            book_id,
            source_path: compact_path(source_path),
            library_path: compact_path(library_path),
            content_hash: compact_string(&content_hash),
        })
    }

    pub fn book_id(&self) -> i64 {
        self.book_id
    }

    pub fn source_path(&self) -> &Path {
        &self.source_path
    }

    pub fn library_path(&self) -> &Path {
        &self.library_path
    }

    pub fn content_hash(&self) -> &str {
        &self.content_hash
    }

    fn compacted(self) -> Self {
        Self {
            book_id: self.book_id,
            source_path: compact_path(self.source_path),
            library_path: compact_path(self.library_path),
            content_hash: compact_string(&self.content_hash),
        }
    }

    fn retained_byte_len(&self) -> usize {
        self.source_path
            .capacity()
            .saturating_add(self.library_path.capacity())
            .saturating_add(self.content_hash.capacity())
    }
}

#[derive(Debug, Clone, Default)]
pub struct ImportReport {
    pub succeeded: usize,
    pub failed: usize,
    imported: Vec<ImportedBook>,
    failures: Vec<ImportFailure>,
    imported_detail_bytes: usize,
    failure_detail_bytes: usize,
}

impl ImportReport {
    pub fn imported(&self) -> &[ImportedBook] {
        &self.imported
    }

    pub fn failures(&self) -> &[ImportFailure] {
        &self.failures
    }

    fn record(&mut self, path: PathBuf, result: Result<Book>) {
        match result {
            Ok(book) => self.record_success(ImportedBook::from_book(path, &book)),
            Err(error) => self.record_failure(ImportFailure::new(path, format!("{error:#}"))),
        }
    }

    pub fn from_imported(imported: ImportedBook) -> Self {
        let mut report = Self::default();
        report.record_success(imported);
        report
    }

    pub fn from_failure(failure: ImportFailure) -> Self {
        let mut report = Self::default();
        report.record_failure(failure);
        report
    }

    fn record_success(&mut self, imported: ImportedBook) {
        self.succeeded = self.succeeded.saturating_add(1);
        let imported = imported.compacted();
        let bytes = imported.retained_byte_len();
        if self.imported.len() < MAX_IMPORT_DETAILS
            && self
                .imported_detail_bytes
                .checked_add(bytes)
                .is_some_and(|total| total <= MAX_IMPORT_DETAIL_BYTES)
        {
            self.imported_detail_bytes += bytes;
            self.imported.push(imported);
        }
    }

    fn record_failure(&mut self, mut failure: ImportFailure) {
        self.failed = self.failed.saturating_add(1);
        if failure.path.as_os_str().as_encoded_bytes().len() > MAX_IMPORT_PATH_BYTES {
            failure.path = PathBuf::new();
        }
        let failure = failure.compacted();
        let bytes = failure.retained_byte_len();
        if self.failures.len() < MAX_IMPORT_FAILURE_DETAILS
            && self
                .failure_detail_bytes
                .checked_add(bytes)
                .is_some_and(|total| total <= MAX_IMPORT_FAILURE_DETAIL_BYTES)
        {
            self.failure_detail_bytes += bytes;
            self.failures.push(failure);
        }
    }

    pub fn merge(&mut self, other: Self) {
        self.succeeded = self.succeeded.saturating_add(other.succeeded);
        self.failed = self.failed.saturating_add(other.failed);
        for imported in other.imported {
            let bytes = imported.retained_byte_len();
            if self.imported.len() >= MAX_IMPORT_DETAILS
                || self
                    .imported_detail_bytes
                    .checked_add(bytes)
                    .is_none_or(|total| total > MAX_IMPORT_DETAIL_BYTES)
            {
                break;
            }
            self.imported_detail_bytes += bytes;
            self.imported.push(imported);
        }
        for failure in other.failures {
            let bytes = failure.retained_byte_len();
            if self.failures.len() >= MAX_IMPORT_FAILURE_DETAILS
                || self
                    .failure_detail_bytes
                    .checked_add(bytes)
                    .is_none_or(|total| total > MAX_IMPORT_FAILURE_DETAIL_BYTES)
            {
                break;
            }
            self.failure_detail_bytes += bytes;
            self.failures.push(failure);
        }
    }
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

#[derive(Debug, PartialEq, Eq)]
struct FileFingerprint {
    hash: String,
    size: u64,
}

#[derive(Debug)]
struct FingerprintedFile {
    fingerprint: FileFingerprint,
    handle: same_file::Handle,
    version: FileVersion,
}

#[cfg(unix)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileVersion {
    device: u64,
    inode: u64,
    len: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
}

#[cfg(windows)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileVersion {
    len: u64,
    creation_time: u64,
    last_write_time: u64,
}

#[cfg(not(any(unix, windows)))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct FileVersion {
    len: u64,
    modified: Option<std::time::SystemTime>,
}

#[derive(Debug)]
struct BookInspection {
    title: String,
    author: Option<String>,
    cover: Option<Vec<u8>>,
    fingerprint: FileFingerprint,
}

struct LocationIdentity<'a> {
    fingerprint: &'a FileFingerprint,
    verified_file: Option<(&'a Path, &'a FingerprintedFile)>,
}

/// A verified private copy that is ready to be published and recorded in the library.
#[derive(Debug)]
pub struct PreparedManagedImport {
    source_str: String,
    extension: String,
    format: BookFormat,
    staged: ManagedStage,
    inspection: BookInspection,
    retention_permit: std::sync::Mutex<Option<tokio::sync::OwnedSemaphorePermit>>,
}

impl PreparedManagedImport {
    fn release_admission(&self) {
        drop(
            self.retention_permit
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .take(),
        );
    }
}

struct ManagedPublication {
    path: PathBuf,
    remove_on_drop: bool,
}

impl ManagedPublication {
    fn keep(&mut self) {
        self.remove_on_drop = false;
    }
}

impl Drop for ManagedPublication {
    fn drop(&mut self) {
        if self.remove_on_drop {
            let _ = std::fs::remove_file(&self.path);
        }
    }
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
        let _work_permit = acquire_import_work(None).await?;
        let _storage_guard = managed_storage_lock().lock().await;
        let new_dir = new_dir.to_path_buf();
        let create_dir = new_dir.clone();
        tokio::task::spawn_blocking(move || std::fs::create_dir_all(&create_dir))
            .await
            .context("managed library directory task failed")?
            .with_context(|| format!("failed to create {}", new_dir.display()))?;
        let new_dir = canonical_path(&new_dir);

        let rows = sqlx::query(
            "SELECT id, file_path, content_hash FROM books
             WHERE storage_kind = 'managed' ORDER BY id LIMIT ?",
        )
        .bind(MAX_LIBRARY_SNAPSHOT_SIZE as i64 + 1)
        .fetch_all(&self.pool)
        .await
        .context("failed to list managed books for relocation")?;
        if rows.len() > MAX_LIBRARY_SNAPSHOT_SIZE {
            bail!("managed relocation exceeds {MAX_LIBRARY_SNAPSHOT_SIZE} books");
        }
        let mut changes = Vec::with_capacity(rows.len());
        let mut created_destinations = Vec::new();
        let mut destination_hashes = HashMap::with_capacity(rows.len());

        for row in rows {
            let book_id = row.get::<i64, _>("id");
            let old_path = path_from_key(&row.get::<String, _>("file_path"));
            let expected_hash = row.get::<Option<String>, _>("content_hash");
            let extension = old_path
                .extension()
                .map(|extension| extension.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            let format = BookFormat::from_extension(&extension)
                .with_context(|| format!("unsupported managed format: .{extension}"))?;
            let source = old_path.clone();
            let destination_dir = new_dir.clone();
            let relocation =
                tokio::task::spawn_blocking(move || -> Result<(PathBuf, bool, String)> {
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
                    let staged = stage_managed_file(
                        &source,
                        &destination_dir,
                        format.max_input_bytes(),
                        None,
                    )?;
                    publish_managed_file(&staged.path, &destination, &fingerprint.hash)?;
                    Ok((canonical_path(&destination), !existed, fingerprint.hash))
                })
                .await
                .context("managed book relocation task failed");
            let (new_path, created, content_hash) = match relocation {
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
            destination_hashes.insert(book_id, content_hash);
        }

        let database_result = async {
            let mut transaction = self.pool.begin().await?;
            for change in &changes {
                let old_path = canonical_path_key(&change.old_path);
                let new_path = canonical_path_key(&change.new_path);
                let result = sqlx::query(
                    "UPDATE books SET file_path = ?
                     WHERE id = ? AND file_path = ? AND storage_kind = 'managed'",
                )
                    .bind(&new_path)
                    .bind(change.book_id)
                    .bind(&old_path)
                    .execute(&mut *transaction)
                    .await
                    .context("failed to update managed book path")?;
                if result.rows_affected() != 1 {
                    bail!("managed book changed during relocation: {}", change.book_id);
                }
                reconcile_identity(
                    &mut transaction,
                    change.book_id,
                    &old_path,
                    &new_path,
                )
                .await?;
            }
            sqlx::query(
                "INSERT INTO preferences (key, value, updated_at)
                 VALUES (?, ?, datetime('now'))
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            )
            .bind(MANAGED_LIBRARY_DIR_PREFERENCE)
            .bind(canonical_path_key(&new_dir))
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
            if change.old_path == change.new_path {
                continue;
            }
            let reference_count =
                sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM books WHERE file_path = ?")
                    .bind(canonical_path_key(&change.old_path))
                    .fetch_one(&self.pool)
                    .await;
            let reference_count = match reference_count {
                Ok(count) => count,
                Err(error) => {
                    eprintln!(
                        "warning: retained old managed book {} because references could not be checked: {error:#}",
                        change.old_path.display()
                    );
                    continue;
                }
            };
            if reference_count != 0 {
                continue;
            }
            let destination = change.new_path.clone();
            let old_path = change.old_path.clone();
            let expected_hash = destination_hashes.get(&change.book_id).cloned();
            let cleanup = tokio::task::spawn_blocking(move || -> Result<()> {
                let expected_hash = expected_hash.context("missing relocation fingerprint")?;
                let fingerprint = file_fingerprint(&destination)?;
                if fingerprint.hash != expected_hash {
                    bail!("relocated copy does not match its staged content");
                }
                std::fs::remove_file(&old_path).context("failed to remove old managed book")
            })
            .await;
            let error = match cleanup {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(format!("{error:#}")),
                Err(error) => Some(format!("relocation cleanup task failed: {error}")),
            };
            if let Some(error) = error {
                eprintln!(
                    "warning: retained old managed book {}: {error}",
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
        let imported = self.import_file_with_hash(path, None, None, None).await?;
        self.get(imported.book_id())
            .await?
            .context("referenced book not found after import")
    }

    async fn import_file_with_hash(
        &self,
        path: &Path,
        expected_hash: Option<&str>,
        cancellation: Option<&ImportCancellation>,
        commit_started: Option<&AtomicBool>,
    ) -> Result<ImportedBook> {
        // Normalize paths so lookups and progress updates stay consistent.
        let path = canonical_path(path);
        validate_import_path(&path)?;
        let path_str = canonical_path_key(&path);

        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let format = BookFormat::from_extension(&ext)
            .with_context(|| format!("unsupported format: .{ext}"))?;
        let _work_permit = acquire_import_work(cancellation).await?;
        let stage_source = path.clone();
        let stage_dir = self.managed_dir.clone();
        let stage_cancellation = cancellation.cloned();
        let staged = tokio::task::spawn_blocking(move || {
            stage_managed_file(
                &stage_source,
                &stage_dir,
                format.max_input_bytes(),
                stage_cancellation.as_ref(),
            )
        })
        .await
        .context("referenced book staging task failed")??;
        let inspection_path = staged.path.clone();
        let title_path = path.clone();
        let expected_hash = expected_hash.map(str::to_owned);
        let inspection_cancellation = cancellation.cloned();
        let inspection = tokio::task::spawn_blocking(move || {
            inspect_book_cancellable(
                &inspection_path,
                &title_path,
                format,
                expected_hash.as_deref(),
                None,
                inspection_cancellation.as_ref(),
            )
        })
        .await
        .context("metadata extraction task failed")??;
        // Serialize final source verification and identity reconciliation with managed removal,
        // relinking, and relocation. The source may itself be a currently managed path.
        // Acquiring this lock is the commit point. From here the source verification and
        // database mutation run to a definitive result even if cancellation arrives.
        let _storage_guard = acquire_managed_storage(cancellation).await?;
        if let Some(commit_started) = commit_started {
            commit_started.store(true, Ordering::Release);
        }
        let source_path = path.clone();
        let source_file = tokio::task::spawn_blocking(move || {
            fingerprint_file_with_limit(&source_path, Some(format.max_input_bytes()), None)
        })
        .await
        .context("book verification task failed")??;
        if source_file.fingerprint != inspection.fingerprint {
            bail!("file changed during import: {}", path.display());
        }
        // Check if already imported after validating a reviewed file.
        if let Some(book) = self.get_by_path(&path_str).await? {
            if book.content_hash.as_deref() != Some(&source_file.fingerprint.hash) {
                bail!(
                    "file contents no longer match the existing library book: {}",
                    path.display()
                );
            }
            let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
            verify_fingerprinted_path(&path, &source_file, "import")?;
            reconcile_identity(&mut transaction, book.id, &path_str, &path_str).await?;
            transaction.commit().await?;
            return Ok(imported_book_from_commit(
                book.id,
                &path_str,
                &path_str,
                &source_file.fingerprint.hash,
            ));
        }

        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        verify_fingerprinted_path(&path, &source_file, "import")?;
        sqlx::query(
            "INSERT OR IGNORE INTO books
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
        .execute(&mut *transaction)
        .await
        .context("failed to insert book")?;
        let book_id: i64 = sqlx::query_scalar("SELECT id FROM books WHERE file_path = ?")
            .bind(&path_str)
            .fetch_one(&mut *transaction)
            .await
            .context("book not found after insert")?;
        reconcile_identity(&mut transaction, book_id, &path_str, &path_str).await?;
        transaction.commit().await?;
        Ok(imported_book_from_commit(
            book_id,
            &path_str,
            &path_str,
            &source_file.fingerprint.hash,
        ))
    }

    /// Copy a book into Shosai's private data directory and add it to the library.
    pub async fn import_managed_file(&self, source: &Path) -> Result<Book> {
        self.import_managed_file_with_hash(source, None).await
    }

    async fn import_managed_file_with_hash(
        &self,
        source: &Path,
        expected_hash: Option<&str>,
    ) -> Result<Book> {
        let prepared = self
            .prepare_managed_file(source, expected_hash, None)
            .await?;
        self.commit_prepared_managed_file(&prepared).await
    }

    /// Prepare a discovered book for managed import without mutating the library database.
    pub async fn prepare_discovered_managed_file(
        &self,
        candidate: ImportCandidate,
    ) -> Result<PreparedManagedImport> {
        validate_import_candidate(&candidate)?;
        self.prepare_managed_file(&candidate.path, Some(&candidate.content_hash), None)
            .await
    }

    pub async fn prepare_discovered_managed_file_cancellable(
        &self,
        candidate: ImportCandidate,
        cancellation: ImportCancellation,
    ) -> Result<PreparedManagedImport> {
        validate_import_candidate(&candidate)?;
        self.prepare_managed_file(
            &candidate.path,
            Some(&candidate.content_hash),
            Some(&cancellation),
        )
        .await
    }

    async fn prepare_managed_file(
        &self,
        source: &Path,
        expected_hash: Option<&str>,
        cancellation: Option<&ImportCancellation>,
    ) -> Result<PreparedManagedImport> {
        let preparation_permit = acquire_import_work(cancellation).await?;
        let source = canonical_path(source);
        validate_import_path(&source)?;
        let source_str = canonical_path_key(&source);
        let ext = source
            .extension()
            .map(|value| value.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let format = BookFormat::from_extension(&ext)
            .with_context(|| format!("unsupported format: .{ext}"))?;
        let stage_source = source.clone();
        let stage_dir = self.managed_dir.clone();
        let stage_cancellation = cancellation.cloned();
        let staged = tokio::task::spawn_blocking(move || {
            stage_managed_file(
                &stage_source,
                &stage_dir,
                format.max_input_bytes(),
                stage_cancellation.as_ref(),
            )
        })
        .await
        .context("managed book staging task failed")??;
        if cancellation.is_some_and(ImportCancellation::is_cancelled) {
            bail!("managed preparation cancelled");
        }
        let inspection_path = staged.path.clone();
        let title_path = source.clone();
        let expected_hash = expected_hash.map(str::to_owned);
        let inspection_cancellation = cancellation.cloned();
        let inspection = tokio::task::spawn_blocking(move || {
            if inspection_cancellation
                .as_ref()
                .is_some_and(ImportCancellation::is_cancelled)
            {
                bail!("managed preparation cancelled");
            }
            inspect_book_cancellable(
                &inspection_path,
                &title_path,
                format,
                expected_hash.as_deref(),
                None,
                inspection_cancellation.as_ref(),
            )
            .and_then(|inspection| {
                if inspection_cancellation
                    .as_ref()
                    .is_some_and(ImportCancellation::is_cancelled)
                {
                    bail!("managed preparation cancelled");
                }
                Ok(inspection)
            })
        })
        .await
        .context("book inspection task failed")??;

        Ok(PreparedManagedImport {
            source_str,
            extension: ext,
            format,
            staged,
            inspection,
            retention_permit: std::sync::Mutex::new(Some(preparation_permit)),
        })
    }

    /// Publish one prepared private copy and update the library database.
    pub async fn commit_prepared_managed_file(
        &self,
        prepared: &PreparedManagedImport,
    ) -> Result<Book> {
        let imported = self
            .commit_prepared_managed_file_inner(prepared, None, None)
            .await?;
        self.get(imported.book_id())
            .await?
            .context("managed book not found after commit")
    }

    pub async fn commit_prepared_managed_file_cancellable(
        &self,
        prepared: &PreparedManagedImport,
        cancellation: ImportCancellation,
    ) -> ImportCompletion {
        let commit_started = AtomicBool::new(false);
        let result = self
            .commit_prepared_managed_file_inner(
                prepared,
                Some(&cancellation),
                Some(&commit_started),
            )
            .await;
        import_completion(
            path_from_key(&prepared.source_str),
            result,
            &cancellation,
            commit_started.load(Ordering::Acquire),
        )
    }

    async fn commit_prepared_managed_file_inner(
        &self,
        prepared: &PreparedManagedImport,
        cancellation: Option<&ImportCancellation>,
        commit_started: Option<&AtomicBool>,
    ) -> Result<ImportedBook> {
        // Acquiring this lock is the commit point. Publication and the database mutation must
        // finish definitively after this point, even if cancellation arrives.
        let _storage_guard = acquire_managed_storage(cancellation).await?;
        if let Some(commit_started) = commit_started {
            commit_started.store(true, Ordering::Release);
        }
        let PreparedManagedImport {
            source_str,
            extension,
            format,
            staged,
            inspection,
            retention_permit: _,
        } = prepared;

        let destination = self
            .managed_dir
            .join(format!("{}.{extension}", inspection.fingerprint.hash));
        validate_import_path(&destination)?;
        let destination_existed = destination.exists();
        let publish_stage = staged.path.clone();
        let copy_destination = destination.clone();
        let expected_hash = inspection.fingerprint.hash.clone();
        tokio::task::spawn_blocking(move || {
            publish_managed_file(&publish_stage, &copy_destination, &expected_hash)
        })
        .await
        .context("managed book publication task failed")??;
        let mut publication = ManagedPublication {
            path: destination.clone(),
            remove_on_drop: !destination_existed,
        };
        let destination = canonical_path(&destination);
        let destination_str = canonical_path_key(&destination);
        let existing_hash = self.get_by_hash(&inspection.fingerprint.hash).await?;

        if let Some(existing) = &existing_hash
            && existing.storage_kind == StorageKind::Managed
        {
            validate_import_path(&path_from_key(&existing.file_path))?;
            // Repair identity attachment if an earlier attempt committed the book row but was
            // interrupted before reconciliation (or if this source is a newly seen alias).
            let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
            reconcile_identity(
                &mut transaction,
                existing.id,
                source_str,
                &existing.file_path,
            )
            .await?;
            transaction.commit().await?;
            publication.keep();
            prepared.release_admission();
            return Ok(imported_book_from_commit(
                existing.id,
                source_str,
                &existing.file_path,
                &inspection.fingerprint.hash,
            ));
        }

        if let Some(existing) = self.get_by_path(source_str).await?.or(existing_hash) {
            self.update_location(
                existing.id,
                &existing.file_path,
                &destination_str,
                StorageKind::Managed,
                Some(source_str),
                LocationIdentity {
                    fingerprint: &inspection.fingerprint,
                    verified_file: None,
                },
            )
            .await?;
            publication.keep();
            prepared.release_admission();
            return Ok(imported_book_from_commit(
                existing.id,
                source_str,
                &destination_str,
                &inspection.fingerprint.hash,
            ));
        }

        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        sqlx::query(
            "INSERT OR IGNORE INTO books
                (title, author, format, file_path, cover_blob, storage_kind,
                 original_path, content_hash, file_size)
             VALUES (?, ?, ?, ?, ?, 'managed', ?, ?, ?)",
        )
        .bind(&inspection.title)
        .bind(&inspection.author)
        .bind(format.as_str())
        .bind(&destination_str)
        .bind(&inspection.cover)
        .bind(source_str)
        .bind(&inspection.fingerprint.hash)
        .bind(inspection.fingerprint.size as i64)
        .execute(&mut *transaction)
        .await
        .context("failed to insert managed book")?;
        let book_id: i64 = sqlx::query_scalar(
            "SELECT id FROM books WHERE file_path = ? OR content_hash = ?
             ORDER BY storage_kind = 'managed' DESC, id ASC LIMIT 1",
        )
        .bind(&destination_str)
        .bind(&inspection.fingerprint.hash)
        .fetch_one(&mut *transaction)
        .await
        .context("managed book not found after insert")?;
        reconcile_identity(&mut transaction, book_id, source_str, &destination_str).await?;
        transaction.commit().await?;
        publication.keep();
        prepared.release_admission();
        Ok(imported_book_from_commit(
            book_id,
            source_str,
            &destination_str,
            &inspection.fingerprint.hash,
        ))
    }

    /// Relink a missing referenced book while preserving its stable identity and reader data.
    pub async fn relink(&self, book_id: i64, replacement: &Path) -> Result<Book> {
        let _work_permit = acquire_import_work(None).await?;
        let _storage_guard = managed_storage_lock().lock().await;
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
        let stage_source = replacement.clone();
        let stage_dir = self.managed_dir.clone();
        let format = book.format;
        let staged = tokio::task::spawn_blocking(move || {
            stage_managed_file(&stage_source, &stage_dir, format.max_input_bytes(), None)
        })
        .await
        .context("replacement staging task failed")??;
        let fingerprint_path = staged.path.clone();
        let fingerprint = tokio::task::spawn_blocking(move || file_fingerprint(&fingerprint_path))
            .await
            .context("book fingerprint task failed")??;
        let Some(expected) = &book.content_hash else {
            bail!("cannot verify this legacy book; remove it and import it again");
        };
        if expected != &fingerprint.hash {
            bail!("selected file does not match this book");
        }
        let source_path = replacement.clone();
        let source_file = tokio::task::spawn_blocking(move || {
            fingerprint_file_with_limit(&source_path, Some(format.max_input_bytes()), None)
        })
        .await
        .context("replacement verification task failed")??;
        if source_file.fingerprint != fingerprint {
            bail!("selected file changed during relink");
        }
        let replacement_str = canonical_path_key(&replacement);
        self.update_location(
            book.id,
            &book.file_path,
            &replacement_str,
            StorageKind::Referenced,
            Some(&replacement_str),
            LocationIdentity {
                fingerprint: &fingerprint,
                verified_file: Some((&replacement, &source_file)),
            },
        )
        .await?;
        self.get(book.id)
            .await?
            .context("book not found after relink")
    }

    /// Copy a list of book files into Shosai, continuing after individual failures.
    pub async fn import_files(&self, paths: &[PathBuf]) -> ImportReport {
        self.add_files(paths, true).await
    }

    /// Link a list of book files in place, continuing after individual failures.
    pub async fn link_files(&self, paths: &[PathBuf]) -> ImportReport {
        self.add_files(paths, false).await
    }

    /// Copy candidates after verifying that they still match their discovery fingerprints.
    pub async fn import_discovered_files(&self, candidates: &[ImportCandidate]) -> ImportReport {
        self.add_discovered_files(candidates, true).await
    }

    /// Link candidates after verifying that they still match their discovery fingerprints.
    pub async fn link_discovered_files(&self, candidates: &[ImportCandidate]) -> ImportReport {
        self.add_discovered_files(candidates, false).await
    }

    /// Link one reviewed candidate, checking cancellation through preparation.
    pub async fn link_discovered_file_cancellable(
        &self,
        candidate: ImportCandidate,
        cancellation: ImportCancellation,
    ) -> ImportCompletion {
        if let Err(error) = validate_import_candidate(&candidate) {
            return ImportCompletion::Completed(Err(ImportFailure::new(
                candidate.path,
                format!("{error:#}"),
            )));
        }
        let content_hash = candidate.content_hash;
        let source_path = candidate.path;
        let commit_started = AtomicBool::new(false);
        let result = self
            .import_file_with_hash(
                &source_path,
                Some(&content_hash),
                Some(&cancellation),
                Some(&commit_started),
            )
            .await;
        import_completion(
            source_path,
            result,
            &cancellation,
            commit_started.load(Ordering::Acquire),
        )
    }

    async fn add_discovered_files(
        &self,
        candidates: &[ImportCandidate],
        managed: bool,
    ) -> ImportReport {
        let mut report = ImportReport::default();
        for candidate in candidates.iter().take(MAX_IMPORT_DISCOVERY_RESULTS) {
            if let Err(error) = validate_import_candidate(candidate) {
                report.record(candidate.path.clone(), Err(error));
                continue;
            }
            let result: Result<ImportedBook> = if managed {
                self.import_managed_file_with_hash(&candidate.path, Some(&candidate.content_hash))
                    .await
                    .map(|book| ImportedBook::from_book(candidate.path.clone(), &book))
            } else {
                self.import_file_with_hash(
                    &candidate.path,
                    Some(&candidate.content_hash),
                    None,
                    None,
                )
                .await
            };
            match result {
                Ok(imported) => report.record_success(imported),
                Err(error) => report.record_failure(ImportFailure::new(
                    candidate.path.clone(),
                    format!("{error:#}"),
                )),
            }
        }
        if candidates.len() > MAX_IMPORT_DISCOVERY_RESULTS {
            report.record_failure(ImportFailure::new(
                PathBuf::new(),
                format!(
                    "too many discovered import candidates (maximum {MAX_IMPORT_DISCOVERY_RESULTS})"
                ),
            ));
        }
        report
    }

    /// Inspect selected files before importing anything.
    pub async fn discover_files(&self, paths: &[PathBuf]) -> ImportDiscovery {
        self.discover(
            paths.to_vec(),
            false,
            ImportCancellation::default(),
            ImportDiscoveryProgress::default(),
        )
        .await
    }

    /// Recursively inspect a directory before importing anything.
    pub async fn discover_directory(&self, dir: &Path) -> ImportDiscovery {
        self.discover(
            vec![dir.to_path_buf()],
            true,
            ImportCancellation::default(),
            ImportDiscoveryProgress::default(),
        )
        .await
    }

    pub async fn discover_files_cancellable(
        &self,
        paths: Vec<PathBuf>,
        cancellation: ImportCancellation,
    ) -> ImportDiscovery {
        self.discover(
            paths,
            false,
            cancellation,
            ImportDiscoveryProgress::default(),
        )
        .await
    }

    pub async fn discover_directory_cancellable(
        &self,
        dir: PathBuf,
        cancellation: ImportCancellation,
    ) -> ImportDiscovery {
        self.discover(
            vec![dir],
            true,
            cancellation,
            ImportDiscoveryProgress::default(),
        )
        .await
    }

    pub async fn discover_files_with_progress(
        &self,
        paths: Vec<PathBuf>,
        cancellation: ImportCancellation,
        progress: ImportDiscoveryProgress,
    ) -> ImportDiscovery {
        self.discover(paths, false, cancellation, progress).await
    }

    pub async fn discover_directory_with_progress(
        &self,
        dir: PathBuf,
        cancellation: ImportCancellation,
        progress: ImportDiscoveryProgress,
    ) -> ImportDiscovery {
        self.discover(vec![dir], true, cancellation, progress).await
    }

    async fn discover(
        &self,
        roots: Vec<PathBuf>,
        recursive: bool,
        cancellation: ImportCancellation,
        progress: ImportDiscoveryProgress,
    ) -> ImportDiscovery {
        if roots.len() > MAX_IMPORT_ROOTS {
            return ImportDiscovery {
                failures: vec![ImportFailure {
                    path: PathBuf::new(),
                    error: format!("too many import roots (maximum {MAX_IMPORT_ROOTS})"),
                }],
                ..ImportDiscovery::default()
            };
        }
        let Some(scan_permit) = acquire_scanner(&cancellation).await else {
            return ImportDiscovery::default();
        };
        let (scan_sender, mut scan_receiver) = tokio::sync::mpsc::channel(16);
        let scan_cancellation = cancellation.clone();
        let scan_progress = progress.clone();
        let scan_task = tokio::task::spawn_blocking(move || {
            let _scan_permit = scan_permit;
            scan_import_candidates(
                roots,
                recursive,
                &scan_cancellation,
                &scan_progress,
                &scan_sender,
            );
        });
        let mut fingerprint_tasks = tokio::task::JoinSet::new();
        let mut fingerprinted = Vec::new();
        let mut discovery = ImportDiscovery::default();
        let mut scanning = true;
        let mut received_results = 0_usize;

        while scanning || !fingerprint_tasks.is_empty() {
            if cancellation.is_cancelled() {
                fingerprint_tasks.abort_all();
                scanning = false;
                scan_receiver.close();
            }

            if fingerprint_tasks.len() >= DISCOVERY_HASH_CONCURRENCY || !scanning {
                if let Some(result) = fingerprint_tasks.join_next().await {
                    collect_fingerprint_result(
                        result,
                        &progress,
                        &mut fingerprinted,
                        &mut discovery.failures,
                    );
                }
                continue;
            }

            if fingerprint_tasks.is_empty() {
                match scan_receiver.recv().await {
                    Some(_item) if received_results >= MAX_IMPORT_DISCOVERY_RESULTS => {
                        scan_receiver.close();
                        scanning = false;
                        discovery.failures.push(ImportFailure {
                            path: PathBuf::new(),
                            error: format!(
                                "book discovery stopped after {MAX_IMPORT_DISCOVERY_RESULTS} results"
                            ),
                        });
                    }
                    Some(ScannedImport::Candidate(candidate)) => {
                        received_results += 1;
                        spawn_candidate_fingerprint(
                            &mut fingerprint_tasks,
                            candidate,
                            cancellation.clone(),
                        );
                    }
                    Some(ScannedImport::Failure(failure)) => {
                        received_results += 1;
                        discovery.failures.push(failure);
                    }
                    None => scanning = false,
                }
                continue;
            }

            tokio::select! {
                item = scan_receiver.recv() => match item {
                    Some(_) if received_results >= MAX_IMPORT_DISCOVERY_RESULTS => {
                        scan_receiver.close();
                        scanning = false;
                        discovery.failures.push(ImportFailure {
                            path: PathBuf::new(),
                            error: format!(
                                "book discovery stopped after {MAX_IMPORT_DISCOVERY_RESULTS} results"
                            ),
                        });
                    }
                    Some(ScannedImport::Candidate(candidate)) => {
                        received_results += 1;
                        spawn_candidate_fingerprint(
                            &mut fingerprint_tasks,
                            candidate,
                            cancellation.clone(),
                        );
                    }
                    Some(ScannedImport::Failure(failure)) => {
                        received_results += 1;
                        discovery.failures.push(failure);
                    }
                    None => scanning = false,
                },
                result = fingerprint_tasks.join_next() => {
                    if let Some(result) = result {
                        collect_fingerprint_result(
                            result,
                            &progress,
                            &mut fingerprinted,
                            &mut discovery.failures,
                        );
                    }
                }
            }
        }

        // `abort_all` cannot stop blocking tasks. Drain them so global admission remains charged
        // until the underlying reads have actually observed cancellation and returned.
        while let Some(result) = fingerprint_tasks.join_next().await {
            collect_fingerprint_result(
                result,
                &progress,
                &mut fingerprinted,
                &mut discovery.failures,
            );
        }
        if let Err(error) = scan_task.await {
            discovery.failures.push(ImportFailure {
                path: PathBuf::new(),
                error: format!("book discovery task failed: {error}"),
            });
        }

        fingerprinted.sort_by(|left, right| left.0.path.cmp(&right.0.path));
        discovery.candidates.reserve(fingerprinted.len());
        let mut selected_hashes = HashMap::<String, PathBuf>::new();

        for (candidate, fingerprint) in fingerprinted {
            if cancellation.is_cancelled() {
                break;
            }
            let fingerprint = match fingerprint {
                Ok(fingerprint) => fingerprint,
                Err(error) => {
                    discovery.failures.push(ImportFailure {
                        path: candidate.path,
                        error,
                    });
                    progress.completed_file();
                    continue;
                }
            };
            let path_key = canonical_path_key(&candidate.path);
            let existing = match self.get_by_path(&path_key).await {
                Ok(Some(book)) => Ok(Some(book)),
                Ok(None) => self.get_by_hash(&fingerprint.hash).await,
                Err(error) => Err(error),
            };
            let existing = match existing {
                Ok(existing) => existing,
                Err(error) => {
                    discovery.failures.push(ImportFailure {
                        path: candidate.path,
                        error: format!("failed to check the library: {error:#}"),
                    });
                    progress.completed_file();
                    continue;
                }
            };
            let duplicate = existing.map_or_else(
                || {
                    selected_hashes
                        .get(&fingerprint.hash)
                        .cloned()
                        .map(|path| ImportDuplicate::SelectedFile { path })
                },
                |book| {
                    Some(ImportDuplicate::ExistingBook {
                        book_id: book.id,
                        title: book.title,
                    })
                },
            );
            selected_hashes
                .entry(fingerprint.hash.clone())
                .or_insert_with(|| candidate.path.clone());
            discovery.candidates.push(ImportCandidate {
                title: filename_title(&candidate.path),
                group_key: import_group_key(&candidate.path),
                path: candidate.path,
                format: candidate.format,
                file_size: fingerprint.size,
                content_hash: fingerprint.hash,
                duplicate,
            });
            progress.completed_file();
        }
        discovery.candidates.sort_by(|left, right| {
            left.group_key
                .cmp(&right.group_key)
                .then_with(|| left.path.cmp(&right.path))
        });
        discovery.failures.sort_by(|left, right| {
            left.path
                .cmp(&right.path)
                .then_with(|| left.error.cmp(&right.error))
        });
        discovery
    }

    async fn add_files(&self, paths: &[PathBuf], managed: bool) -> ImportReport {
        let mut report = ImportReport::default();
        for path in paths.iter().take(MAX_IMPORT_ROOTS) {
            let result = if managed {
                self.import_managed_file(path).await
            } else {
                self.import_file(path).await
            };
            report.record(path.clone(), result);
        }
        if paths.len() > MAX_IMPORT_ROOTS {
            report.record_failure(ImportFailure::new(
                PathBuf::new(),
                format!("too many import roots (maximum {MAX_IMPORT_ROOTS})"),
            ));
        }
        report
    }

    /// Import all supported files from a directory recursively.
    pub async fn import_directory(&self, dir: &Path) -> ImportReport {
        self.add_directory(dir, true).await
    }

    /// Add all supported files from a directory without copying them recursively.
    pub async fn link_directory(&self, dir: &Path) -> ImportReport {
        self.add_directory(dir, false).await
    }

    async fn add_directory(&self, dir: &Path, managed: bool) -> ImportReport {
        let discovery = self.discover_directory(dir).await;
        let mut report = self
            .add_discovered_files(&discovery.candidates, managed)
            .await;
        for failure in discovery.failures {
            report.record_failure(failure);
        }
        report
    }

    /// List all books, ordered by most recently read first, then by date added.
    pub async fn list_all(&self) -> Result<Vec<Book>> {
        let page = self.page(None, None, MAX_LIBRARY_PAGE_SIZE, 0).await?;
        if page.has_more {
            bail!("library contains more than {MAX_LIBRARY_PAGE_SIZE} books; use page()");
        }
        Ok(page.books)
    }

    /// Search books by title or author.
    pub async fn search(&self, query: &str) -> Result<Vec<Book>> {
        let page = self
            .page(Some(query), None, MAX_LIBRARY_PAGE_SIZE, 0)
            .await?;
        if page.has_more {
            bail!("library search exceeds {MAX_LIBRARY_PAGE_SIZE} books; use page()");
        }
        Ok(page.books)
    }

    /// Filter books by format.
    pub async fn filter_by_format(&self, format: BookFormat) -> Result<Vec<Book>> {
        let page = self
            .page(None, Some(format), MAX_LIBRARY_PAGE_SIZE, 0)
            .await?;
        if page.has_more {
            bail!("library filter exceeds {MAX_LIBRARY_PAGE_SIZE} books; use page()");
        }
        Ok(page.books)
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
        if query.is_some_and(|query| query.len() > MAX_LIBRARY_QUERY_BYTES) {
            bail!("library query exceeds {MAX_LIBRARY_QUERY_BYTES} bytes");
        }
        let limit = limit.clamp(1, MAX_LIBRARY_PAGE_SIZE);
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
        if query.is_some_and(|query| query.len() > MAX_LIBRARY_QUERY_BYTES) {
            bail!("library query exceeds {MAX_LIBRARY_QUERY_BYTES} bytes");
        }
        let mut builder = QueryBuilder::new("SELECT id FROM books");
        push_library_filters(&mut builder, query, format);
        builder.push(" ORDER BY last_read DESC NULLS LAST, date_added DESC, id DESC LIMIT ");
        builder.push_bind(MAX_LIBRARY_SNAPSHOT_SIZE as i64 + 1);

        let rows = builder
            .build()
            .fetch_all(&self.pool)
            .await
            .context("failed to snapshot library order")?;
        let ids = rows
            .iter()
            .filter_map(|row| row.try_get("id").ok())
            .collect::<Vec<_>>();
        if ids.len() > MAX_LIBRARY_SNAPSHOT_SIZE {
            bail!("library snapshot exceeds {MAX_LIBRARY_SNAPSHOT_SIZE} books");
        }
        Ok(ids)
    }

    /// Load books from a previously captured ordered ID snapshot.
    pub async fn books_by_ids(&self, ids: &[i64]) -> Result<Vec<Book>> {
        if ids.len() > MAX_LIBRARY_SNAPSHOT_SIZE {
            bail!("library snapshot exceeds {MAX_LIBRARY_SNAPSHOT_SIZE} books");
        }
        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut books_by_id = HashMap::new();
        for chunk in ids.chunks(SQLITE_ID_CHUNK_SIZE) {
            let mut builder = QueryBuilder::new(
                "SELECT id, title, author, format, file_path, storage_kind, original_path, \
                 content_hash, file_size, cover_blob, progress, \
                 date_added, last_read FROM books WHERE id IN (",
            );
            let mut separated = builder.separated(", ");
            for id in chunk {
                separated.push_bind(id);
            }
            separated.push_unseparated(")");
            let rows = builder
                .build()
                .fetch_all(&self.pool)
                .await
                .context("failed to load books from library snapshot")?;
            books_by_id.extend(
                rows.iter()
                    .filter_map(row_to_book)
                    .map(|book| (book.id, book)),
            );
        }

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
        let key = canonical_path_key(path);

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
        let _storage_guard = managed_storage_lock().lock().await;
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
             FROM books WHERE content_hash = ?
             ORDER BY storage_kind = 'managed' DESC, id ASC LIMIT 1",
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
        identity: LocationIdentity<'_>,
    ) -> Result<()> {
        let mut transaction = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some((path, file)) = identity.verified_file {
            verify_fingerprinted_path(path, file, "location update")?;
        }
        sqlx::query(
            "UPDATE books SET file_path = ?, storage_kind = ?, original_path = ?,
                              content_hash = ?, file_size = ? WHERE id = ?",
        )
        .bind(new_path)
        .bind(storage_kind.as_str())
        .bind(original_path)
        .bind(&identity.fingerprint.hash)
        .bind(identity.fingerprint.size as i64)
        .bind(book_id)
        .execute(&mut *transaction)
        .await
        .context("failed to update book location")?;
        reconcile_identity(&mut transaction, book_id, old_path, new_path).await?;
        transaction.commit().await?;
        Ok(())
    }

    /// Open the current bytes for a stable library identity after verifying its stored hash.
    pub async fn open_book_document_at(&self, book_id: i64, path: &Path) -> Result<OpenDocument> {
        let plan = OpenDocumentPlan::prepare(&DeviceFileLocator::from_path(path))?;
        self.open_book_document_with_plan(book_id, path, plan)
            .await
            .map(|(document, _)| document)
    }

    #[doc(hidden)]
    pub async fn open_book_document_with_plan(
        &self,
        book_id: i64,
        path: &Path,
        plan: OpenDocumentPlan,
    ) -> Result<(OpenDocument, String)> {
        let book = self
            .get(book_id)
            .await?
            .with_context(|| format!("book {book_id} not found"))?;
        let requested_path = canonical_path(path);
        if canonical_path_key(&requested_path) != book.file_path {
            bail!("book location changed before it could be opened");
        }
        let expected_hash = book
            .content_hash
            .context("cannot verify this legacy book; remove it and import it again")?;
        let format = book.format;
        if plan.format() != format {
            bail!("book format no longer matches the library identity");
        }
        tokio::task::spawn_blocking(move || {
            let admitted = plan.read_bytes()?;
            let actual_hash = format!("{:x}", Sha256::digest(&admitted.data));
            if actual_hash != expected_hash {
                bail!("book contents no longer match the library identity");
            }
            let document = OpenDocument::from_admitted_bytes(admitted)?;
            Ok((document, actual_hash))
        })
        .await
        .context("book open task failed")?
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
        let path = path_from_key(file_path);
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
    let content_hash: String = sqlx::query_scalar("SELECT content_hash FROM books WHERE id = ?")
        .bind(book_id)
        .fetch_optional(&mut **transaction)
        .await
        .context("failed to resolve book content identity")?
        .context("book has no stable content hash")?;
    let reading = sqlx::query(
        "SELECT page, location_offset, zoom, updated_at, revision
         FROM reading_state
         WHERE book_id = ?
            OR (book_id IS NULL AND content_hash = ? AND (file_path = ? OR file_path = ?))
         ORDER BY revision DESC LIMIT 1",
    )
    .bind(book_id)
    .bind(&content_hash)
    .bind(old_path)
    .bind(new_path)
    .fetch_optional(&mut **transaction)
    .await
    .context("failed to select reading state aliases")?;
    sqlx::query(
        "DELETE FROM reading_state
         WHERE book_id = ?
            OR (book_id IS NULL AND content_hash = ? AND (file_path = ? OR file_path = ?))",
    )
    .bind(book_id)
    .bind(&content_hash)
    .bind(old_path)
    .bind(new_path)
    .execute(&mut **transaction)
    .await
    .context("failed to remove reading state aliases")?;
    if let Some(reading) = reading {
        sqlx::query(
            "INSERT INTO reading_state
                (file_path, content_hash, book_id, page, location_offset, zoom, updated_at, revision)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(new_path)
        .bind(&content_hash)
        .bind(book_id)
        .bind(reading.get::<i64, _>("page"))
        .bind(reading.get::<Option<i64>, _>("location_offset"))
        .bind(reading.get::<f64, _>("zoom"))
        .bind(reading.get::<String, _>("updated_at"))
        .bind(reading.get::<i64, _>("revision"))
        .execute(&mut **transaction)
        .await
        .context("failed to merge reading state aliases")?;
    }

    // Keep an existing stable-ID row (and therefore any UI edit target) while copying the
    // newest duplicate's user-visible metadata onto it.
    sqlx::query(
        "UPDATE bookmarks AS stable
         SET (title, color, created_at) = (
           SELECT candidate.title, candidate.color, candidate.created_at
           FROM bookmarks AS candidate
           WHERE (candidate.book_id = ?
                  OR (candidate.book_id IS NULL AND candidate.content_hash = ?
                      AND (candidate.file_path = ? OR candidate.file_path = ?)))
             AND candidate.page = stable.page
             AND candidate.location_offset IS stable.location_offset
             AND candidate.note IS stable.note
           ORDER BY candidate.created_at DESC, candidate.id DESC LIMIT 1
         )
         WHERE stable.book_id = ?",
    )
    .bind(book_id)
    .bind(&content_hash)
    .bind(old_path)
    .bind(new_path)
    .bind(book_id)
    .execute(&mut **transaction)
    .await
    .context("failed to preserve stable bookmark aliases")?;
    sqlx::query(
        "DELETE FROM bookmarks
         WHERE (book_id = ?
                OR (book_id IS NULL AND content_hash = ? AND (file_path = ? OR file_path = ?)))
           AND id NOT IN (
             SELECT id FROM (
               SELECT id, ROW_NUMBER() OVER (
                 PARTITION BY page, location_offset, note
                 ORDER BY (book_id = ?) DESC, created_at DESC, id DESC
               ) AS rank
               FROM bookmarks
               WHERE book_id = ?
                  OR (book_id IS NULL AND content_hash = ? AND (file_path = ? OR file_path = ?))
             ) WHERE rank = 1
           )",
    )
    .bind(book_id)
    .bind(&content_hash)
    .bind(old_path)
    .bind(new_path)
    .bind(book_id)
    .bind(book_id)
    .bind(&content_hash)
    .bind(old_path)
    .bind(new_path)
    .execute(&mut **transaction)
    .await
    .context("failed to deduplicate bookmark aliases")?;
    sqlx::query(
        "UPDATE bookmarks SET file_path = ?, content_hash = ?, book_id = ?
         WHERE book_id = ?
            OR (book_id IS NULL AND content_hash = ? AND (file_path = ? OR file_path = ?))",
    )
    .bind(new_path)
    .bind(&content_hash)
    .bind(book_id)
    .bind(book_id)
    .bind(&content_hash)
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
    cancellation: Option<&ImportCancellation>,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    check_import_cancelled(cancellation)?;
    match format {
        BookFormat::Pdf => extract_pdf_metadata(path, title_path, cancellation),
        BookFormat::Epub => extract_epub_metadata(path, title_path, cancellation),
        BookFormat::Cbz => extract_cbz_metadata(path, title_path, cancellation),
    }
}

fn inspect_book_cancellable(
    path: &Path,
    title_path: &Path,
    format: BookFormat,
    expected_hash: Option<&str>,
    initial_fingerprint: Option<FileFingerprint>,
    cancellation: Option<&ImportCancellation>,
) -> Result<BookInspection> {
    inspect_book_with(
        path,
        title_path,
        expected_hash,
        initial_fingerprint,
        || extract_metadata_and_cover(path, title_path, format, cancellation),
        |path| file_fingerprint_cancellable(path, cancellation),
    )
}

fn inspect_book_with(
    path: &Path,
    title_path: &Path,
    expected_hash: Option<&str>,
    initial_fingerprint: Option<FileFingerprint>,
    extract: impl FnOnce() -> Result<(String, Option<String>, Option<Vec<u8>>)>,
    mut fingerprint: impl FnMut(&Path) -> Result<FileFingerprint>,
) -> Result<BookInspection> {
    let before = match (initial_fingerprint, expected_hash) {
        (Some(fingerprint), _) => Some(fingerprint),
        (None, Some(_)) => Some(fingerprint(path)?),
        (None, None) => None,
    };
    if let (Some(expected_hash), Some(before)) = (expected_hash, &before)
        && before.hash != expected_hash
    {
        bail!("file changed after review: {}", title_path.display());
    }
    let (title, author, cover) = extract()?;
    if title.len() > MAX_IMPORT_METADATA_BYTES
        || author
            .as_ref()
            .is_some_and(|author| author.len() > MAX_IMPORT_METADATA_BYTES)
    {
        bail!("book title or author exceeds import metadata byte limits");
    }
    if cover
        .as_ref()
        .is_some_and(|cover| cover.len() > MAX_IMPORT_COVER_BYTES)
    {
        bail!("book cover exceeds import retained byte limit");
    }
    let fingerprint = fingerprint(path)?;
    if before.as_ref().is_some_and(|before| before != &fingerprint) {
        bail!("file changed after review: {}", title_path.display());
    }
    Ok(BookInspection {
        title,
        author,
        cover,
        fingerprint,
    })
}

fn file_fingerprint(path: &Path) -> Result<FileFingerprint> {
    file_fingerprint_cancellable(path, None)
}

fn file_fingerprint_cancellable(
    path: &Path,
    cancellation: Option<&ImportCancellation>,
) -> Result<FileFingerprint> {
    let max_input_bytes = path
        .extension()
        .and_then(|extension| extension.to_str())
        .and_then(BookFormat::from_extension)
        .map(BookFormat::max_input_bytes);
    file_fingerprint_with_limit(path, max_input_bytes, cancellation)
}

fn file_fingerprint_with_limit(
    path: &Path,
    max_input_bytes: Option<u64>,
    cancellation: Option<&ImportCancellation>,
) -> Result<FileFingerprint> {
    Ok(fingerprint_file_with_limit(path, max_input_bytes, cancellation)?.fingerprint)
}

fn fingerprint_file_with_limit(
    path: &Path,
    max_input_bytes: Option<u64>,
    cancellation: Option<&ImportCancellation>,
) -> Result<FingerprintedFile> {
    if cancellation.is_some_and(ImportCancellation::is_cancelled) {
        bail!("discovery cancelled");
    }
    let mut file = open_fingerprint_file(path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    // Derive both the bound and expected byte count from the opened descriptor, not a path that
    // can be replaced between metadata and open.
    let before = file.metadata()?;
    let file_size = before.len();
    if let Some(max_input_bytes) = max_input_bytes
        && file_size > max_input_bytes
    {
        bail!("book input is larger than {max_input_bytes} bytes");
    }
    let fingerprint = fingerprint_reader(
        std::io::Read::take(&mut file, file_size.saturating_add(1)),
        file_size,
        cancellation,
    )?;
    let after = file.metadata()?;
    let before_version = file_version(&before);
    let after_version = file_version(&after);
    if after_version != before_version {
        bail!("file changed while fingerprinting: {}", path.display());
    }
    Ok(FingerprintedFile {
        fingerprint,
        handle: same_file::Handle::from_file(file)?,
        version: after_version,
    })
}

fn verify_fingerprinted_path(path: &Path, file: &FingerprintedFile, operation: &str) -> Result<()> {
    let current = open_fingerprint_file(path)
        .with_context(|| format!("failed to verify {} during {operation}", path.display()))?;
    let version = file_version(
        &current
            .metadata()
            .with_context(|| format!("failed to inspect {} during {operation}", path.display()))?,
    );
    let handle = same_file::Handle::from_file(current)
        .with_context(|| format!("failed to verify {} during {operation}", path.display()))?;
    if handle != file.handle || version != file.version {
        bail!("file changed during {operation}: {}", path.display());
    }
    Ok(())
}

#[cfg(not(windows))]
fn open_fingerprint_file(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::File::open(path)
}

#[cfg(windows)]
fn open_fingerprint_file(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_SHARE_READ: u32 = 0x0000_0001;
    std::fs::OpenOptions::new()
        .read(true)
        // Retain a handle which prevents replacement or mutation between the
        // expensive hash and the database transaction.
        .share_mode(FILE_SHARE_READ)
        .open(path)
}

#[cfg(unix)]
fn file_version(metadata: &std::fs::Metadata) -> FileVersion {
    use std::os::unix::fs::MetadataExt;

    FileVersion {
        device: metadata.dev(),
        inode: metadata.ino(),
        len: metadata.len(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
    }
}

#[cfg(windows)]
fn file_version(metadata: &std::fs::Metadata) -> FileVersion {
    use std::os::windows::fs::MetadataExt;

    FileVersion {
        len: metadata.file_size(),
        creation_time: metadata.creation_time(),
        last_write_time: metadata.last_write_time(),
    }
}

#[cfg(not(any(unix, windows)))]
fn file_version(metadata: &std::fs::Metadata) -> FileVersion {
    FileVersion {
        len: metadata.len(),
        modified: metadata.modified().ok(),
    }
}

fn fingerprint_reader(
    mut reader: impl std::io::Read,
    file_size: u64,
    cancellation: Option<&ImportCancellation>,
) -> Result<FileFingerprint> {
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    let mut actual_size = 0_u64;
    loop {
        if cancellation.is_some_and(ImportCancellation::is_cancelled) {
            bail!("discovery cancelled");
        }
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        actual_size = actual_size.saturating_add(read as u64);
        if actual_size > file_size {
            bail!("file grew while fingerprinting");
        }
        hasher.update(&buffer[..read]);
    }
    if actual_size != file_size {
        bail!("file size changed while fingerprinting (expected {file_size}, read {actual_size})");
    }
    Ok(FileFingerprint {
        hash: format!("{:x}", hasher.finalize()),
        size: file_size,
    })
}

struct PendingImportCandidate {
    path: PathBuf,
    format: BookFormat,
}

enum ScannedImport {
    Candidate(PendingImportCandidate),
    Failure(ImportFailure),
}

enum ScanCursor {
    Path(PathBuf),
    Directory(PathBuf, std::fs::ReadDir),
}

fn spawn_candidate_fingerprint(
    tasks: &mut tokio::task::JoinSet<(PendingImportCandidate, Result<FileFingerprint>)>,
    candidate: PendingImportCandidate,
    cancellation: ImportCancellation,
) {
    let path = candidate.path.clone();
    let admission = fingerprint_admission().clone();
    tasks.spawn(async move {
        let permit = tokio::select! {
            permit = admission.acquire_owned() => {
                permit.expect("fingerprint semaphore closed")
            }
            () = cancellation.cancelled() => return (
                candidate,
                Err(anyhow::anyhow!("discovery cancelled")),
            ),
        };
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let fingerprint = file_fingerprint_cancellable(&path, Some(&cancellation));
            (candidate, fingerprint)
        })
        .await
        .unwrap_or_else(|error| panic!("fingerprint blocking task failed: {error}"))
    });
}

fn collect_fingerprint_result(
    result: std::result::Result<
        (PendingImportCandidate, Result<FileFingerprint>),
        tokio::task::JoinError,
    >,
    progress: &ImportDiscoveryProgress,
    fingerprinted: &mut Vec<(
        PendingImportCandidate,
        std::result::Result<FileFingerprint, String>,
    )>,
    failures: &mut Vec<ImportFailure>,
) {
    match result {
        Ok((candidate, result)) => {
            progress.hashed_file();
            fingerprinted.push((candidate, result.map_err(|error| format!("{error:#}"))));
        }
        Err(error) => {
            progress.hashed_file();
            progress.completed_file();
            failures.push(ImportFailure {
                path: PathBuf::new(),
                error: format!("book fingerprint task failed: {error}"),
            });
        }
    }
}

fn scan_import_candidates(
    roots: Vec<PathBuf>,
    recursive: bool,
    cancellation: &ImportCancellation,
    progress: &ImportDiscoveryProgress,
    sender: &tokio::sync::mpsc::Sender<ScannedImport>,
) {
    let mut pending = roots
        .into_iter()
        .rev()
        .map(ScanCursor::Path)
        .collect::<Vec<_>>();
    let mut visited_dirs = HashSet::new();
    let mut traversal_entries = 0_usize;

    while let Some(cursor) = pending.pop() {
        if cancellation.is_cancelled() {
            break;
        }
        traversal_entries += 1;
        if traversal_entries > MAX_IMPORT_TRAVERSAL_ENTRIES {
            let _ = sender.blocking_send(ScannedImport::Failure(ImportFailure {
                path: PathBuf::new(),
                error: format!(
                    "book discovery stopped after {MAX_IMPORT_TRAVERSAL_ENTRIES} filesystem entries"
                ),
            }));
            break;
        }
        let original_path = match cursor {
            ScanCursor::Path(path) => path,
            ScanCursor::Directory(path, mut entries) => {
                match entries.next() {
                    Some(Ok(entry)) => {
                        pending.push(ScanCursor::Directory(path, entries));
                        pending.push(ScanCursor::Path(entry.path()));
                    }
                    Some(Err(error)) => {
                        pending.push(ScanCursor::Directory(path.clone(), entries));
                        if sender
                            .blocking_send(ScannedImport::Failure(ImportFailure {
                                path: path.clone(),
                                error: format!(
                                    "failed to read an entry in {}: {error}",
                                    path.display()
                                ),
                            }))
                            .is_err()
                        {
                            break;
                        }
                    }
                    None => {}
                }
                continue;
            }
        };
        let path = canonical_path(&original_path);
        let metadata = match std::fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                let extension = path
                    .extension()
                    .map(|extension| extension.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                if (!recursive || BookFormat::from_extension(&extension).is_some())
                    && sender
                        .blocking_send(ScannedImport::Failure(ImportFailure {
                            path,
                            error: format!(
                                "failed to inspect {}: {error}",
                                original_path.display()
                            ),
                        }))
                        .is_err()
                {
                    break;
                }
                continue;
            }
        };
        if recursive && metadata.is_dir() {
            if !visited_dirs.insert(path.clone()) {
                continue;
            }
            match std::fs::read_dir(&path) {
                Ok(entries) => pending.push(ScanCursor::Directory(path, entries)),
                Err(error) => {
                    if sender
                        .blocking_send(ScannedImport::Failure(ImportFailure {
                            path: path.clone(),
                            error: format!("failed to read directory {}: {error}", path.display()),
                        }))
                        .is_err()
                    {
                        break;
                    }
                }
            }
            continue;
        }
        if !metadata.is_file() {
            continue;
        }

        let extension = path
            .extension()
            .map(|extension| extension.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let Some(format) = BookFormat::from_extension(&extension) else {
            if !recursive
                && sender
                    .blocking_send(ScannedImport::Failure(ImportFailure {
                        path,
                        error: format!("unsupported format: .{extension}"),
                    }))
                    .is_err()
            {
                break;
            }
            continue;
        };
        progress.found_file();
        if metadata.len() > format.max_input_bytes() {
            progress.completed_file();
            if sender
                .blocking_send(ScannedImport::Failure(ImportFailure {
                    path,
                    error: format!(
                        "{} input is larger than {} bytes",
                        format,
                        format.max_input_bytes()
                    ),
                }))
                .is_err()
            {
                break;
            }
            continue;
        }
        if sender
            .blocking_send(ScannedImport::Candidate(PendingImportCandidate {
                path,
                format,
            }))
            .is_err()
        {
            break;
        }
    }

    progress.finish_enumerating();
}

/// Reject caller-supplied discovery DTOs that could bypass discovery bounds.
fn validate_import_candidate(candidate: &ImportCandidate) -> Result<()> {
    const MAX_IMPORT_HASH_BYTES: usize = 128;

    if candidate.title.len() > MAX_IMPORT_METADATA_BYTES
        || candidate.group_key.len() > MAX_IMPORT_METADATA_BYTES
        || candidate.content_hash.len() > MAX_IMPORT_HASH_BYTES
        || candidate.path.as_os_str().as_encoded_bytes().len() > MAX_IMPORT_PATH_BYTES
    {
        bail!("import candidate metadata exceeds byte limits");
    }
    let path_format = candidate
        .path
        .extension()
        .and_then(|extension| extension.to_str())
        .and_then(BookFormat::from_extension)
        .context("import candidate has an unsupported path format")?;
    if path_format != candidate.format {
        bail!("import candidate format does not match its path");
    }
    if candidate.file_size > candidate.format.max_input_bytes() {
        bail!("import candidate exceeds its format input byte limit");
    }
    if candidate.content_hash.len() != 64
        || !candidate
            .content_hash
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
    {
        bail!("import candidate has an invalid SHA-256 fingerprint");
    }
    if let Some(duplicate) = &candidate.duplicate {
        match duplicate {
            ImportDuplicate::ExistingBook { title, .. }
                if title.len() > MAX_IMPORT_METADATA_BYTES =>
            {
                bail!("import candidate duplicate metadata exceeds byte limits");
            }
            ImportDuplicate::SelectedFile { path }
                if path.as_os_str().as_encoded_bytes().len() > MAX_IMPORT_PATH_BYTES =>
            {
                bail!("import candidate duplicate metadata exceeds byte limits");
            }
            _ => {}
        }
    }
    Ok(())
}

fn validate_import_path(path: &Path) -> Result<()> {
    if path.as_os_str().as_encoded_bytes().len() > MAX_IMPORT_PATH_BYTES {
        bail!("import path exceeds byte limit");
    }
    Ok(())
}

fn truncate_utf8(value: String, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.as_str().to_owned();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn compact_string(value: &str) -> String {
    value.to_owned()
}

fn compact_path(path: PathBuf) -> PathBuf {
    PathBuf::from(path.as_os_str())
}

fn imported_book_from_commit(
    book_id: i64,
    source_path_key: &str,
    library_path_key: &str,
    content_hash: &str,
) -> ImportedBook {
    ImportedBook {
        book_id,
        source_path: compact_path(path_from_key(source_path_key)),
        library_path: compact_path(path_from_key(library_path_key)),
        content_hash: compact_string(content_hash),
    }
}

fn import_completion(
    path: PathBuf,
    result: Result<ImportedBook>,
    cancellation: &ImportCancellation,
    commit_started: bool,
) -> ImportCompletion {
    match result {
        Ok(imported) => ImportCompletion::Completed(Ok(imported)),
        Err(_) if cancellation.is_cancelled() && !commit_started => ImportCompletion::Cancelled,
        Err(error) => {
            ImportCompletion::Completed(Err(ImportFailure::new(path, format!("{error:#}"))))
        }
    }
}

/// Normalize user-visible import text for grouping and filtering.
pub fn normalize_import_text(text: &str) -> String {
    text.nfc()
        .case_fold()
        .nfc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn import_group_key(path: &Path) -> String {
    normalize_import_text(&filename_title(path))
}

#[derive(Debug)]
struct ManagedStage {
    path: PathBuf,
}

impl Drop for ManagedStage {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn unique_managed_path(parent: &Path, label: &str) -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);

    parent.join(format!(
        ".{label}.{}.{}.{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    ))
}

fn stage_managed_file(
    source: &Path,
    managed_dir: &Path,
    max_input_bytes: u64,
    cancellation: Option<&ImportCancellation>,
) -> Result<ManagedStage> {
    use std::io::Write;

    std::fs::create_dir_all(managed_dir)
        .with_context(|| format!("failed to create {}", managed_dir.display()))?;
    let path = unique_managed_path(managed_dir, "import");
    let mut input = std::fs::File::open(source)
        .with_context(|| format!("failed to read {}", source.display()))?;
    if input.metadata()?.len() > max_input_bytes {
        bail!("book exceeds its input byte limit");
    }
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .context("failed to create managed book staging file")?;
    let result = copy_managed_file(&mut input, &mut output, max_input_bytes, cancellation)
        .and_then(|_| output.flush().and_then(|_| output.sync_all()));
    if let Err(error) = result {
        let _ = std::fs::remove_file(&path);
        return Err(error).context("failed to stage managed book");
    }
    Ok(ManagedStage { path })
}

fn copy_managed_file(
    mut input: impl std::io::Read,
    mut output: impl std::io::Write,
    max_input_bytes: u64,
    cancellation: Option<&ImportCancellation>,
) -> std::io::Result<()> {
    let mut copied = 0_u64;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        if cancellation.is_some_and(ImportCancellation::is_cancelled) {
            return Err(std::io::Error::other("managed preparation cancelled"));
        }
        let remaining = max_input_bytes.saturating_add(1).saturating_sub(copied);
        let read =
            std::io::Read::read(&mut std::io::Read::take(&mut input, remaining), &mut buffer)?;
        if read == 0 {
            return Ok(());
        }
        output.write_all(&buffer[..read])?;
        copied = copied.saturating_add(read as u64);
        if copied > max_input_bytes {
            return Err(std::io::Error::other("book exceeds its input byte limit"));
        }
    }
}

fn publish_managed_file(stage: &Path, destination: &Path, expected_hash: &str) -> Result<()> {
    if file_fingerprint(stage)?.hash != expected_hash {
        bail!(
            "managed book staging verification failed: {}",
            stage.display()
        );
    }

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
            sync_parent_directory(destination)?;
            if let Some(quarantine) = quarantine {
                let _ = std::fs::remove_file(quarantine);
                sync_parent_directory(destination)?;
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

#[cfg(unix)]
fn sync_parent_directory(path: &Path) -> Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    std::fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .with_context(|| format!("failed to sync managed book directory {}", parent.display()))
}

#[cfg(not(unix))]
fn sync_parent_directory(_path: &Path) -> Result<()> {
    Ok(())
}

pub(crate) async fn backfill_missing_fingerprints(pool: &SqlitePool) -> Result<()> {
    const BACKFILL_BATCH_SIZE: i64 = 100;
    let mut after_id = i64::MIN;
    loop {
        let rows = sqlx::query(
            "SELECT id, file_path, format FROM books
             WHERE content_hash IS NULL AND id > ? ORDER BY id LIMIT ?",
        )
        .bind(after_id)
        .bind(BACKFILL_BATCH_SIZE)
        .fetch_all(pool)
        .await
        .context("failed to load legacy books for fingerprinting")?;
        if rows.is_empty() {
            break;
        }
        for row in rows {
            let id: i64 = row.get("id");
            after_id = id;
            let file_path: String = row.get("file_path");
            let Some(format) = BookFormat::from_db(&row.get::<String, _>("format")) else {
                eprintln!("warning: legacy book {file_path} has an unsupported format");
                continue;
            };
            let path = path_from_key(&file_path);
            if !path.is_file() {
                continue;
            }
            let _work_permit = acquire_import_work(None).await?;
            let fingerprint_path = path.clone();
            let file = match tokio::task::spawn_blocking(move || {
                fingerprint_file_with_limit(&fingerprint_path, Some(format.max_input_bytes()), None)
            })
            .await
            {
                Ok(Ok(file)) => file,
                Ok(Err(error)) => {
                    eprintln!("warning: failed to fingerprint legacy book {file_path}: {error}");
                    continue;
                }
                Err(error) => {
                    eprintln!("warning: legacy book fingerprint task failed: {error}");
                    continue;
                }
            };
            let mut transaction = pool.begin_with("BEGIN IMMEDIATE").await?;
            if let Err(error) = verify_fingerprinted_path(&path, &file, "fingerprint backfill") {
                eprintln!("warning: failed to verify legacy book {file_path}: {error}");
                continue;
            }
            sqlx::query(
                "UPDATE books SET content_hash = ?, file_size = ?
                 WHERE id = ? AND file_path = ? AND content_hash IS NULL",
            )
            .bind(file.fingerprint.hash)
            .bind(file.fingerprint.size as i64)
            .bind(id)
            .bind(file_path)
            .execute(&mut *transaction)
            .await
            .context("failed to save legacy book fingerprint")?;
            transaction.commit().await?;
        }
        tokio::task::yield_now().await;
    }
    Ok(())
}

fn extract_pdf_metadata(
    path: &Path,
    title_path: &Path,
    cancellation: Option<&ImportCancellation>,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    let is_cancelled = || cancellation.is_some_and(ImportCancellation::is_cancelled);
    let doc = if cancellation.is_some() {
        PdfDoc::open_with_limit_cancellable(path, MAX_PDF_INPUT_BYTES, &is_cancelled)?
    } else {
        PdfDoc::open(path)?
    };
    check_import_cancelled(cancellation)?;
    let meta = doc.metadata();
    let title = meta.title.unwrap_or_else(|| filename_title(title_path));
    let author = meta.author;

    // Render page zero directly at thumbnail size instead of materializing a reader-sized page.
    let (page_width, page_height) = doc.page_size(0)?;
    let scale = ((COVER_MAX_WIDTH - 1) as f32 / page_width)
        .min((COVER_MAX_HEIGHT - 1) as f32 / page_height)
        .min(1.0);
    check_import_cancelled(cancellation)?;
    let cover = doc
        .render_page(0, scale)
        .ok()
        .and_then(|page| encode_cover_png(page.width, page.height, &page.pixels));
    check_import_cancelled(cancellation)?;

    Ok((title, author, cover))
}

fn extract_epub_metadata(
    path: &Path,
    title_path: &Path,
    cancellation: Option<&ImportCancellation>,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    let is_cancelled = || cancellation.is_some_and(ImportCancellation::is_cancelled);
    let inspection = if cancellation.is_some() {
        EpubDoc::inspect_with_limits_cancellable(path, EpubLimits::default(), &is_cancelled)?
    } else {
        EpubDoc::inspect(path)?
    };
    check_import_cancelled(cancellation)?;
    let meta = inspection.metadata();
    let title = meta
        .title
        .clone()
        .unwrap_or_else(|| filename_title(title_path));
    let author = meta.author.clone();

    let cover = inspection.cover().and_then(|cover| {
        check_import_cancelled(cancellation)
            .ok()
            .and_then(|()| resize_cover_image(cover, cancellation))
    });
    check_import_cancelled(cancellation)?;

    Ok((title, author, cover))
}

fn extract_cbz_metadata(
    path: &Path,
    title_path: &Path,
    cancellation: Option<&ImportCancellation>,
) -> Result<(String, Option<String>, Option<Vec<u8>>)> {
    let is_cancelled = || cancellation.is_some_and(ImportCancellation::is_cancelled);
    let doc = if cancellation.is_some() {
        CbzDoc::open_with_limits_cancellable(path, CbzLimits::default(), &is_cancelled)?
    } else {
        CbzDoc::open(path)?
    };
    check_import_cancelled(cancellation)?;
    let title = filename_title(title_path);

    // Use first page as cover.
    let cover = if cancellation.is_some() {
        doc.page_image_bytes_cancellable(0, &is_cancelled)
    } else {
        doc.page_image_bytes(0)
    }
    .ok()
    .and_then(|data| {
        check_import_cancelled(cancellation)
            .ok()
            .and_then(|()| resize_cover_image(&data, cancellation))
    });
    check_import_cancelled(cancellation)?;

    Ok((title, None, cover))
}

fn filename_title(path: &Path) -> String {
    path.file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "Unknown".to_string())
}

fn check_import_cancelled(cancellation: Option<&ImportCancellation>) -> Result<()> {
    if cancellation.is_some_and(ImportCancellation::is_cancelled) {
        bail!("import cancelled");
    }
    Ok(())
}

/// Resize an image to fit within cover thumbnail bounds and encode as PNG.
fn resize_cover_image(data: &[u8], cancellation: Option<&ImportCancellation>) -> Option<Vec<u8>> {
    let img = image::load_from_memory(data).ok()?;
    check_import_cancelled(cancellation).ok()?;
    let thumb = img.resize(
        COVER_MAX_WIDTH,
        COVER_MAX_HEIGHT,
        image::imageops::FilterType::Triangle,
    );
    check_import_cancelled(cancellation).ok()?;
    let rgba = thumb.to_rgba8();
    check_import_cancelled(cancellation).ok()?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_reports_keep_exact_counts_with_bounded_details() {
        let mut report = ImportReport::default();
        for index in 0..(MAX_IMPORT_DETAILS + 20) {
            report.record_success(ImportedBook {
                book_id: index as i64,
                source_path: PathBuf::from(format!("source-{index}.epub")),
                library_path: PathBuf::from(format!("library-{index}.epub")),
                content_hash: "a".repeat(64),
            });
        }
        for index in 0..(MAX_IMPORT_FAILURE_DETAILS + 20) {
            report.record_failure(ImportFailure {
                path: PathBuf::from(format!("failure-{index}.epub")),
                error: "é".repeat(MAX_IMPORT_ERROR_BYTES),
            });
        }

        assert_eq!(report.succeeded, MAX_IMPORT_DETAILS + 20);
        assert_eq!(report.failed, MAX_IMPORT_FAILURE_DETAILS + 20);
        assert!(report.imported.len() <= MAX_IMPORT_DETAILS);
        assert!(report.failures.len() <= MAX_IMPORT_FAILURE_DETAILS);
        assert!(report.imported_detail_bytes <= MAX_IMPORT_DETAIL_BYTES);
        assert!(report.failure_detail_bytes <= MAX_IMPORT_FAILURE_DETAIL_BYTES);
        assert!(
            report
                .failures
                .iter()
                .all(|failure| failure.error.len() <= MAX_IMPORT_ERROR_BYTES
                    && failure.error.capacity() <= MAX_IMPORT_ERROR_BYTES)
        );
    }

    #[test]
    fn import_reports_rebuild_overallocated_details() {
        let mut source_path = PathBuf::with_capacity(MAX_IMPORT_DETAIL_BYTES * 4);
        source_path.push("source.epub");
        let mut library_path = PathBuf::with_capacity(MAX_IMPORT_DETAIL_BYTES * 4);
        library_path.push("library.epub");
        let mut content_hash = String::with_capacity(MAX_IMPORT_DETAIL_BYTES * 4);
        content_hash.push_str(&"a".repeat(64));
        let imported = ImportedBook {
            book_id: 1,
            source_path,
            library_path,
            content_hash,
        };

        let mut failure_path = PathBuf::with_capacity(MAX_IMPORT_FAILURE_DETAIL_BYTES * 4);
        failure_path.push("failure.epub");
        let mut error = String::with_capacity(MAX_IMPORT_FAILURE_DETAIL_BYTES * 4);
        error.push_str("failed");

        let success_report = ImportReport::from_imported(imported);
        let failure_report = ImportReport::from_failure(ImportFailure {
            path: failure_path,
            error,
        });

        assert!(success_report.imported[0].retained_byte_len() < 1024);
        assert_eq!(
            success_report.imported_detail_bytes,
            success_report.imported[0].retained_byte_len()
        );
        assert!(failure_report.failures[0].retained_byte_len() < 1024);
        assert_eq!(
            failure_report.failure_detail_bytes,
            failure_report.failures[0].retained_byte_len()
        );
    }

    #[tokio::test]
    async fn cancellation_wins_before_available_commit_admission_is_polled() {
        let cancellation = ImportCancellation::default();
        cancellation.cancel();

        let error = acquire_managed_storage(Some(&cancellation))
            .await
            .unwrap_err();

        assert!(error.to_string().contains("cancelled"));
    }

    #[test]
    fn extracted_metadata_is_bounded_before_persistence() {
        let fingerprint = || FileFingerprint {
            hash: "a".repeat(64),
            size: 1,
        };
        let oversized_title = inspect_book_with(
            Path::new("book.epub"),
            Path::new("book.epub"),
            None,
            None,
            || Ok(("x".repeat(MAX_IMPORT_METADATA_BYTES + 1), None, None)),
            |_| Ok(fingerprint()),
        )
        .unwrap_err();
        let oversized_cover = inspect_book_with(
            Path::new("book.epub"),
            Path::new("book.epub"),
            None,
            None,
            || {
                Ok((
                    "Book".to_owned(),
                    None,
                    Some(vec![0; MAX_IMPORT_COVER_BYTES + 1]),
                ))
            },
            |_| Ok(fingerprint()),
        )
        .unwrap_err();

        assert!(oversized_title.to_string().contains("metadata byte limits"));
        assert!(oversized_cover.to_string().contains("retained byte limit"));
    }

    struct CancellingReader {
        cancellation: ImportCancellation,
        reads: usize,
    }

    impl std::io::Read for CancellingReader {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.reads += 1;
            buffer[0] = 1;
            self.cancellation.cancel();
            Ok(1)
        }
    }

    #[test]
    fn fingerprinting_checks_for_cancellation_between_chunks() {
        let cancellation = ImportCancellation::default();
        let reader = CancellingReader {
            cancellation: cancellation.clone(),
            reads: 0,
        };

        let Err(error) = fingerprint_reader(reader, 2, Some(&cancellation)) else {
            panic!("fingerprinting should stop after cancellation");
        };

        assert!(error.to_string().contains("discovery cancelled"));
    }

    #[test]
    fn managed_copy_stops_after_mid_stream_cancellation() {
        let cancellation = ImportCancellation::default();
        let reader = CancellingReader {
            cancellation: cancellation.clone(),
            reads: 0,
        };
        let mut output = Vec::new();

        let error = copy_managed_file(reader, &mut output, 1024, Some(&cancellation)).unwrap_err();

        assert!(error.to_string().contains("cancelled"));
        assert_eq!(output.len(), 1);
    }

    #[test]
    fn fingerprinting_rejects_short_and_growing_readers_instead_of_claiming_metadata_size() {
        let short = fingerprint_reader(&b"short"[..], 10, None).unwrap_err();
        assert!(short.to_string().contains("expected 10, read 5"));

        let growing = fingerprint_reader(&b"too long"[..], 3, None).unwrap_err();
        assert!(growing.to_string().contains("grew"));
    }

    #[test]
    fn fingerprinted_file_detects_atomic_path_replacement() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        let replacement = directory.path().join("replacement.epub");
        std::fs::write(&path, b"original").unwrap();
        std::fs::write(&replacement, b"replacement").unwrap();
        let file = fingerprint_file_with_limit(&path, Some(1024), None).unwrap();

        #[cfg(windows)]
        {
            std::fs::remove_file(&path).unwrap_err();
            drop(file);
            std::fs::remove_file(&path).unwrap();
            std::fs::rename(&replacement, &path).unwrap();
        }

        #[cfg(not(windows))]
        {
            std::fs::rename(&replacement, &path).unwrap();
            let error = verify_fingerprinted_path(&path, &file, "test").unwrap_err();
            assert!(error.to_string().contains("changed during test"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn fingerprinted_file_detects_same_size_overwrite_with_restored_mtime() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        std::fs::write(&path, b"original").unwrap();
        let original_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();
        let file = fingerprint_file_with_limit(&path, Some(1024), None).unwrap();

        std::fs::write(&path, b"replaced").unwrap();
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(original_mtime))
            .unwrap();

        let error = verify_fingerprinted_path(&path, &file, "test").unwrap_err();
        assert!(error.to_string().contains("changed during test"));
    }

    #[test]
    fn managed_staging_rejects_oversized_sparse_inputs_without_publishing_a_stage() {
        let source_dir = tempfile::tempdir().unwrap();
        let managed_dir = tempfile::tempdir().unwrap();
        let source = source_dir.path().join("oversized.pdf");
        std::fs::File::create(&source)
            .unwrap()
            .set_len(MAX_PDF_INPUT_BYTES + 1)
            .unwrap();

        let error = stage_managed_file(&source, managed_dir.path(), MAX_PDF_INPUT_BYTES, None)
            .expect_err("oversized managed input must be rejected");

        assert!(error.to_string().contains("input byte limit"));
        assert_eq!(std::fs::read_dir(managed_dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn managed_staging_cancellation_removes_partial_stage() {
        let source_dir = tempfile::tempdir().unwrap();
        let managed_dir = tempfile::tempdir().unwrap();
        let source = source_dir.path().join("book.epub");
        std::fs::write(&source, vec![1_u8; 128 * 1024]).unwrap();
        let cancellation = ImportCancellation::default();
        cancellation.cancel();

        let error = stage_managed_file(
            &source,
            managed_dir.path(),
            MAX_PDF_INPUT_BYTES,
            Some(&cancellation),
        )
        .expect_err("cancelled staging must fail");

        assert!(format!("{error:#}").contains("cancelled"));
        assert_eq!(std::fs::read_dir(managed_dir.path()).unwrap().count(), 0);
    }

    #[test]
    fn reviewed_inspection_reuses_preinspection_fingerprint_then_hashes_after_extraction() {
        use std::cell::RefCell;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        std::fs::write(&path, b"reviewed bytes").unwrap();
        let before = file_fingerprint(&path).unwrap();
        let expected_hash = before.hash.clone();
        let events = RefCell::new(vec!["pre"]);

        let inspection = inspect_book_with(
            &path,
            &path,
            Some(&expected_hash),
            Some(before),
            || {
                events.borrow_mut().push("inspect");
                Ok(("Book".into(), None, None))
            },
            |path| {
                events.borrow_mut().push("post");
                file_fingerprint(path)
            },
        )
        .unwrap();

        assert_eq!(&*events.borrow(), &["pre", "inspect", "post"]);
        assert_eq!(inspection.fingerprint.hash, expected_hash);
    }

    #[test]
    fn reviewed_inspection_rejects_changes_before_or_during_extraction() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        std::fs::write(&path, b"reviewed bytes").unwrap();
        let reviewed = file_fingerprint(&path).unwrap();
        let expected_hash = reviewed.hash.clone();

        std::fs::write(&path, b"changed before inspection").unwrap();
        let before_error = inspect_book_with(
            &path,
            &path,
            Some(&expected_hash),
            None,
            || panic!("changed file must be rejected before extraction"),
            file_fingerprint,
        )
        .unwrap_err();
        assert!(before_error.to_string().contains("changed after review"));

        std::fs::write(&path, b"reviewed bytes").unwrap();
        let during_error = inspect_book_with(
            &path,
            &path,
            Some(&expected_hash),
            Some(reviewed),
            || {
                std::fs::write(&path, b"replacement during inspection")?;
                Ok(("Book".into(), None, None))
            },
            file_fingerprint,
        )
        .unwrap_err();
        assert!(during_error.to_string().contains("changed after review"));
    }

    #[test]
    fn reviewed_inspection_fingerprint_passes_honor_cancellation() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        std::fs::write(&path, b"reviewed bytes").unwrap();
        let expected_hash = file_fingerprint(&path).unwrap().hash;

        let cancelled_before = ImportCancellation::default();
        cancelled_before.cancel();
        let before_error = inspect_book_with(
            &path,
            &path,
            Some(&expected_hash),
            None,
            || panic!("cancelled first fingerprint must stop before extraction"),
            |path| file_fingerprint_cancellable(path, Some(&cancelled_before)),
        )
        .unwrap_err();
        assert!(before_error.to_string().contains("cancelled"));

        let cancelled_during = ImportCancellation::default();
        let during_error = inspect_book_with(
            &path,
            &path,
            Some(&expected_hash),
            None,
            || {
                cancelled_during.cancel();
                Ok(("Book".into(), None, None))
            },
            |path| file_fingerprint_cancellable(path, Some(&cancelled_during)),
        )
        .unwrap_err();
        assert!(during_error.to_string().contains("cancelled"));
    }

    #[test]
    fn scanner_streams_candidates_before_directory_enumeration_finishes() {
        let directory = tempfile::tempdir().unwrap();
        for index in 0..20 {
            std::fs::write(directory.path().join(format!("book-{index}.epub")), b"book").unwrap();
        }
        let cancellation = ImportCancellation::default();
        let progress = ImportDiscoveryProgress::default();
        let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
        let scan_path = directory.path().to_path_buf();
        let scan_cancellation = cancellation.clone();
        let scan_progress = progress.clone();
        let scanner = std::thread::spawn(move || {
            scan_import_candidates(
                vec![scan_path],
                true,
                &scan_cancellation,
                &scan_progress,
                &sender,
            );
        });

        assert!(matches!(
            receiver.blocking_recv(),
            Some(ScannedImport::Candidate(_))
        ));
        assert!(progress.snapshot().enumerating);

        cancellation.cancel();
        drop(receiver);
        scanner.join().unwrap();
    }

    #[test]
    fn scanner_rejects_oversized_inputs_before_fingerprinting() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("oversized.pdf");
        std::fs::File::create(&path)
            .unwrap()
            .set_len(MAX_PDF_INPUT_BYTES + 1)
            .unwrap();
        let cancellation = ImportCancellation::default();
        let progress = ImportDiscoveryProgress::default();
        let (sender, mut receiver) = tokio::sync::mpsc::channel(1);

        scan_import_candidates(vec![path.clone()], false, &cancellation, &progress, &sender);

        let Some(ScannedImport::Failure(failure)) = receiver.blocking_recv() else {
            panic!("oversized input should fail discovery");
        };
        assert_eq!(failure.path, canonical_path(&path));
        assert!(failure.error.contains("input is larger"));
        let snapshot = progress.snapshot();
        assert_eq!(snapshot.hashed_files, 0);
        assert_eq!(snapshot.completed_files, 1);
    }

    #[tokio::test]
    async fn fingerprint_task_failure_is_reported_without_a_fake_candidate() {
        let progress = ImportDiscoveryProgress::default();
        progress.found_file();
        let mut tasks =
            tokio::task::JoinSet::<(PendingImportCandidate, Result<FileFingerprint>)>::new();
        tasks.spawn(async { panic!("fingerprint failed") });
        let result = tasks.join_next().await.unwrap();
        let mut fingerprinted = Vec::new();
        let mut failures = Vec::new();

        collect_fingerprint_result(result, &progress, &mut fingerprinted, &mut failures);

        assert!(fingerprinted.is_empty());
        assert_eq!(failures.len(), 1);
        assert!(failures[0].path.as_os_str().is_empty());
        assert!(failures[0].error.contains("fingerprint task failed"));
        let snapshot = progress.snapshot();
        assert_eq!(snapshot.hashed_files, 1);
        assert_eq!(snapshot.completed_files, 1);
    }

    #[tokio::test]
    async fn scanner_admission_wait_is_cancelled_promptly() {
        let held = scanner_admission().clone().acquire_owned().await.unwrap();
        let cancellation = ImportCancellation::default();
        let waiting = {
            let cancellation = cancellation.clone();
            tokio::spawn(async move { acquire_scanner(&cancellation).await })
        };
        tokio::task::yield_now().await;

        cancellation.cancel();
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), waiting)
            .await
            .expect("cancellation should wake scanner admission")
            .unwrap();
        assert!(result.is_none());
        drop(held);
    }

    #[tokio::test]
    async fn managed_preparation_wait_is_globally_bounded_and_cancellable() {
        let held = import_work_admission()
            .clone()
            .acquire_many_owned(IMPORT_WORK_CONCURRENCY as u32)
            .await
            .unwrap();
        let cancellation = ImportCancellation::default();
        let waiting = {
            let cancellation = cancellation.clone();
            tokio::spawn(async move { acquire_import_work(Some(&cancellation)).await })
        };
        tokio::task::yield_now().await;

        cancellation.cancel();
        let error = tokio::time::timeout(std::time::Duration::from_secs(1), waiting)
            .await
            .expect("cancellation should wake managed preparation admission")
            .unwrap()
            .unwrap_err();
        assert!(error.to_string().contains("cancelled"));
        drop(held);
    }

    #[tokio::test]
    async fn referenced_import_waits_for_process_global_work_admission() {
        let held = import_work_admission()
            .clone()
            .acquire_many_owned(IMPORT_WORK_CONCURRENCY as u32)
            .await
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let store = crate::reading_state::ReadingStateStore::open_at_async(
            &directory.path().join("state.db"),
        )
        .await
        .unwrap();
        let library = Library::new(store.pool().clone(), directory.path().join("managed"));
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let importing = tokio::spawn(async move { library.import_file(&source).await });
        tokio::task::yield_now().await;

        assert!(!importing.is_finished());
        drop(held);
        importing.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn prepared_managed_import_retains_work_admission_until_drop() {
        let directory = tempfile::tempdir().unwrap();
        let store = crate::reading_state::ReadingStateStore::open_at_async(
            &directory.path().join("state.db"),
        )
        .await
        .unwrap();
        let library = Library::new(store.pool().clone(), directory.path().join("managed"));
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let prepared = library.prepare_managed_file(&source, None, None);
        let prepared = tokio::time::timeout(std::time::Duration::from_secs(5), prepared)
            .await
            .expect("managed preparation should obtain admission")
            .unwrap();

        assert!(
            tokio::time::timeout(
                std::time::Duration::from_millis(20),
                import_work_admission()
                    .clone()
                    .acquire_many_owned(IMPORT_WORK_CONCURRENCY as u32),
            )
            .await
            .is_err()
        );
        drop(prepared);
        let _held_after_drop = import_work_admission()
            .clone()
            .acquire_many_owned(IMPORT_WORK_CONCURRENCY as u32)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn successful_managed_commit_releases_retained_admission() {
        let directory = tempfile::tempdir().unwrap();
        let store = crate::reading_state::ReadingStateStore::open_at_async(
            &directory.path().join("state.db"),
        )
        .await
        .unwrap();
        let library = Library::new(store.pool().clone(), directory.path().join("managed"));
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.epub");
        let prepared = library
            .prepare_managed_file(&source, None, None)
            .await
            .unwrap();

        library
            .commit_prepared_managed_file(&prepared)
            .await
            .unwrap();
        let duplicate = library
            .prepare_managed_file(&source, None, None)
            .await
            .unwrap();
        library
            .commit_prepared_managed_file(&duplicate)
            .await
            .unwrap();

        let _all_permits = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            import_work_admission()
                .clone()
                .acquire_many_owned(IMPORT_WORK_CONCURRENCY as u32),
        )
        .await
        .expect("a committed preparation must release its admission")
        .unwrap();
        drop(duplicate);
        drop(prepared);
    }

    #[test]
    fn caller_supplied_import_candidate_strings_are_bounded() {
        let candidate = ImportCandidate {
            path: PathBuf::from("book.epub"),
            title: "x".repeat(4 * 1024 + 1),
            group_key: "book".to_owned(),
            format: BookFormat::Epub,
            file_size: 1,
            content_hash: "0".repeat(64),
            duplicate: None,
        };

        assert!(
            validate_import_candidate(&candidate)
                .unwrap_err()
                .to_string()
                .contains("metadata exceeds")
        );
    }

    #[test]
    fn caller_supplied_import_candidate_identity_is_validated() {
        let mut candidate = ImportCandidate {
            path: PathBuf::from("book.epub"),
            title: "book".to_owned(),
            group_key: "book".to_owned(),
            format: BookFormat::Pdf,
            file_size: 1,
            content_hash: "0".repeat(64),
            duplicate: None,
        };
        assert!(
            validate_import_candidate(&candidate)
                .unwrap_err()
                .to_string()
                .contains("does not match")
        );

        candidate.format = BookFormat::Epub;
        candidate.content_hash = "not-a-sha256".to_owned();
        assert!(
            validate_import_candidate(&candidate)
                .unwrap_err()
                .to_string()
                .contains("SHA-256")
        );

        candidate.content_hash = "0".repeat(64);
        candidate.file_size = EpubLimits::default().max_input_bytes + 1;
        assert!(
            validate_import_candidate(&candidate)
                .unwrap_err()
                .to_string()
                .contains("input byte limit")
        );
    }

    #[test]
    fn pdf_cover_is_rendered_within_thumbnail_bounds() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sample.pdf");

        let (_, _, cover) = extract_pdf_metadata(&path, &path, None).unwrap();
        let cover = image::load_from_memory(&cover.unwrap()).unwrap();

        assert!(cover.width() <= COVER_MAX_WIDTH);
        assert!(cover.height() <= COVER_MAX_HEIGHT);
    }

    #[test]
    fn publishing_rejects_a_stage_that_does_not_match_its_expected_hash() {
        let directory = tempfile::tempdir().unwrap();
        let expected = directory.path().join("expected.epub");
        let stage = directory.path().join("stage.tmp");
        let destination = directory.path().join("managed.epub");
        std::fs::write(&expected, b"expected bytes").unwrap();
        std::fs::write(&stage, b"corrupt bytes").unwrap();
        std::fs::write(&destination, b"existing destination").unwrap();
        let expected_hash = file_fingerprint(&expected).unwrap().hash;

        let result = publish_managed_file(&stage, &destination, &expected_hash);

        assert!(result.is_err());
        assert_eq!(
            std::fs::read(&destination).unwrap(),
            b"existing destination"
        );
        assert!(stage.exists());
    }
}
