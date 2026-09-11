//! Owned, coarse-grained API suitable for a generated Dart/Rust bridge.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use thiserror::Error;
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};

use crate::annotations::{
    ANNOTATION_SNAPSHOT_BASE_BYTES, Annotation, AnnotationAssociationConflict,
    AnnotationAssociationInvalidRequest, AnnotationAssociationOutcome,
    AnnotationAssociationSourceCancelled, AnnotationAssociationSourceNotFound,
    AnnotationAssociationSourceWorkLimit, AnnotationDocumentFormat, AnnotationDocumentVersionId,
    AnnotationDocumentVersionLimit, AnnotationId, AnnotationReconciliationCancelled,
    AnnotationReconciliationWorkLimit, AnnotationResolution, AnnotationSnapshotLimit,
    AnnotationStore, AnnotationTarget, DocumentFingerprint, EpubAnchor, HighlightColor,
    MAX_ANNOTATION_BODY_SCALARS, MAX_ANNOTATION_SNAPSHOT_BYTES, MAX_TEXT_ANCHOR_RESOLUTION_WORK,
    NewAnnotation, PageRect, PdfAnchor, QuoteSelector, TextAnchorResolutionError,
    TextAnchorResolver, TextScalarIndex,
};
#[cfg(test)]
use crate::annotations::{
    AnnotationPersistenceTestGate, MAX_ANNOTATION_DOCUMENT_VERSIONS, MAX_ANNOTATIONS_PER_SNAPSHOT,
};

use crate::application::{DeviceFileLocator, OpenDocument, OpenDocumentError, OpenDocumentPlan};
use crate::bookmarks::{
    Bookmark, BookmarkBookNotFound, BookmarkCountLimit, BookmarkExportLimit, BookmarkNotFound,
    BookmarkStore,
};
use crate::document::{Document, RenderedPage};
#[cfg(test)]
use crate::epub::EpubLimits;
use crate::epub::{
    EPUB_TEXT_MAX_ENDPOINTS, EPUB_TEXT_MAX_PIXELS, EPUB_TEXT_MAX_SCALARS, EpubTextAlign,
    EpubTextDirection, EpubTextEndpoint, EpubTextRequest, EpubTextRun,
};
use crate::library::BookFormat;
use crate::library::{
    Book, BookPage, ImportCancellation, ImportCandidate, ImportCompletion, Library,
    LibraryQueryCancelled, LibraryQueryWorkLimit, StorageKind,
};
use crate::reader::{ReaderPreferences, ReaderTheme, ReadingMode, ZoomMode};
use crate::reading_state::{FileReadingState, ReadingStateBookNotFound, ReadingStateStore};
use crate::search::{SearchCancellation, SearchError, SearchLimits, SearchMatch};
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_BRIDGE_BUFFER_BYTES: usize = 160 * 1024 * 1024;
pub const MAX_BRIDGE_RETAINED_BUFFER_BYTES: usize = 320 * 1024 * 1024;
pub const MAX_BRIDGE_RENDER_WORKERS: usize = 2;
pub const MAX_BRIDGE_OPEN_WORKERS: usize = 2;
pub const MAX_BRIDGE_REQUESTS: usize = 64;
pub const MAX_BRIDGE_DOCUMENTS: usize = 64;
pub const MAX_BRIDGE_BUFFERS: usize = 256;
pub const MAX_BRIDGE_RETAINED_DOCUMENT_BYTES: usize = 3 * 1024 * 1024 * 1024;
pub const MAX_BRIDGE_PROBE_BYTES: usize = 512 * 1024 * 1024;
pub const MAX_BRIDGE_LOCAL_ID_BYTES: usize = 4 * 1024;
pub const MAX_BRIDGE_PATH_KEY_BYTES: usize = 64 * 1024;
// The resolver retains its usize/range indexes plus source/profile/normalized
// text at peak. Limiting PDF text to 2 MiB keeps the conservative 144 MiB
// reservation below the process-wide transient buffer budget on 64-bit hosts.
const MAX_ANNOTATION_PDF_TEXT_BYTES: usize = 2 * 1024 * 1024;
const ANNOTATION_RESOLUTION_WORKSPACE_BYTES: u32 = 144 * 1024 * 1024;
const ANNOTATION_GEOMETRY_WORKSPACE_BYTES: u32 = 8 * 1024 * 1024;

static NEXT_REGISTRY_ID: AtomicU64 = AtomicU64::new(1);

/// Fixed-field request that can be generated directly into a Dart value.
#[derive(Debug, Clone)]
pub struct OpenRequest {
    pub book_id: Option<i64>,
    pub local_id: String,
    pub path_key: String,
    pub format_hint: Option<BookFormat>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DocumentHandle {
    pub registry: u64,
    pub id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BufferHandle {
    pub registry: u64,
    pub id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SelectionHandle {
    pub registry: u64,
    pub id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogicalUnit {
    Page,
    Chapter,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentSummary {
    pub handle: DocumentHandle,
    pub book_id: Option<i64>,
    pub format: BookFormat,
    pub title: Option<String>,
    pub logical_unit: LogicalUnit,
    pub logical_unit_count: usize,
}

#[derive(Debug, Clone)]
pub struct LibraryBookDto {
    pub book_id: i64,
    pub title: String,
    pub author: Option<String>,
    pub format: BookFormat,
    pub path_key: String,
    pub managed: bool,
    pub cover: Option<Vec<u8>>,
    pub progress: f64,
    pub date_added: String,
    pub last_read: Option<String>,
}

impl From<Book> for LibraryBookDto {
    fn from(book: Book) -> Self {
        Self {
            book_id: book.id,
            title: book.title,
            author: book.author,
            format: book.format,
            path_key: book.file_path,
            managed: book.storage_kind == StorageKind::Managed,
            cover: book.cover,
            progress: book.progress,
            date_added: book.date_added,
            last_read: book.last_read,
        }
    }
}

fn import_item(path_key: String, book: Book) -> ImportItemDto {
    let mut book = LibraryBookDto::from(book);
    book.cover = None;
    ImportItemDto {
        path_key,
        book: Some(book),
        error: None,
    }
}

#[derive(Debug, Clone)]
pub struct LibraryPageDto {
    pub books: Vec<LibraryBookDto>,
    pub has_more: bool,
}

#[derive(Debug, Clone)]
pub struct ImportItemDto {
    pub path_key: String,
    pub book: Option<LibraryBookDto>,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ImportReportDto {
    pub imported: usize,
    pub failed: usize,
    pub cancelled: bool,
    pub items: Vec<ImportItemDto>,
}

#[derive(Debug, Clone)]
pub struct BookmarkDto {
    pub id: i64,
    pub book_id: Option<i64>,
    pub unit: usize,
    pub offset: Option<usize>,
    pub title: Option<String>,
    pub note: Option<String>,
    pub color: String,
    pub created_at: String,
}

impl From<Bookmark> for BookmarkDto {
    fn from(value: Bookmark) -> Self {
        Self {
            id: value.id,
            book_id: value.book_id,
            unit: value.page,
            offset: value.location_offset,
            title: value.title,
            note: value.note,
            color: value.color,
            created_at: value.created_at,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReadingStateDto {
    pub unit: usize,
    pub offset: Option<usize>,
    pub zoom: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReaderSettingsDto {
    pub continuous: bool,
    pub theme: String,
    pub epub_font_size: f32,
    pub epub_line_spacing: f32,
    /// Zero is fit-page, -1 is fit-width, and a positive value is manual scale.
    pub pdf_zoom: f32,
}

impl From<ReaderPreferences> for ReaderSettingsDto {
    fn from(value: ReaderPreferences) -> Self {
        Self {
            continuous: value.reading_mode == ReadingMode::Continuous,
            theme: value.theme.stored().to_owned(),
            epub_font_size: value.epub_font_size,
            epub_line_spacing: value.epub_line_spacing,
            pdf_zoom: match value.pdf_zoom {
                ZoomMode::FitPage => 0.0,
                ZoomMode::FitWidth => -1.0,
                ZoomMode::Manual(v) => v,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RenderRequest {
    pub document: DocumentHandle,
    pub page: usize,
    pub scale: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderedBuffer {
    pub handle: BufferHandle,
    pub width: u32,
    pub height: u32,
    pub byte_len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SelectionRect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SelectionEndpoint {
    pub offset: usize,
    pub range_start: usize,
    pub range_end: usize,
    pub rect: SelectionRect,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SelectionPageRect {
    pub character: usize,
    pub rect: SelectionRect,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SelectionCaret {
    /// Logical scalar/PDFium-character boundary represented by this caret.
    pub offset: usize,
    pub x: f32,
    pub along_line: f32,
    pub vertical: bool,
    pub top: f32,
    pub bottom: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SelectionVisualLine {
    /// Carets in visual (left-to-right) order. The same offset may occur on two
    /// wrapped lines; its line membership preserves upstream/downstream affinity.
    pub carets: Vec<SelectionCaret>,
}

/// Owned visible-surface text and hit zones. Pointer movement consumes this
/// value locally and never re-enters PDFium or Rust.
#[derive(Debug, Clone, PartialEq)]
pub struct SelectionSurface {
    /// Retains request and geometry admission until the host discards the surface.
    pub handle: SelectionHandle,
    pub width: f32,
    pub height: f32,
    pub text: String,
    /// Rust-owned completeness decision. False disables copying and makes PDF
    /// persistence omit its text range and quote selector.
    pub copy_eligible: bool,
    pub resource_path: Option<String>,
    /// Retained straight-alpha RGBA raster produced by the same EPUB layout.
    /// The caller owns this handle and must release it after decoding.
    pub raster: Option<RenderedBuffer>,
    pub endpoints: Vec<SelectionEndpoint>,
    /// All legal extended-grapheme caret offsets, in logical order.
    pub grapheme_boundaries: Vec<usize>,
    /// UAX #29 word-segment stops, including punctuation boundaries.
    pub word_boundaries: Vec<usize>,
    /// Renderer/extractor-produced visual line membership and caret geometry.
    pub visual_lines: Vec<SelectionVisualLine>,
    /// Durable PDF page-coordinate character rectangles; empty for EPUB.
    pub page_rectangles: Vec<SelectionPageRect>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BridgeAnnotation {
    pub id: String,
    pub unit: usize,
    pub resolution: AnnotationResolution,
    /// Text-backed half-open range. Geometry-only PDF annotations have no range.
    pub text_range: Option<AnnotationTextRange>,
    /// Normalized exact quote when the source text mapping was complete.
    pub quote: Option<String>,
    /// Rust-produced PDF display geometry; empty for EPUB annotations.
    pub rectangles: Vec<SelectionRect>,
    pub color: HighlightColor,
    pub body: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AnnotationTextRange {
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotationAssociationSourceDto {
    pub version_id: String,
    pub format: BookFormat,
    pub local_path: String,
    pub fingerprint_algorithm: String,
    pub fingerprint_version: u32,
    pub fingerprint: Vec<u8>,
    pub live_annotations: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnnotationAssociationSourcePageDto {
    pub sources: Vec<AnnotationAssociationSourceDto>,
    pub next_cursor: Option<String>,
    pub previous_cursor: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CreateAnnotationRequest {
    pub document: DocumentHandle,
    pub unit: usize,
    pub start: usize,
    pub end: usize,
    pub display_scale: f32,
    pub color: HighlightColor,
    pub body: Option<String>,
}

#[derive(Debug, Default)]
struct CancellationInner {
    cancelled: Arc<AtomicBool>,
    notify: Arc<Notify>,
    publication: Mutex<()>,
}

#[derive(Debug, Clone, Default)]
pub struct Cancellation(Arc<CancellationInner>);

impl Cancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        let _publication = self
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        self.0.cancelled.store(true, Ordering::Release);
        self.0.notify.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }

    fn flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.0.cancelled)
    }

    fn notifier(&self) -> Arc<Notify> {
        Arc::clone(&self.0.notify)
    }

    pub(crate) async fn cancelled(&self) {
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
pub enum BridgeErrorKind {
    Cancelled,
    NotFound,
    Inaccessible,
    Unsupported,
    InvalidRequest,
    Malformed,
    LimitExceeded,
    BackendUnavailable,
    RenderFailed,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum BridgeError {
    #[error("operation was cancelled")]
    Cancelled,
    #[error("unknown, foreign, or released document handle")]
    InvalidDocumentHandle,
    #[error("unknown, foreign, or released buffer handle")]
    InvalidBufferHandle,
    #[error("document was not found")]
    DocumentNotFound,
    #[error("{0} was not found")]
    ResourceNotFound(String),
    #[error("document is inaccessible")]
    DocumentInaccessible,
    #[error("operation is unsupported for {0}")]
    UnsupportedOperation(BookFormat),
    #[error("unsupported file format: .{0}")]
    UnsupportedFormat(String),
    #[error("invalid page {page}; document has {page_count} pages")]
    InvalidPage { page: usize, page_count: usize },
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("failed to open {format}: {detail}")]
    Open { format: BookFormat, detail: String },
    #[error("{format} exceeds an opening resource limit: {detail}")]
    OpenLimit { format: BookFormat, detail: String },
    #[error("{format} backend is unavailable: {detail}")]
    Backend { format: BookFormat, detail: String },
    #[error("document render failed: {0}")]
    Render(String),
    #[error("bridge buffer exceeds its memory budget")]
    BufferLimit,
    #[error("bridge document exceeds its retention budget")]
    DocumentLimit,
    #[error("bridge request count exceeds its admission limit")]
    RequestLimit,
    #[error("bridge buffer count exceeds its retention limit")]
    BufferCountLimit,
    #[error("annotation snapshot exceeds its retention limit")]
    AnnotationLimit,
    #[error("Rust operation panicked")]
    Panic,
    #[error("bridge worker stopped unexpectedly")]
    Worker,
    #[error("annotation storage failed: {0}")]
    Storage(String),
}

impl BridgeError {
    pub fn kind(&self) -> BridgeErrorKind {
        match self {
            Self::Cancelled => BridgeErrorKind::Cancelled,
            Self::InvalidDocumentHandle
            | Self::InvalidBufferHandle
            | Self::DocumentNotFound
            | Self::ResourceNotFound(_) => BridgeErrorKind::NotFound,
            Self::DocumentInaccessible => BridgeErrorKind::Inaccessible,
            Self::BufferLimit
            | Self::DocumentLimit
            | Self::RequestLimit
            | Self::BufferCountLimit
            | Self::AnnotationLimit
            | Self::OpenLimit { .. } => BridgeErrorKind::LimitExceeded,
            Self::Panic | Self::Worker | Self::Backend { .. } | Self::Storage(_) => {
                BridgeErrorKind::BackendUnavailable
            }
            Self::Render(_) => BridgeErrorKind::RenderFailed,
            Self::UnsupportedOperation(_) | Self::UnsupportedFormat(_) => {
                BridgeErrorKind::Unsupported
            }
            Self::InvalidPage { .. } | Self::InvalidRequest(_) => BridgeErrorKind::InvalidRequest,
            Self::Open { .. } => BridgeErrorKind::Malformed,
        }
    }
}

#[derive(Debug)]
struct RetainedBuffer {
    pixels: Vec<u8>,
    transferred: bool,
    _bytes: OwnedSemaphorePermit,
    _slot: OwnedSemaphorePermit,
}

#[derive(Debug)]
struct RetainedDocument {
    document: OpenDocument,
    book_id: Option<i64>,
    local_path: String,
    fingerprint: DocumentFingerprint,
    _bytes: OwnedSemaphorePermit,
    _slot: OwnedSemaphorePermit,
}

#[derive(Debug)]
struct RetainedSelection {
    _request_slot: OwnedSemaphorePermit,
    _bytes: OwnedSemaphorePermit,
}

#[derive(Debug, Default)]
struct Registry {
    documents: HashMap<DocumentHandle, Arc<RetainedDocument>>,
    buffers: HashMap<BufferHandle, RetainedBuffer>,
    selections: HashMap<SelectionHandle, RetainedSelection>,
}

#[derive(Debug)]
struct BridgeAdmission {
    request_slots: Arc<Semaphore>,
    render_slots: Arc<Semaphore>,
    buffer_bytes: Arc<Semaphore>,
    planning_slots: Arc<Semaphore>,
    open_slots: Arc<Semaphore>,
    document_slots: Arc<Semaphore>,
    buffer_slots: Arc<Semaphore>,
    document_bytes: Arc<Semaphore>,
    probe_bytes: Arc<Semaphore>,
    buffer_capacity: usize,
}

#[cfg(test)]
#[derive(Debug)]
struct TestPhaseGate {
    entered: Semaphore,
    release: Semaphore,
}

#[cfg(test)]
impl Default for TestPhaseGate {
    fn default() -> Self {
        Self {
            entered: Semaphore::new(0),
            release: Semaphore::new(0),
        }
    }
}

#[cfg(test)]
impl TestPhaseGate {
    async fn pause(&self) {
        self.entered.add_permits(1);
        self.release.acquire().await.unwrap().forget();
    }

    async fn wait_until_entered(&self) {
        self.entered.acquire().await.unwrap().forget();
    }

    fn release(&self) {
        self.release.add_permits(1);
    }
}

#[cfg(test)]
#[derive(Debug, Default)]
struct AnnotationTestHooks {
    initialization: Option<Arc<TestPhaseGate>>,
    before_acceptance: Option<Arc<TestPhaseGate>>,
    persistence: Option<Arc<AnnotationPersistenceTestGate>>,
    list: Option<Arc<AnnotationPersistenceTestGate>>,
    fail_create_response: bool,
}

impl BridgeAdmission {
    fn new(buffer_bytes: usize, render_workers: usize) -> Self {
        Self {
            request_slots: Arc::new(Semaphore::new(MAX_BRIDGE_REQUESTS)),
            render_slots: Arc::new(Semaphore::new(render_workers)),
            buffer_bytes: Arc::new(Semaphore::new(buffer_bytes)),
            planning_slots: Arc::new(Semaphore::new(MAX_BRIDGE_OPEN_WORKERS)),
            open_slots: Arc::new(Semaphore::new(MAX_BRIDGE_OPEN_WORKERS)),
            document_slots: Arc::new(Semaphore::new(MAX_BRIDGE_DOCUMENTS)),
            buffer_slots: Arc::new(Semaphore::new(MAX_BRIDGE_BUFFERS)),
            document_bytes: Arc::new(Semaphore::new(MAX_BRIDGE_RETAINED_DOCUMENT_BYTES)),
            probe_bytes: Arc::new(Semaphore::new(MAX_BRIDGE_PROBE_BYTES)),
            buffer_capacity: buffer_bytes,
        }
    }
}

static GLOBAL_ADMISSION: OnceLock<Arc<BridgeAdmission>> = OnceLock::new();

#[derive(Debug, Clone)]
pub struct Bridge {
    registry_id: u64,
    next_handle: Arc<AtomicU64>,
    registry: Arc<Mutex<Registry>>,
    admission: Arc<BridgeAdmission>,
    annotation_store: Arc<tokio::sync::OnceCell<AnnotationStore>>,
    annotation_database: Option<Arc<PathBuf>>,
    state_store: Arc<tokio::sync::OnceCell<ReadingStateStore>>,
    #[cfg(test)]
    selection_worker_barrier: Option<Arc<std::sync::Barrier>>,
    #[cfg(test)]
    selection_second_cancellation_barrier: Option<Arc<std::sync::Barrier>>,
    #[cfg(test)]
    annotation_resolution_worker_barrier: Option<Arc<std::sync::Barrier>>,
    #[cfg(test)]
    library_open_worker_barrier: Option<Arc<std::sync::Barrier>>,
    #[cfg(test)]
    library_query_progress_barrier: Option<Arc<std::sync::Barrier>>,
    #[cfg(test)]
    annotation_reconciliation_progress_barrier: Option<Arc<std::sync::Barrier>>,
    #[cfg(test)]
    annotation_reconciliation_work_limit: Option<usize>,
    #[cfg(test)]
    before_annotation_reconciliation: Option<Arc<TestPhaseGate>>,
    #[cfg(test)]
    after_annotation_reconciliation_commit: Option<Arc<TestPhaseGate>>,
    #[cfg(test)]
    product_read_cancellation_gate: Option<Arc<TestPhaseGate>>,
    #[cfg(test)]
    state_store_initialization_gate: Option<Arc<TestPhaseGate>>,
    #[cfg(test)]
    annotation_test_hooks: Option<Arc<AnnotationTestHooks>>,
}

impl Default for Bridge {
    fn default() -> Self {
        Self::new()
    }
}

impl Bridge {
    pub fn new() -> Self {
        let admission = Arc::clone(GLOBAL_ADMISSION.get_or_init(|| {
            Arc::new(BridgeAdmission::new(
                MAX_BRIDGE_RETAINED_BUFFER_BYTES,
                MAX_BRIDGE_RENDER_WORKERS,
            ))
        }));
        Self::with_admission(admission)
    }

    /// Construct a bridge whose annotation storage uses a host-owned SQLite path.
    ///
    /// Production hosts may keep using [`Self::new`]. Tests and platform hosts
    /// that own application-data placement can inject the exact database path.
    pub fn with_database_path(database: PathBuf) -> Self {
        let admission = Arc::clone(GLOBAL_ADMISSION.get_or_init(|| {
            Arc::new(BridgeAdmission::new(
                MAX_BRIDGE_RETAINED_BUFFER_BYTES,
                MAX_BRIDGE_RENDER_WORKERS,
            ))
        }));
        Self::with_admission_database(admission, Some(Arc::new(database)))
    }

    #[cfg(test)]
    fn with_limits(buffer_bytes: usize, render_workers: usize) -> Self {
        Self::with_admission(Arc::new(BridgeAdmission::new(buffer_bytes, render_workers)))
    }

    fn with_admission(admission: Arc<BridgeAdmission>) -> Self {
        Self::with_admission_database(admission, None)
    }

    fn with_admission_database(
        admission: Arc<BridgeAdmission>,
        annotation_database: Option<Arc<PathBuf>>,
    ) -> Self {
        Self {
            registry_id: NEXT_REGISTRY_ID.fetch_add(1, Ordering::Relaxed),
            next_handle: Arc::new(AtomicU64::new(0)),
            registry: Arc::new(Mutex::new(Registry::default())),
            admission,
            annotation_store: Arc::new(tokio::sync::OnceCell::new()),
            annotation_database,
            state_store: Arc::new(tokio::sync::OnceCell::new()),
            #[cfg(test)]
            selection_worker_barrier: None,
            #[cfg(test)]
            selection_second_cancellation_barrier: None,
            #[cfg(test)]
            annotation_resolution_worker_barrier: None,
            #[cfg(test)]
            library_open_worker_barrier: None,
            #[cfg(test)]
            library_query_progress_barrier: None,
            #[cfg(test)]
            annotation_reconciliation_progress_barrier: None,
            #[cfg(test)]
            annotation_reconciliation_work_limit: None,
            #[cfg(test)]
            before_annotation_reconciliation: None,
            #[cfg(test)]
            after_annotation_reconciliation_commit: None,
            #[cfg(test)]
            product_read_cancellation_gate: None,
            #[cfg(test)]
            state_store_initialization_gate: None,
            #[cfg(test)]
            annotation_test_hooks: None,
        }
    }

    pub async fn open_document(
        &self,
        request: OpenRequest,
        cancellation: Cancellation,
    ) -> Result<DocumentSummary, BridgeError> {
        check_cancelled(&cancellation)?;
        let _request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        if request.local_id.len() > MAX_BRIDGE_LOCAL_ID_BYTES {
            return Err(BridgeError::InvalidRequest(format!(
                "local_id exceeds {MAX_BRIDGE_LOCAL_ID_BYTES} bytes"
            )));
        }
        if request.path_key.len() > MAX_BRIDGE_PATH_KEY_BYTES {
            return Err(BridgeError::InvalidRequest(format!(
                "path_key exceeds {MAX_BRIDGE_PATH_KEY_BYTES} bytes"
            )));
        }
        if request.book_id.is_some() {
            return Err(BridgeError::InvalidRequest(
                "book_id requires a library-backed resolver; use an untracked locator".to_owned(),
            ));
        }
        let path = crate::path_key::try_path_from_key(&request.path_key).map_err(|_| {
            BridgeError::InvalidRequest("path_key uses an invalid reserved encoding".to_owned())
        })?;
        let local_path = crate::path_key::canonical_path_key(
            &path.canonicalize().unwrap_or_else(|_| path.clone()),
        );
        let mut locator = DeviceFileLocator::new(request.local_id, path);
        if let Some(format) = request.format_hint {
            locator = locator.with_format_hint(format);
        }
        let document_slot =
            acquire_permits(Arc::clone(&self.admission.document_slots), 1, &cancellation).await?;
        let planning_slot =
            acquire_permits(Arc::clone(&self.admission.planning_slots), 1, &cancellation).await?;
        let planning_cancellation = cancellation.clone();
        let (plan, guards) = tokio::task::spawn_blocking(move || {
            let plan = guarded(|| {
                OpenDocumentPlan::prepare_cancellable(&locator, &planning_cancellation)
                    .map_err(map_open_error)
            });
            (plan, (_request_slot, document_slot, planning_slot))
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        let (_request_slot, document_slot, planning_slot) = guards;
        check_cancelled(&cancellation)?;
        let plan = plan?;
        drop(planning_slot);
        let maximum_retained_bytes = plan
            .retained_admission_byte_len()
            .filter(|bytes| *bytes <= MAX_BRIDGE_RETAINED_DOCUMENT_BYTES)
            .ok_or(BridgeError::DocumentLimit)?;
        let maximum_byte_permits =
            u32::try_from(maximum_retained_bytes).map_err(|_| BridgeError::DocumentLimit)?;
        let document_bytes = acquire_permits(
            Arc::clone(&self.admission.document_bytes),
            maximum_byte_permits,
            &cancellation,
        )
        .await?;
        let open_slot =
            acquire_permits(Arc::clone(&self.admission.open_slots), 1, &cancellation).await?;
        let worker_cancellation = cancellation.clone();
        let (opened, guards) = tokio::task::spawn_blocking(move || {
            let document = guarded(|| {
                plan.open_with_content_hash_cancellable(worker_cancellation)
                    .map_err(map_open_error)
            });
            (
                document,
                (_request_slot, document_slot, document_bytes, open_slot),
            )
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        let (_request_slot, document_slot, mut document_bytes, open_slot) = guards;
        check_cancelled(&cancellation)?;
        let (document, content_hash) = opened?;
        let actual_retained_bytes = document
            .retained_byte_len()
            .ok_or(BridgeError::DocumentLimit)?;
        if actual_retained_bytes > maximum_retained_bytes {
            return Err(BridgeError::DocumentLimit);
        }
        let unused_bytes = maximum_retained_bytes - actual_retained_bytes;
        drop(document_bytes.split(unused_bytes));
        drop(open_slot);
        let _publication = cancellation
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        check_cancelled(&cancellation)?;

        let handle = self.document_handle();
        let format = document.format();
        let summary = DocumentSummary {
            handle,
            book_id: request.book_id,
            format,
            title: document.title(),
            logical_unit: if format == BookFormat::Epub {
                LogicalUnit::Chapter
            } else {
                LogicalUnit::Page
            },
            logical_unit_count: document.page_count(),
        };
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .insert(
                handle,
                Arc::new(RetainedDocument {
                    document,
                    book_id: request.book_id,
                    local_path,
                    fingerprint: DocumentFingerprint::new(
                        "sha256-hex",
                        1,
                        content_hash.into_bytes(),
                    )
                    .map_err(storage_error)?,
                    _bytes: document_bytes,
                    _slot: document_slot,
                }),
            );
        Ok(summary)
    }

    async fn state_store(&self) -> Result<&ReadingStateStore, BridgeError> {
        self.state_store
            .get_or_try_init(|| async {
                #[cfg(test)]
                if let Some(gate) = &self.state_store_initialization_gate {
                    gate.pause().await;
                }
                match self.annotation_database.as_deref() {
                    Some(path) => ReadingStateStore::open_at_async_deferred_backfill(path).await,
                    None => ReadingStateStore::open_async_deferred_backfill().await,
                }
                .map_err(|error| BridgeError::Storage(error.to_string()))
            })
            .await
    }

    async fn library(&self) -> Result<Library, BridgeError> {
        let state = self.state_store().await?;
        let library = Library::new(state.pool().clone(), state.managed_books_dir());
        #[cfg(test)]
        if let Some(barrier) = &self.library_query_progress_barrier {
            library.set_query_progress_barrier(Arc::clone(barrier));
        }
        Ok(library)
    }

    pub async fn library_page(
        &self,
        query: Option<String>,
        format: Option<BookFormat>,
        limit: u32,
        offset: u32,
    ) -> Result<LibraryPageDto, BridgeError> {
        if query
            .as_ref()
            .is_some_and(|query| query.len() > crate::library::MAX_LIBRARY_QUERY_BYTES)
        {
            return Err(BridgeError::InvalidRequest(
                "library query exceeds its byte limit".into(),
            ));
        }
        let BookPage { books, has_more } = self
            .library()
            .await?
            .metadata_page(query.as_deref(), format, limit, offset)
            .await
            .map_err(storage_error)?;
        Ok(LibraryPageDto {
            books: books.into_iter().map(Into::into).collect(),
            has_more,
        })
    }

    pub async fn library_page_cancellable(
        &self,
        query: Option<String>,
        format: Option<BookFormat>,
        limit: u32,
        offset: u32,
        cancellation: Cancellation,
    ) -> Result<LibraryPageDto, BridgeError> {
        if query
            .as_ref()
            .is_some_and(|query| query.len() > crate::library::MAX_LIBRARY_QUERY_BYTES)
        {
            return Err(BridgeError::InvalidRequest(
                "library query exceeds its byte limit".into(),
            ));
        }
        check_cancelled(&cancellation)?;
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let cancelled = cancellation.flag();
        let cancellation_notifier = cancellation.notifier();
        let bridge = self.clone();
        let initialization_cancellation = cancellation.clone();
        let query_cancelled = Arc::clone(&cancelled);
        let query_notifier = Arc::clone(&cancellation_notifier);
        let query_future = tokio::spawn(async move {
            let library = bridge.library().await;
            let result = if initialization_cancellation.is_cancelled() {
                Err(BridgeError::Cancelled)
            } else {
                match library {
                    Ok(library) => library
                        .metadata_page_cancellable(
                            query.as_deref(),
                            format,
                            limit,
                            offset,
                            query_cancelled,
                            query_notifier,
                        )
                        .await
                        .map_err(|error| {
                            if error.is::<LibraryQueryCancelled>() {
                                BridgeError::Cancelled
                            } else if error.is::<LibraryQueryWorkLimit>() {
                                BridgeError::BufferLimit
                            } else {
                                storage_error(error)
                            }
                        }),
                    Err(error) => Err(error),
                }
            };
            (result, request_slot)
        });
        tokio::pin!(query_future);
        let result = tokio::select! {
            result = &mut query_future => result,
            () = cancellation.cancelled() => {
                cancelled.store(true, Ordering::Release);
                cancellation_notifier.notify_one();
                #[cfg(test)]
                if let Some(gate) = &self.product_read_cancellation_gate {
                    gate.pause().await;
                }
                query_future.await
            }
        };
        let (result, _request_slot) = result.map_err(|_| BridgeError::Worker)?;
        check_cancelled(&cancellation)?;
        let BookPage { books, has_more } = result?;
        Ok(LibraryPageDto {
            books: books.into_iter().map(Into::into).collect(),
            has_more,
        })
    }

    pub async fn library_cover(
        &self,
        book_id: i64,
        cancellation: Cancellation,
    ) -> Result<Option<Vec<u8>>, BridgeError> {
        check_cancelled(&cancellation)?;
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let cover = self
            .library()
            .await?
            .cover(book_id)
            .await
            .map_err(storage_error)?;
        drop(request_slot);
        check_cancelled(&cancellation)?;
        Ok(cover)
    }

    pub async fn import_paths(
        &self,
        path_keys: Vec<String>,
        managed: bool,
        cancellation: Cancellation,
    ) -> Result<Vec<ImportItemDto>, BridgeError> {
        check_cancelled(&cancellation)?;
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let bridge = self.clone();
        let operation = tokio::spawn(async move {
            let result = bridge
                .import_paths_admitted(path_keys, managed, cancellation)
                .await;
            (result, request_slot)
        });
        let (result, _request_slot) = operation.await.map_err(|_| BridgeError::Worker)?;
        result
    }

    pub async fn import_directory(
        &self,
        path_key: String,
        managed: bool,
        cancellation: Cancellation,
    ) -> Result<ImportReportDto, BridgeError> {
        check_cancelled(&cancellation)?;
        if path_key.len() > MAX_BRIDGE_PATH_KEY_BYTES {
            return Err(BridgeError::InvalidRequest(
                "import path key is too long".into(),
            ));
        }
        let path = crate::path_key::try_path_from_key(&path_key)
            .map_err(|_| BridgeError::InvalidRequest("invalid import path key".into()))?;
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let bridge = self.clone();
        let operation = tokio::spawn(async move {
            let result = async {
                let library = bridge.library().await?;
                let discovery_cancellation = ImportCancellation::default();
                let operation_cancellation = discovery_cancellation.clone();
                let discovering =
                    library.discover_directory_cancellable(path, operation_cancellation.clone());
                tokio::pin!(discovering);
                let discovery = tokio::select! {
                    discovery = &mut discovering => discovery,
                    () = cancellation.cancelled() => {
                        discovery_cancellation.cancel();
                        discovering.await
                    }
                };
                check_cancelled(&cancellation)?;
                let mut imported = 0;
                let mut failed = discovery.failures.len();
                let mut items = discovery
                    .failures
                    .into_iter()
                    .take(256)
                    .map(|failure| ImportItemDto {
                        path_key: crate::path_key(failure.path()),
                        book: None,
                        error: Some(failure.error().to_owned()),
                    })
                    .collect::<Vec<_>>();
                for candidate in discovery.candidates {
                    let candidate_path_key = crate::path_key(&candidate.path);
                    match bridge
                        .import_candidate(&library, candidate, managed, &cancellation)
                        .await
                    {
                        Ok(book) => {
                            imported += 1;
                            if items.len() < 256 {
                                items.push(import_item(candidate_path_key, book));
                            }
                        }
                        Err(BridgeError::Cancelled) if imported > 0 || failed > 0 => {
                            return Ok(ImportReportDto {
                                imported,
                                failed,
                                cancelled: true,
                                items,
                            });
                        }
                        Err(BridgeError::Cancelled) => return Err(BridgeError::Cancelled),
                        Err(error) => {
                            failed += 1;
                            if items.len() < 256 {
                                items.push(ImportItemDto {
                                    path_key: candidate_path_key,
                                    book: None,
                                    error: Some(error.to_string()),
                                });
                            }
                        }
                    }
                }
                Ok(ImportReportDto {
                    imported,
                    failed,
                    cancelled: false,
                    items,
                })
            }
            .await;
            (result, request_slot)
        });
        let (result, _request_slot) = operation.await.map_err(|_| BridgeError::Worker)?;
        result
    }

    async fn import_candidate(
        &self,
        library: &Library,
        candidate: ImportCandidate,
        managed: bool,
        cancellation: &Cancellation,
    ) -> Result<Book, BridgeError> {
        let import_cancellation = ImportCancellation::default();
        let operation_cancellation = import_cancellation.clone();
        let importing = async {
            if managed {
                library
                    .import_discovered_file_cancellable(candidate, operation_cancellation)
                    .await
            } else {
                library
                    .link_discovered_file_cancellable(candidate, operation_cancellation)
                    .await
            }
        };
        tokio::pin!(importing);
        let completion = tokio::select! {
            completion = &mut importing => completion,
            () = cancellation.cancelled() => {
                import_cancellation.cancel();
                importing.await
            }
        };
        match completion {
            ImportCompletion::Cancelled => Err(BridgeError::Cancelled),
            ImportCompletion::Completed(Ok(imported)) => library
                .get(imported.book_id())
                .await
                .map_err(storage_error)?
                .ok_or_else(|| BridgeError::Storage("book not found after import".into())),
            ImportCompletion::Completed(Err(failure)) => {
                Err(BridgeError::Storage(failure.error().to_owned()))
            }
        }
    }

    async fn import_paths_admitted(
        &self,
        path_keys: Vec<String>,
        managed: bool,
        cancellation: Cancellation,
    ) -> Result<Vec<ImportItemDto>, BridgeError> {
        if path_keys.len() > 256 {
            return Err(BridgeError::InvalidRequest(
                "at most 256 selected paths may be imported".into(),
            ));
        }
        // Validate the complete request before the first filesystem or database effect.
        let paths = path_keys
            .iter()
            .map(|path_key| {
                if path_key.len() > MAX_BRIDGE_PATH_KEY_BYTES {
                    return Err(BridgeError::InvalidRequest(
                        "import path key is too long".into(),
                    ));
                }
                crate::path_key::try_path_from_key(path_key)
                    .map_err(|_| BridgeError::InvalidRequest("invalid import path key".into()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let library = self.library().await?;
        let mut items = Vec::with_capacity(path_keys.len());
        for (path_key, path) in path_keys.into_iter().zip(paths) {
            // Once an item has committed, preserve and return that definitive outcome instead of
            // replacing the whole batch with an ambiguous cancellation error.
            if cancellation.is_cancelled() {
                if items.is_empty() {
                    return Err(BridgeError::Cancelled);
                }
                break;
            }
            let import_cancellation = ImportCancellation::default();
            let operation_cancellation = import_cancellation.clone();
            let failure_path = path.clone();
            let importing = async {
                let mut discovery = library
                    .discover_files_cancellable(vec![path], operation_cancellation.clone())
                    .await;
                if operation_cancellation.is_cancelled() {
                    return ImportCompletion::Cancelled;
                }
                if let Some(failure) = discovery.failures.pop() {
                    return ImportCompletion::Completed(Err(failure));
                }
                let Some(candidate) = discovery.candidates.pop() else {
                    return ImportCompletion::Completed(Err(crate::library::ImportFailure::new(
                        failure_path,
                        "selected path did not produce an import candidate",
                    )));
                };
                if managed {
                    library
                        .import_discovered_file_cancellable(candidate, operation_cancellation)
                        .await
                } else {
                    library
                        .link_discovered_file_cancellable(candidate, operation_cancellation)
                        .await
                }
            };
            tokio::pin!(importing);
            let completion = tokio::select! {
                completion = &mut importing => completion,
                () = cancellation.cancelled() => {
                    import_cancellation.cancel();
                    importing.await
                }
            };
            let result: anyhow::Result<Book> = match completion {
                ImportCompletion::Cancelled => {
                    if items.is_empty() {
                        return Err(BridgeError::Cancelled);
                    }
                    break;
                }
                ImportCompletion::Completed(Ok(imported)) => {
                    match library.get(imported.book_id()).await {
                        Ok(Some(book)) => Ok(book),
                        Ok(None) => Err(anyhow::anyhow!("book not found after import")),
                        Err(error) => Err(error),
                    }
                }
                ImportCompletion::Completed(Err(failure)) => {
                    Err(anyhow::anyhow!(failure.error().to_owned()))
                }
            };
            items.push(match result {
                Ok(book) => import_item(path_key, book),
                Err(error) => ImportItemDto {
                    path_key,
                    book: None,
                    error: Some(error.to_string()),
                },
            });
        }
        Ok(items)
    }

    pub async fn open_library_book(
        &self,
        book_id: i64,
        cancellation: Cancellation,
    ) -> Result<DocumentSummary, BridgeError> {
        let book = self
            .library()
            .await?
            .get(book_id)
            .await
            .map_err(storage_error)?
            .ok_or(BridgeError::DocumentNotFound)?;
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let document_slot =
            acquire_permits(Arc::clone(&self.admission.document_slots), 1, &cancellation).await?;
        let planning_slot =
            acquire_permits(Arc::clone(&self.admission.planning_slots), 1, &cancellation).await?;
        let path = crate::path_from_key(&book.file_path);
        let mut locator = DeviceFileLocator::new(format!("library:{book_id}"), path.clone());
        locator = locator.with_format_hint(book.format);
        let planning_cancellation = cancellation.clone();
        let (plan, guards) = tokio::task::spawn_blocking(move || {
            let plan = guarded(|| {
                OpenDocumentPlan::prepare_cancellable(&locator, &planning_cancellation)
                    .map_err(map_open_error)
            });
            (plan, (request_slot, document_slot, planning_slot))
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        let (request_slot, document_slot, planning_slot) = guards;
        check_cancelled(&cancellation)?;
        let plan = plan?;
        drop(planning_slot);
        let maximum_retained_bytes = plan
            .retained_admission_byte_len()
            .filter(|bytes| *bytes <= MAX_BRIDGE_RETAINED_DOCUMENT_BYTES)
            .ok_or(BridgeError::DocumentLimit)?;
        let bytes = acquire_permits(
            Arc::clone(&self.admission.document_bytes),
            u32::try_from(maximum_retained_bytes).map_err(|_| BridgeError::DocumentLimit)?,
            &cancellation,
        )
        .await?;
        let open_slot =
            acquire_permits(Arc::clone(&self.admission.open_slots), 1, &cancellation).await?;
        let library = self.library().await?;
        let opening_cancellation = cancellation.clone();
        #[cfg(test)]
        let worker_barrier = self.library_open_worker_barrier.clone();
        let opening = tokio::spawn(async move {
            library
                .open_book_document_plan_with_guards(
                    book_id,
                    &path,
                    plan,
                    opening_cancellation,
                    (request_slot, document_slot, bytes, open_slot),
                    #[cfg(test)]
                    worker_barrier,
                )
                .await
        });
        let opened = opening.await.map_err(|_| BridgeError::Worker)?;
        check_cancelled(&cancellation)?;
        let ((document, hash), (mut request_slot, document_slot, mut bytes, open_slot)) =
            opened.map_err(library_open_error)?;
        let retained = document
            .retained_byte_len()
            .ok_or(BridgeError::DocumentLimit)?;
        if retained > maximum_retained_bytes {
            return Err(BridgeError::DocumentLimit);
        }
        drop(bytes.split(maximum_retained_bytes - retained));
        drop(open_slot);
        let handle = self.document_handle();
        let format = document.format();
        let summary = DocumentSummary {
            handle,
            book_id: Some(book_id),
            format,
            title: document.title(),
            logical_unit: if format == BookFormat::Epub {
                LogicalUnit::Chapter
            } else {
                LogicalUnit::Page
            },
            logical_unit_count: document.page_count(),
        };
        let fingerprint =
            DocumentFingerprint::new("sha256-hex", 1, hash.into_bytes()).map_err(storage_error)?;
        let mut reconciliation_accepted = false;
        if let Ok(annotation_format) = annotation_document_format(&document) {
            let cancelled = cancellation.flag();
            let cancellation_notifier = cancellation.notifier();
            let bridge = self.clone();
            let initialization_cancellation = cancellation.clone();
            let commit_cancellation = cancellation.clone();
            let local_path = book.file_path.clone();
            let reconciliation_fingerprint = fingerprint.clone();
            let reconciliation_cancelled = Arc::clone(&cancelled);
            let reconciliation_notifier = Arc::clone(&cancellation_notifier);
            #[cfg(test)]
            let progress_barrier = self.annotation_reconciliation_progress_barrier.clone();
            #[cfg(test)]
            let work_limit = self.annotation_reconciliation_work_limit;
            let reconciliation = tokio::spawn(async move {
                #[cfg(test)]
                if let Some(gate) = &bridge.before_annotation_reconciliation {
                    gate.pause().await;
                }
                let store = bridge.annotation_store().await;
                let result = if initialization_cancellation.is_cancelled() {
                    Err(BridgeError::Cancelled)
                } else {
                    match store {
                        Ok(store) => store
                            .reconcile_opened_book_cancellable_async(
                                book_id,
                                &local_path,
                                annotation_format,
                                &reconciliation_fingerprint,
                                reconciliation_cancelled,
                                reconciliation_notifier,
                                #[cfg(test)]
                                progress_barrier,
                                #[cfg(test)]
                                work_limit,
                                move || {
                                    let _publication = commit_cancellation
                                        .0
                                        .publication
                                        .lock()
                                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                                    !commit_cancellation.is_cancelled()
                                },
                            )
                            .await
                            .map_err(annotation_storage_error),
                        Err(error) => Err(error),
                    }
                };
                #[cfg(test)]
                if result.is_ok()
                    && let Some(gate) = &bridge.after_annotation_reconciliation_commit
                {
                    gate.pause().await;
                }
                (result, request_slot)
            });
            tokio::pin!(reconciliation);
            let result = tokio::select! {
                result = &mut reconciliation => result,
                () = cancellation.cancelled() => {
                    cancelled.store(true, Ordering::Release);
                    cancellation_notifier.notify_one();
                    #[cfg(test)]
                    if let Some(gate) = &self.product_read_cancellation_gate {
                        gate.pause().await;
                    }
                    reconciliation.await
                }
            };
            let (result, returned_request_slot) = result.map_err(|_| BridgeError::Worker)?;
            request_slot = returned_request_slot;
            reconciliation_accepted = result.is_ok();
            result?;
        }
        let _publication = cancellation
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !reconciliation_accepted {
            check_cancelled(&cancellation)?;
        }
        self.registry
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .documents
            .insert(
                handle,
                Arc::new(RetainedDocument {
                    document,
                    book_id: Some(book_id),
                    local_path: book.file_path,
                    fingerprint,
                    _bytes: bytes,
                    _slot: document_slot,
                }),
            );
        drop(request_slot);
        Ok(summary)
    }

    pub async fn search_document(
        &self,
        handle: DocumentHandle,
        query: String,
        cancellation: Cancellation,
    ) -> Result<Vec<SearchMatch>, BridgeError> {
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let retained = self.document(handle)?;
        let document = retained.document.clone();
        let format = document.format();
        if format == BookFormat::Cbz {
            return Err(BridgeError::UnsupportedOperation(BookFormat::Cbz));
        }
        let limits = SearchLimits::default();
        let workspace = limits
            .maximum_workspace_bytes()
            .ok_or(BridgeError::BufferLimit)?;
        if workspace > self.admission.buffer_capacity {
            return Err(BridgeError::BufferLimit);
        }
        let worker_slot =
            acquire_permits(Arc::clone(&self.admission.render_slots), 1, &cancellation).await?;
        let workspace = acquire_permits(
            Arc::clone(&self.admission.buffer_bytes),
            u32::try_from(workspace).map_err(|_| BridgeError::BufferLimit)?,
            &cancellation,
        )
        .await?;
        let search_cancel = SearchCancellation::new();
        let worker_cancel = search_cancel.clone();
        let mut worker = tokio::task::spawn_blocking(move || {
            let _guards = (request_slot, workspace, worker_slot, retained);
            match &document {
                OpenDocument::Pdf(pdf) => {
                    crate::search::search_pdf_with(pdf, &query, limits, &worker_cancel)
                }
                OpenDocument::Epub(epub) => {
                    crate::search::search_epub_with(epub, &query, limits, &worker_cancel)
                }
                OpenDocument::Cbz(_) => {
                    Err(SearchError::Document("CBZ has no searchable text".into()))
                }
            }
        });
        tokio::select! {
            result = &mut worker => result.map_err(|_| BridgeError::Worker)?.map_err(|error| match error {
                SearchError::Cancelled => BridgeError::Cancelled,
                SearchError::QueryLimit { .. } | SearchError::InvalidLimit { .. } => BridgeError::InvalidRequest(error.to_string()),
                SearchError::ResultLimit { .. } | SearchError::TextLimit { .. } | SearchError::MatchLimit { .. } => BridgeError::OpenLimit { format, detail: error.to_string() },
                _ => BridgeError::Render(error.to_string()),
            }),
            () = cancellation.cancelled() => {
                search_cancel.cancel();
                let _ = worker.await.map_err(|_| BridgeError::Worker)?;
                Err(BridgeError::Cancelled)
            }
        }
    }

    pub async fn list_bookmarks(&self, book_id: i64) -> Result<Vec<BookmarkDto>, BridgeError> {
        let store = self.state_store().await?;
        BookmarkStore::new(store.pool().clone())
            .list_for_book_async(book_id)
            .await
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(bookmark_storage_error)
    }

    pub async fn list_bookmarks_cancellable(
        &self,
        book_id: i64,
        cancellation: Cancellation,
    ) -> Result<Vec<BookmarkDto>, BridgeError> {
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        check_cancelled(&cancellation)?;
        let bridge = self.clone();
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            let result = bridge.list_bookmarks(book_id).await;
            let result = if operation_cancellation.is_cancelled() {
                Err(BridgeError::Cancelled)
            } else {
                result
            };
            (result, request_slot)
        });
        tokio::pin!(operation);
        let (result, _request_slot) = tokio::select! {
            result = &mut operation => result.map_err(|_| BridgeError::Worker)?,
            () = cancellation.cancelled() => {
                #[cfg(test)]
                if let Some(gate) = &self.product_read_cancellation_gate {
                    gate.pause().await;
                }
                let (_, request_slot) = operation.await.map_err(|_| BridgeError::Worker)?;
                (Err(BridgeError::Cancelled), request_slot)
            },
        };
        check_cancelled(&cancellation)?;
        result
    }

    pub async fn toggle_bookmark(
        &self,
        book_id: i64,
        unit: usize,
        offset: Option<usize>,
        title: Option<String>,
    ) -> Result<Option<BookmarkDto>, BridgeError> {
        if unit > i64::MAX as usize
            || offset.is_some_and(|value| value > i64::MAX as usize)
            || title
                .as_ref()
                .is_some_and(|value| value.len() > crate::bookmarks::MAX_BOOKMARK_TITLE_BYTES)
        {
            return Err(BridgeError::InvalidRequest(
                "bookmark title exceeds its byte limit".into(),
            ));
        }
        let store = self.state_store().await?;
        BookmarkStore::new(store.pool().clone())
            .toggle_for_book_at_async(
                book_id,
                std::path::Path::new(""),
                unit,
                offset,
                title.as_deref(),
            )
            .await
            .map(|v| v.map(Into::into))
            .map_err(bookmark_storage_error)
    }

    pub async fn update_bookmark(
        &self,
        id: i64,
        title: Option<String>,
        note: Option<String>,
    ) -> Result<(), BridgeError> {
        if title
            .as_ref()
            .is_some_and(|value| value.len() > crate::bookmarks::MAX_BOOKMARK_TITLE_BYTES)
            || note
                .as_ref()
                .is_some_and(|value| value.len() > crate::bookmarks::MAX_BOOKMARK_NOTE_BYTES)
        {
            return Err(BridgeError::InvalidRequest(
                "bookmark fields exceed their byte limits".into(),
            ));
        }
        let store = self.state_store().await?;
        let bookmarks = BookmarkStore::new(store.pool().clone());
        bookmarks
            .update_fields_async(id, title.as_deref(), note.as_deref())
            .await
            .map_err(bookmark_storage_error)
    }

    pub async fn delete_bookmark(&self, id: i64) -> Result<(), BridgeError> {
        let store = self.state_store().await?;
        BookmarkStore::new(store.pool().clone())
            .remove_async(id)
            .await
            .map_err(storage_error)
    }

    pub async fn export_bookmarks(&self, book_id: i64) -> Result<String, BridgeError> {
        let state = self.state_store().await?;
        let book = self
            .library()
            .await?
            .get(book_id)
            .await
            .map_err(storage_error)?
            .ok_or(BridgeError::DocumentNotFound)?;
        let hash = book
            .content_hash
            .ok_or_else(|| BridgeError::Storage("book has no content fingerprint".into()))?;
        BookmarkStore::new(state.pool().clone())
            .export_markdown_async(&crate::path_from_key(&book.file_path), &hash)
            .await
            .map_err(bookmark_storage_error)
    }

    pub async fn load_reading_state(
        &self,
        book_id: i64,
    ) -> Result<Option<ReadingStateDto>, BridgeError> {
        self.state_store()
            .await?
            .get_for_book_async(book_id)
            .await
            .map(|v| {
                v.map(|s| ReadingStateDto {
                    unit: s.page,
                    offset: s.location_offset,
                    zoom: s.zoom,
                })
            })
            .map_err(storage_error)
    }

    pub async fn load_reading_state_cancellable(
        &self,
        book_id: i64,
        cancellation: Cancellation,
    ) -> Result<Option<ReadingStateDto>, BridgeError> {
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        check_cancelled(&cancellation)?;
        let bridge = self.clone();
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            let result = bridge.load_reading_state(book_id).await;
            let result = if operation_cancellation.is_cancelled() {
                Err(BridgeError::Cancelled)
            } else {
                result
            };
            (result, request_slot)
        });
        tokio::pin!(operation);
        let (result, _request_slot) = tokio::select! {
            result = &mut operation => result.map_err(|_| BridgeError::Worker)?,
            () = cancellation.cancelled() => {
                #[cfg(test)]
                if let Some(gate) = &self.product_read_cancellation_gate {
                    gate.pause().await;
                }
                let (_, request_slot) = operation.await.map_err(|_| BridgeError::Worker)?;
                (Err(BridgeError::Cancelled), request_slot)
            },
        };
        check_cancelled(&cancellation)?;
        result
    }

    pub async fn save_reading_state(
        &self,
        book_id: i64,
        value: ReadingStateDto,
    ) -> Result<(), BridgeError> {
        let unit_count = self
            .registry
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .documents
            .values()
            .find(|document| document.book_id == Some(book_id))
            .map(|document| document.document.page_count());
        self.save_reading_state_inner(book_id, value, unit_count)
            .await
    }

    pub async fn save_reading_state_with_unit_count(
        &self,
        book_id: i64,
        value: ReadingStateDto,
        unit_count: usize,
    ) -> Result<(), BridgeError> {
        if unit_count == 0 {
            return Err(BridgeError::InvalidRequest(
                "unit count must be positive".into(),
            ));
        }
        self.save_reading_state_inner(book_id, value, Some(unit_count))
            .await
    }

    async fn save_reading_state_inner(
        &self,
        book_id: i64,
        value: ReadingStateDto,
        unit_count: Option<usize>,
    ) -> Result<(), BridgeError> {
        if !value.zoom.is_finite()
            || value.zoom <= 0.0
            || value.unit > i64::MAX as usize
            || value
                .offset
                .is_some_and(|offset| offset > i64::MAX as usize)
        {
            return Err(BridgeError::InvalidRequest(
                "zoom must be finite and positive".into(),
            ));
        }
        let state = FileReadingState {
            page: value.unit,
            location_offset: value.offset,
            zoom: value.zoom,
        };
        let store = self.state_store().await?;
        if let Some(unit_count) = unit_count {
            store
                .set_for_book_with_progress_async(
                    book_id,
                    &state,
                    reading_progress(value.unit, unit_count),
                )
                .await
                .map_err(reading_state_storage_error)?;
        } else {
            store
                .set_for_book_async(book_id, &state)
                .await
                .map_err(reading_state_storage_error)?;
        }
        Ok(())
    }

    pub async fn load_reader_settings(&self) -> Result<ReaderSettingsDto, BridgeError> {
        let store = self.state_store().await?;
        let mut p = ReaderPreferences {
            reading_mode: ReadingMode::from_stored(
                store
                    .get_pref_async("reader.mode")
                    .await
                    .map_err(storage_error)?
                    .as_deref(),
            ),
            theme: ReaderTheme::from_stored(
                store
                    .get_pref_async("reader.theme")
                    .await
                    .map_err(storage_error)?
                    .as_deref(),
            ),
            ..ReaderPreferences::default()
        };
        if let Some(v) = store
            .get_pref_async("reader.epub_font_size")
            .await
            .map_err(storage_error)?
            .and_then(|v| v.parse().ok())
        {
            p.epub_font_size = v;
        }
        if let Some(v) = store
            .get_pref_async("reader.epub_line_spacing")
            .await
            .map_err(storage_error)?
            .and_then(|v| v.parse().ok())
        {
            p.epub_line_spacing = v;
        }
        if let Some(v) = store
            .get_pref_async("reader.pdf_zoom")
            .await
            .map_err(storage_error)?
            .and_then(|v| v.parse::<f32>().ok())
        {
            p.pdf_zoom = if v == 0.0 {
                ZoomMode::FitPage
            } else if v == -1.0 {
                ZoomMode::FitWidth
            } else {
                ZoomMode::Manual(v)
            };
        }
        Ok(p.into())
    }

    pub async fn load_reader_settings_cancellable(
        &self,
        cancellation: Cancellation,
    ) -> Result<ReaderSettingsDto, BridgeError> {
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        check_cancelled(&cancellation)?;
        let bridge = self.clone();
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            let result = bridge.load_reader_settings().await;
            let result = if operation_cancellation.is_cancelled() {
                Err(BridgeError::Cancelled)
            } else {
                result
            };
            (result, request_slot)
        });
        tokio::pin!(operation);
        let (result, _request_slot) = tokio::select! {
            result = &mut operation => result.map_err(|_| BridgeError::Worker)?,
            () = cancellation.cancelled() => {
                #[cfg(test)]
                if let Some(gate) = &self.product_read_cancellation_gate {
                    gate.pause().await;
                }
                let (_, request_slot) = operation.await.map_err(|_| BridgeError::Worker)?;
                (Err(BridgeError::Cancelled), request_slot)
            },
        };
        check_cancelled(&cancellation)?;
        result
    }

    pub async fn save_reader_settings(&self, value: ReaderSettingsDto) -> Result<(), BridgeError> {
        if !(8.0..=72.0).contains(&value.epub_font_size)
            || !(1.0..=3.0).contains(&value.epub_line_spacing)
            || !matches!(value.theme.as_str(), "light" | "sepia" | "dark")
            || !value.pdf_zoom.is_finite()
            || (value.pdf_zoom != 0.0
                && value.pdf_zoom != -1.0
                && !(0.25..=8.0).contains(&value.pdf_zoom))
        {
            return Err(BridgeError::InvalidRequest(
                "reader settings are outside supported bounds".into(),
            ));
        }
        self.state_store()
            .await?
            .set_prefs_async(&[
                (
                    "reader.mode",
                    if value.continuous {
                        "continuous"
                    } else {
                        "paginated"
                    }
                    .to_owned(),
                ),
                ("reader.theme", value.theme),
                ("reader.epub_font_size", value.epub_font_size.to_string()),
                (
                    "reader.epub_line_spacing",
                    value.epub_line_spacing.to_string(),
                ),
                ("reader.pdf_zoom", value.pdf_zoom.to_string()),
            ])
            .await
            .map_err(storage_error)
    }

    pub async fn remove_library_book(&self, book_id: i64) -> Result<bool, BridgeError> {
        let library = self.library().await?;
        if library.get(book_id).await.map_err(storage_error)?.is_none() {
            return Ok(false);
        }
        library
            .remove(book_id)
            .await
            .map_err(library_mutation_error)?;
        Ok(true)
    }

    async fn annotation_store(&self) -> Result<&AnnotationStore, BridgeError> {
        self.annotation_store
            .get_or_try_init(|| async {
                #[cfg(test)]
                if let Some(gate) = self
                    .annotation_test_hooks
                    .as_ref()
                    .and_then(|hooks| hooks.initialization.as_ref())
                {
                    gate.pause().await;
                }
                let state = match self.annotation_database.as_deref() {
                    Some(path) => {
                        crate::reading_state::ReadingStateStore::open_at_async_deferred_backfill(
                            path,
                        )
                        .await
                    }
                    None => {
                        crate::reading_state::ReadingStateStore::open_async_deferred_backfill()
                            .await
                    }
                }
                .map_err(|error| BridgeError::Storage(error.to_string()))?;
                #[cfg(test)]
                return Ok(AnnotationStore::new_with_test_gates(
                    state.pool().clone(),
                    self.annotation_test_hooks
                        .as_ref()
                        .and_then(|hooks| hooks.persistence.clone()),
                    self.annotation_test_hooks
                        .as_ref()
                        .and_then(|hooks| hooks.list.clone()),
                    self.annotation_test_hooks
                        .as_ref()
                        .is_some_and(|hooks| hooks.fail_create_response),
                ));
                #[cfg(not(test))]
                Ok(AnnotationStore::new(state.pool().clone()))
            })
            .await
    }

    pub async fn create_annotation(
        &self,
        request: CreateAnnotationRequest,
        cancellation: Cancellation,
    ) -> Result<BridgeAnnotation, BridgeError> {
        let CreateAnnotationRequest {
            document,
            unit,
            start,
            end,
            display_scale,
            color,
            body,
        } = request;
        validate_annotation_body(body.as_deref())?;
        if start >= end {
            return Err(BridgeError::InvalidRequest(
                "annotation range must be non-empty".into(),
            ));
        }
        if !display_scale.is_finite() || display_scale <= 0.0 {
            return Err(BridgeError::InvalidRequest(
                "annotation display scale must be finite and positive".into(),
            ));
        }
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let retained = self.document(document)?;
        check_cancelled(&cancellation)?;
        let store = tokio::select! {
            store = self.annotation_store() => store?,
            () = cancellation.cancelled() => return Err(BridgeError::Cancelled),
        };
        let extraction_scale = if matches!(&retained.document, OpenDocument::Pdf(_)) {
            display_scale
        } else {
            1.0
        };
        let extracted = self
            .extract_selection(
                document,
                Arc::clone(&retained),
                unit,
                extraction_scale,
                680.0,
                18.0,
                false,
                &cancellation,
                request_slot,
            )
            .await?;
        let surface = &extracted.surface;
        let chars: Vec<char> = surface.text.chars().collect();
        if end > chars.len() {
            return Err(BridgeError::InvalidRequest(
                "annotation range exceeds text".into(),
            ));
        }
        let quote = QuoteSelector::new(
            &chars[start..end].iter().collect::<String>(),
            &chars[..start].iter().collect::<String>(),
            &chars[end..].iter().collect::<String>(),
        )
        .map_err(storage_error)?;
        let (target, quote) = match &retained.document {
            OpenDocument::Epub(_) => (
                AnnotationTarget::Epub(
                    EpubAnchor::new(
                        u32::try_from(unit).map_err(|_| {
                            BridgeError::InvalidRequest("unit exceeds range".into())
                        })?,
                        surface.resource_path.as_deref().ok_or_else(|| {
                            BridgeError::InvalidRequest("EPUB resource path missing".into())
                        })?,
                        u32::try_from(start).map_err(|_| {
                            BridgeError::InvalidRequest("range exceeds range".into())
                        })?,
                        u32::try_from(end).map_err(|_| {
                            BridgeError::InvalidRequest("range exceeds range".into())
                        })?,
                    )
                    .map_err(storage_error)?,
                ),
                Some(quote),
            ),
            OpenDocument::Pdf(_) => {
                let rectangles = surface
                    .page_rectangles
                    .iter()
                    .copied()
                    .filter(|value| start <= value.character && value.character < end)
                    .map(|value| {
                        PageRect::new(
                            value.rect.left,
                            value.rect.top,
                            value.rect.right,
                            value.rect.bottom,
                        )
                        .map_err(storage_error)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let complete = surface.copy_eligible;
                (
                    AnnotationTarget::Pdf(
                        PdfAnchor::new(
                            u32::try_from(unit).map_err(|_| {
                                BridgeError::InvalidRequest("unit exceeds range".into())
                            })?,
                            complete.then(|| {
                                (
                                    u32::try_from(start).expect("bounded PDF start"),
                                    u32::try_from(end).expect("bounded PDF end"),
                                )
                            }),
                            rectangles,
                        )
                        .map_err(storage_error)?,
                    ),
                    complete.then_some(quote),
                )
            }
            OpenDocument::Cbz(_) => return Err(BridgeError::UnsupportedOperation(BookFormat::Cbz)),
        };
        let annotation = NewAnnotation {
            id: AnnotationId::new(),
            book_id: retained.book_id,
            local_path: Some(retained.local_path.clone()),
            fingerprint: retained.fingerprint.clone(),
            quote,
            target,
            color,
            body,
            provenance: None,
        };
        drop(chars);
        let ExtractedSelection {
            surface,
            request_slot,
            retained_bytes,
        } = extracted;
        drop(surface);
        drop(retained_bytes);
        let conversion_slot =
            acquire_permits(Arc::clone(&self.admission.render_slots), 1, &cancellation).await?;
        let pending = Annotation {
            id: annotation.id.clone(),
            book_id: annotation.book_id,
            local_path: annotation.local_path.clone(),
            fingerprint: annotation.fingerprint.clone(),
            quote: annotation.quote.clone(),
            target: annotation.target.clone(),
            color: annotation.color,
            body: annotation.body.clone(),
            provenance: annotation.provenance.clone(),
            created_at: String::new(),
            modified_at: String::new(),
            deleted_at: None,
        };
        let (mut prepared, response_guards) = self
            .resolve_annotation_dtos(
                Arc::clone(&retained),
                vec![pending],
                display_scale,
                cancellation.clone(),
                vec![request_slot, conversion_slot],
                false,
            )
            .await?;
        let prepared = prepared.remove(0);
        #[cfg(test)]
        if let Some(gate) = self
            .annotation_test_hooks
            .as_ref()
            .and_then(|hooks| hooks.before_acceptance.as_ref())
        {
            gate.pause().await;
        }
        // This is the persistence acceptance boundary: cancellation takes the
        // same lock, so no write can begin after cancellation has won.
        {
            let _publication = cancellation
                .0
                .publication
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            check_cancelled(&cancellation)?;
        }
        store
            .create_async(&annotation)
            .await
            .map_err(annotation_storage_error)?;
        drop(response_guards);
        Ok(prepared)
    }

    pub async fn list_annotations(
        &self,
        document: DocumentHandle,
        scale: f32,
        cancellation: Cancellation,
    ) -> Result<Vec<BridgeAnnotation>, BridgeError> {
        if !scale.is_finite() || scale <= 0.0 {
            return Err(BridgeError::InvalidRequest(
                "annotation display scale must be finite and positive".into(),
            ));
        }
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let render_slot =
            acquire_permits(Arc::clone(&self.admission.render_slots), 1, &cancellation).await?;
        let snapshot_bytes = acquire_permits(
            Arc::clone(&self.admission.probe_bytes),
            u32::try_from(MAX_ANNOTATION_SNAPSHOT_BYTES)
                .expect("annotation snapshot limit fits in u32"),
            &cancellation,
        )
        .await?;
        let retained = self.document(document)?;
        let format = annotation_document_format(&retained.document)?;
        let store = tokio::select! {
            store = self.annotation_store() => store?,
            () = cancellation.cancelled() => return Err(BridgeError::Cancelled),
        };
        check_cancelled(&cancellation)?;
        let listed = tokio::select! {
            result = store.list_for_local_document_async(
                &retained.local_path,
                format,
                Some(&retained.fingerprint),
            ) => {
                check_cancelled(&cancellation)?;
                result.map_err(annotation_storage_error)?
            },
            () = cancellation.cancelled() => return Err(BridgeError::Cancelled),
        };
        let items = bounded_annotation_snapshot(listed)?;
        self.resolve_annotation_dtos(
            retained,
            items,
            scale,
            cancellation,
            vec![request_slot, snapshot_bytes, render_slot],
            true,
        )
        .await
        .map(|(items, _guards)| items)
    }

    pub async fn list_annotation_association_sources(
        &self,
        target: DocumentHandle,
        cursor: Option<&str>,
        limit: usize,
        cancellation: Cancellation,
    ) -> Result<AnnotationAssociationSourcePageDto, BridgeError> {
        let _request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let target = self.document(target)?;
        let format = annotation_document_format(&target.document)?;
        let cursor = cursor
            .map(AnnotationDocumentVersionId::from_str)
            .transpose()
            .map_err(|_| BridgeError::InvalidRequest("invalid association source cursor".into()))?;
        let store = tokio::select! {
            store = self.annotation_store() => store?,
            () = cancellation.cancelled() => return Err(BridgeError::Cancelled),
        };
        let page = store
            .list_association_sources_cancellable_async(
                format,
                &target.local_path,
                &target.fingerprint,
                cursor.as_ref(),
                limit,
                (
                    {
                        let cancellation = cancellation.clone();
                        move || cancellation.is_cancelled()
                    },
                    cancellation.cancelled(),
                ),
            )
            .await
            .map_err(annotation_storage_error)?;
        check_cancelled(&cancellation)?;
        Ok(AnnotationAssociationSourcePageDto {
            sources: page
                .sources
                .into_iter()
                .map(|source| AnnotationAssociationSourceDto {
                    version_id: source.version_id.to_string(),
                    format: match source.format {
                        AnnotationDocumentFormat::Epub => BookFormat::Epub,
                        AnnotationDocumentFormat::Pdf => BookFormat::Pdf,
                    },
                    local_path: source.local_path,
                    fingerprint_algorithm: source.fingerprint.algorithm,
                    fingerprint_version: source.fingerprint.version,
                    fingerprint: source.fingerprint.bytes,
                    live_annotations: source.live_annotations,
                })
                .collect(),
            next_cursor: page.next_cursor.map(|cursor| cursor.to_string()),
            previous_cursor: page.previous_cursor.map(|cursor| cursor.to_string()),
        })
    }

    pub async fn associate_annotation_version(
        &self,
        source_version_id: &str,
        target: DocumentHandle,
        cancellation: Cancellation,
    ) -> Result<AnnotationAssociationOutcome, BridgeError> {
        let _request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let source = AnnotationDocumentVersionId::from_str(source_version_id)
            .map_err(|_| BridgeError::InvalidRequest("invalid association source ID".into()))?;
        let target = self.document(target)?;
        let format = match &target.document {
            OpenDocument::Epub(_) => AnnotationDocumentFormat::Epub,
            OpenDocument::Pdf(_) => AnnotationDocumentFormat::Pdf,
            OpenDocument::Cbz(_) => {
                return Err(BridgeError::UnsupportedOperation(BookFormat::Cbz));
            }
        };
        let store = tokio::select! {
            store = self.annotation_store() => store?,
            () = cancellation.cancelled() => return Err(BridgeError::Cancelled),
        };
        #[cfg(test)]
        if let Some(gate) = self
            .annotation_test_hooks
            .as_ref()
            .and_then(|hooks| hooks.before_acceptance.as_ref())
        {
            gate.pause().await;
        }
        // Association is durable after this acceptance boundary. Cancellation
        // takes the same lock, so it either wins before persistence starts or
        // receives the definitive association result.
        {
            let _publication = cancellation
                .0
                .publication
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            check_cancelled(&cancellation)?;
        }
        store
            .associate_document_version_for_book_async(
                &source,
                format,
                &target.local_path,
                &target.fingerprint,
                target.book_id,
            )
            .await
            .map_err(annotation_storage_error)
    }

    async fn resolve_annotation_dtos(
        &self,
        retained: Arc<RetainedDocument>,
        annotations: Vec<Annotation>,
        scale: f32,
        cancellation: Cancellation,
        mut guards: Vec<OwnedSemaphorePermit>,
        resolve_persisted_text: bool,
    ) -> Result<(Vec<BridgeAnnotation>, Vec<OwnedSemaphorePermit>), BridgeError> {
        if annotations.is_empty() {
            return Ok((Vec::new(), guards));
        }
        let workspace_bytes = if resolve_persisted_text
            && annotations.iter().any(|annotation| {
                matches!(&annotation.target, AnnotationTarget::Epub(_))
                    || matches!(
                        &annotation.target,
                        AnnotationTarget::Pdf(anchor) if anchor.character_range.is_some()
                    )
            }) {
            ANNOTATION_RESOLUTION_WORKSPACE_BYTES
        } else {
            ANNOTATION_GEOMETRY_WORKSPACE_BYTES
        };
        if workspace_bytes as usize > self.admission.buffer_capacity {
            return Err(BridgeError::BufferLimit);
        }
        if workspace_bytes != 0 {
            guards.push(
                acquire_permits(
                    Arc::clone(&self.admission.buffer_bytes),
                    workspace_bytes,
                    &cancellation,
                )
                .await?,
            );
        }
        let worker_cancellation = cancellation.clone();
        #[cfg(test)]
        let worker_barrier = self.annotation_resolution_worker_barrier.clone();
        let current_fingerprint = retained.fingerprint.clone();
        let (result, guards) = tokio::task::spawn_blocking(move || {
            #[cfg(test)]
            if let Some(barrier) = worker_barrier {
                barrier.wait();
                barrier.wait();
            }
            let result = guarded(|| {
                annotation_dtos(
                    annotations,
                    &retained.document,
                    &current_fingerprint,
                    scale,
                    resolve_persisted_text,
                    &|| worker_cancellation.is_cancelled(),
                )
            });
            (result, guards)
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        check_cancelled(&cancellation)?;
        Ok((result?, guards))
    }

    pub async fn update_annotation(
        &self,
        document: DocumentHandle,
        id: &str,
        color: HighlightColor,
        body: Option<String>,
    ) -> Result<bool, BridgeError> {
        validate_annotation_body(body.as_deref())?;
        let _request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let retained = self.document(document)?;
        let format = annotation_document_format(&retained.document)?;
        let id = AnnotationId::from_str(id)
            .map_err(|_| BridgeError::InvalidRequest("invalid annotation ID".into()))?;
        let store = self.annotation_store().await?;
        if let Some(book_id) = retained.book_id {
            store
                .update_for_book_document_async(
                    &id,
                    book_id,
                    &retained.local_path,
                    format,
                    &retained.fingerprint,
                    color,
                    body.as_deref(),
                )
                .await
        } else {
            store
                .update_for_local_document_async(
                    &id,
                    &retained.local_path,
                    format,
                    &retained.fingerprint,
                    color,
                    body.as_deref(),
                )
                .await
        }
        .map_err(annotation_storage_error)
    }

    pub async fn delete_annotation(
        &self,
        document: DocumentHandle,
        id: &str,
    ) -> Result<bool, BridgeError> {
        let _request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let retained = self.document(document)?;
        let format = annotation_document_format(&retained.document)?;
        let id = AnnotationId::from_str(id)
            .map_err(|_| BridgeError::InvalidRequest("invalid annotation ID".into()))?;
        let store = self.annotation_store().await?;
        if let Some(book_id) = retained.book_id {
            store
                .delete_for_book_document_async(
                    &id,
                    book_id,
                    &retained.local_path,
                    format,
                    &retained.fingerprint,
                )
                .await
        } else {
            store
                .delete_for_local_document_async(
                    &id,
                    &retained.local_path,
                    format,
                    &retained.fingerprint,
                )
                .await
        }
        .map_err(storage_error)
    }

    pub async fn render_page(
        &self,
        request: RenderRequest,
        cancellation: Cancellation,
    ) -> Result<RenderedBuffer, BridgeError> {
        check_cancelled(&cancellation)?;
        let _request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let buffer_slot = try_acquire_slot(
            Arc::clone(&self.admission.buffer_slots),
            BridgeError::BufferCountLimit,
        )?;
        if !request.scale.is_finite() || request.scale <= 0.0 {
            return Err(BridgeError::InvalidRequest(
                "render scale must be finite and positive".to_owned(),
            ));
        }
        let retained_document = self.document(request.document)?;
        let probe_byte_len = render_probe_byte_len(&retained_document.document, request.page)?;
        let probe_byte_permits =
            u32::try_from(probe_byte_len).map_err(|_| BridgeError::BufferLimit)?;
        let render_slot =
            acquire_permits(Arc::clone(&self.admission.render_slots), 1, &cancellation).await?;
        let probe_bytes = acquire_permits(
            Arc::clone(&self.admission.probe_bytes),
            probe_byte_permits,
            &cancellation,
        )
        .await?;
        let preflight_document = Arc::clone(&retained_document);
        let page = request.page;
        let scale = request.scale;
        let preflight_cancellation = cancellation.clone();
        let (byte_len, guards) = tokio::task::spawn_blocking(move || {
            let byte_len = guarded(|| {
                render_byte_len(&preflight_document.document, page, scale, &|| {
                    preflight_cancellation.is_cancelled()
                })
            });
            (
                byte_len,
                (_request_slot, buffer_slot, render_slot, probe_bytes),
            )
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        let (_request_slot, buffer_slot, render_slot, probe_bytes) = guards;
        check_cancelled(&cancellation)?;
        let byte_len = byte_len?;
        if byte_len > MAX_BRIDGE_BUFFER_BYTES {
            return Err(BridgeError::BufferLimit);
        }
        let render_transient_byte_len = match &retained_document.document {
            OpenDocument::Pdf(_) => byte_len,
            OpenDocument::Cbz(document) => document
                .render_admission_byte_len_at_scale(request.page, request.scale)
                .ok_or(BridgeError::BufferLimit)?,
            OpenDocument::Epub(_) => {
                return Err(BridgeError::UnsupportedOperation(BookFormat::Epub));
            }
        };
        drop(probe_bytes);
        if render_transient_byte_len > MAX_BRIDGE_PROBE_BYTES {
            return Err(BridgeError::BufferLimit);
        }
        let render_transient_permits =
            u32::try_from(render_transient_byte_len).map_err(|_| BridgeError::BufferLimit)?;
        let render_transient_bytes = acquire_permits(
            Arc::clone(&self.admission.probe_bytes),
            render_transient_permits,
            &cancellation,
        )
        .await?;
        let transfer_peak = byte_len.checked_mul(2).ok_or(BridgeError::BufferLimit)?;
        let byte_permits = u32::try_from(transfer_peak).map_err(|_| BridgeError::BufferLimit)?;
        let buffer_bytes = acquire_permits(
            Arc::clone(&self.admission.buffer_bytes),
            byte_permits,
            &cancellation,
        )
        .await?;
        check_cancelled(&cancellation)?;
        let render_cancellation = cancellation.clone();
        let (rendered, guards) = tokio::task::spawn_blocking(move || {
            let rendered = guarded(|| {
                render(
                    retained_document.document.clone(),
                    request.page,
                    request.scale,
                    &|| render_cancellation.is_cancelled(),
                )
            });
            (
                rendered,
                (
                    _request_slot,
                    buffer_slot,
                    render_slot,
                    render_transient_bytes,
                    buffer_bytes,
                ),
            )
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        let (_request_slot, buffer_slot, render_slot, render_transient_bytes, buffer_bytes) =
            guards;
        check_cancelled(&cancellation)?;
        let rendered = rendered?;
        drop(render_slot);
        drop(render_transient_bytes);
        let _publication = cancellation
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        check_cancelled(&cancellation)?;
        self.store_buffer(request.document, rendered, buffer_bytes, buffer_slot)
    }

    pub async fn selection_surface(
        &self,
        document: DocumentHandle,
        unit: usize,
        scale: f32,
        width: f32,
        font_size: f32,
        cancellation: Cancellation,
    ) -> Result<SelectionSurface, BridgeError> {
        check_cancelled(&cancellation)?;
        if !scale.is_finite()
            || scale <= 0.0
            || !width.is_finite()
            || width <= 0.0
            || !font_size.is_finite()
            || font_size <= 0.0
        {
            return Err(BridgeError::InvalidRequest(
                "selection layout values must be finite and positive".to_owned(),
            ));
        }
        let retained = self.document(document)?;
        let request_slot = try_acquire_slot(
            Arc::clone(&self.admission.request_slots),
            BridgeError::RequestLimit,
        )?;
        let mut extracted = self
            .extract_selection(
                document,
                retained,
                unit,
                scale,
                width,
                font_size,
                true,
                &cancellation,
                request_slot,
            )
            .await?;
        let handle = self.selection_handle();
        extracted.surface.handle = handle;
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !registry.documents.contains_key(&document) {
            if let Some(raster) = extracted.surface.raster {
                registry.buffers.remove(&raster.handle);
            }
            return Err(BridgeError::InvalidDocumentHandle);
        }
        registry.selections.insert(
            handle,
            RetainedSelection {
                _request_slot: extracted.request_slot,
                _bytes: extracted.retained_bytes,
            },
        );
        drop(registry);
        Ok(extracted.surface)
    }

    #[allow(clippy::too_many_arguments)]
    async fn extract_selection(
        &self,
        document_handle: DocumentHandle,
        retained: Arc<RetainedDocument>,
        unit: usize,
        scale: f32,
        width: f32,
        font_size: f32,
        retain_raster: bool,
        cancellation: &Cancellation,
        request_slot: OwnedSemaphorePermit,
    ) -> Result<ExtractedSelection, BridgeError> {
        let render_slot =
            acquire_permits(Arc::clone(&self.admission.render_slots), 1, cancellation).await?;
        let transient =
            selection_transient_byte_len(&retained.document, unit, scale, retain_raster)?;
        let transient = u32::try_from(transient).map_err(|_| BridgeError::BufferLimit)?;
        let transient_bytes = acquire_permits(
            Arc::clone(&self.admission.probe_bytes),
            transient,
            cancellation,
        )
        .await?;
        let (buffer_slot, buffer_bytes) =
            if retain_raster && matches!(retained.document, OpenDocument::Epub(_)) {
                let slot = try_acquire_slot(
                    Arc::clone(&self.admission.buffer_slots),
                    BridgeError::BufferCountLimit,
                )?;
                let bytes = acquire_permits(
                    Arc::clone(&self.admission.buffer_bytes),
                    u32::try_from(EPUB_TEXT_MAX_PIXELS * 4 * 2)
                        .map_err(|_| BridgeError::BufferLimit)?,
                    cancellation,
                )
                .await?;
                (Some(slot), Some(bytes))
            } else {
                (None, None)
            };
        let worker_cancellation = cancellation.clone();
        let retained_document = Arc::clone(&retained);
        #[cfg(test)]
        let worker_barrier = self.selection_worker_barrier.clone();
        #[cfg(test)]
        let cancellation_barrier = self.selection_second_cancellation_barrier.clone();
        let (extraction, guards) = tokio::task::spawn_blocking(move || {
            #[cfg(test)]
            if let Some(barrier) = worker_barrier {
                barrier.wait();
                barrier.wait();
            }
            #[cfg(test)]
            let cancellation_checks = std::sync::atomic::AtomicUsize::new(0);
            let surface = guarded(|| {
                selection_surface(
                    &retained_document.document,
                    unit,
                    scale,
                    width,
                    font_size,
                    retain_raster,
                    &|| {
                        #[cfg(test)]
                        if cancellation_checks.fetch_add(1, Ordering::Relaxed) == 1
                            && let Some(barrier) = &cancellation_barrier
                        {
                            barrier.wait();
                            barrier.wait();
                        }
                        worker_cancellation.is_cancelled()
                    },
                )
            });
            (
                surface,
                (
                    request_slot,
                    render_slot,
                    transient_bytes,
                    buffer_slot,
                    buffer_bytes,
                ),
            )
        })
        .await
        .map_err(|_| BridgeError::Worker)?;
        let (request_slot, render_slot, transient_bytes, buffer_slot, buffer_bytes) = guards;
        let _publication = cancellation
            .0
            .publication
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        check_cancelled(cancellation)?;
        let mut extraction = extraction?;
        let retained_len = selection_retained_byte_len(&extraction.surface)?;
        let mut transient_bytes = transient_bytes;
        let retained_bytes = transient_bytes
            .split(retained_len)
            .ok_or(BridgeError::BufferLimit)?;
        drop(transient_bytes);
        if let Some(pixels) = extraction.raster.take() {
            extraction.surface.raster = Some(self.store_owned_buffer(
                document_handle,
                extraction.raster_width,
                extraction.raster_height,
                pixels,
                buffer_bytes.expect("EPUB raster bytes reserved"),
                buffer_slot.expect("EPUB raster slot reserved"),
            )?);
        }
        drop(render_slot);
        Ok(ExtractedSelection {
            surface: extraction.surface,
            request_slot,
            retained_bytes,
        })
    }

    /// Copy a retained raster into the bridge generator's `Uint8List` representation.
    /// The caller must release the handle after the Dart list is no longer retained.
    pub fn take_buffer(&self, handle: BufferHandle) -> Result<Vec<u8>, BridgeError> {
        self.ensure_buffer_handle(handle)?;
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let buffer = registry
            .buffers
            .get_mut(&handle)
            .ok_or(BridgeError::InvalidBufferHandle)?;
        if buffer.transferred {
            return Err(BridgeError::InvalidBufferHandle);
        }
        buffer.transferred = true;
        Ok(buffer.pixels.clone())
    }

    pub fn release_document(&self, handle: DocumentHandle) -> bool {
        if handle.registry != self.registry_id {
            return false;
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .remove(&handle)
            .is_some()
    }

    pub fn release_buffer(&self, handle: BufferHandle) -> bool {
        if handle.registry != self.registry_id {
            return false;
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .buffers
            .remove(&handle)
            .is_some()
    }

    pub fn release_selection(&self, handle: SelectionHandle) -> bool {
        if handle.registry != self.registry_id {
            return false;
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .selections
            .remove(&handle)
            .is_some()
    }

    fn document(&self, handle: DocumentHandle) -> Result<Arc<RetainedDocument>, BridgeError> {
        if handle.registry != self.registry_id {
            return Err(BridgeError::InvalidDocumentHandle);
        }
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .documents
            .get(&handle)
            .cloned()
            .ok_or(BridgeError::InvalidDocumentHandle)
    }

    fn ensure_buffer_handle(&self, handle: BufferHandle) -> Result<(), BridgeError> {
        (handle.registry == self.registry_id)
            .then_some(())
            .ok_or(BridgeError::InvalidBufferHandle)
    }

    fn document_handle(&self) -> DocumentHandle {
        DocumentHandle {
            registry: self.registry_id,
            id: self.next_id(),
        }
    }

    fn buffer_handle(&self) -> BufferHandle {
        BufferHandle {
            registry: self.registry_id,
            id: self.next_id(),
        }
    }

    fn selection_handle(&self) -> SelectionHandle {
        SelectionHandle {
            registry: self.registry_id,
            id: self.next_id(),
        }
    }

    fn next_id(&self) -> u64 {
        self.next_handle.fetch_add(1, Ordering::Relaxed) + 1
    }

    fn store_buffer(
        &self,
        document: DocumentHandle,
        rendered: RenderedPage,
        bytes: OwnedSemaphorePermit,
        slot: OwnedSemaphorePermit,
    ) -> Result<RenderedBuffer, BridgeError> {
        let byte_len = rendered.pixels.len();
        if byte_len
            .checked_mul(2)
            .is_none_or(|peak| peak > bytes.num_permits())
            || rendered.pixels.len() > MAX_BRIDGE_BUFFER_BYTES
        {
            return Err(BridgeError::BufferLimit);
        }
        let pixels = rendered.pixels.to_vec();
        let mut registry = self
            .registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if document.registry != self.registry_id || !registry.documents.contains_key(&document) {
            return Err(BridgeError::InvalidDocumentHandle);
        }
        let handle = self.buffer_handle();
        let result = RenderedBuffer {
            handle,
            width: rendered.width,
            height: rendered.height,
            byte_len,
        };
        registry.buffers.insert(
            handle,
            RetainedBuffer {
                pixels,
                transferred: false,
                _bytes: bytes,
                _slot: slot,
            },
        );
        Ok(result)
    }

    fn store_owned_buffer(
        &self,
        document: DocumentHandle,
        width: u32,
        height: u32,
        pixels: Vec<u8>,
        bytes: OwnedSemaphorePermit,
        slot: OwnedSemaphorePermit,
    ) -> Result<RenderedBuffer, BridgeError> {
        let byte_len = pixels.len();
        if byte_len
            .checked_mul(2)
            .is_none_or(|peak| peak > bytes.num_permits())
            || byte_len > MAX_BRIDGE_BUFFER_BYTES
        {
            return Err(BridgeError::BufferLimit);
        }
        let mut registry = self.registry.lock().unwrap_or_else(|p| p.into_inner());
        if !registry.documents.contains_key(&document) {
            return Err(BridgeError::InvalidDocumentHandle);
        }
        let handle = self.buffer_handle();
        registry.buffers.insert(
            handle,
            RetainedBuffer {
                pixels,
                transferred: false,
                _bytes: bytes,
                _slot: slot,
            },
        );
        Ok(RenderedBuffer {
            handle,
            width,
            height,
            byte_len,
        })
    }
}

async fn acquire_permits(
    semaphore: Arc<Semaphore>,
    permits: u32,
    cancellation: &Cancellation,
) -> Result<OwnedSemaphorePermit, BridgeError> {
    tokio::select! {
        permit = semaphore.acquire_many_owned(permits) => permit.map_err(|_| BridgeError::Worker),
        () = cancellation.cancelled() => Err(BridgeError::Cancelled),
    }
}

fn try_acquire_slot(
    semaphore: Arc<Semaphore>,
    error: BridgeError,
) -> Result<OwnedSemaphorePermit, BridgeError> {
    semaphore.try_acquire_owned().map_err(|_| error)
}

fn guarded<T>(operation: impl FnOnce() -> Result<T, BridgeError>) -> Result<T, BridgeError> {
    catch_unwind(AssertUnwindSafe(operation)).map_err(|_| BridgeError::Panic)?
}

fn check_cancelled(cancellation: &Cancellation) -> Result<(), BridgeError> {
    if cancellation.is_cancelled() {
        Err(BridgeError::Cancelled)
    } else {
        Ok(())
    }
}

#[cfg(test)]
fn retained_document_byte_len(
    format: BookFormat,
    encoded_byte_len: usize,
) -> Result<usize, BridgeError> {
    let retained = OpenDocument::retained_admission_byte_len(format, encoded_byte_len)
        .ok_or(BridgeError::DocumentLimit)?;
    if retained > MAX_BRIDGE_RETAINED_DOCUMENT_BYTES {
        return Err(BridgeError::DocumentLimit);
    }
    Ok(retained)
}

fn map_open_error(error: OpenDocumentError) -> BridgeError {
    match error {
        OpenDocumentError::UnsupportedFormat(extension) => {
            BridgeError::UnsupportedFormat(extension)
        }
        OpenDocumentError::NotFound => BridgeError::DocumentNotFound,
        OpenDocumentError::Inaccessible(_) => BridgeError::DocumentInaccessible,
        OpenDocumentError::LimitExceeded { format, detail } => {
            BridgeError::OpenLimit { format, detail }
        }
        OpenDocumentError::BackendUnavailable { format, detail } => {
            BridgeError::Backend { format, detail }
        }
        OpenDocumentError::Open { format, detail } => BridgeError::Open { format, detail },
    }
}

fn render_probe_byte_len(document: &OpenDocument, page: usize) -> Result<usize, BridgeError> {
    let page_count = document.page_count();
    if page >= page_count {
        return Err(BridgeError::InvalidPage { page, page_count });
    }
    let byte_len = match document {
        OpenDocument::Cbz(document) => document
            .render_admission_byte_len(page)
            .ok_or(BridgeError::InvalidPage { page, page_count })?,
        OpenDocument::Pdf(_) | OpenDocument::Epub(_) => 0,
    };
    if byte_len > MAX_BRIDGE_PROBE_BYTES {
        return Err(BridgeError::BufferLimit);
    }
    Ok(byte_len)
}

fn render_byte_len(
    document: &OpenDocument,
    page: usize,
    scale: f32,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<usize, BridgeError> {
    if is_cancelled() {
        return Err(BridgeError::Cancelled);
    }
    let page_count = document.page_count();
    if page >= page_count {
        return Err(BridgeError::InvalidPage { page, page_count });
    }
    match document {
        OpenDocument::Pdf(document) => {
            let byte_len = document
                .rendered_byte_len(page, scale)
                .map_err(map_preflight_error)?;
            if is_cancelled() {
                Err(BridgeError::Cancelled)
            } else {
                Ok(byte_len)
            }
        }
        OpenDocument::Cbz(document) => document
            .rendered_byte_len_cancellable(page, scale, is_cancelled)
            .map_err(map_preflight_error),
        OpenDocument::Epub(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Epub)),
    }
}

fn render(
    document: OpenDocument,
    page: usize,
    scale: f32,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<RenderedPage, BridgeError> {
    match document {
        OpenDocument::Pdf(document) => document
            .render_page_with_highlights_cancellable(page, scale, &[], is_cancelled)
            .map_err(map_render_error),
        OpenDocument::Cbz(document) => document
            .render_page_cancellable(page, scale, is_cancelled)
            .map_err(map_render_error),
        OpenDocument::Epub(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Epub)),
    }
}

fn selection_surface(
    document: &OpenDocument,
    unit: usize,
    scale: f32,
    width: f32,
    font_size: f32,
    rasterize: bool,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<SelectionExtraction, BridgeError> {
    if is_cancelled() {
        return Err(BridgeError::Cancelled);
    }
    match document {
        OpenDocument::Pdf(document) => {
            let snapshot = document
                .selection_snapshot_cancellable(unit, scale, is_cancelled)
                .map_err(map_render_error)?;
            let (bitmap_width, bitmap_height) = snapshot.bitmap_size();
            let text = snapshot.text().to_owned();
            let copy_eligible = snapshot.text_mapping_complete();
            let (grapheme_boundaries, word_boundaries) = navigation_boundaries(&text);
            let page_rectangles = snapshot
                .page_rectangles(0, text.chars().count())
                .into_iter()
                .map(
                    |(character, (left, bottom, right, top))| SelectionPageRect {
                        character,
                        rect: SelectionRect {
                            left,
                            top: bottom,
                            right,
                            bottom: top,
                        },
                    },
                )
                .collect();
            Ok(SelectionExtraction {
                surface: SelectionSurface {
                    handle: SelectionHandle { registry: 0, id: 0 },
                    width: bitmap_width as f32,
                    height: bitmap_height as f32,
                    text,
                    copy_eligible,
                    resource_path: None,
                    raster: None,
                    endpoints: snapshot
                        .endpoints()
                        .into_iter()
                        .map(pdf_selection_endpoint)
                        .collect(),
                    grapheme_boundaries,
                    word_boundaries,
                    visual_lines: snapshot
                        .visual_lines_cancellable(is_cancelled)
                        .map_err(map_render_error)?
                        .into_iter()
                        .map(|line| SelectionVisualLine {
                            carets: line
                                .carets
                                .into_iter()
                                .map(|caret| SelectionCaret {
                                    offset: caret.character,
                                    x: caret.x,
                                    along_line: caret.along_line,
                                    vertical: caret.vertical,
                                    top: caret.top,
                                    bottom: caret.bottom,
                                })
                                .collect(),
                        })
                        .collect(),
                    page_rectangles,
                },
                raster: None,
                raster_width: 0,
                raster_height: 0,
            })
        }
        OpenDocument::Epub(document) => {
            let chapter =
                document
                    .presentation()
                    .chapter(unit)
                    .ok_or(BridgeError::InvalidPage {
                        page: unit,
                        page_count: document.chapter_count(),
                    })?;
            let text = bounded_epub_selection_text(chapter.search_text(), is_cancelled)?;
            let request = EpubTextRequest {
                runs: vec![EpubTextRun {
                    text: text.clone(),
                    family: None,
                    monospace: false,
                    font_size,
                    bold: false,
                    italic: false,
                    foreground: [0, 0, 0, 255],
                    link: None,
                }],
                max_width: width,
                line_height: font_size * 1.5,
                scale,
                align: EpubTextAlign::Left,
                direction: EpubTextDirection::LeftToRight,
                highlights: Vec::new(),
            };
            let layout = if rasterize {
                document
                    .fonts()
                    .layout_text_cancellable(&request, is_cancelled)
            } else {
                document
                    .fonts()
                    .measure_text_cancellable(&request, is_cancelled)
            }
            .map_err(|error| {
                if is_cancelled() {
                    BridgeError::Cancelled
                } else {
                    map_render_error(error)
                }
            })?;
            let surface_width = layout.width.max(1.0 / scale);
            let surface_height = layout.height.max(1.0 / scale);
            let raster_width = (surface_width * scale).ceil() as u32;
            let raster_height = (surface_height * scale).ceil() as u32;
            let raster_pixels = (raster_width as usize)
                .checked_mul(raster_height as usize)
                .ok_or(BridgeError::BufferLimit)?;
            if rasterize && raster_pixels > EPUB_TEXT_MAX_PIXELS {
                return Err(BridgeError::BufferLimit);
            }
            let mut raster = if rasterize {
                vec![
                    0;
                    raster_pixels
                        .checked_mul(4)
                        .ok_or(BridgeError::BufferLimit)?
                ]
            } else {
                Vec::new()
            };
            for line in layout.lines.iter().filter(|_| rasterize) {
                if is_cancelled() {
                    return Err(BridgeError::Cancelled);
                }
                let top = (line.top * scale).round() as usize;
                let copy_width = raster_width.min(line.pixel_width) as usize;
                for row in 0..line.pixel_height as usize {
                    if is_cancelled() {
                        return Err(BridgeError::Cancelled);
                    }
                    let destination = (top + row)
                        .checked_mul(raster_width as usize)
                        .and_then(|offset| offset.checked_mul(4))
                        .and_then(|offset| offset.checked_add(copy_width * 4))
                        .ok_or(BridgeError::BufferLimit)?;
                    if destination > raster.len() {
                        return Err(BridgeError::BufferLimit);
                    }
                    let source = row * line.pixel_width as usize * 4;
                    raster[destination - copy_width * 4..destination]
                        .copy_from_slice(&line.rgba[source..source + copy_width * 4]);
                }
            }
            let path = document.chapter(unit).map(|chapter| chapter.path.clone());
            let (grapheme_boundaries, word_boundaries) = navigation_boundaries(&text);
            let visual_lines = epub_visual_lines(&text, &layout, scale);
            Ok(SelectionExtraction {
                surface: SelectionSurface {
                    handle: SelectionHandle { registry: 0, id: 0 },
                    width: surface_width,
                    height: surface_height,
                    text,
                    copy_eligible: true,
                    resource_path: path,
                    raster: None,
                    endpoints: layout
                        .endpoints
                        .into_iter()
                        .map(|endpoint| SelectionEndpoint {
                            offset: endpoint.scalar,
                            range_start: endpoint.scalar_start,
                            range_end: endpoint.scalar_end,
                            rect: SelectionRect {
                                left: endpoint.rect.x,
                                top: endpoint.rect.y,
                                right: endpoint.rect.x + endpoint.rect.width,
                                bottom: endpoint.rect.y + endpoint.rect.height,
                            },
                        })
                        .collect(),
                    grapheme_boundaries,
                    word_boundaries,
                    visual_lines,
                    page_rectangles: Vec::new(),
                },
                raster: rasterize.then_some(raster),
                raster_width,
                raster_height,
            })
        }
        OpenDocument::Cbz(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Cbz)),
    }
}

fn epub_visual_lines(
    text: &str,
    layout: &crate::epub::EpubTextLayout,
    scale: f32,
) -> Vec<SelectionVisualLine> {
    let mut line_carets = vec![Vec::new(); layout.lines.len()];
    for endpoint in &layout.endpoints {
        if let Some(carets) = line_carets.get_mut(endpoint.visual_line) {
            carets.push(SelectionCaret {
                offset: endpoint.scalar,
                x: endpoint.caret_x,
                along_line: endpoint.caret_x,
                vertical: false,
                top: endpoint.rect.y,
                bottom: endpoint.rect.y + endpoint.rect.height,
            });
        }
    }
    if !text.is_empty() {
        let scalar_count = text.chars().count();
        for (line, carets) in layout.lines.iter().zip(&mut line_carets) {
            if carets.is_empty() && line.scalars.start <= scalar_count {
                carets.push(SelectionCaret {
                    offset: line.scalars.start,
                    x: if line.rtl { line.width } else { 0.0 },
                    along_line: if line.rtl { line.width } else { 0.0 },
                    vertical: false,
                    top: line.top,
                    bottom: line.top + line.pixel_height as f32 / scale,
                });
            }
        }
    }
    line_carets
        .into_iter()
        .map(|mut carets| {
            carets.sort_by(|left, right| left.x.total_cmp(&right.x));
            carets.dedup_by(|left, right| left.offset == right.offset);
            SelectionVisualLine { carets }
        })
        .collect()
}

fn navigation_boundaries(text: &str) -> (Vec<usize>, Vec<usize>) {
    let mut scalar = 0;
    let mut graphemes = vec![0];
    for grapheme in text.graphemes(true) {
        scalar += grapheme.chars().count();
        graphemes.push(scalar);
    }
    let mut words = Vec::new();
    scalar = 0;
    for segment in text.split_word_bounds() {
        let end = scalar + segment.chars().count();
        if segment.unicode_words().next().is_some() {
            words.extend([scalar, end]);
        }
        scalar = end;
    }
    words.extend([0, scalar]);
    words.sort_unstable();
    words.dedup();
    (graphemes, words)
}

struct SelectionExtraction {
    surface: SelectionSurface,
    raster: Option<Vec<u8>>,
    raster_width: u32,
    raster_height: u32,
}

struct ExtractedSelection {
    surface: SelectionSurface,
    request_slot: OwnedSemaphorePermit,
    retained_bytes: OwnedSemaphorePermit,
}

fn selection_retained_byte_len(surface: &SelectionSurface) -> Result<usize, BridgeError> {
    let vectors = surface
        .endpoints
        .capacity()
        .checked_mul(std::mem::size_of::<SelectionEndpoint>())
        .and_then(|bytes| {
            bytes.checked_add(surface.grapheme_boundaries.capacity() * std::mem::size_of::<usize>())
        })
        .and_then(|bytes| {
            bytes.checked_add(surface.word_boundaries.capacity() * std::mem::size_of::<usize>())
        })
        .and_then(|bytes| {
            bytes.checked_add(
                surface.visual_lines.capacity() * std::mem::size_of::<SelectionVisualLine>(),
            )
        })
        .and_then(|bytes| {
            surface.visual_lines.iter().try_fold(bytes, |total, line| {
                total.checked_add(line.carets.capacity() * std::mem::size_of::<SelectionCaret>())
            })
        })
        .and_then(|bytes| {
            bytes.checked_add(
                surface.page_rectangles.capacity() * std::mem::size_of::<SelectionPageRect>(),
            )
        })
        .ok_or(BridgeError::BufferLimit)?;
    std::mem::size_of::<SelectionSurface>()
        .checked_add(surface.text.capacity())
        .and_then(|bytes| {
            bytes.checked_add(surface.resource_path.as_ref().map_or(0, String::capacity))
        })
        .and_then(|bytes| bytes.checked_add(vectors))
        .ok_or(BridgeError::BufferLimit)
}

fn bounded_epub_selection_text(
    chapter_text: &str,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<String, BridgeError> {
    let mut scalar_count = 0;
    for _ in chapter_text.chars() {
        if scalar_count % 1024 == 0 && is_cancelled() {
            return Err(BridgeError::Cancelled);
        }
        scalar_count += 1;
        if scalar_count > EPUB_TEXT_MAX_SCALARS {
            return Err(BridgeError::BufferLimit);
        }
    }
    Ok(chapter_text.to_owned())
}

fn pdf_selection_endpoint(
    (rect, endpoint): (
        crate::pdf::PdfSelectionRect,
        crate::pdf::PdfSelectionEndpoint,
    ),
) -> SelectionEndpoint {
    SelectionEndpoint {
        offset: endpoint.character,
        range_start: endpoint.underlying_character,
        range_end: endpoint.underlying_character.saturating_add(1),
        rect: SelectionRect {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
        },
    }
}

fn selection_transient_byte_len(
    document: &OpenDocument,
    unit: usize,
    scale: f32,
    rasterize: bool,
) -> Result<usize, BridgeError> {
    if unit >= document.page_count() {
        return Err(BridgeError::InvalidPage {
            page: unit,
            page_count: document.page_count(),
        });
    }
    match document {
        OpenDocument::Pdf(document) => document
            .selection_admission_byte_len(unit, scale)
            .map_err(map_preflight_error),
        OpenDocument::Epub(_) => {
            let native_workspace = EPUB_TEXT_MAX_ENDPOINTS
                .checked_mul(std::mem::size_of::<EpubTextEndpoint>())
                // Chapter text, request runs, shaping text/control buffers, and
                // scalar-boundary indexes coexist during native layout.
                .and_then(|bytes| bytes.checked_add(EPUB_TEXT_MAX_SCALARS * 4 * 12))
                .ok_or(BridgeError::BufferLimit)?;
            // Bridge geometry is built while native layout remains live. Caret
            // vectors may retain up to four slots for each endpoint because
            // Vec's first growth allocates four elements; boundary vectors can
            // retain the next power-of-two capacity above the scalar ceiling.
            let bridge_geometry = EPUB_TEXT_MAX_ENDPOINTS
                .checked_mul(std::mem::size_of::<SelectionEndpoint>())
                .and_then(|bytes| {
                    bytes.checked_add(
                        EPUB_TEXT_MAX_ENDPOINTS * 4 * std::mem::size_of::<SelectionCaret>(),
                    )
                })
                .and_then(|bytes| {
                    bytes.checked_add(
                        EPUB_TEXT_MAX_ENDPOINTS * std::mem::size_of::<SelectionVisualLine>(),
                    )
                })
                .and_then(|bytes| {
                    bytes.checked_add(EPUB_TEXT_MAX_SCALARS * 2 * 2 * std::mem::size_of::<usize>())
                })
                .and_then(|bytes| bytes.checked_add(EPUB_TEXT_MAX_SCALARS * 4))
                .and_then(|bytes| bytes.checked_add(std::mem::size_of::<SelectionSurface>()))
                .ok_or(BridgeError::BufferLimit)?;
            let rasters = if rasterize {
                EPUB_TEXT_MAX_PIXELS * 4 * 2
            } else {
                0
            };
            native_workspace
                .checked_add(bridge_geometry)
                .and_then(|bytes| bytes.checked_add(rasters))
                .ok_or(BridgeError::BufferLimit)
        }
        OpenDocument::Cbz(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Cbz)),
    }
}

fn storage_error(error: impl std::fmt::Display) -> BridgeError {
    BridgeError::Storage(error.to_string())
}

fn library_mutation_error(error: anyhow::Error) -> BridgeError {
    if error.is::<AnnotationSnapshotLimit>() || error.is::<AnnotationDocumentVersionLimit>() {
        BridgeError::AnnotationLimit
    } else if error.is::<BookmarkCountLimit>() || error.is::<AnnotationReconciliationWorkLimit>() {
        BridgeError::BufferLimit
    } else if error.is::<AnnotationAssociationConflict>() {
        BridgeError::InvalidRequest(error.to_string())
    } else {
        storage_error(error)
    }
}

fn bookmark_storage_error(error: anyhow::Error) -> BridgeError {
    if error.is::<BookmarkCountLimit>() || error.is::<BookmarkExportLimit>() {
        BridgeError::BufferLimit
    } else if error.is::<BookmarkNotFound>() || error.is::<BookmarkBookNotFound>() {
        BridgeError::ResourceNotFound("bookmark".into())
    } else {
        storage_error(error)
    }
}

fn reading_state_storage_error(error: anyhow::Error) -> BridgeError {
    if error.is::<ReadingStateBookNotFound>() {
        BridgeError::ResourceNotFound("library book".into())
    } else {
        storage_error(error)
    }
}

fn library_open_error(error: anyhow::Error) -> BridgeError {
    if let Some(open) = error.downcast_ref::<OpenDocumentError>() {
        map_open_error(open.clone())
    } else if error.downcast_ref::<sqlx::Error>().is_some() {
        storage_error(error)
    } else {
        BridgeError::DocumentInaccessible
    }
}

fn reading_progress(unit: usize, unit_count: usize) -> f64 {
    if unit_count <= 1 {
        1.0
    } else {
        unit.min(unit_count - 1) as f64 / (unit_count - 1) as f64
    }
}

fn annotation_storage_error(error: anyhow::Error) -> BridgeError {
    if error.is::<AnnotationAssociationSourceCancelled>()
        || error.is::<AnnotationReconciliationCancelled>()
    {
        BridgeError::Cancelled
    } else if error.is::<AnnotationAssociationSourceWorkLimit>()
        || error.is::<AnnotationReconciliationWorkLimit>()
    {
        BridgeError::BufferLimit
    } else if error.is::<AnnotationSnapshotLimit>() || error.is::<AnnotationDocumentVersionLimit>()
    {
        BridgeError::AnnotationLimit
    } else if error.is::<AnnotationAssociationConflict>()
        || error.is::<AnnotationAssociationInvalidRequest>()
    {
        BridgeError::InvalidRequest(error.to_string())
    } else if error.is::<AnnotationAssociationSourceNotFound>() {
        BridgeError::ResourceNotFound("annotation association source".into())
    } else {
        storage_error(error)
    }
}

fn annotation_document_format(
    document: &OpenDocument,
) -> Result<AnnotationDocumentFormat, BridgeError> {
    match document {
        OpenDocument::Epub(_) => Ok(AnnotationDocumentFormat::Epub),
        OpenDocument::Pdf(_) => Ok(AnnotationDocumentFormat::Pdf),
        OpenDocument::Cbz(_) => Err(BridgeError::UnsupportedOperation(BookFormat::Cbz)),
    }
}

fn bounded_annotation_snapshot(
    annotations: Vec<Annotation>,
) -> Result<Vec<Annotation>, BridgeError> {
    let retained_bytes = annotations.iter().try_fold(0usize, |total, annotation| {
        let strings = annotation.id.to_string().len()
            + annotation.body.as_ref().map_or(0, String::len)
            + annotation.quote.as_ref().map_or(0, |quote| {
                quote.original.as_ref().map_or(0, String::len)
                    + quote.exact.len()
                    + quote.prefix.len()
                    + quote.suffix.len()
            });
        // Text-backed PDF highlights paint through the retained selection
        // surface, so only geometry-only annotations retain DTO rectangles.
        let rectangles = match &annotation.target {
            AnnotationTarget::Pdf(anchor) if anchor.character_range.is_none() => {
                anchor.rectangles.len() * std::mem::size_of::<PageRect>()
            }
            AnnotationTarget::Pdf(_) | AnnotationTarget::Epub(_) => 0,
        };
        total
            .checked_add(ANNOTATION_SNAPSHOT_BASE_BYTES + strings + rectangles)
            .ok_or(BridgeError::AnnotationLimit)
    })?;
    if retained_bytes > MAX_ANNOTATION_SNAPSHOT_BYTES {
        return Err(BridgeError::AnnotationLimit);
    }
    Ok(annotations)
}

fn annotation_dtos(
    annotations: Vec<Annotation>,
    document: &OpenDocument,
    current_fingerprint: &DocumentFingerprint,
    scale: f32,
    resolve_persisted_text: bool,
    is_cancelled: &dyn Fn() -> bool,
) -> Result<Vec<BridgeAnnotation>, BridgeError> {
    let mut annotations_by_unit = HashMap::<usize, Vec<usize>>::new();
    for (index, annotation) in annotations.iter().enumerate() {
        if !resolve_persisted_text {
            continue;
        }
        if is_cancelled() {
            return Err(BridgeError::Cancelled);
        }
        let unit = match (&annotation.target, document) {
            (AnnotationTarget::Epub(anchor), OpenDocument::Epub(document)) => {
                let unit = anchor.spine_occurrence as usize;
                if document
                    .chapter(unit)
                    .is_none_or(|chapter| chapter.path != anchor.resource_path.as_str())
                {
                    continue;
                }
                unit
            }
            (AnnotationTarget::Pdf(anchor), OpenDocument::Pdf(document))
                if anchor.character_range.is_some()
                    && (anchor.page as usize) < document.page_count() =>
            {
                anchor.page as usize
            }
            _ => continue,
        };
        annotations_by_unit.entry(unit).or_default().push(index);
    }
    let mut resolved_texts = if resolve_persisted_text {
        vec![None; annotations.len()]
    } else {
        annotations
            .iter()
            .map(|annotation| {
                let range = match &annotation.target {
                    AnnotationTarget::Epub(anchor) => {
                        Some(anchor.scalar_start as usize..anchor.scalar_end as usize)
                    }
                    AnnotationTarget::Pdf(anchor) => anchor
                        .character_range
                        .map(|(start, end)| start as usize..end as usize),
                };
                range.map(|range| crate::annotations::ResolvedTextAnchor {
                    resolution: AnnotationResolution::Exact,
                    range: Some(range),
                })
            })
            .collect()
    };
    let mut remaining_work = MAX_TEXT_ANCHOR_RESOLUTION_WORK;
    for (unit, indices) in annotations_by_unit {
        let text = match document {
            OpenDocument::Epub(document) => document
                .presentation()
                .chapter(unit)
                .map(|chapter| {
                    bounded_epub_selection_text(chapter.search_text(), is_cancelled)
                        .map(|text| (text, true))
                })
                .transpose()?,
            OpenDocument::Pdf(document) if unit < document.page_count() => Some(
                document
                    .page_text_with_mapping_bounded(
                        unit,
                        MAX_ANNOTATION_PDF_TEXT_BYTES,
                        is_cancelled,
                    )
                    .map_err(|error| match error {
                        crate::pdf::BoundedPageTextError::Cancelled => BridgeError::Cancelled,
                        crate::pdf::BoundedPageTextError::Limit { .. } => BridgeError::BufferLimit,
                        crate::pdf::BoundedPageTextError::Document(error) => {
                            map_render_error(error)
                        }
                    })?,
            ),
            OpenDocument::Pdf(_) => None,
            OpenDocument::Cbz(_) => None,
        };
        let Some((text, mapping_complete)) = text else {
            continue;
        };
        if !mapping_complete {
            continue;
        }
        let scalar_index = TextScalarIndex::new(&text, &mut remaining_work, is_cancelled)
            .map_err(map_text_anchor_resolution_error)?;
        let mut unresolved = Vec::new();
        for index in indices {
            let (stored_range, quote) =
                match (&annotations[index].target, &annotations[index].quote) {
                    (AnnotationTarget::Epub(anchor), Some(quote)) => (
                        anchor.scalar_start as usize..anchor.scalar_end as usize,
                        quote,
                    ),
                    (AnnotationTarget::Pdf(anchor), Some(quote)) => {
                        let Some((start, end)) = anchor.character_range else {
                            continue;
                        };
                        (start as usize..end as usize, quote)
                    }
                    _ => continue,
                };
            if annotations[index].fingerprint == *current_fingerprint {
                if let Some(resolved) = scalar_index
                    .resolve_exact(stored_range, quote, &mut remaining_work, is_cancelled)
                    .map_err(map_text_anchor_resolution_error)?
                {
                    resolved_texts[index] = Some(resolved);
                } else {
                    unresolved.push(index);
                }
            } else {
                unresolved.push(index);
            }
        }
        if unresolved.is_empty() {
            continue;
        }
        let resolver =
            TextAnchorResolver::from_index(scalar_index, &mut remaining_work, is_cancelled)
                .map_err(map_text_anchor_resolution_error)?;
        for index in unresolved {
            let (mut stored_range, quote) =
                match (&annotations[index].target, &annotations[index].quote) {
                    (AnnotationTarget::Epub(anchor), Some(quote)) => (
                        anchor.scalar_start as usize..anchor.scalar_end as usize,
                        quote,
                    ),
                    (AnnotationTarget::Pdf(anchor), Some(quote)) => {
                        let Some((start, end)) = anchor.character_range else {
                            continue;
                        };
                        (start as usize..end as usize, quote)
                    }
                    _ => continue,
                };
            if annotations[index].fingerprint != *current_fingerprint {
                stored_range = usize::MAX..usize::MAX;
            }
            resolved_texts[index] = Some(
                resolver
                    .resolve(stored_range, quote, &mut remaining_work, is_cancelled)
                    .map_err(map_text_anchor_resolution_error)?,
            );
        }
    }
    let batches = annotations
        .iter()
        .enumerate()
        .filter_map(|(index, annotation)| match (&annotation.target, document) {
            (AnnotationTarget::Pdf(anchor), OpenDocument::Pdf(pdf))
                if anchor.character_range.is_none()
                    && annotation.fingerprint == *current_fingerprint
                    && (anchor.page as usize) < pdf.page_count() =>
            {
                Some((
                    index,
                    (
                        anchor.page as usize,
                        anchor
                            .rectangles
                            .iter()
                            .map(|rect| (rect.left, rect.bottom, rect.right, rect.top))
                            .collect(),
                    ),
                ))
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    let mut resolved_rectangles = if batches.is_empty() {
        HashMap::new()
    } else {
        let OpenDocument::Pdf(pdf) = document else {
            unreachable!("only matching PDF batches are collected");
        };
        let geometry = batches
            .iter()
            .map(|(_, batch)| batch.clone())
            .collect::<Vec<_>>();
        let converted = pdf
            .page_rectangle_batches_to_pixels(&geometry, scale, is_cancelled)
            .map_err(map_render_error)?
            .into_iter();
        batches
            .into_iter()
            .map(|(index, _)| index)
            .zip(converted)
            .collect()
    };
    annotations
        .into_iter()
        .enumerate()
        .map(|(index, annotation)| {
            if is_cancelled() {
                return Err(BridgeError::Cancelled);
            }
            annotation_dto(
                annotation,
                resolved_rectangles.remove(&index),
                resolved_texts[index].take(),
            )
        })
        .collect()
}

fn annotation_dto(
    annotation: Annotation,
    resolved_pdf_rectangles: Option<Vec<crate::pdf::PdfSelectionRect>>,
    resolved_text: Option<crate::annotations::ResolvedTextAnchor>,
) -> Result<BridgeAnnotation, BridgeError> {
    let quote = annotation
        .quote
        .as_ref()
        .and_then(|quote| quote.original.clone());
    let geometry_only = matches!(
        &annotation.target,
        AnnotationTarget::Pdf(anchor) if anchor.character_range.is_none()
    );
    let geometry_resolved = resolved_pdf_rectangles.is_some();
    let resolution = resolved_text.as_ref().map_or_else(
        || {
            if geometry_only && geometry_resolved {
                AnnotationResolution::Exact
            } else {
                AnnotationResolution::Orphaned
            }
        },
        |resolved| resolved.resolution,
    );
    let (unit, text_range, rectangles) = match annotation.target {
        AnnotationTarget::Epub(anchor) => (
            anchor.spine_occurrence as usize,
            resolved_text
                .and_then(|resolved| resolved.range)
                .map(|range| AnnotationTextRange {
                    start: range.start,
                    end: range.end,
                }),
            Vec::new(),
        ),
        AnnotationTarget::Pdf(anchor) => {
            let text_range = resolved_text
                .and_then(|resolved| resolved.range)
                .map(|range| AnnotationTextRange {
                    start: range.start,
                    end: range.end,
                });
            let page = anchor.page as usize;
            let rectangles = if anchor.character_range.is_some() {
                Vec::new()
            } else {
                resolved_pdf_rectangles
                    .unwrap_or_default()
                    .into_iter()
                    .map(|rect| SelectionRect {
                        left: rect.left,
                        top: rect.top,
                        right: rect.right,
                        bottom: rect.bottom,
                    })
                    .collect()
            };
            (page, text_range, rectangles)
        }
    };
    Ok(BridgeAnnotation {
        id: annotation.id.to_string(),
        unit,
        resolution,
        text_range,
        quote,
        rectangles,
        color: annotation.color,
        body: annotation.body,
    })
}

fn map_text_anchor_resolution_error(error: TextAnchorResolutionError) -> BridgeError {
    match error {
        TextAnchorResolutionError::InvalidSelector => {
            BridgeError::InvalidRequest(error.to_string())
        }
        TextAnchorResolutionError::Cancelled => BridgeError::Cancelled,
        TextAnchorResolutionError::WorkLimit => BridgeError::BufferLimit,
    }
}

fn validate_annotation_body(body: Option<&str>) -> Result<(), BridgeError> {
    if body.is_some_and(|body| {
        body.chars().take(MAX_ANNOTATION_BODY_SCALARS + 1).count() > MAX_ANNOTATION_BODY_SCALARS
    }) {
        Err(BridgeError::InvalidRequest(format!(
            "annotation body exceeds {MAX_ANNOTATION_BODY_SCALARS} Unicode scalars"
        )))
    } else {
        Ok(())
    }
}

fn map_preflight_error(error: anyhow::Error) -> BridgeError {
    if is_resource_limit(&error) {
        BridgeError::BufferLimit
    } else {
        BridgeError::InvalidRequest(error.to_string())
    }
}

fn map_render_error(error: anyhow::Error) -> BridgeError {
    if is_resource_limit(&error) {
        BridgeError::BufferLimit
    } else {
        BridgeError::Render(error.to_string())
    }
}

fn is_resource_limit(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<crate::application::ResourceLimitError>()
            .is_some()
    })
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};

    use super::*;
    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

    #[test]
    fn library_dto_retains_the_bounded_cover_payload() {
        let cover = vec![1, 2, 3, 4];
        let book = crate::library::Book {
            id: 7,
            title: "Cover book".to_owned(),
            author: None,
            format: BookFormat::Epub,
            file_path: "/library/cover.epub".to_owned(),
            storage_kind: crate::library::StorageKind::Managed,
            original_path: None,
            content_hash: None,
            file_size: None,
            cover: Some(cover.clone()),
            progress: 0.25,
            date_added: "2026-09-10".to_owned(),
            last_read: None,
        };
        let dto = LibraryBookDto::from(book.clone());

        assert_eq!(dto.cover, Some(cover));
        assert_eq!(
            import_item("cover.epub".to_owned(), book)
                .book
                .unwrap()
                .cover,
            None
        );
    }

    fn cbz_request() -> OpenRequest {
        OpenRequest {
            book_id: None,
            local_id: "fixture".to_owned(),
            path_key: crate::path_key::path_key(std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.cbz"
            ))),
            format_hint: Some(BookFormat::Cbz),
        }
    }

    #[tokio::test]
    async fn bridge_rejects_unverified_book_identity_pairings() {
        let bridge = Bridge::new();
        let mut request = cbz_request();
        request.book_id = Some(7);

        assert!(matches!(
            bridge.open_document(request, Cancellation::new()).await,
            Err(BridgeError::InvalidRequest(message)) if message.contains("library-backed")
        ));
    }

    fn pdf_request() -> OpenRequest {
        OpenRequest {
            book_id: None,
            local_id: "pdf-fixture".to_owned(),
            path_key: crate::path_key::path_key(std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            ))),
            format_hint: Some(BookFormat::Pdf),
        }
    }

    fn epub_request() -> OpenRequest {
        OpenRequest {
            book_id: None,
            local_id: "epub-fixture".to_owned(),
            path_key: crate::path_key::path_key(std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.epub"
            ))),
            format_hint: Some(BookFormat::Epub),
        }
    }

    fn annotation_request(document: DocumentHandle) -> CreateAnnotationRequest {
        CreateAnnotationRequest {
            document,
            unit: 0,
            start: 0,
            end: 1,
            display_scale: 1.0,
            color: HighlightColor::Yellow,
            body: None,
        }
    }

    async fn association_fixture(
        persistence: Arc<AnnotationPersistenceTestGate>,
    ) -> (tempfile::TempDir, Bridge, DocumentHandle, String) {
        let directory = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            persistence: Some(Arc::clone(&persistence)),
            ..AnnotationTestHooks::default()
        }));
        bridge.annotation_store().await.unwrap();
        let source = bridge
            .open_document(epub_request(), Cancellation::new())
            .await
            .unwrap();
        persistence.release();
        bridge
            .create_annotation(annotation_request(source.handle), Cancellation::new())
            .await
            .unwrap();
        persistence.wait_until_entered().await;
        let target_path = directory.path().join("changed.epub");
        std::fs::write(&target_path, epub_with_body("changed fixture text")).unwrap();
        let target = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "association-target".into(),
                    path_key: crate::path_key::path_key(&target_path),
                    format_hint: Some(BookFormat::Epub),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let source_id = bridge
            .list_annotation_association_sources(target.handle, None, 1, Cancellation::new())
            .await
            .unwrap()
            .sources[0]
            .version_id
            .clone();
        (directory, bridge, target.handle, source_id)
    }

    fn empty_epub() -> Vec<u8> {
        epub_with_body("")
    }

    fn epub_with_body(body: &str) -> Vec<u8> {
        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        let chapter =
            format!("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>{body}</body></html>");
        let entries: Vec<(&str, &[u8])> = vec![
            ("mimetype", b"application/epub+zip"),
            (
                "META-INF/container.xml",
                br#"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
            ),
            (
                "OPS/content.opf",
                br#"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">empty</dc:identifier><dc:title>Empty</dc:title><dc:language>en</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#,
            ),
            (
                "OPS/chapter.xhtml", chapter.as_bytes(),
            ),
        ];
        for (path, contents) in &entries {
            archive
                .start_file(*path, SimpleFileOptions::default())
                .unwrap();
            archive.write_all(contents).unwrap();
        }
        archive.finish().unwrap().into_inner()
    }

    fn selectable_pdf_with_media_box(width: u32, height: u32, text: &str) -> Vec<u8> {
        let content = format!("BT /F1 200 Tf 1 0 0 1 100 {} Tm ({text}) Tj ET", height / 2);
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
            format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
            ),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
            format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len() + 1
            ),
        ];
        let mut pdf = b"%PDF-1.4\n".to_vec();
        let mut offsets = Vec::new();
        for (index, object) in objects.iter().enumerate() {
            offsets.push(pdf.len());
            pdf.extend_from_slice(format!("{} 0 obj\n{object}\nendobj\n", index + 1).as_bytes());
        }
        let xref = pdf.len();
        pdf.extend_from_slice(format!("xref\n0 {}\n", objects.len() + 1).as_bytes());
        pdf.extend_from_slice(b"0000000000 65535 f \n");
        for offset in offsets {
            pdf.extend_from_slice(format!("{offset:010} 00000 n \n").as_bytes());
        }
        pdf.extend_from_slice(
            format!(
                "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
                objects.len() + 1
            )
            .as_bytes(),
        );
        pdf
    }

    #[test]
    fn bridge_errors_expose_stable_categories() {
        assert_eq!(
            BridgeError::InvalidDocumentHandle.kind(),
            BridgeErrorKind::NotFound
        );
        assert_eq!(
            BridgeError::DocumentInaccessible.kind(),
            BridgeErrorKind::Inaccessible
        );
        assert_eq!(
            BridgeError::InvalidRequest("bad scale".to_owned()).kind(),
            BridgeErrorKind::InvalidRequest
        );
        assert_eq!(
            BridgeError::Open {
                format: BookFormat::Cbz,
                detail: "entry exceeds byte limit".to_owned(),
            }
            .kind(),
            BridgeErrorKind::Malformed,
            "detail text must not determine the category"
        );
        assert_eq!(
            BridgeError::UnsupportedOperation(BookFormat::Epub).kind(),
            BridgeErrorKind::Unsupported
        );
        assert_eq!(
            BridgeError::BufferLimit.kind(),
            BridgeErrorKind::LimitExceeded
        );
        assert_eq!(
            map_open_error(OpenDocumentError::BackendUnavailable {
                format: BookFormat::Pdf,
                detail: "missing PDFium".to_owned(),
            })
            .kind(),
            BridgeErrorKind::BackendUnavailable
        );
        assert_eq!(
            BridgeError::Worker.kind(),
            BridgeErrorKind::BackendUnavailable
        );
        assert_eq!(
            BridgeError::Render("backend error".to_owned()).kind(),
            BridgeErrorKind::RenderFailed
        );
        assert_eq!(
            map_preflight_error(anyhow::Error::new(crate::application::ResourceLimitError(
                "decoded image limit".to_owned()
            ))),
            BridgeError::BufferLimit
        );
        assert_eq!(
            map_render_error(anyhow::Error::new(crate::application::ResourceLimitError(
                "PDF endpoint limit".to_owned()
            ))),
            BridgeError::BufferLimit
        );
    }

    #[test]
    fn pdf_caret_endpoint_keeps_its_underlying_character_range() {
        let mapped = pdf_selection_endpoint((
            crate::pdf::PdfSelectionRect {
                left: 1.0,
                top: 2.0,
                right: 3.0,
                bottom: 4.0,
            },
            crate::pdf::PdfSelectionEndpoint {
                underlying_character: 7,
                character: 8,
                page_x: 0.0,
                page_y: 0.0,
            },
        ));

        assert_eq!(mapped.offset, 8);
        assert_eq!((mapped.range_start, mapped.range_end), (7, 8));
    }

    #[test]
    fn navigation_stops_are_grapheme_safe_and_unicode_word_aware() {
        let text = "Cafe\u{301}—naïve! 東京";
        let (graphemes, words) = navigation_boundaries(text);

        assert!(graphemes.contains(&5));
        assert!(!graphemes.contains(&4), "decomposed accent is one grapheme");
        assert_eq!(words, vec![0, 5, 6, 11, 13, 14, 15]);
    }

    #[test]
    fn word_stops_skip_standalone_whitespace_and_punctuation() {
        let (_, words) = navigation_boundaries("one,  two?! 三");
        assert_eq!(words, vec![0, 3, 6, 9, 12, 13]);
    }

    #[test]
    fn geometry_only_pdf_annotation_dto_does_not_invent_text() {
        let pdf = crate::pdf::PdfDoc::open(std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        )))
        .unwrap();
        let canonical = pdf
            .selection_snapshot(0, 1.0)
            .unwrap()
            .page_rectangles(0, 1)[0]
            .1;
        let expected = pdf.page_rectangles_to_pixels(0, 2.0, &[canonical]).unwrap()[0];
        let annotation = Annotation {
            id: AnnotationId::new(),
            book_id: None,
            local_path: Some("sample.pdf".into()),
            fingerprint: DocumentFingerprint::new("sha256", 1, vec![7; 32]).unwrap(),
            quote: None,
            target: AnnotationTarget::Pdf(
                PdfAnchor::new(
                    0,
                    None,
                    vec![
                        PageRect::new(canonical.0, canonical.1, canonical.2, canonical.3).unwrap(),
                    ],
                )
                .unwrap(),
            ),
            color: HighlightColor::Yellow,
            body: None,
            provenance: None,
            created_at: "now".into(),
            modified_at: "now".into(),
            deleted_at: None,
        };
        let current_fingerprint = annotation.fingerprint.clone();

        let dto = annotation_dtos(
            vec![annotation],
            &OpenDocument::Pdf(pdf.into()),
            &current_fingerprint,
            2.0,
            true,
            &|| false,
        )
        .unwrap()
        .remove(0);
        assert_eq!(dto.resolution, AnnotationResolution::Exact);
        assert_eq!(dto.text_range, None);
        assert_eq!(dto.quote, None);
        assert_eq!(
            dto.rectangles,
            vec![SelectionRect {
                left: expected.left,
                top: expected.top,
                right: expected.right,
                bottom: expected.bottom,
            }]
        );
    }

    #[test]
    fn missing_pdf_pages_orphan_only_the_affected_annotations() {
        let pdf = crate::pdf::PdfDoc::open(std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        )))
        .unwrap();
        let fingerprint = DocumentFingerprint::new("sha256", 1, vec![7; 32]).unwrap();
        let annotation = |target, quote| Annotation {
            id: AnnotationId::new(),
            book_id: None,
            local_path: Some("sample.pdf".into()),
            fingerprint: fingerprint.clone(),
            quote,
            target,
            color: HighlightColor::Yellow,
            body: None,
            provenance: None,
            created_at: "now".into(),
            modified_at: "now".into(),
            deleted_at: None,
        };
        let missing_page = u32::try_from(pdf.page_count()).unwrap();
        let geometry = annotation(
            AnnotationTarget::Pdf(
                PdfAnchor::new(
                    missing_page,
                    None,
                    vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()],
                )
                .unwrap(),
            ),
            None,
        );
        let text = annotation(
            AnnotationTarget::Pdf(
                PdfAnchor::new(
                    missing_page,
                    Some((0, 1)),
                    vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()],
                )
                .unwrap(),
            ),
            Some(QuoteSelector::new("x", "", "").unwrap()),
        );
        let valid_geometry = annotation(
            AnnotationTarget::Pdf(
                PdfAnchor::new(0, None, vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()]).unwrap(),
            ),
            None,
        );
        let incompatible = annotation(
            AnnotationTarget::Epub(EpubAnchor::new(0, "missing.xhtml", 0, 1).unwrap()),
            Some(QuoteSelector::new("x", "", "").unwrap()),
        );

        let resolved = annotation_dtos(
            vec![geometry, text, valid_geometry, incompatible],
            &OpenDocument::Pdf(pdf.into()),
            &fingerprint,
            1.0,
            true,
            &|| false,
        )
        .unwrap();
        assert_eq!(resolved.len(), 4);
        assert!(resolved[..2].iter().all(|item| {
            item.resolution == AnnotationResolution::Orphaned
                && item.text_range.is_none()
                && item.rectangles.is_empty()
        }));
        assert_eq!(resolved[2].resolution, AnnotationResolution::Exact);
        assert!(!resolved[2].rectangles.is_empty());
        assert_eq!(resolved[3].resolution, AnnotationResolution::Orphaned);
    }

    #[test]
    fn annotation_snapshot_rejects_aggregate_retained_bytes() {
        let annotations = (0..=MAX_ANNOTATION_SNAPSHOT_BYTES
            / crate::annotations::MAX_ANNOTATION_BODY_SCALARS)
            .map(|_| Annotation {
                id: AnnotationId::new(),
                book_id: None,
                local_path: Some("sample.epub".into()),
                fingerprint: DocumentFingerprint::new("sha256", 1, vec![7; 32]).unwrap(),
                quote: None,
                target: AnnotationTarget::Epub(EpubAnchor::new(0, "chapter.xhtml", 0, 1).unwrap()),
                color: HighlightColor::Yellow,
                body: Some("x".repeat(crate::annotations::MAX_ANNOTATION_BODY_SCALARS)),
                provenance: None,
                created_at: "now".into(),
                modified_at: "now".into(),
                deleted_at: None,
            })
            .collect();

        assert_eq!(
            bounded_annotation_snapshot(annotations).unwrap_err(),
            BridgeError::AnnotationLimit
        );
    }

    #[test]
    fn public_bridge_facades_share_process_admission() {
        let first = Bridge::new();
        let second = Bridge::new();

        assert!(Arc::ptr_eq(&first.admission, &second.admission));
    }

    #[tokio::test]
    async fn document_slots_are_shared_across_bridge_facades() {
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.document_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(admission);
        let first_bridge = Bridge::with_admission(Arc::clone(&admission));
        let second_bridge = Bridge::with_admission(admission);
        let first = first_bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let mut waiting = Box::pin(second_bridge.open_document(cbz_request(), Cancellation::new()));

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), &mut waiting)
                .await
                .is_err(),
            "the second facade must wait for the shared document slot"
        );
        assert!(first_bridge.release_document(first.handle));
        let second = waiting.await.unwrap();
        assert!(second_bridge.release_document(second.handle));
    }

    #[tokio::test]
    async fn request_count_rejects_without_creating_waiters() {
        let admission = Arc::new(BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1));
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let _requests = Arc::clone(&admission.request_slots)
            .acquire_many_owned(MAX_BRIDGE_REQUESTS as u32)
            .await
            .unwrap();

        let error = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap_err();

        assert_eq!(error, BridgeError::RequestLimit);
    }

    #[tokio::test]
    async fn annotation_mutations_share_request_admission() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(admission);
        let bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let id = AnnotationId::new().to_string();
        let request = Arc::clone(&admission.request_slots)
            .acquire_owned()
            .await
            .unwrap();

        assert_eq!(
            bridge
                .update_annotation(document.handle, &id, HighlightColor::Green, None,)
                .await,
            Err(BridgeError::RequestLimit)
        );
        assert_eq!(
            bridge.delete_annotation(document.handle, &id).await,
            Err(BridgeError::RequestLimit)
        );

        drop(request);
        assert!(
            !bridge
                .update_annotation(document.handle, &id, HighlightColor::Green, None,)
                .await
                .unwrap()
        );
        assert_eq!(admission.request_slots.available_permits(), 1);
        assert!(
            !bridge
                .delete_annotation(document.handle, &id)
                .await
                .unwrap()
        );
        assert_eq!(admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn buffer_count_is_shared_and_released_with_the_buffer() {
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.buffer_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(admission);
        let first = Bridge::with_admission(Arc::clone(&admission));
        let second = Bridge::with_admission(admission);
        let first_document = first
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let second_document = second
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let request = |document| RenderRequest {
            document,
            page: 0,
            scale: 1.0,
        };
        let buffer = first
            .render_page(request(first_document.handle), Cancellation::new())
            .await
            .unwrap();

        assert_eq!(
            second
                .render_page(request(second_document.handle), Cancellation::new())
                .await,
            Err(BridgeError::BufferCountLimit)
        );
        assert!(first.release_buffer(buffer.handle));
        let buffer = second
            .render_page(request(second_document.handle), Cancellation::new())
            .await
            .unwrap();
        assert!(second.release_buffer(buffer.handle));
    }

    #[tokio::test]
    async fn cbz_probe_and_decode_peak_is_acquired_atomically() {
        let document = OpenDocument::open(&DeviceFileLocator::from_path(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.cbz"
        )))
        .unwrap();
        let permits = render_probe_byte_len(&document, 0).unwrap();
        let semaphore = Arc::new(Semaphore::new(permits));
        let first = acquire_permits(
            Arc::clone(&semaphore),
            u32::try_from(permits).unwrap(),
            &Cancellation::new(),
        )
        .await
        .unwrap();
        let cancellation = Cancellation::new();
        let mut second = Box::pin(acquire_permits(
            Arc::clone(&semaphore),
            u32::try_from(permits).unwrap(),
            &cancellation,
        ));

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), &mut second)
                .await
                .is_err()
        );
        drop(first);
        let _second = second.await.unwrap();
    }

    #[tokio::test]
    async fn pdf_render_waits_for_transient_memory_admission() {
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.probe_bytes = Arc::new(Semaphore::new(0));
        let bridge = Bridge::with_admission(Arc::new(admission));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let mut render = Box::pin(bridge.render_page(
            RenderRequest {
                document: document.handle,
                page: 0,
                scale: 1.0,
            },
            cancellation.clone(),
        ));

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), &mut render)
                .await
                .is_err()
        );
        cancellation.cancel();
        assert_eq!(render.await, Err(BridgeError::Cancelled));
    }

    #[tokio::test]
    async fn pdf_selection_uses_request_render_and_transient_admission_before_worker() {
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.probe_bytes = Arc::new(Semaphore::new(0));
        let admission = Arc::new(admission);
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let mut selection = Box::pin(bridge.selection_surface(
            document.handle,
            0,
            1.0,
            680.0,
            18.0,
            cancellation.clone(),
        ));

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), &mut selection)
                .await
                .is_err()
        );
        assert_eq!(
            admission.request_slots.available_permits(),
            MAX_BRIDGE_REQUESTS - 1
        );
        assert_eq!(admission.render_slots.available_permits(), 0);
        cancellation.cancel();
        assert_eq!(selection.await, Err(BridgeError::Cancelled));
        assert_eq!(
            admission.request_slots.available_permits(),
            MAX_BRIDGE_REQUESTS
        );
        assert_eq!(admission.render_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn annotation_listing_waits_for_render_before_reserving_probe_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.probe_bytes = Arc::new(Semaphore::new(MAX_ANNOTATION_SNAPSHOT_BYTES));
        let admission = Arc::new(admission);
        let bridge = Arc::new(Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        ));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let held_render_slot = Arc::clone(&admission.render_slots)
            .acquire_owned()
            .await
            .unwrap();
        let listing = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            async move {
                bridge
                    .list_annotations(document.handle, 1.0, Cancellation::new())
                    .await
            }
        });
        while admission.request_slots.available_permits() == MAX_BRIDGE_REQUESTS {
            tokio::task::yield_now().await;
        }

        assert_eq!(
            admission.probe_bytes.available_permits(),
            MAX_ANNOTATION_SNAPSHOT_BYTES
        );
        drop(held_render_slot);
        assert!(listing.await.unwrap().unwrap().is_empty());
        assert_eq!(
            admission.probe_bytes.available_permits(),
            MAX_ANNOTATION_SNAPSHOT_BYTES
        );
    }

    #[tokio::test]
    async fn epub_selection_raster_is_retained_until_explicit_release() {
        let buffer_budget = EPUB_TEXT_MAX_PIXELS * 4 * 2;
        let bridge = Bridge::with_limits(buffer_budget, 1);
        let document = bridge
            .open_document(epub_request(), Cancellation::new())
            .await
            .unwrap();

        let surface = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let raster = surface.raster.expect("EPUB selection owns a raster");
        assert!(raster.byte_len > 0);
        assert_eq!(bridge.admission.buffer_bytes.available_permits(), 0);
        assert!(bridge.release_selection(surface.handle));
        assert_eq!(bridge.admission.buffer_bytes.available_permits(), 0);
        assert_eq!(
            bridge.take_buffer(raster.handle).unwrap().len(),
            raster.byte_len
        );
        assert_eq!(bridge.admission.buffer_bytes.available_permits(), 0);
        assert!(bridge.release_buffer(raster.handle));
        assert_eq!(
            bridge.admission.buffer_bytes.available_permits(),
            buffer_budget
        );
        assert_eq!(
            bridge.take_buffer(raster.handle),
            Err(BridgeError::InvalidBufferHandle)
        );
        assert!(!bridge.release_selection(surface.handle));
    }

    #[tokio::test]
    async fn retained_selection_exhausts_and_releases_request_admission() {
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(admission);
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();

        let first = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(admission.request_slots.available_permits(), 0);
        assert_eq!(
            bridge
                .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        );

        assert!(bridge.release_selection(first.handle));
        let second = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        assert!(bridge.release_selection(second.handle));
        assert_eq!(admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn retained_pdf_selections_do_not_hold_transient_render_admission() {
        let document = OpenDocument::open(&DeviceFileLocator::from_path(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        )))
        .unwrap();
        let selection_peak = selection_transient_byte_len(&document, 0, 1.0, false).unwrap();
        let probe_capacity = selection_peak * 2;
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.probe_bytes = Arc::new(Semaphore::new(probe_capacity));
        let admission = Arc::new(admission);
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let first = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let second = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();

        let rendered = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            bridge.render_page(
                RenderRequest {
                    document: document.handle,
                    page: 0,
                    scale: 1.0,
                },
                Cancellation::new(),
            ),
        )
        .await
        .expect("render admission must not depend on releasing retained selections")
        .unwrap();
        assert!(bridge.release_buffer(rendered.handle));
        assert!(bridge.release_selection(first.handle));
        assert!(bridge.release_selection(second.handle));
        assert_eq!(admission.probe_bytes.available_permits(), probe_capacity);
    }

    #[tokio::test]
    async fn dropped_epub_selection_keeps_admission_until_worker_exits() {
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        admission.buffer_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(admission);
        let worker_barrier = Arc::new(std::sync::Barrier::new(2));
        let mut bridge = Bridge::with_admission(Arc::clone(&admission));
        bridge.selection_worker_barrier = Some(Arc::clone(&worker_barrier));
        let bridge = Arc::new(bridge);
        let document = bridge
            .open_document(epub_request(), Cancellation::new())
            .await
            .unwrap();
        let (drop_tx, drop_rx) = tokio::sync::oneshot::channel();
        let (dropped_tx, dropped_rx) = std::sync::mpsc::sync_channel(1);
        let operation_bridge = Arc::clone(&bridge);
        let operation = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    tokio::select! {
                        _ = operation_bridge.selection_surface(
                            document.handle,
                            0,
                            1.0,
                            680.0,
                            18.0,
                            Cancellation::new(),
                        ) => panic!("selection must remain blocked"),
                        _ = drop_rx => {}
                    }
                    dropped_tx.send(()).unwrap();
                });
        });

        worker_barrier.wait();
        drop_tx.send(()).unwrap();
        dropped_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("the outer selection future must be dropped");
        assert_eq!(admission.request_slots.available_permits(), 0);
        assert_eq!(admission.buffer_slots.available_permits(), 0);

        worker_barrier.wait();
        operation.join().unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while admission.request_slots.available_permits() == 0
                || admission.buffer_slots.available_permits() == 0
            {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the detached blocking worker must release its admission");
        assert!(bridge.registry.lock().unwrap().buffers.is_empty());
        assert!(bridge.registry.lock().unwrap().selections.is_empty());
    }

    #[tokio::test]
    async fn dropped_annotation_create_keeps_request_admission_until_worker_exits() {
        let directory = tempfile::tempdir().unwrap();
        let worker_barrier = Arc::new(std::sync::Barrier::new(2));
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(admission);
        let mut bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        bridge.annotation_resolution_worker_barrier = Some(Arc::clone(&worker_barrier));
        let bridge = Arc::new(bridge);
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let (drop_tx, drop_rx) = tokio::sync::oneshot::channel();
        let (dropped_tx, dropped_rx) = std::sync::mpsc::sync_channel(1);
        let operation_bridge = Arc::clone(&bridge);
        let operation = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    tokio::select! {
                        _ = operation_bridge.create_annotation(
                            annotation_request(document.handle),
                            Cancellation::new(),
                        ) => panic!("annotation create must remain blocked"),
                        _ = drop_rx => {}
                    }
                    dropped_tx.send(()).unwrap();
                });
        });

        worker_barrier.wait();
        drop_tx.send(()).unwrap();
        dropped_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("the outer annotation create future must be dropped");
        assert_eq!(admission.request_slots.available_permits(), 0);

        worker_barrier.wait();
        operation.join().unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while admission.request_slots.available_permits() == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("detached annotation conversion must release request admission");
        assert_eq!(admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn pdf_selection_cancelled_during_worker_reports_cancellation() {
        let cancellation_barrier = Arc::new(std::sync::Barrier::new(2));
        let mut bridge = Bridge::new();
        bridge.selection_second_cancellation_barrier = Some(Arc::clone(&cancellation_barrier));
        let bridge = Arc::new(bridge);
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let operation_bridge = Arc::clone(&bridge);
        let operation_cancellation = cancellation.clone();
        let operation = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(operation_bridge.selection_surface(
                    document.handle,
                    0,
                    1.0,
                    680.0,
                    18.0,
                    operation_cancellation,
                ))
        });

        cancellation_barrier.wait();
        cancellation.cancel();
        cancellation_barrier.wait();
        assert_eq!(operation.join().unwrap(), Err(BridgeError::Cancelled));
    }

    #[tokio::test]
    async fn pdf_annotation_persists_quote_and_underlying_page_rectangles() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let surface = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let endpoint = surface
            .endpoints
            .iter()
            .find(|endpoint| endpoint.range_start < endpoint.range_end)
            .copied()
            .unwrap();
        let chars: Vec<_> = surface.text.chars().collect();
        let expected_quote: String = chars[endpoint.range_start..endpoint.range_end]
            .iter()
            .collect();
        assert!(bridge.release_selection(surface.handle));

        bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.handle,
                    unit: 0,
                    start: endpoint.range_start,
                    end: endpoint.range_end,
                    display_scale: 2.0,
                    color: HighlightColor::Yellow,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let retained = bridge.document(document.handle).unwrap();
        let stored = bridge
            .annotation_store()
            .await
            .unwrap()
            .list_for_local_path_async(&retained.local_path)
            .await
            .unwrap();

        assert_eq!(stored.len(), 1);
        assert_eq!(
            stored[0].quote.as_ref().unwrap().original.as_deref(),
            Some(expected_quote.as_str())
        );
        let AnnotationTarget::Pdf(anchor) = &stored[0].target else {
            panic!("PDF selection must persist a PDF anchor");
        };
        assert_eq!(
            anchor.character_range,
            Some((endpoint.range_start as u32, endpoint.range_end as u32))
        );
        assert!(!anchor.rectangles.is_empty());
        let listed = bridge
            .list_annotations(document.handle, 2.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].resolution, AnnotationResolution::Exact);
        assert_eq!(
            listed[0].text_range,
            Some(AnnotationTextRange {
                start: endpoint.range_start,
                end: endpoint.range_end,
            })
        );
    }

    #[tokio::test]
    async fn pdf_annotation_creation_uses_the_displayed_scale() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("large-page.pdf");
        std::fs::write(&path, selectable_pdf_with_media_box(7_000, 7_000, "scale")).unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let document = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "large-page".into(),
                    path_key: crate::path_key::path_key(&path),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let retained = bridge.document(document.handle).unwrap();
        assert!(matches!(
            selection_transient_byte_len(&retained.document, 0, 1.0, false),
            Err(BridgeError::BufferLimit)
        ));
        let surface = bridge
            .selection_surface(document.handle, 0, 0.1, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let endpoint = surface
            .endpoints
            .iter()
            .find(|endpoint| endpoint.range_start < endpoint.range_end)
            .copied()
            .unwrap();
        assert!(bridge.release_selection(surface.handle));

        let created = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.handle,
                    unit: 0,
                    start: endpoint.range_start,
                    end: endpoint.range_end,
                    display_scale: 0.1,
                    color: HighlightColor::Yellow,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        assert_eq!(created.resolution, AnnotationResolution::Exact);
        assert_eq!(
            bridge
                .list_annotations(document.handle, 0.1, Cancellation::new())
                .await
                .unwrap(),
            vec![created]
        );
    }

    #[tokio::test]
    async fn annotation_response_preparation_fails_before_persistence() {
        let directory = tempfile::tempdir().unwrap();
        let admission = Arc::new(BridgeAdmission::new(
            ANNOTATION_GEOMETRY_WORKSPACE_BYTES as usize - 1,
            1,
        ));
        let bridge = Bridge::with_admission_database(
            admission,
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let retained = bridge.document(document.handle).unwrap();

        assert_eq!(
            bridge
                .create_annotation(annotation_request(document.handle), Cancellation::new())
                .await,
            Err(BridgeError::BufferLimit)
        );
        assert!(
            bridge
                .annotation_store()
                .await
                .unwrap()
                .list_for_local_path_async(&retained.local_path)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn inserted_annotation_decode_failure_rolls_back() {
        let directory = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            fail_create_response: true,
            ..AnnotationTestHooks::default()
        }));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let retained = bridge.document(document.handle).unwrap();

        assert!(matches!(
            bridge
                .create_annotation(annotation_request(document.handle), Cancellation::new())
                .await,
            Err(BridgeError::Storage(message))
                if message.contains("response preparation failure")
        ));
        assert!(
            bridge
                .annotation_store()
                .await
                .unwrap()
                .list_for_local_path_async(&retained.local_path)
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn oversized_annotation_bodies_fail_before_async_work() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let body = "x".repeat(MAX_ANNOTATION_BODY_SCALARS + 1);
        let mut request = annotation_request(document.handle);
        request.body = Some(body.clone());

        assert!(matches!(
            bridge.create_annotation(request, Cancellation::new()).await,
            Err(BridgeError::InvalidRequest(message)) if message.contains("annotation body")
        ));
        assert!(bridge.annotation_store.get().is_none());
        assert!(matches!(
            bridge
                .update_annotation(
                    document.handle,
                    &AnnotationId::new().to_string(),
                    HighlightColor::Green,
                    Some(body),
                )
                .await,
            Err(BridgeError::InvalidRequest(message)) if message.contains("annotation body")
        ));
        assert!(bridge.annotation_store.get().is_none());
    }

    #[tokio::test]
    async fn exact_annotations_survive_oversized_graphemes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("oversized-grapheme.epub");
        let body = format!("ordinary e{}", "\u{301}".repeat(1_025));
        std::fs::write(&path, epub_with_body(&body)).unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let request = || OpenRequest {
            book_id: None,
            local_id: "oversized-grapheme".into(),
            path_key: crate::path_key::path_key(&path),
            format_hint: Some(BookFormat::Epub),
        };
        let document = bridge
            .open_document(request(), Cancellation::new())
            .await
            .unwrap();
        let surface = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let chars = surface.text.chars().collect::<Vec<_>>();
        let start = chars
            .windows("ordinary".len())
            .position(|window| window.iter().collect::<String>() == "ordinary")
            .unwrap();
        let end = start + "ordinary".len();
        assert!(bridge.release_buffer(surface.raster.unwrap().handle));
        assert!(bridge.release_selection(surface.handle));

        let created = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.handle,
                    unit: 0,
                    start,
                    end,
                    display_scale: 1.0,
                    color: HighlightColor::Yellow,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        assert_eq!(created.resolution, AnnotationResolution::Exact);
        let oversized_start = chars
            .iter()
            .rposition(|character| *character == 'e')
            .unwrap();
        let oversized = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.handle,
                    unit: 0,
                    start: oversized_start,
                    end: chars.len(),
                    display_scale: 1.0,
                    color: HighlightColor::Green,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        assert_eq!(oversized.resolution, AnnotationResolution::Exact);
        let listed = bridge
            .list_annotations(document.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 2);
        assert!(listed.contains(&created));
        assert!(listed.contains(&oversized));

        assert!(bridge.release_document(document.handle));
        let reopened = bridge
            .open_document(request(), Cancellation::new())
            .await
            .unwrap();
        assert_eq!(
            bridge
                .list_annotations(reopened.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .len(),
            2
        );
    }

    #[tokio::test]
    async fn epub_annotation_measurement_ignores_unused_raster_limits() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("tall-layout.epub");
        let body = "x".repeat(20);
        std::fs::write(&path, epub_with_body(&body)).unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let document = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "tall-layout".into(),
                    path_key: crate::path_key::path_key(&path),
                    format_hint: Some(BookFormat::Epub),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let retained = bridge.document(document.handle).unwrap();
        match selection_surface(&retained.document, 0, 1.0, 680.0, 1024.0, true, &|| false) {
            Err(BridgeError::BufferLimit) => {}
            Err(BridgeError::Render(message))
                if message.contains("16777216-pixel per-call ceiling") => {}
            Err(error) => panic!("unexpected raster failure: {error:?}"),
            Ok(extraction) => panic!(
                "default raster unexpectedly fit: {}x{}, text={}, lines={}",
                extraction.raster_width,
                extraction.raster_height,
                extraction.surface.text.chars().count(),
                extraction.surface.visual_lines.len(),
            ),
        }
        let measurement =
            selection_surface(&retained.document, 0, 1.0, 680.0, 1024.0, false, &|| false);
        if let Err(error) = measurement {
            panic!("measurement failed: {error:?}");
        }
        let surface = bridge
            .selection_surface(document.handle, 0, 0.1, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let endpoint = surface
            .endpoints
            .iter()
            .find(|endpoint| endpoint.range_start < endpoint.range_end)
            .copied()
            .unwrap();
        assert!(bridge.release_buffer(surface.raster.unwrap().handle));
        assert!(bridge.release_selection(surface.handle));

        let created = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.handle,
                    unit: 0,
                    start: endpoint.range_start,
                    end: endpoint.range_end,
                    display_scale: 0.1,
                    color: HighlightColor::Yellow,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        assert_eq!(created.resolution, AnnotationResolution::Exact);
        assert_eq!(
            bridge
                .list_annotations(document.handle, 0.1, Cancellation::new())
                .await
                .unwrap(),
            vec![created]
        );
    }

    #[tokio::test]
    async fn epub_annotation_admits_retained_caret_capacity() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("many-caret-lines.epub");
        let body = format!("<p>{}</p>", "i".repeat(65)).repeat(496);
        std::fs::write(&path, epub_with_body(&body)).unwrap();
        let admission = Arc::new(BridgeAdmission::new(
            MAX_BRIDGE_RETAINED_BUFFER_BYTES,
            MAX_BRIDGE_RENDER_WORKERS,
        ));
        let bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        let document = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "many-caret-lines".into(),
                    path_key: crate::path_key::path_key(&path),
                    format_hint: Some(BookFormat::Epub),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let initial_probe_bytes = admission.probe_bytes.available_permits();
        let surface = bridge
            .selection_surface(document.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let endpoint = surface
            .endpoints
            .iter()
            .find(|endpoint| endpoint.range_start < endpoint.range_end)
            .copied()
            .unwrap();
        assert!(bridge.release_buffer(surface.raster.unwrap().handle));
        assert!(bridge.release_selection(surface.handle));
        assert_eq!(
            admission.probe_bytes.available_permits(),
            initial_probe_bytes
        );

        let created = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.handle,
                    unit: 0,
                    start: endpoint.range_start,
                    end: endpoint.range_end,
                    display_scale: 1.0,
                    color: HighlightColor::Yellow,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        assert_eq!(
            created.text_range,
            Some(AnnotationTextRange {
                start: endpoint.range_start,
                end: endpoint.range_end,
            })
        );
        assert_eq!(
            bridge
                .list_annotations(document.handle, 1.0, Cancellation::new())
                .await
                .unwrap(),
            vec![created]
        );
        assert_eq!(
            admission.probe_bytes.available_permits(),
            initial_probe_bytes
        );
    }

    #[test]
    fn exact_snapshot_reuses_its_scalar_index() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("exact-snapshot.epub");
        let body = "e\u{301}".repeat(32_767);
        std::fs::write(&path, epub_with_body(&body)).unwrap();
        let document = OpenDocument::open(&DeviceFileLocator::from_path(&path)).unwrap();
        let quote = QuoteSelector::new("e\u{301}", "", "").unwrap();
        let annotations = (0..MAX_ANNOTATIONS_PER_SNAPSHOT)
            .map(|_| Annotation {
                id: AnnotationId::new(),
                book_id: None,
                local_path: Some(path.to_string_lossy().into_owned()),
                fingerprint: DocumentFingerprint::new("sha256", 1, vec![7; 32]).unwrap(),
                quote: Some(quote.clone()),
                target: AnnotationTarget::Epub(
                    EpubAnchor::new(0, "OPS/chapter.xhtml", 65_532, 65_534).unwrap(),
                ),
                color: HighlightColor::Yellow,
                body: None,
                provenance: None,
                created_at: "now".into(),
                modified_at: "now".into(),
                deleted_at: None,
            })
            .collect();
        let current_fingerprint = DocumentFingerprint::new("sha256", 1, vec![7; 32]).unwrap();

        let resolved = annotation_dtos(
            annotations,
            &document,
            &current_fingerprint,
            1.0,
            true,
            &|| false,
        )
        .unwrap();
        assert_eq!(resolved.len(), MAX_ANNOTATIONS_PER_SNAPSHOT);
        assert!(
            resolved
                .iter()
                .all(|annotation| annotation.resolution == AnnotationResolution::Exact)
        );
    }

    #[test]
    fn changed_fingerprint_bypasses_offsets_and_orphans_pdf_geometry() {
        let directory = tempfile::tempdir().unwrap();
        let epub_path = directory.path().join("changed.epub");
        std::fs::write(&epub_path, epub_with_body("target target")).unwrap();
        let epub = OpenDocument::open(&DeviceFileLocator::from_path(&epub_path)).unwrap();
        let stored_fingerprint = DocumentFingerprint::new("sha256", 1, vec![1; 32]).unwrap();
        let current_fingerprint = DocumentFingerprint::new("sha256", 1, vec![2; 32]).unwrap();
        let annotation = Annotation {
            id: AnnotationId::new(),
            book_id: None,
            local_path: Some("old.epub".into()),
            fingerprint: stored_fingerprint.clone(),
            quote: Some(QuoteSelector::new("target", "", "").unwrap()),
            target: AnnotationTarget::Epub(EpubAnchor::new(0, "OPS/chapter.xhtml", 0, 6).unwrap()),
            color: HighlightColor::Yellow,
            body: None,
            provenance: None,
            created_at: "now".into(),
            modified_at: "now".into(),
            deleted_at: None,
        };
        let resolved = annotation_dtos(
            vec![annotation],
            &epub,
            &current_fingerprint,
            1.0,
            true,
            &|| false,
        )
        .unwrap();
        assert_eq!(resolved[0].resolution, AnnotationResolution::Ambiguous);
        assert!(resolved[0].text_range.is_none());

        let pdf = crate::pdf::PdfDoc::open(std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        )))
        .unwrap();
        let geometry = Annotation {
            id: AnnotationId::new(),
            book_id: None,
            local_path: Some("old.pdf".into()),
            fingerprint: stored_fingerprint,
            quote: None,
            target: AnnotationTarget::Pdf(
                PdfAnchor::new(0, None, vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()]).unwrap(),
            ),
            color: HighlightColor::Yellow,
            body: None,
            provenance: None,
            created_at: "now".into(),
            modified_at: "now".into(),
            deleted_at: None,
        };
        let resolved = annotation_dtos(
            vec![geometry],
            &OpenDocument::Pdf(pdf.into()),
            &current_fingerprint,
            1.0,
            true,
            &|| false,
        )
        .unwrap();
        assert_eq!(resolved[0].resolution, AnnotationResolution::Orphaned);
        assert!(resolved[0].rectangles.is_empty());
    }

    #[test]
    fn changed_pdf_quote_recovery_requires_complete_target_mapping() {
        let document =
            crate::pdf::PdfDoc::from_bytes(selectable_pdf_with_media_box(50, 200, "A")).unwrap();
        let (text, complete) = document
            .page_text_with_mapping_bounded(0, usize::MAX, || false)
            .unwrap();
        assert_eq!(text, "\u{FFFD}");
        assert!(!complete);
        let annotation = Annotation {
            id: AnnotationId::new(),
            book_id: None,
            local_path: Some("source.pdf".into()),
            fingerprint: DocumentFingerprint::new("sha256", 1, vec![1; 32]).unwrap(),
            quote: Some(QuoteSelector::new("\u{FFFD}", "", "").unwrap()),
            target: AnnotationTarget::Pdf(
                PdfAnchor::new(
                    0,
                    Some((0, 1)),
                    vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()],
                )
                .unwrap(),
            ),
            color: HighlightColor::Yellow,
            body: None,
            provenance: None,
            created_at: "now".into(),
            modified_at: "now".into(),
            deleted_at: None,
        };
        let current_fingerprint = DocumentFingerprint::new("sha256", 1, vec![2; 32]).unwrap();

        let resolved = annotation_dtos(
            vec![annotation],
            &OpenDocument::Pdf(document.into()),
            &current_fingerprint,
            1.0,
            true,
            &|| false,
        )
        .unwrap();

        assert_eq!(resolved[0].resolution, AnnotationResolution::Orphaned);
        assert!(resolved[0].text_range.is_none());
    }

    #[tokio::test]
    async fn explicit_bridge_association_recovers_changed_pdf_quote() {
        let directory = tempfile::tempdir().unwrap();
        let source_path = directory.path().join("source.pdf");
        let target_path = directory.path().join("target.pdf");
        let source_bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ))
        .unwrap();
        let mut target_bytes = source_bytes.clone();
        target_bytes.extend_from_slice(b"\n% changed version\n");
        std::fs::write(&source_path, source_bytes).unwrap();
        std::fs::write(&target_path, target_bytes).unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let open = |path: &std::path::Path, local_id: &str| OpenRequest {
            book_id: None,
            local_id: local_id.into(),
            path_key: crate::path_key::path_key(path),
            format_hint: Some(BookFormat::Pdf),
        };
        let source = bridge
            .open_document(open(&source_path, "source"), Cancellation::new())
            .await
            .unwrap();
        let surface = bridge
            .selection_surface(source.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let endpoint = surface
            .endpoints
            .iter()
            .find(|endpoint| endpoint.range_start < endpoint.range_end)
            .copied()
            .unwrap();
        assert!(bridge.release_selection(surface.handle));
        let created = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: source.handle,
                    unit: 0,
                    start: endpoint.range_start,
                    end: endpoint.range_end,
                    display_scale: 1.0,
                    color: HighlightColor::Yellow,
                    body: None,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let target = bridge
            .open_document(open(&target_path, "target"), Cancellation::new())
            .await
            .unwrap();
        let source_version = bridge
            .list_annotation_association_sources(target.handle, None, 1, Cancellation::new())
            .await
            .unwrap()
            .sources
            .remove(0)
            .version_id;

        assert_eq!(
            bridge
                .associate_annotation_version(&source_version, target.handle, Cancellation::new(),)
                .await
                .unwrap(),
            AnnotationAssociationOutcome::Associated
        );
        let recovered = bridge
            .list_annotations(target.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].id, created.id);
        assert_eq!(recovered[0].resolution, AnnotationResolution::Recovered);
    }

    #[tokio::test]
    async fn explicit_bridge_association_recovers_changed_document_annotations() {
        let directory = tempfile::tempdir().unwrap();
        let source_path = directory.path().join("source.epub");
        let target_path = directory.path().join("target.epub");
        std::fs::write(&source_path, epub_with_body("lead target tail")).unwrap();
        std::fs::write(&target_path, epub_with_body("inserted lead target tail")).unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let open = |path: &std::path::Path, local_id: &str| OpenRequest {
            book_id: None,
            local_id: local_id.into(),
            path_key: crate::path_key::path_key(path),
            format_hint: Some(BookFormat::Epub),
        };
        let source = bridge
            .open_document(open(&source_path, "source"), Cancellation::new())
            .await
            .unwrap();
        let surface = bridge
            .selection_surface(source.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
            .await
            .unwrap();
        let chars = surface.text.chars().collect::<Vec<_>>();
        let start = chars
            .windows("target".len())
            .position(|window| window.iter().collect::<String>() == "target")
            .unwrap();
        let end = start + "target".len();
        assert!(bridge.release_buffer(surface.raster.unwrap().handle));
        assert!(bridge.release_selection(surface.handle));
        let created = bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: source.handle,
                    unit: 0,
                    start,
                    end,
                    display_scale: 1.0,
                    color: HighlightColor::Yellow,
                    body: Some("shared note".into()),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let target = bridge
            .open_document(open(&target_path, "target"), Cancellation::new())
            .await
            .unwrap();
        let sources = bridge
            .list_annotation_association_sources(target.handle, None, 10, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(sources.sources.len(), 1);

        assert!(
            bridge
                .list_annotations(target.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty(),
            "changed bytes must not infer association"
        );
        assert_eq!(
            bridge
                .associate_annotation_version(
                    &sources.sources[0].version_id,
                    target.handle,
                    Cancellation::new(),
                )
                .await
                .unwrap(),
            AnnotationAssociationOutcome::Associated
        );
        let recovered = bridge
            .list_annotations(target.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].id, created.id);
        assert_eq!(recovered[0].resolution, AnnotationResolution::Recovered);
        assert_eq!(recovered[0].body.as_deref(), Some("shared note"));
        assert!(
            bridge
                .update_annotation(
                    target.handle,
                    &created.id,
                    HighlightColor::Green,
                    Some("updated through target".into()),
                )
                .await
                .unwrap()
        );
        assert!(
            bridge
                .delete_annotation(source.handle, &created.id)
                .await
                .unwrap()
        );
        assert!(
            bridge
                .list_annotations(target.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty(),
            "a shared tombstone must prevent resurrection on every version"
        );
    }

    #[tokio::test]
    async fn associated_collection_creation_preserves_its_existing_book_owner() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        let first_path = directory.path().join("first.pdf");
        let second_path = directory.path().join("second.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &first_path,
        )
        .unwrap();
        std::fs::write(
            &second_path,
            selectable_pdf_with_media_box(600, 800, "second"),
        )
        .unwrap();
        let imported = bridge
            .import_paths(
                vec![crate::path_key(&first_path), crate::path_key(&second_path)],
                true,
                Cancellation::new(),
            )
            .await
            .unwrap();
        let first_book = imported[0].book.as_ref().unwrap().book_id;
        let first_managed_path = imported[0].book.as_ref().unwrap().path_key.clone();
        let second_book = imported[1].book.as_ref().unwrap().book_id;
        let first = bridge
            .open_library_book(first_book, Cancellation::new())
            .await
            .unwrap();
        bridge
            .create_annotation(annotation_request(first.handle), Cancellation::new())
            .await
            .unwrap();
        let second = bridge
            .open_library_book(second_book, Cancellation::new())
            .await
            .unwrap();
        let source = bridge
            .list_annotation_association_sources(second.handle, None, 10, Cancellation::new())
            .await
            .unwrap()
            .sources
            .into_iter()
            .find(|source| source.local_path == crate::path_key::canonical_path_key(&first_path))
            .unwrap();
        bridge
            .associate_annotation_version(&source.version_id, second.handle, Cancellation::new())
            .await
            .unwrap();
        let second_untracked = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "second-untracked".into(),
                    path_key: crate::path_key(&second_path),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        bridge
            .create_annotation(
                annotation_request(second_untracked.handle),
                Cancellation::new(),
            )
            .await
            .unwrap();
        assert!(matches!(
            bridge
                .create_annotation(annotation_request(first.handle), Cancellation::new())
                .await,
            Err(BridgeError::InvalidRequest(_))
        ));
        let pool = bridge.state_store().await.unwrap().pool();
        let legacy_id = "00000000-0000-4000-8000-000000000001";
        sqlx::query(
            "INSERT INTO annotations (
               id, book_id, local_path, format, anchor_version,
               fingerprint_algorithm, fingerprint_version, fingerprint,
               original_quote, normalization_profile, normalized_exact,
               normalized_prefix, normalized_suffix, color, body, source_system,
               source_id, epub_spine_occurrence, epub_resource_path,
               epub_scalar_start, epub_scalar_end, pdf_page, pdf_char_start,
               pdf_char_end, created_at, modified_at, deleted_at,
               annotation_document_id)
             SELECT ?, ?, ?, format, anchor_version, fingerprint_algorithm,
                    fingerprint_version, fingerprint, original_quote,
                    normalization_profile, normalized_exact, normalized_prefix,
                    normalized_suffix, color, body, source_system, source_id,
                    epub_spine_occurrence, epub_resource_path, epub_scalar_start,
                    epub_scalar_end, pdf_page, pdf_char_start, pdf_char_end,
                    created_at, modified_at, deleted_at, NULL
             FROM annotations WHERE book_id = ? LIMIT 1",
        )
        .bind(legacy_id)
        .bind(first_book)
        .bind(&first_managed_path)
        .bind(second_book)
        .execute(pool)
        .await
        .unwrap();
        assert!(matches!(
            bridge.remove_library_book(first_book).await,
            Err(BridgeError::InvalidRequest(_))
        ));
        assert!(std::path::Path::new(&first_managed_path).exists());
        sqlx::query("DELETE FROM annotations WHERE id = ?")
            .bind(legacy_id)
            .execute(pool)
            .await
            .unwrap();
        assert!(bridge.remove_library_book(first_book).await.unwrap());
        assert!(!std::path::Path::new(&first_managed_path).exists());

        let reopened = bridge
            .open_library_book(second_book, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(
            bridge
                .list_annotations(reopened.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .len(),
            2
        );
        let other_owners: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM annotations WHERE book_id IS NULL OR book_id != ?",
        )
        .bind(second_book)
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(other_owners, 0);
    }

    #[tokio::test]
    async fn cancellation_before_association_acceptance_prevents_persistence() {
        let persistence = Arc::new(AnnotationPersistenceTestGate::new());
        let (_directory, mut bridge, target, source_id) =
            association_fixture(Arc::clone(&persistence)).await;
        let before_acceptance = Arc::new(TestPhaseGate::default());
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            before_acceptance: Some(Arc::clone(&before_acceptance)),
            persistence: Some(persistence),
            ..AnnotationTestHooks::default()
        }));
        let bridge = Arc::new(bridge);
        let cancellation = Cancellation::new();
        let operation_bridge = Arc::clone(&bridge);
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            operation_bridge
                .associate_annotation_version(&source_id, target, operation_cancellation)
                .await
        });

        before_acceptance.wait_until_entered().await;
        cancellation.cancel();
        before_acceptance.release();
        assert_eq!(operation.await.unwrap(), Err(BridgeError::Cancelled));
        assert!(
            bridge
                .list_annotations(target, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn accepted_association_finishes_after_cancellation() {
        let persistence = Arc::new(AnnotationPersistenceTestGate::new());
        let (_directory, bridge, target, source_id) =
            association_fixture(Arc::clone(&persistence)).await;
        let bridge = Arc::new(bridge);
        let cancellation = Cancellation::new();
        let operation_bridge = Arc::clone(&bridge);
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            operation_bridge
                .associate_annotation_version(&source_id, target, operation_cancellation)
                .await
        });

        persistence.wait_until_entered().await;
        cancellation.cancel();
        persistence.release();
        assert_eq!(
            operation.await.unwrap().unwrap(),
            AnnotationAssociationOutcome::Associated
        );
        assert_eq!(
            bridge
                .list_annotations(target, 1.0, Cancellation::new())
                .await
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn cancellation_interrupts_pending_annotation_store_initialization() {
        let directory = tempfile::tempdir().unwrap();
        let gate = Arc::new(TestPhaseGate::default());
        let admission = Arc::new(BridgeAdmission::new(
            MAX_BRIDGE_RETAINED_BUFFER_BYTES,
            MAX_BRIDGE_RENDER_WORKERS,
        ));
        let mut bridge = Bridge::with_admission_database(
            admission,
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            initialization: Some(Arc::clone(&gate)),
            ..AnnotationTestHooks::default()
        }));
        let bridge = Arc::new(bridge);
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let document_handle = document.handle;
        let operation_bridge = Arc::clone(&bridge);
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            operation_bridge
                .create_annotation(annotation_request(document_handle), operation_cancellation)
                .await
        });

        gate.wait_until_entered().await;
        assert_eq!(
            bridge.admission.request_slots.available_permits(),
            MAX_BRIDGE_REQUESTS - 1
        );
        cancellation.cancel();
        assert_eq!(operation.await.unwrap(), Err(BridgeError::Cancelled));
        assert_eq!(
            bridge.admission.request_slots.available_permits(),
            MAX_BRIDGE_REQUESTS
        );
        gate.release();
        assert!(
            bridge
                .list_annotations(document.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn cancellation_after_extraction_before_acceptance_cannot_persist_annotation() {
        let directory = tempfile::tempdir().unwrap();
        let gate = Arc::new(TestPhaseGate::default());
        let admission = Arc::new(BridgeAdmission::new(
            MAX_BRIDGE_RETAINED_BUFFER_BYTES,
            MAX_BRIDGE_RENDER_WORKERS,
        ));
        let mut bridge = Bridge::with_admission_database(
            admission,
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        bridge.annotation_store().await.unwrap();
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            before_acceptance: Some(Arc::clone(&gate)),
            ..AnnotationTestHooks::default()
        }));
        let bridge = Arc::new(bridge);
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let document_handle = document.handle;
        let operation_bridge = Arc::clone(&bridge);
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            operation_bridge
                .create_annotation(annotation_request(document_handle), operation_cancellation)
                .await
        });

        gate.wait_until_entered().await;
        assert_eq!(
            bridge.admission.request_slots.available_permits(),
            MAX_BRIDGE_REQUESTS - 1
        );
        assert_eq!(
            bridge.admission.probe_bytes.available_permits(),
            MAX_BRIDGE_PROBE_BYTES
        );
        cancellation.cancel();
        gate.release();
        assert_eq!(operation.await.unwrap(), Err(BridgeError::Cancelled));
        assert_eq!(
            bridge.admission.request_slots.available_permits(),
            MAX_BRIDGE_REQUESTS
        );
        assert_eq!(
            bridge.admission.probe_bytes.available_permits(),
            MAX_BRIDGE_PROBE_BYTES
        );
        assert!(
            bridge
                .list_annotations(document.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn accepted_annotation_finishes_after_cancellation() {
        let directory = tempfile::tempdir().unwrap();
        let gate = Arc::new(AnnotationPersistenceTestGate::new());
        let mut bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            persistence: Some(Arc::clone(&gate)),
            ..AnnotationTestHooks::default()
        }));
        bridge.annotation_store().await.unwrap();
        let bridge = Arc::new(bridge);
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let document_handle = document.handle;
        let operation_bridge = Arc::clone(&bridge);
        let operation_cancellation = cancellation.clone();
        let operation = tokio::spawn(async move {
            operation_bridge
                .create_annotation(annotation_request(document_handle), operation_cancellation)
                .await
        });

        gate.wait_until_entered().await;
        cancellation.cancel();
        gate.release();
        operation.await.unwrap().unwrap();
        assert_eq!(
            bridge
                .list_annotations(document.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn annotation_preparation_releases_probe_bytes_before_persistence() {
        let directory = tempfile::tempdir().unwrap();
        let gate = Arc::new(AnnotationPersistenceTestGate::new());
        let document = OpenDocument::open(&DeviceFileLocator::from_path(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        )))
        .unwrap();
        let probe_bytes = selection_transient_byte_len(&document, 0, 1.0, false).unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.probe_bytes = Arc::new(Semaphore::new(probe_bytes));
        let admission = Arc::new(admission);
        let mut bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("annotations.sqlite"))),
        );
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            persistence: Some(Arc::clone(&gate)),
            ..AnnotationTestHooks::default()
        }));
        bridge.annotation_store().await.unwrap();
        let bridge = Arc::new(bridge);
        let summary = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let create_bridge = Arc::clone(&bridge);
        let create = tokio::spawn(async move {
            create_bridge
                .create_annotation(annotation_request(summary.handle), Cancellation::new())
                .await
        });
        gate.wait_until_entered().await;
        assert_eq!(admission.probe_bytes.available_permits(), probe_bytes);

        let selection_bridge = Arc::clone(&bridge);
        let selection = tokio::spawn(async move {
            selection_bridge
                .selection_surface(summary.handle, 0, 1.0, 680.0, 18.0, Cancellation::new())
                .await
        });
        tokio::task::yield_now().await;
        assert_eq!(admission.render_slots.available_permits(), 0);
        gate.release();

        let surface = tokio::time::timeout(std::time::Duration::from_secs(5), selection)
            .await
            .expect("selection must not deadlock")
            .unwrap()
            .unwrap();
        assert!(bridge.release_selection(surface.handle));
        tokio::time::timeout(std::time::Duration::from_secs(5), create)
            .await
            .expect("accepted create must finish")
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn cancellation_interrupts_annotation_database_listing() {
        let directory = tempfile::tempdir().unwrap();
        let gate = Arc::new(AnnotationPersistenceTestGate::new());
        let mut bridge = Bridge::with_database_path(directory.path().join("annotations.sqlite"));
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            list: Some(Arc::clone(&gate)),
            ..AnnotationTestHooks::default()
        }));
        bridge.annotation_store().await.unwrap();
        let bridge = Arc::new(bridge);
        let summary = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let list_bridge = Arc::clone(&bridge);
        let list_cancellation = cancellation.clone();
        let list = tokio::spawn(async move {
            list_bridge
                .list_annotations(summary.handle, 1.0, list_cancellation)
                .await
        });

        gate.wait_until_entered().await;
        cancellation.cancel();
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(1), list)
                .await
                .expect("cancelled list must not wait for the database gate")
                .unwrap(),
            Err(BridgeError::Cancelled)
        );
    }

    #[tokio::test]
    async fn annotation_admission_spans_blocked_persistence_success_and_failure() {
        for fail in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let gate = Arc::new(AnnotationPersistenceTestGate::new());
            let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
            admission.request_slots = Arc::new(Semaphore::new(1));
            let admission = Arc::new(admission);
            let mut bridge = Bridge::with_admission_database(
                Arc::clone(&admission),
                Some(Arc::new(directory.path().join("annotations.sqlite"))),
            );
            bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
                persistence: Some(Arc::clone(&gate)),
                ..AnnotationTestHooks::default()
            }));
            let store = bridge.annotation_store().await.unwrap();
            if fail {
                store
                    .execute_test_sql(
                        "CREATE TRIGGER reject_annotation BEFORE INSERT ON annotations \
                         BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END",
                    )
                    .await
                    .unwrap();
            }
            let bridge = Arc::new(bridge);
            let document = bridge
                .open_document(pdf_request(), Cancellation::new())
                .await
                .unwrap();
            let operation_bridge = Arc::clone(&bridge);
            let operation = tokio::spawn(async move {
                operation_bridge
                    .create_annotation(annotation_request(document.handle), Cancellation::new())
                    .await
            });

            gate.wait_until_entered().await;
            assert_eq!(admission.request_slots.available_permits(), 0);
            assert_eq!(
                admission.probe_bytes.available_permits(),
                MAX_BRIDGE_PROBE_BYTES
            );
            gate.release();
            let result = operation.await.unwrap();
            if fail {
                assert!(matches!(result, Err(BridgeError::Storage(_))));
            } else {
                result.unwrap();
            }
            assert_eq!(admission.request_slots.available_permits(), 1);
            assert_eq!(
                admission.probe_bytes.available_permits(),
                MAX_BRIDGE_PROBE_BYTES
            );
        }
    }

    #[test]
    fn epub_selection_peak_includes_line_assembled_and_geometry_storage() {
        let document = OpenDocument::open(&DeviceFileLocator::from_path(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.epub"
        )))
        .unwrap();
        let peak = selection_transient_byte_len(&document, 0, 1.0, true).unwrap();
        let two_rasters = EPUB_TEXT_MAX_PIXELS * 4 * 2;

        assert!(peak > two_rasters);
        assert!(selection_transient_byte_len(&document, 0, 1.0, false).unwrap() < peak);
    }

    #[test]
    fn empty_epub_chapter_has_a_decodable_blank_surface() {
        let document = OpenDocument::Epub(Arc::new(
            crate::epub::EpubDoc::from_bytes(empty_epub()).unwrap(),
        ));

        let extraction =
            selection_surface(&document, 0, 2.0, 680.0, 18.0, true, &|| false).unwrap();

        assert_eq!(extraction.raster_width, 1);
        assert!(extraction.raster_height > 0);
        assert_eq!(
            extraction.raster.as_ref().unwrap().len(),
            extraction.raster_height as usize * 4
        );
        assert_eq!(extraction.surface.width, 0.5);
        assert!(extraction.surface.height > 0.0);
        assert!(extraction.surface.text.is_empty());
        assert!(extraction.surface.endpoints.is_empty());
        assert!(
            extraction
                .surface
                .visual_lines
                .iter()
                .all(|line| line.carets.is_empty())
        );
    }

    #[test]
    fn epub_blank_paragraphs_export_real_newline_carets() {
        let document = OpenDocument::Epub(Arc::new(
            crate::epub::EpubDoc::from_bytes(empty_epub()).unwrap(),
        ));
        let OpenDocument::Epub(document) = document else {
            unreachable!()
        };
        let text = "\nAlpha\n\nOmega";
        let layout = document
            .fonts()
            .measure_text(&EpubTextRequest {
                runs: vec![EpubTextRun {
                    text: text.into(),
                    family: None,
                    monospace: false,
                    font_size: 18.0,
                    bold: false,
                    italic: false,
                    foreground: [0, 0, 0, 255],
                    link: None,
                }],
                max_width: 680.0,
                line_height: 27.0,
                scale: 1.0,
                align: EpubTextAlign::Left,
                direction: EpubTextDirection::LeftToRight,
                highlights: Vec::new(),
            })
            .unwrap();
        let visual_lines = epub_visual_lines(text, &layout, 1.0);
        let newline_offsets = text
            .chars()
            .enumerate()
            .filter_map(|(offset, character)| (character == '\n').then_some(offset))
            .collect::<Vec<_>>();
        let blank_lines = visual_lines
            .iter()
            .filter(|line| line.carets.len() == 1)
            .collect::<Vec<_>>();

        assert!(
            blank_lines.len() >= 2,
            "leading and interior blank lines survive: text={text:?}, lines={:?}",
            visual_lines
        );
        assert!(blank_lines.iter().all(|line| {
            newline_offsets.contains(&line.carets[0].offset)
                && line.carets[0].top < line.carets[0].bottom
                && line.carets[0].x.is_finite()
        }));
        assert!(visual_lines.iter().all(|line| !line.carets.is_empty()));

        let terminal_text = "Alpha\n";
        let terminal_layout = document
            .fonts()
            .measure_text(&EpubTextRequest {
                runs: vec![EpubTextRun {
                    text: terminal_text.into(),
                    family: None,
                    monospace: false,
                    font_size: 18.0,
                    bold: false,
                    italic: false,
                    foreground: [0, 0, 0, 255],
                    link: None,
                }],
                max_width: 680.0,
                line_height: 27.0,
                scale: 1.0,
                align: EpubTextAlign::Left,
                direction: EpubTextDirection::LeftToRight,
                highlights: Vec::new(),
            })
            .unwrap();
        let terminal_lines = epub_visual_lines(terminal_text, &terminal_layout, 1.0);
        assert_eq!(
            terminal_lines.last().unwrap().carets[0].offset,
            terminal_text.chars().count()
        );
        assert!(terminal_lines.iter().all(|line| !line.carets.is_empty()));
    }

    #[test]
    fn epub_chapter_text_is_bounded_before_ownership_clone() {
        let oversized = "x".repeat(EPUB_TEXT_MAX_SCALARS + 1);
        assert_eq!(
            bounded_epub_selection_text(&oversized, &|| false),
            Err(BridgeError::BufferLimit)
        );
        assert_eq!(
            bounded_epub_selection_text("chapter", &|| true),
            Err(BridgeError::Cancelled)
        );
    }

    #[test]
    fn epub_retention_charge_includes_bounded_expansion() {
        let encoded = 1024;

        let retained = retained_document_byte_len(BookFormat::Epub, encoded).unwrap();

        assert!(retained > encoded);
        assert!(
            retained
                >= usize::try_from(EpubLimits::default().max_total_uncompressed_bytes).unwrap()
        );
        assert!(retained <= MAX_BRIDGE_RETAINED_DOCUMENT_BYTES);
    }

    #[tokio::test]
    async fn parsed_epub_charge_allows_two_retained_documents() {
        let bridge = Bridge::new();
        let first = bridge
            .open_document(epub_request(), Cancellation::new())
            .await
            .unwrap();

        let second = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            bridge.open_document(epub_request(), Cancellation::new()),
        )
        .await
        .expect("a small second EPUB must not wait for the first handle")
        .unwrap();

        assert!(bridge.release_document(first.handle));
        assert!(bridge.release_document(second.handle));
    }

    #[test]
    fn cbz_retention_charge_includes_copied_directory_names_and_indexes() {
        let encoded = 1024;

        let retained = retained_document_byte_len(BookFormat::Cbz, encoded).unwrap();

        assert!(retained > encoded * 2);
    }

    #[tokio::test]
    async fn queued_document_users_keep_retention_admission() {
        let admission = Arc::new(BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1));
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let summary = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let retained = bridge.document(summary.handle).unwrap();
        let admitted = admission.document_bytes.available_permits();

        assert!(bridge.release_document(summary.handle));
        assert_eq!(admission.document_bytes.available_permits(), admitted);
        drop(retained);
        assert_eq!(
            admission.document_bytes.available_permits(),
            MAX_BRIDGE_RETAINED_DOCUMENT_BYTES
        );
    }

    #[tokio::test]
    async fn byte_admission_precedes_open_worker_and_parsing() {
        let mut configured = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        configured.open_slots = Arc::new(Semaphore::new(2));
        configured.document_bytes = Arc::new(Semaphore::new(0));
        let admission = Arc::new(configured);
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let cancellation = Cancellation::new();
        let mut opens = Vec::new();
        for _ in 0..3 {
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            opens.push(tokio::spawn(async move {
                bridge.open_document(epub_request(), cancellation).await
            }));
        }

        tokio::task::yield_now().await;
        assert_eq!(admission.open_slots.available_permits(), 2);

        cancellation.cancel();
        for open in opens {
            assert_eq!(open.await.unwrap(), Err(BridgeError::Cancelled));
        }
        assert_eq!(admission.open_slots.available_permits(), 2);
    }

    #[tokio::test]
    async fn library_byte_admission_precedes_verified_open_worker() {
        let directory = tempfile::tempdir().unwrap();
        let mut configured = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        configured.open_slots = Arc::new(Semaphore::new(1));
        configured.document_bytes = Arc::new(Semaphore::new(0));
        let admission = Arc::new(configured);
        let bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let cancellation = Cancellation::new();
        let open = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while admission.document_slots.available_permits() == MAX_BRIDGE_DOCUMENTS {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("library open must reach document byte admission");
        assert_eq!(admission.open_slots.available_permits(), 1);

        cancellation.cancel();
        assert_eq!(open.await.unwrap(), Err(BridgeError::Cancelled));
        assert!(bridge.registry.lock().unwrap().documents.is_empty());
        assert_eq!(admission.open_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn verified_open_cancels_while_waiting_to_recheck_library_identity() {
        let directory = tempfile::tempdir().unwrap();
        let mut configured = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        configured.open_slots = Arc::new(Semaphore::new(1));
        let admission = Arc::new(configured);
        let bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let held_open_slot = Arc::clone(&admission.open_slots)
            .acquire_owned()
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let opening = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while admission.document_bytes.available_permits() == MAX_BRIDGE_RETAINED_DOCUMENT_BYTES
            {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("library open must reach open-worker admission");
        let mut connections = Vec::new();
        for _ in 0..pool.options().get_max_connections() {
            connections.push(pool.acquire().await.unwrap());
        }
        drop(held_open_slot);
        tokio::task::yield_now().await;

        cancellation.cancel();
        let result = tokio::time::timeout(std::time::Duration::from_millis(500), opening)
            .await
            .expect("verified metadata recheck cancellation must be prompt")
            .unwrap();
        assert_eq!(result, Err(BridgeError::Cancelled));
        assert_eq!(admission.open_slots.available_permits(), 1);
        assert_eq!(
            admission.document_slots.available_permits(),
            MAX_BRIDGE_DOCUMENTS
        );
        drop(connections);
    }

    #[tokio::test]
    async fn dropped_library_open_retains_admission_until_worker_exits() {
        let directory = tempfile::tempdir().unwrap();
        let admission = Arc::new(BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1));
        let open_slots = admission.open_slots.available_permits();
        let mut bridge = Bridge::with_admission_database(
            Arc::clone(&admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let worker_barrier = Arc::new(std::sync::Barrier::new(2));
        bridge.library_open_worker_barrier = Some(Arc::clone(&worker_barrier));
        let bridge = Arc::new(bridge);
        let (drop_tx, drop_rx) = tokio::sync::oneshot::channel();
        let (dropped_tx, dropped_rx) = std::sync::mpsc::sync_channel(1);
        let operation_bridge = Arc::clone(&bridge);
        let operation = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    tokio::select! {
                        _ = operation_bridge.open_library_book(book_id, Cancellation::new()) => {
                            panic!("library open must remain blocked")
                        }
                        _ = drop_rx => {}
                    }
                    dropped_tx.send(()).unwrap();
                });
        });

        worker_barrier.wait();
        drop_tx.send(()).unwrap();
        dropped_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .expect("the outer library open future must be dropped");
        assert_eq!(admission.open_slots.available_permits(), open_slots - 1);
        assert_eq!(
            admission.document_slots.available_permits(),
            MAX_BRIDGE_DOCUMENTS - 1
        );
        worker_barrier.wait();
        operation.join().unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while admission.open_slots.available_permits() != open_slots {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("worker guards must release after the blocking open exits");
        assert_eq!(
            admission.document_slots.available_permits(),
            MAX_BRIDGE_DOCUMENTS
        );
    }

    #[tokio::test]
    async fn cancellation_during_verified_library_open_keeps_cancelled_category() {
        let directory = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let worker_barrier = Arc::new(std::sync::Barrier::new(2));
        bridge.library_open_worker_barrier = Some(Arc::clone(&worker_barrier));
        let cancellation = Cancellation::new();
        let open = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });

        let entered = Arc::clone(&worker_barrier);
        tokio::task::spawn_blocking(move || entered.wait())
            .await
            .unwrap();
        cancellation.cancel();
        tokio::task::spawn_blocking(move || worker_barrier.wait())
            .await
            .unwrap();

        assert_eq!(open.await.unwrap(), Err(BridgeError::Cancelled));
    }

    #[tokio::test]
    async fn cancellation_prevents_opening_and_allocating_handles() {
        let bridge = Bridge::new();
        let cancellation = Cancellation::new();
        cancellation.cancel();

        let error = bridge
            .open_document(cbz_request(), cancellation)
            .await
            .unwrap_err();

        assert_eq!(error, BridgeError::Cancelled);
        assert!(bridge.registry.lock().unwrap().documents.is_empty());
    }

    #[tokio::test]
    async fn missing_documents_have_a_stable_not_found_category() {
        let bridge = Bridge::new();
        let mut request = cbz_request();
        request.path_key = "/definitely/missing/shosai-book.cbz".to_owned();

        let error = bridge
            .open_document(request, Cancellation::new())
            .await
            .unwrap_err();

        assert_eq!(error, BridgeError::DocumentNotFound);
        assert_eq!(error.kind(), BridgeErrorKind::NotFound);
    }

    #[tokio::test]
    async fn malformed_reserved_path_keys_are_invalid_requests() {
        let bridge = Bridge::new();
        let mut request = cbz_request();
        request.path_key = "\0unix-path-v1:not-hex".to_owned();

        let error = bridge
            .open_document(request, Cancellation::new())
            .await
            .unwrap_err();

        assert_eq!(error.kind(), BridgeErrorKind::InvalidRequest);
    }

    #[tokio::test]
    async fn oversized_request_strings_are_rejected_before_document_admission() {
        let bridge = Bridge::new();
        let mut local_id = cbz_request();
        local_id.local_id = "x".repeat(MAX_BRIDGE_LOCAL_ID_BYTES + 1);
        let mut path_key = cbz_request();
        path_key.path_key = "x".repeat(MAX_BRIDGE_PATH_KEY_BYTES + 1);

        for request in [local_id, path_key] {
            assert!(matches!(
                bridge.open_document(request, Cancellation::new()).await,
                Err(BridgeError::InvalidRequest(_))
            ));
        }
        assert!(bridge.registry.lock().unwrap().documents.is_empty());
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    #[tokio::test]
    async fn open_requests_decode_lossless_native_path_keys() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join(OsStr::from_bytes(b"book-\x80.cbz"));
        std::fs::copy(
            concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/sample.cbz"),
            &path,
        )
        .unwrap();
        let request = OpenRequest {
            book_id: None,
            local_id: "native-path".to_owned(),
            path_key: crate::path_key::path_key(&path),
            format_hint: Some(BookFormat::Cbz),
        };

        let summary = Bridge::new()
            .open_document(request, Cancellation::new())
            .await
            .unwrap();

        assert_eq!(summary.format, BookFormat::Cbz);
    }

    #[test]
    fn cancellation_waits_for_the_publication_barrier() {
        let cancellation = Cancellation::new();
        let publication = cancellation.0.publication.lock().unwrap();
        let cancelling = cancellation.clone();
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            cancelling.cancel();
            finished_tx.send(()).unwrap();
        });

        assert!(
            finished_rx
                .recv_timeout(std::time::Duration::from_millis(20))
                .is_err()
        );
        drop(publication);
        finished_rx
            .recv_timeout(std::time::Duration::from_secs(1))
            .unwrap();
        thread.join().unwrap();
        assert!(cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn owned_buffers_and_documents_are_released_deterministically() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        assert_eq!(document.logical_unit, LogicalUnit::Page);
        let rendered = bridge
            .render_page(
                RenderRequest {
                    document: document.handle,
                    page: 0,
                    scale: 1.0,
                },
                Cancellation::new(),
            )
            .await
            .unwrap();

        let bytes = bridge.take_buffer(rendered.handle).unwrap();
        assert_eq!(bytes.len(), rendered.byte_len);
        assert_eq!(
            bridge.take_buffer(rendered.handle),
            Err(BridgeError::InvalidBufferHandle)
        );
        assert!(bridge.release_buffer(rendered.handle));
        assert!(bridge.release_document(document.handle));
        assert!(!bridge.release_document(document.handle));
    }

    #[tokio::test]
    async fn retained_and_in_flight_buffers_share_one_budget() {
        let bridge = Bridge::with_limits(8, 1);
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let permit = Arc::clone(&bridge.admission.buffer_bytes)
            .acquire_many_owned(8)
            .await
            .unwrap();
        let slot = Arc::clone(&bridge.admission.buffer_slots)
            .try_acquire_owned()
            .unwrap();
        let buffer = bridge
            .store_buffer(
                document.handle,
                RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: vec![0; 4].into(),
                },
                permit,
                slot,
            )
            .unwrap();
        assert_eq!(bridge.admission.buffer_bytes.available_permits(), 0);
        let retained_pointer = bridge.registry.lock().unwrap().buffers[&buffer.handle]
            .pixels
            .as_ptr();
        let transferred = bridge.take_buffer(buffer.handle).unwrap();
        assert_ne!(transferred.as_ptr(), retained_pointer);
        assert_eq!(bridge.admission.buffer_bytes.available_permits(), 0);
        assert!(bridge.release_buffer(buffer.handle));
        assert_eq!(bridge.admission.buffer_bytes.available_permits(), 8);
    }

    #[tokio::test]
    async fn annotation_resolution_workspace_caps_peak_concurrency() {
        const INDEX_AND_TEXT_BYTES_PER_INPUT_BYTE: usize = 64;
        const NORMALIZATION_AND_MATCHER_OVERHEAD: usize = 16 * 1024 * 1024;
        assert!(
            MAX_ANNOTATION_PDF_TEXT_BYTES * INDEX_AND_TEXT_BYTES_PER_INPUT_BYTE
                + NORMALIZATION_AND_MATCHER_OVERHEAD
                <= ANNOTATION_RESOLUTION_WORKSPACE_BYTES as usize
        );
        assert!(ANNOTATION_RESOLUTION_WORKSPACE_BYTES as usize <= MAX_BRIDGE_BUFFER_BYTES);

        let admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 3);
        let cancellation = Cancellation::new();
        let first = acquire_permits(
            Arc::clone(&admission.buffer_bytes),
            ANNOTATION_RESOLUTION_WORKSPACE_BYTES,
            &cancellation,
        )
        .await
        .unwrap();
        let second = acquire_permits(
            Arc::clone(&admission.buffer_bytes),
            ANNOTATION_RESOLUTION_WORKSPACE_BYTES,
            &cancellation,
        )
        .await
        .unwrap();
        let third = acquire_permits(
            Arc::clone(&admission.buffer_bytes),
            ANNOTATION_RESOLUTION_WORKSPACE_BYTES,
            &cancellation,
        );
        tokio::pin!(third);
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(10), &mut third)
                .await
                .is_err()
        );
        drop(first);
        let _third = tokio::time::timeout(std::time::Duration::from_secs(1), third)
            .await
            .expect("a third workspace must be admitted after one completes")
            .unwrap();
        drop(second);
    }

    #[tokio::test]
    async fn released_document_cannot_publish_an_in_flight_result() {
        let bridge = Bridge::with_limits(8, 1);
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();
        let permit = Arc::clone(&bridge.admission.buffer_bytes)
            .acquire_many_owned(8)
            .await
            .unwrap();
        let slot = Arc::clone(&bridge.admission.buffer_slots)
            .try_acquire_owned()
            .unwrap();
        assert!(bridge.release_document(document.handle));

        assert_eq!(
            bridge.store_buffer(
                document.handle,
                RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: vec![0; 4].into(),
                },
                permit,
                slot,
            ),
            Err(BridgeError::InvalidDocumentHandle)
        );
        assert!(bridge.registry.lock().unwrap().buffers.is_empty());
    }

    #[tokio::test]
    async fn cancellation_interrupts_waiting_for_buffer_budget() {
        let bridge = Bridge::with_limits(4, 1);
        let _permit = Arc::clone(&bridge.admission.buffer_bytes)
            .acquire_many_owned(4)
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let waiting = acquire_permits(Arc::clone(&bridge.admission.buffer_bytes), 4, &cancellation);
        tokio::pin!(waiting);
        cancellation.cancel();

        assert_eq!(waiting.await.unwrap_err(), BridgeError::Cancelled);
    }

    #[tokio::test]
    async fn cancellation_cannot_be_lost_while_waiters_register() {
        for _ in 0..1_000 {
            let cancellation = Cancellation::new();
            let waiting = cancellation.cancelled();
            tokio::pin!(waiting);
            cancellation.cancel();
            tokio::time::timeout(std::time::Duration::from_millis(100), waiting)
                .await
                .expect("a cancellation notification must not be lost");
        }
    }

    #[tokio::test]
    async fn handles_cannot_be_used_with_another_bridge_registry() {
        let first = Bridge::new();
        let second = Bridge::new();
        let document = first
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();

        assert_eq!(
            second
                .render_page(
                    RenderRequest {
                        document: document.handle,
                        page: 0,
                        scale: 1.0,
                    },
                    Cancellation::new(),
                )
                .await,
            Err(BridgeError::InvalidDocumentHandle)
        );
    }

    #[tokio::test]
    async fn invalid_pages_and_oversized_scales_fail_before_rendering() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();

        assert!(matches!(
            bridge
                .render_page(
                    RenderRequest {
                        document: document.handle,
                        page: usize::MAX,
                        scale: 1.0,
                    },
                    Cancellation::new(),
                )
                .await,
            Err(BridgeError::InvalidPage { .. })
        ));
        assert_eq!(
            bridge
                .render_page(
                    RenderRequest {
                        document: document.handle,
                        page: 0,
                        scale: 100_000.0,
                    },
                    Cancellation::new(),
                )
                .await,
            Err(BridgeError::BufferLimit)
        );
    }

    #[tokio::test]
    async fn product_bridge_library_state_settings_and_removal_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;

        let page = bridge
            .library_page(Some("sample".into()), Some(BookFormat::Pdf), 10, 0)
            .await
            .unwrap();
        assert_eq!(page.books[0].book_id, book_id);
        bridge
            .save_reading_state(
                book_id,
                ReadingStateDto {
                    unit: 1,
                    offset: None,
                    zoom: 1.5,
                },
            )
            .await
            .unwrap();
        assert_eq!(
            bridge
                .load_reading_state(book_id)
                .await
                .unwrap()
                .unwrap()
                .unit,
            1
        );
        let settings = ReaderSettingsDto {
            continuous: true,
            theme: "sepia".into(),
            epub_font_size: 18.0,
            epub_line_spacing: 1.8,
            pdf_zoom: -1.0,
        };
        bridge.save_reader_settings(settings.clone()).await.unwrap();
        assert_eq!(bridge.load_reader_settings().await.unwrap(), settings);
        assert!(bridge.remove_library_book(book_id).await.unwrap());
        assert!(!bridge.remove_library_book(book_id).await.unwrap());
        assert!(
            source.exists(),
            "referenced imports must not delete user files"
        );
    }

    #[tokio::test]
    async fn library_cover_is_loaded_separately_from_metadata_pages() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.cbz"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;

        let page = bridge.library_page(None, None, 10, 0).await.unwrap();
        assert_eq!(page.books.len(), 1);
        assert_eq!(page.books[0].cover, None);
        assert!(
            bridge
                .library_cover(book_id, Cancellation::new())
                .await
                .unwrap()
                .is_some()
        );
    }

    #[tokio::test]
    async fn directory_import_recursively_returns_every_supported_book() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(directory.path().join("selected/nested")).unwrap();
        // Canonicalize before joining so expectations match the scanned paths on
        // platforms where the temp root is a symlink (macOS) or uses an extended
        // prefix (Windows).
        let source = directory.path().join("selected").canonicalize().unwrap();
        let nested = source.join("nested");
        std::fs::copy(
            concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/sample.pdf"),
            source.join("one.pdf"),
        )
        .unwrap();
        std::fs::copy(
            concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/sample.epub"),
            nested.join("two.epub"),
        )
        .unwrap();
        std::fs::write(source.join("ignored.txt"), "not a book").unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));

        let report = bridge
            .import_directory(crate::path_key(&source), false, Cancellation::new())
            .await
            .unwrap();

        assert_eq!(report.imported, 2);
        assert_eq!(report.failed, 0);
        assert!(!report.cancelled);
        assert_eq!(report.items.len(), 2);
        assert!(report.items.iter().all(|item| item.book.is_some()));
        assert!(
            report
                .items
                .iter()
                .any(|item| item.path_key == crate::path_key(&source.join("one.pdf")))
        );
        assert!(
            report
                .items
                .iter()
                .any(|item| item.path_key == crate::path_key(&nested.join("two.epub")))
        );
    }

    #[tokio::test]
    async fn directory_import_bounds_retained_item_details() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("selected");
        std::fs::create_dir(&source).unwrap();
        let fixture = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/sample.pdf");
        for index in 0..257 {
            std::fs::copy(fixture, source.join(format!("book-{index}.pdf"))).unwrap();
        }
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));

        let report = bridge
            .import_directory(crate::path_key(&source), false, Cancellation::new())
            .await
            .unwrap();

        assert_eq!(report.imported, 257);
        assert_eq!(report.failed, 0);
        assert!(!report.cancelled);
        assert_eq!(report.items.len(), 256);
    }

    #[tokio::test]
    async fn library_open_rejects_bytes_changed_after_import() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &source,
        )
        .unwrap();
        let imported = bridge
            .import_paths(vec![crate::path_key(&source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        std::fs::write(&source, selectable_pdf_with_media_box(800, 600, "changed")).unwrap();

        let untracked = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "changed-valid-pdf".into(),
                    path_key: crate::path_key(&source),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .expect("replacement bytes must still be a valid PDF");
        assert!(bridge.release_document(untracked.handle));

        assert_eq!(
            bridge.open_library_book(book_id, Cancellation::new()).await,
            Err(BridgeError::DocumentInaccessible)
        );
        assert!(
            bridge
                .registry
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .documents
                .is_empty(),
            "unverified bytes must never receive the stable library identity"
        );
    }

    #[tokio::test]
    async fn search_participates_in_request_admission() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let request_slots = Arc::clone(&bridge.admission.request_slots);
        let available = u32::try_from(request_slots.available_permits()).unwrap();
        let _held = request_slots.acquire_many_owned(available).await.unwrap();

        assert_eq!(
            bridge
                .search_document(document.handle, "test".into(), Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        );
    }

    #[tokio::test]
    async fn search_acquires_worker_before_waiting_for_workspace() {
        let mut configured = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        configured.render_slots = Arc::new(Semaphore::new(1));
        configured.buffer_bytes = Arc::new(Semaphore::new(0));
        let admission = Arc::new(configured);
        let bridge = Bridge::with_admission(Arc::clone(&admission));
        let document = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let cancellation = Cancellation::new();
        let search = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move {
                bridge
                    .search_document(document.handle, "test".into(), cancellation)
                    .await
            }
        });

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while admission.render_slots.available_permits() != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("search must hold the worker while waiting for workspace");
        cancellation.cancel();

        assert_eq!(search.await.unwrap(), Err(BridgeError::Cancelled));
        assert_eq!(admission.render_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn library_annotations_are_owned_by_stable_book_identity() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let document = bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();

        let created = bridge
            .create_annotation(annotation_request(document.handle), Cancellation::new())
            .await
            .unwrap();

        assert!(
            bridge
                .update_annotation(
                    document.handle,
                    &created.id,
                    HighlightColor::Blue,
                    Some("edited".into()),
                )
                .await
                .unwrap()
        );
        let listed = bridge
            .list_annotations(document.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed[0].body.as_deref(), Some("edited"));

        let stored = bridge
            .annotation_store()
            .await
            .unwrap()
            .list_for_book_async(book_id)
            .await
            .unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].book_id, Some(book_id));
        assert!(
            bridge
                .delete_annotation(document.handle, &created.id)
                .await
                .unwrap()
        );
        assert!(
            bridge
                .list_annotations(document.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn annotations_created_before_import_remain_owned_after_library_open() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let local = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let annotation = bridge
            .create_annotation(annotation_request(local.handle), Cancellation::new())
            .await
            .unwrap();
        assert!(bridge.release_document(local.handle));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], true, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let library = bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();

        let listed = bridge
            .list_annotations(library.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, annotation.id);
        assert!(
            bridge
                .delete_annotation(library.handle, &annotation.id)
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn library_open_backfills_legacy_book_annotation_documents() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let document = bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();
        let created = bridge
            .create_annotation(annotation_request(document.handle), Cancellation::new())
            .await
            .unwrap();
        assert!(bridge.release_document(document.handle));
        let pool = bridge.state_store().await.unwrap().pool().clone();
        sqlx::query("UPDATE annotations SET annotation_document_id = NULL WHERE id = ?")
            .bind(&created.id)
            .execute(&pool)
            .await
            .unwrap();

        let reopened = bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();
        let listed = bridge
            .list_annotations(reopened.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, created.id);
        let document_id: Option<String> =
            sqlx::query_scalar("SELECT annotation_document_id FROM annotations WHERE id = ?")
                .bind(&created.id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(document_id.is_some());
    }

    #[tokio::test]
    async fn library_open_backfill_owns_the_write_transaction_before_reading() {
        let directory = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let mut writer = pool.acquire().await.unwrap();
        sqlx::query("PRAGMA busy_timeout = 0")
            .execute(&mut *writer)
            .await
            .unwrap();
        let gate = Arc::new(AnnotationPersistenceTestGate::new());
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            persistence: Some(Arc::clone(&gate)),
            ..AnnotationTestHooks::default()
        }));
        let opening = tokio::spawn({
            let bridge = bridge.clone();
            async move { bridge.open_library_book(book_id, Cancellation::new()).await }
        });
        gate.wait_until_entered().await;
        let competing = sqlx::query("BEGIN IMMEDIATE").execute(&mut *writer).await;
        if competing.is_ok() {
            sqlx::query("ROLLBACK").execute(&mut *writer).await.unwrap();
        }
        gate.release();

        let opening = opening.await.unwrap();
        assert!(matches!(competing, Err(sqlx::Error::Database(_))));
        assert!(opening.is_ok());
        sqlx::query("BEGIN IMMEDIATE")
            .execute(&mut *writer)
            .await
            .unwrap();
        sqlx::query("ROLLBACK").execute(&mut *writer).await.unwrap();
    }

    #[tokio::test]
    async fn relative_dot_path_annotations_survive_import() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let request_path = std::path::Path::new("tests/fixtures/../fixtures/sample.pdf");
        let local = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "relative-dot".into(),
                    path_key: crate::path_key(request_path),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let annotation = bridge
            .create_annotation(annotation_request(local.handle), Cancellation::new())
            .await
            .unwrap();
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let raw_path = crate::path_key(request_path);
        sqlx::query("UPDATE annotations SET local_path = ? WHERE id = ?")
            .bind(&raw_path)
            .bind(&annotation.id)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE annotation_document_versions SET local_path = ?
             WHERE document_id = (
               SELECT annotation_document_id FROM annotations WHERE id = ?
             )",
        )
        .bind(&raw_path)
        .bind(&annotation.id)
        .execute(&pool)
        .await
        .unwrap();
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let library = bridge
            .open_library_book(
                imported[0].book.as_ref().unwrap().book_id,
                Cancellation::new(),
            )
            .await
            .unwrap();

        let listed = bridge
            .list_annotations(library.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, annotation.id);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlink_path_annotations_survive_import() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &source,
        )
        .unwrap();
        let alias = directory.path().join("alias.pdf");
        symlink(&source, &alias).unwrap();
        let local = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "symlink".into(),
                    path_key: crate::path_key(&alias),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let annotation = bridge
            .create_annotation(annotation_request(local.handle), Cancellation::new())
            .await
            .unwrap();
        let imported = bridge
            .import_paths(vec![crate::path_key(&source)], false, Cancellation::new())
            .await
            .unwrap();
        let library = bridge
            .open_library_book(
                imported[0].book.as_ref().unwrap().book_id,
                Cancellation::new(),
            )
            .await
            .unwrap();

        let listed = bridge
            .list_annotations(library.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, annotation.id);
    }

    #[tokio::test]
    async fn import_merges_all_unowned_raw_and_canonical_annotation_aliases() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let raw_path = "tests/fixtures/../fixtures/sample.pdf";
        let local = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "canonical".into(),
                    path_key: crate::path_key(source),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let first = bridge
            .create_annotation(annotation_request(local.handle), Cancellation::new())
            .await
            .unwrap();
        let retained = bridge.document(local.handle).unwrap();
        let second = NewAnnotation {
            id: AnnotationId::new(),
            book_id: None,
            local_path: Some(raw_path.into()),
            fingerprint: retained.fingerprint.clone(),
            quote: None,
            target: AnnotationTarget::Pdf(
                PdfAnchor::new(0, None, vec![PageRect::new(0.0, 0.0, 1.0, 1.0).unwrap()]).unwrap(),
            ),
            color: HighlightColor::Blue,
            body: None,
            provenance: None,
        };
        let second = bridge
            .annotation_store()
            .await
            .unwrap()
            .create_async(&second)
            .await
            .unwrap();
        let imported = bridge
            .import_paths(vec![raw_path.into()], false, Cancellation::new())
            .await
            .unwrap();
        let library = bridge
            .open_library_book(
                imported[0].book.as_ref().unwrap().book_id,
                Cancellation::new(),
            )
            .await
            .unwrap();

        let listed = bridge
            .list_annotations(library.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 2);
        assert!(listed.iter().any(|item| item.id == first.id));
        assert!(listed.iter().any(|item| item.id == second.id.to_string()));
    }

    #[tokio::test]
    async fn identical_referenced_books_do_not_steal_annotation_ownership() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let first_path = directory.path().join("first.pdf");
        let second_path = directory.path().join("second.pdf");
        let fixture = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        std::fs::copy(fixture, &first_path).unwrap();
        std::fs::copy(fixture, &second_path).unwrap();
        let imported = bridge
            .import_paths(
                vec![crate::path_key(&first_path)],
                false,
                Cancellation::new(),
            )
            .await
            .unwrap();
        let first_book_id = imported[0].book.as_ref().unwrap().book_id;
        let first_book = bridge
            .library()
            .await
            .unwrap()
            .get(first_book_id)
            .await
            .unwrap()
            .unwrap();
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let second_book: i64 = sqlx::query_scalar(
            "INSERT INTO books (
               title, format, file_path, storage_kind, content_hash, file_size
             ) VALUES ('Second', 'pdf', ?, 'referenced', ?, ?) RETURNING id",
        )
        .bind(crate::path_key::canonical_path_key(&second_path))
        .bind(first_book.content_hash.as_deref().unwrap())
        .bind(
            first_book
                .file_size
                .map(|size| i64::try_from(size).unwrap()),
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        let first_document = bridge
            .open_library_book(first_book.id, Cancellation::new())
            .await
            .unwrap();
        let annotation = bridge
            .create_annotation(
                annotation_request(first_document.handle),
                Cancellation::new(),
            )
            .await
            .unwrap();
        let second_document = bridge
            .open_library_book(second_book, Cancellation::new())
            .await
            .unwrap();
        assert!(
            bridge
                .list_annotations(second_document.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .is_empty()
        );
        let first_reopened = bridge
            .open_library_book(first_book.id, Cancellation::new())
            .await
            .unwrap();
        let listed = bridge
            .list_annotations(first_reopened.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, annotation.id);
    }

    #[tokio::test]
    async fn claimed_untracked_alias_cannot_be_reclaimed_by_another_book() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let first_path = directory.path().join("first.pdf");
        let second_path = directory.path().join("second.pdf");
        let fixture = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        std::fs::copy(fixture, &first_path).unwrap();
        std::fs::copy(fixture, &second_path).unwrap();
        let untracked = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "second-untracked".into(),
                    path_key: crate::path_key(&second_path),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        let annotation = bridge
            .create_annotation(annotation_request(untracked.handle), Cancellation::new())
            .await
            .unwrap();
        let imported = bridge
            .import_paths(
                vec![crate::path_key(&first_path)],
                false,
                Cancellation::new(),
            )
            .await
            .unwrap();
        let first_book = imported[0].book.as_ref().unwrap().book_id;
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let hash: String = sqlx::query_scalar("SELECT content_hash FROM books WHERE id = ?")
            .bind(first_book)
            .fetch_one(&pool)
            .await
            .unwrap();
        let second_book: i64 = sqlx::query_scalar(
            "INSERT INTO books (title, format, file_path, storage_kind, content_hash)
             VALUES ('Second', 'pdf', ?, 'referenced', ?) RETURNING id",
        )
        .bind(crate::path_key::canonical_path_key(&second_path))
        .bind(&hash)
        .fetch_one(&pool)
        .await
        .unwrap();

        assert!(matches!(
            bridge
                .open_library_book(second_book, Cancellation::new())
                .await,
            Err(BridgeError::InvalidRequest(_))
        ));
        let owner: Option<i64> = sqlx::query_scalar("SELECT book_id FROM annotations WHERE id = ?")
            .bind(&annotation.id)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(owner, Some(first_book));
        let first = bridge
            .open_library_book(first_book, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(
            bridge
                .list_annotations(first.handle, 1.0, Cancellation::new())
                .await
                .unwrap()[0]
                .id,
            annotation.id
        );
    }

    #[tokio::test]
    async fn managed_import_counts_changed_fingerprint_versions_before_merging() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &source,
        )
        .unwrap();
        let local = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "version-limit".into(),
                    path_key: crate::path_key(&source),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        bridge
            .create_annotation(annotation_request(local.handle), Cancellation::new())
            .await
            .unwrap();
        let retained = bridge.document(local.handle).unwrap();
        let store = bridge.annotation_store().await.unwrap();
        let source_version = store
            .list_association_sources_async(
                AnnotationDocumentFormat::Pdf,
                "/different.pdf",
                &DocumentFingerprint::new("sha256", 1, vec![0; 32]).unwrap(),
                None,
                1,
            )
            .await
            .unwrap()
            .sources
            .into_iter()
            .next()
            .unwrap()
            .version_id;
        for index in 1..MAX_ANNOTATION_DOCUMENT_VERSIONS {
            store
                .associate_document_version_async(
                    &source_version,
                    AnnotationDocumentFormat::Pdf,
                    &format!("/changed/{index}.pdf"),
                    &DocumentFingerprint::new(
                        "sha256",
                        1,
                        u64::try_from(index).unwrap().to_le_bytes().to_vec(),
                    )
                    .unwrap(),
                )
                .await
                .unwrap();
        }
        let imported = bridge
            .import_paths(vec![crate::path_key(&source)], true, Cancellation::new())
            .await
            .unwrap();

        assert!(imported[0].book.is_none());
        assert!(
            imported[0]
                .error
                .as_deref()
                .unwrap()
                .contains("version limit")
        );
        let pool = bridge.state_store().await.unwrap().pool();
        let version_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM annotation_document_versions")
                .fetch_one(pool)
                .await
                .unwrap();
        let book_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM books")
            .fetch_one(pool)
            .await
            .unwrap();
        assert_eq!(
            version_count,
            i64::try_from(MAX_ANNOTATION_DOCUMENT_VERSIONS).unwrap()
        );
        assert_eq!(book_count, 0);
        assert_eq!(retained.book_id, None);
    }

    #[tokio::test]
    async fn retained_local_handle_creates_library_owned_annotation_after_import() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let local = bridge
            .open_document(pdf_request(), Cancellation::new())
            .await
            .unwrap();
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], true, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;

        let annotation = bridge
            .create_annotation(annotation_request(local.handle), Cancellation::new())
            .await
            .unwrap();
        let stored = bridge
            .annotation_store()
            .await
            .unwrap()
            .get_async(&AnnotationId::from_str(&annotation.id).unwrap(), false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored.book_id, Some(book_id));

        let library = bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();
        let listed = bridge
            .list_annotations(library.handle, 1.0, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, annotation.id);
    }

    #[tokio::test]
    async fn invalid_bookmark_update_is_atomic() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let bookmark = bridge
            .toggle_bookmark(book_id, 0, None, Some("before".into()))
            .await
            .unwrap()
            .unwrap();

        assert!(
            bridge
                .update_bookmark(
                    bookmark.id,
                    Some("after".into()),
                    Some("x".repeat(crate::bookmarks::MAX_BOOKMARK_NOTE_BYTES + 1)),
                )
                .await
                .is_err()
        );
        let stored = bridge.list_bookmarks(book_id).await.unwrap();
        assert_eq!(stored[0].title.as_deref(), Some("before"));
        assert_eq!(stored[0].note, None);
    }

    #[test]
    fn progress_uses_document_boundaries() {
        assert_eq!(reading_progress(0, 1), 1.0);
        assert_eq!(reading_progress(0, 3), 0.0);
        assert_eq!(reading_progress(1, 3), 0.5);
        assert_eq!(reading_progress(2, 3), 1.0);
        assert_eq!(reading_progress(usize::MAX, 3), 1.0);
    }

    #[tokio::test]
    async fn explicit_unit_count_updates_progress_without_a_retained_document() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;

        bridge
            .save_reading_state_with_unit_count(
                book_id,
                ReadingStateDto {
                    unit: 1,
                    offset: None,
                    zoom: 1.0,
                },
                3,
            )
            .await
            .unwrap();

        let page = bridge.library_page(None, None, 10, 0).await.unwrap();
        assert_eq!(page.books[0].progress, 0.5);
    }

    #[tokio::test]
    async fn reading_state_rolls_back_when_progress_update_fails() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let source = std::path::Path::new(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/sample.pdf"
        ));
        let imported = bridge
            .import_paths(vec![crate::path_key(source)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();
        let state_store = bridge.state_store().await.unwrap();
        sqlx::query(
            "CREATE TRIGGER reject_test_progress BEFORE UPDATE OF progress ON books
             BEGIN SELECT RAISE(ABORT, 'injected progress failure'); END",
        )
        .execute(state_store.pool())
        .await
        .unwrap();

        assert!(
            bridge
                .save_reading_state(
                    book_id,
                    ReadingStateDto {
                        unit: 0,
                        offset: Some(3),
                        zoom: 1.0,
                    },
                )
                .await
                .is_err()
        );
        assert!(bridge.load_reading_state(book_id).await.unwrap().is_none());
    }

    #[tokio::test]
    async fn product_reads_honor_cancellation_and_validation_categories() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let cancelled = Cancellation::new();
        cancelled.cancel();

        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 10, 0, cancelled.clone())
                .await,
            Err(BridgeError::Cancelled)
        ));
        assert!(matches!(
            bridge
                .list_bookmarks_cancellable(1, cancelled.clone())
                .await,
            Err(BridgeError::Cancelled)
        ));
        assert_eq!(
            bridge
                .load_reading_state_cancellable(1, cancelled.clone())
                .await,
            Err(BridgeError::Cancelled)
        );
        assert_eq!(
            bridge.load_reader_settings_cancellable(cancelled).await,
            Err(BridgeError::Cancelled)
        );
        assert!(matches!(
            bridge
                .library_page_cancellable(Some("x".repeat(4097)), None, 10, 0, Cancellation::new(),)
                .await,
            Err(BridgeError::InvalidRequest(_))
        ));
        assert!(matches!(
            bridge.update_bookmark(-1, None, None).await,
            Err(BridgeError::ResourceNotFound(_))
        ));
        assert!(matches!(
            bridge.list_bookmarks(-1).await,
            Err(BridgeError::ResourceNotFound(_))
        ));
        assert!(matches!(
            bridge.toggle_bookmark(-1, 0, None, None).await,
            Err(BridgeError::ResourceNotFound(_))
        ));
    }

    #[tokio::test]
    async fn pre_cancelled_library_page_does_not_initialize_storage() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("fresh").join("state.sqlite");
        let bridge = Bridge::with_database_path(database.clone());
        let cancellation = Cancellation::new();
        cancellation.cancel();

        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, cancellation)
                .await,
            Err(BridgeError::Cancelled)
        ));
        assert!(!database.exists());
    }

    #[tokio::test]
    async fn active_library_cancellation_retains_request_admission_until_sqlite_exits() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge = Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let mut transaction = bridge
            .state_store()
            .await
            .unwrap()
            .pool()
            .begin()
            .await
            .unwrap();
        for index in 0..2_000 {
            sqlx::query(
                "INSERT INTO books (title, format, file_path, storage_kind)
                 VALUES (?, 'pdf', ?, 'referenced')",
            )
            .bind(format!("Book {index}"))
            .bind(format!("/books/{index}.pdf"))
            .execute(&mut *transaction)
            .await
            .unwrap();
        }
        transaction.commit().await.unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let cancellation_gate = Arc::new(TestPhaseGate::default());
        bridge.library_query_progress_barrier = Some(Arc::clone(&barrier));
        bridge.product_read_cancellation_gate = Some(Arc::clone(&cancellation_gate));
        let cancellation = Cancellation::new();
        let query = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move {
                bridge
                    .library_page_cancellable(Some("Book".into()), None, 500, 0, cancellation)
                    .await
            }
        });
        tokio::task::spawn_blocking({
            let barrier = Arc::clone(&barrier);
            move || barrier.wait()
        })
        .await
        .unwrap();

        cancellation.cancel();
        cancellation_gate.wait_until_entered().await;
        let competing = bridge
            .library_page_cancellable(None, None, 1, 0, Cancellation::new())
            .await;
        cancellation_gate.release();
        tokio::task::yield_now().await;
        let competing_while_sqlite_exits = bridge
            .library_page_cancellable(None, None, 1, 0, Cancellation::new())
            .await;
        tokio::task::spawn_blocking(move || barrier.wait())
            .await
            .unwrap();
        assert!(matches!(competing, Err(BridgeError::RequestLimit)));
        assert!(matches!(
            competing_while_sqlite_exits,
            Err(BridgeError::RequestLimit)
        ));
        assert!(matches!(query.await.unwrap(), Err(BridgeError::Cancelled)));
        assert!(bridge.library_page(None, None, 1, 0).await.is_ok());
    }

    #[tokio::test]
    async fn dropped_library_page_retains_request_admission_until_sqlite_exits() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge = Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let mut transaction = pool.begin().await.unwrap();
        for index in 0..2_000 {
            sqlx::query(
                "INSERT INTO books (title, format, file_path, storage_kind)
                 VALUES (?, 'pdf', ?, 'referenced')",
            )
            .bind(format!("Book {index}"))
            .bind(format!("/books/{index}.pdf"))
            .execute(&mut *transaction)
            .await
            .unwrap();
        }
        transaction.commit().await.unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        bridge.library_query_progress_barrier = Some(Arc::clone(&barrier));
        let bridge = Arc::new(bridge);
        let query = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            async move {
                bridge
                    .library_page_cancellable(
                        Some("Book".into()),
                        None,
                        500,
                        0,
                        Cancellation::new(),
                    )
                    .await
            }
        });
        tokio::task::spawn_blocking({
            let barrier = Arc::clone(&barrier);
            move || barrier.wait()
        })
        .await
        .unwrap();

        query.abort();
        assert!(query.await.unwrap_err().is_cancelled());
        assert_eq!(bridge.admission.request_slots.available_permits(), 0);
        tokio::task::spawn_blocking(move || barrier.wait())
            .await
            .unwrap();
        while bridge.admission.request_slots.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(bridge.admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn dropped_cold_library_page_retains_admission_through_blocked_initialization() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("state.sqlite");
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge =
            Bridge::with_admission_database(Arc::new(admission), Some(Arc::new(database)));
        let initialization_gate = Arc::new(TestPhaseGate::default());
        bridge.state_store_initialization_gate = Some(Arc::clone(&initialization_gate));
        let bridge = Arc::new(bridge);
        let query = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            async move {
                bridge
                    .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                    .await
            }
        });
        initialization_gate.wait_until_entered().await;

        query.abort();
        assert!(query.await.unwrap_err().is_cancelled());
        assert_eq!(bridge.admission.request_slots.available_permits(), 0);
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));

        initialization_gate.release();
        while bridge.admission.request_slots.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(bridge.admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn cancelled_cold_library_initialization_returns_typed_cancellation_on_failure() {
        let directory = tempfile::tempdir().unwrap();
        let invalid_parent = directory.path().join("not-a-directory");
        std::fs::write(&invalid_parent, b"file").unwrap();
        let mut bridge = Bridge::with_database_path(invalid_parent.join("state.sqlite"));
        let initialization_gate = Arc::new(TestPhaseGate::default());
        bridge.state_store_initialization_gate = Some(Arc::clone(&initialization_gate));
        let cancellation = Cancellation::new();
        let query = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move {
                bridge
                    .library_page_cancellable(None, None, 1, 0, cancellation)
                    .await
            }
        });
        initialization_gate.wait_until_entered().await;

        initialization_gate.release();
        cancellation.cancel();

        assert!(matches!(query.await.unwrap(), Err(BridgeError::Cancelled)));
    }

    #[tokio::test]
    async fn dropped_open_retains_admission_through_cold_annotation_initialization() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge = Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let initialization_gate = Arc::new(TestPhaseGate::default());
        bridge.annotation_test_hooks = Some(Arc::new(AnnotationTestHooks {
            initialization: Some(Arc::clone(&initialization_gate)),
            ..AnnotationTestHooks::default()
        }));
        let bridge = Arc::new(bridge);
        let opening = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            async move { bridge.open_library_book(book_id, Cancellation::new()).await }
        });
        initialization_gate.wait_until_entered().await;

        opening.abort();
        assert!(opening.await.unwrap_err().is_cancelled());
        assert_eq!(bridge.admission.request_slots.available_permits(), 0);
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));

        initialization_gate.release();
        while bridge.admission.request_slots.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(bridge.admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn library_page_cancels_while_waiting_for_a_connection() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let bridge = Arc::new(Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        ));
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let mut connections = Vec::new();
        for _ in 0..pool.options().get_max_connections() {
            connections.push(pool.acquire().await.unwrap());
        }
        let cancellation = Cancellation::new();
        let query = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            let cancellation = cancellation.clone();
            async move {
                bridge
                    .library_page_cancellable(None, None, 1, 0, cancellation)
                    .await
            }
        });
        while bridge.admission.request_slots.available_permits() != 0 {
            tokio::task::yield_now().await;
        }
        cancellation.cancel();

        let result = tokio::time::timeout(std::time::Duration::from_millis(500), query)
            .await
            .expect("library pool acquisition cancellation must be prompt")
            .unwrap();
        assert!(matches!(result, Err(BridgeError::Cancelled)));
        drop(connections);
    }

    #[tokio::test]
    async fn active_open_reconciliation_cancellation_rolls_back_and_retains_admission() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge = Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let book_path = directory.path().join("book.pdf");
        let alias_path = directory.path().join("alias.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &book_path,
        )
        .unwrap();
        std::fs::copy(&book_path, &alias_path).unwrap();
        let imported = bridge
            .import_paths(
                vec![crate::path_key(&book_path)],
                false,
                Cancellation::new(),
            )
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let alias = bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: "alias".into(),
                    path_key: crate::path_key(&alias_path),
                    format_hint: Some(BookFormat::Pdf),
                },
                Cancellation::new(),
            )
            .await
            .unwrap();
        bridge
            .create_annotation(annotation_request(alias.handle), Cancellation::new())
            .await
            .unwrap();
        bridge.release_document(alias.handle);
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let cancellation_gate = Arc::new(TestPhaseGate::default());
        bridge.annotation_reconciliation_progress_barrier = Some(Arc::clone(&barrier));
        bridge.product_read_cancellation_gate = Some(Arc::clone(&cancellation_gate));
        let cancellation = Cancellation::new();
        let mut bridge = Arc::new(bridge);
        let opening = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });
        tokio::task::spawn_blocking({
            let barrier = Arc::clone(&barrier);
            move || barrier.wait()
        })
        .await
        .unwrap();

        cancellation.cancel();
        cancellation_gate.wait_until_entered().await;
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));
        cancellation_gate.release();
        tokio::task::yield_now().await;
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));
        tokio::task::spawn_blocking(move || barrier.wait())
            .await
            .unwrap();
        assert!(matches!(
            opening.await.unwrap(),
            Err(BridgeError::Cancelled)
        ));
        let unowned: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM annotations WHERE book_id IS NULL")
                .fetch_one(bridge.state_store().await.unwrap().pool())
                .await
                .unwrap();
        assert_eq!(unowned, 1);

        Arc::get_mut(&mut bridge)
            .unwrap()
            .annotation_reconciliation_progress_barrier = None;
        let reopened = bridge
            .open_library_book(book_id, Cancellation::new())
            .await
            .unwrap();
        assert_eq!(
            bridge
                .list_annotations(reopened.handle, 1.0, Cancellation::new())
                .await
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn cancellation_after_reconciliation_commit_returns_the_opened_document() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let committed = Arc::new(TestPhaseGate::default());
        bridge.after_annotation_reconciliation_commit = Some(Arc::clone(&committed));
        let bridge = Arc::new(bridge);
        let cancellation = Cancellation::new();
        let opening = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });
        committed.wait_until_entered().await;

        cancellation.cancel();
        committed.release();

        let document = opening.await.unwrap().unwrap();
        assert_eq!(document.book_id, Some(book_id));
        assert!(bridge.release_document(document.handle));
    }

    #[tokio::test]
    async fn dropped_open_keeps_reconciliation_admitted_until_connection_cleanup() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge = Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let barrier = Arc::new(std::sync::Barrier::new(2));
        bridge.annotation_reconciliation_progress_barrier = Some(Arc::clone(&barrier));
        let bridge = Arc::new(bridge);
        let opening = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            async move { bridge.open_library_book(book_id, Cancellation::new()).await }
        });
        tokio::task::spawn_blocking({
            let barrier = Arc::clone(&barrier);
            move || barrier.wait()
        })
        .await
        .unwrap();

        opening.abort();
        assert!(opening.await.unwrap_err().is_cancelled());
        assert_eq!(bridge.admission.request_slots.available_permits(), 0);
        tokio::task::spawn_blocking(move || barrier.wait())
            .await
            .unwrap();
        while bridge.admission.request_slots.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(bridge.admission.request_slots.available_permits(), 1);
        assert!(bridge.library_page(None, None, 1, 0).await.is_ok());
    }

    #[tokio::test]
    async fn open_reconciliation_reports_a_typed_sqlite_work_limit() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        bridge.annotation_reconciliation_work_limit = Some(1);

        assert!(matches!(
            bridge.open_library_book(book_id, Cancellation::new()).await,
            Err(BridgeError::BufferLimit)
        ));
        bridge.annotation_reconciliation_work_limit = None;
        assert!(
            bridge
                .open_library_book(book_id, Cancellation::new())
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn legacy_tombstone_rewrite_limit_rejects_before_mutation() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book = imported[0].book.as_ref().unwrap();
        let pool = bridge.state_store().await.unwrap().pool();
        let content_hash: String =
            sqlx::query_scalar("SELECT content_hash FROM books WHERE id = ?")
                .bind(book.book_id)
                .fetch_one(pool)
                .await
                .unwrap();
        let mut transaction = pool.begin().await.unwrap();
        for index in 0..4_097 {
            sqlx::query(
                "INSERT INTO annotations (
                   id, book_id, local_path, format, anchor_version,
                   fingerprint_algorithm, fingerprint_version, fingerprint,
                   color, pdf_page, created_at, modified_at, deleted_at,
                   annotation_document_id)
                 VALUES (?, ?, ?, 'pdf', 1, 'sha256-hex', 1, ?,
                         'yellow', 0, '2026-01-01T00:00:00Z',
                         '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL)",
            )
            .bind(format!("00000000-0000-4000-8000-{index:012}"))
            .bind(book.book_id)
            .bind(&book.path_key)
            .bind(content_hash.as_bytes())
            .execute(&mut *transaction)
            .await
            .unwrap();
        }
        transaction.commit().await.unwrap();

        assert!(matches!(
            bridge
                .open_library_book(book.book_id, Cancellation::new())
                .await,
            Err(BridgeError::BufferLimit)
        ));
        let rewritten: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM annotations WHERE annotation_document_id IS NOT NULL",
        )
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(rewritten, 0);
    }

    #[tokio::test]
    async fn open_reconciliation_cancels_while_waiting_for_a_connection() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let pool = bridge.annotation_store().await.unwrap().test_pool().clone();
        let mut connections = Vec::new();
        for _ in 0..pool.options().get_max_connections() {
            connections.push(pool.acquire().await.unwrap());
        }
        let gate = Arc::new(TestPhaseGate::default());
        bridge.before_annotation_reconciliation = Some(Arc::clone(&gate));
        let bridge = Arc::new(bridge);
        let cancellation = Cancellation::new();
        let opening = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });
        gate.wait_until_entered().await;
        gate.release();
        tokio::task::yield_now().await;
        cancellation.cancel();

        let result = tokio::time::timeout(std::time::Duration::from_millis(500), opening)
            .await
            .expect("connection acquisition cancellation must be prompt")
            .unwrap();
        assert!(matches!(result, Err(BridgeError::Cancelled)));
        drop(connections);
    }

    #[tokio::test]
    async fn open_reconciliation_cancels_while_waiting_for_the_writer_lock() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.pdf");
        std::fs::copy(
            std::path::Path::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/sample.pdf"
            )),
            &path,
        )
        .unwrap();
        let mut bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let imported = bridge
            .import_paths(vec![crate::path_key(&path)], false, Cancellation::new())
            .await
            .unwrap();
        let book_id = imported[0].book.as_ref().unwrap().book_id;
        let pool = bridge.annotation_store().await.unwrap().test_pool().clone();
        let writer = pool.begin_with("BEGIN IMMEDIATE").await.unwrap();
        let gate = Arc::new(TestPhaseGate::default());
        bridge.before_annotation_reconciliation = Some(Arc::clone(&gate));
        let bridge = Arc::new(bridge);
        let cancellation = Cancellation::new();
        let opening = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            let cancellation = cancellation.clone();
            async move { bridge.open_library_book(book_id, cancellation).await }
        });
        gate.wait_until_entered().await;
        gate.release();
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        cancellation.cancel();

        let result = tokio::time::timeout(std::time::Duration::from_millis(500), opening)
            .await
            .expect("writer-lock cancellation must be prompt")
            .unwrap();
        assert!(matches!(result, Err(BridgeError::Cancelled)));
        writer.rollback().await.unwrap();
    }

    #[tokio::test]
    async fn active_bookmark_cancellation_retains_request_admission_until_sqlite_exits() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let mut bridge = Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        );
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let book_id: i64 = sqlx::query_scalar(
            "INSERT INTO books (title, format, file_path, storage_kind, content_hash)
             VALUES ('Book', 'pdf', '/books/book.pdf', 'referenced', ?) RETURNING id",
        )
        .bind("a".repeat(64))
        .fetch_one(&pool)
        .await
        .unwrap();
        let writer = pool.begin_with("BEGIN IMMEDIATE").await.unwrap();
        let cancellation_gate = Arc::new(TestPhaseGate::default());
        bridge.product_read_cancellation_gate = Some(Arc::clone(&cancellation_gate));
        let cancellation = Cancellation::new();
        let operation = tokio::spawn({
            let bridge = bridge.clone();
            let cancellation = cancellation.clone();
            async move {
                bridge
                    .list_bookmarks_cancellable(book_id, cancellation)
                    .await
            }
        });
        while bridge.admission.request_slots.available_permits() != 0 {
            tokio::task::yield_now().await;
        }

        cancellation.cancel();
        cancellation_gate.wait_until_entered().await;
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));
        cancellation_gate.release();
        tokio::task::yield_now().await;
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));
        writer.commit().await.unwrap();
        assert!(matches!(
            operation.await.unwrap(),
            Err(BridgeError::Cancelled)
        ));
        assert!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn dropped_bookmark_read_retains_request_admission_until_sqlite_exits() {
        let directory = tempfile::tempdir().unwrap();
        let mut admission = BridgeAdmission::new(MAX_BRIDGE_RETAINED_BUFFER_BYTES, 1);
        admission.request_slots = Arc::new(Semaphore::new(1));
        let bridge = Arc::new(Bridge::with_admission_database(
            Arc::new(admission),
            Some(Arc::new(directory.path().join("state.sqlite"))),
        ));
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let book_id: i64 = sqlx::query_scalar(
            "INSERT INTO books (title, format, file_path, storage_kind, content_hash)
             VALUES ('Book', 'pdf', '/books/book.pdf', 'referenced', ?) RETURNING id",
        )
        .bind("a".repeat(64))
        .fetch_one(&pool)
        .await
        .unwrap();
        let writer = pool.begin_with("BEGIN IMMEDIATE").await.unwrap();
        let operation = tokio::spawn({
            let bridge = Arc::clone(&bridge);
            async move {
                bridge
                    .list_bookmarks_cancellable(book_id, Cancellation::new())
                    .await
            }
        });
        while bridge.admission.request_slots.available_permits() != 0 {
            tokio::task::yield_now().await;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;

        operation.abort();
        assert!(operation.await.unwrap_err().is_cancelled());
        assert!(matches!(
            bridge
                .library_page_cancellable(None, None, 1, 0, Cancellation::new())
                .await,
            Err(BridgeError::RequestLimit)
        ));
        writer.commit().await.unwrap();
        while bridge.admission.request_slots.available_permits() == 0 {
            tokio::task::yield_now().await;
        }
        assert_eq!(bridge.admission.request_slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn persistence_categories_do_not_depend_on_error_text() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let store = bridge.state_store().await.unwrap();
        sqlx::query("INSERT INTO preferences (key, value) VALUES ('reader.mode', ?)")
            .bind("invalid".repeat(crate::reading_state::MAX_PREFERENCE_VALUE_BYTES))
            .execute(store.pool())
            .await
            .unwrap();

        assert!(matches!(
            bridge.load_reader_settings().await,
            Err(BridgeError::Storage(_))
        ));
        assert!(matches!(
            bridge
                .save_reading_state_with_unit_count(
                    404,
                    ReadingStateDto {
                        unit: 0,
                        offset: None,
                        zoom: 1.0,
                    },
                    1,
                )
                .await,
            Err(BridgeError::ResourceNotFound(_))
        ));
        assert_eq!(
            bookmark_storage_error(BookmarkExportLimit.into()),
            BridgeError::BufferLimit
        );
        assert_eq!(
            library_mutation_error(AnnotationSnapshotLimit.into()),
            BridgeError::AnnotationLimit
        );
        assert!(matches!(
            annotation_storage_error(
                AnnotationAssociationInvalidRequest("different format".into()).into()
            ),
            BridgeError::InvalidRequest(_)
        ));
        assert!(matches!(
            annotation_storage_error(AnnotationAssociationSourceNotFound.into()),
            BridgeError::ResourceNotFound(_)
        ));
    }

    #[tokio::test]
    async fn managed_removal_preserves_bookmark_union_limit_category() {
        let directory = tempfile::tempdir().unwrap();
        let bridge = Bridge::with_database_path(directory.path().join("state.sqlite"));
        let library = bridge.library().await.unwrap();
        std::fs::create_dir_all(library.managed_dir()).unwrap();
        let managed_path = library.managed_dir().join("book.pdf");
        let source_path = directory.path().join("source.pdf");
        std::fs::write(&managed_path, b"managed").unwrap();
        std::fs::write(&source_path, b"source").unwrap();
        let pool = bridge.state_store().await.unwrap().pool().clone();
        let hash = "a".repeat(64);
        let book_id: i64 = sqlx::query_scalar(
            "INSERT INTO books (
               title, format, file_path, storage_kind, original_path, content_hash
             ) VALUES ('Book', 'pdf', ?, 'managed', ?, ?) RETURNING id",
        )
        .bind(crate::path_key::canonical_path_key(&managed_path))
        .bind(crate::path_key::canonical_path_key(&source_path))
        .bind(&hash)
        .fetch_one(&pool)
        .await
        .unwrap();
        let mut transaction = pool.begin().await.unwrap();
        for page in 0..=crate::bookmarks::MAX_BOOKMARKS_PER_BOOK {
            sqlx::query(
                "INSERT INTO bookmarks (
                   file_path, content_hash, page, color, created_at
                 ) VALUES (?, ?, ?, 'yellow', datetime('now'))",
            )
            .bind(crate::path_key::canonical_path_key(&source_path))
            .bind(&hash)
            .bind(i64::try_from(page).unwrap())
            .execute(&mut *transaction)
            .await
            .unwrap();
        }
        transaction.commit().await.unwrap();

        let error = bridge.remove_library_book(book_id).await.unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::LimitExceeded);
        assert!(matches!(error, BridgeError::BufferLimit));
    }

    #[tokio::test]
    async fn cbz_search_reports_unsupported_instead_of_render_failure() {
        let bridge = Bridge::new();
        let document = bridge
            .open_document(cbz_request(), Cancellation::new())
            .await
            .unwrap();

        assert_eq!(
            bridge
                .search_document(document.handle, "text".into(), Cancellation::new())
                .await,
            Err(BridgeError::UnsupportedOperation(BookFormat::Cbz))
        );
    }
}
