use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use shosai_core::annotations::AnnotationAssociationOutcome;
use shosai_core::annotations::{AnnotationResolution, HighlightColor};
use shosai_core::bridge::{
    AnnotationAssociationSourceDto, AnnotationAssociationSourcePageDto, AnnotationTextRange,
    BookmarkDto, Bridge, BridgeAnnotation, BridgeError, BufferHandle, Cancellation,
    CreateAnnotationRequest, DocumentHandle, ImportItemDto, ImportReportDto, LibraryBookDto,
    OpenRequest, ReaderSettingsDto, ReadingStateDto, RenderRequest, SelectionHandle,
    SelectionSurface,
};
use shosai_core::library::BookFormat;
use shosai_core::search::SearchMatch;
use thiserror::Error;

const MAX_CANCELLATIONS: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlutterBookFormat {
    Pdf,
    Epub,
    Cbz,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlutterHighlightColor {
    Yellow,
    Green,
    Blue,
    Pink,
    Purple,
}

impl From<FlutterHighlightColor> for HighlightColor {
    fn from(value: FlutterHighlightColor) -> Self {
        match value {
            FlutterHighlightColor::Yellow => Self::Yellow,
            FlutterHighlightColor::Green => Self::Green,
            FlutterHighlightColor::Blue => Self::Blue,
            FlutterHighlightColor::Pink => Self::Pink,
            FlutterHighlightColor::Purple => Self::Purple,
        }
    }
}
impl From<HighlightColor> for FlutterHighlightColor {
    fn from(value: HighlightColor) -> Self {
        match value {
            HighlightColor::Yellow => Self::Yellow,
            HighlightColor::Green => Self::Green,
            HighlightColor::Blue => Self::Blue,
            HighlightColor::Pink => Self::Pink,
            HighlightColor::Purple => Self::Purple,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FlutterAnnotation {
    pub id: String,
    pub unit: usize,
    pub resolution: FlutterAnnotationResolution,
    pub text_range: Option<FlutterAnnotationTextRange>,
    pub quote: Option<String>,
    pub rectangles: Option<Vec<FlutterSelectionRect>>,
    pub color: FlutterHighlightColor,
    pub body: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlutterAnnotationResolution {
    Exact,
    Recovered,
    Ambiguous,
    Orphaned,
}

impl From<AnnotationResolution> for FlutterAnnotationResolution {
    fn from(value: AnnotationResolution) -> Self {
        match value {
            AnnotationResolution::Exact => Self::Exact,
            AnnotationResolution::Recovered => Self::Recovered,
            AnnotationResolution::Ambiguous => Self::Ambiguous,
            AnnotationResolution::Orphaned => Self::Orphaned,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlutterAnnotationTextRange {
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlutterAnnotationAssociationSource {
    pub version_id: String,
    pub format: FlutterBookFormat,
    pub local_path: String,
    pub fingerprint_algorithm: String,
    pub fingerprint_version: u32,
    pub fingerprint: Vec<u8>,
    pub live_annotations: usize,
}

impl From<AnnotationAssociationSourceDto> for FlutterAnnotationAssociationSource {
    fn from(value: AnnotationAssociationSourceDto) -> Self {
        Self {
            version_id: value.version_id,
            format: value.format.into(),
            local_path: value.local_path,
            fingerprint_algorithm: value.fingerprint_algorithm,
            fingerprint_version: value.fingerprint_version,
            fingerprint: value.fingerprint,
            live_annotations: value.live_annotations,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlutterAnnotationAssociationSourcePage {
    pub sources: Vec<FlutterAnnotationAssociationSource>,
    pub next_cursor: Option<String>,
    pub previous_cursor: Option<String>,
}

impl From<AnnotationAssociationSourcePageDto> for FlutterAnnotationAssociationSourcePage {
    fn from(value: AnnotationAssociationSourcePageDto) -> Self {
        Self {
            sources: value.sources.into_iter().map(Into::into).collect(),
            next_cursor: value.next_cursor,
            previous_cursor: value.previous_cursor,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlutterAnnotationAssociationOutcome {
    Associated,
    AlreadyAssociated,
}

impl From<AnnotationAssociationOutcome> for FlutterAnnotationAssociationOutcome {
    fn from(value: AnnotationAssociationOutcome) -> Self {
        match value {
            AnnotationAssociationOutcome::Associated => Self::Associated,
            AnnotationAssociationOutcome::AlreadyAssociated => Self::AlreadyAssociated,
        }
    }
}

impl From<AnnotationTextRange> for FlutterAnnotationTextRange {
    fn from(value: AnnotationTextRange) -> Self {
        Self {
            start: value.start,
            end: value.end,
        }
    }
}

impl From<BridgeAnnotation> for FlutterAnnotation {
    fn from(value: BridgeAnnotation) -> Self {
        Self {
            id: value.id,
            unit: value.unit,
            resolution: value.resolution.into(),
            text_range: value.text_range.map(Into::into),
            quote: value.quote,
            rectangles: Some(
                value
                    .rectangles
                    .into_iter()
                    .map(|rect| FlutterSelectionRect {
                        left: rect.left,
                        top: rect.top,
                        right: rect.right,
                        bottom: rect.bottom,
                    })
                    .collect(),
            ),
            color: value.color.into(),
            body: value.body,
        }
    }
}

impl From<FlutterBookFormat> for BookFormat {
    fn from(value: FlutterBookFormat) -> Self {
        match value {
            FlutterBookFormat::Pdf => Self::Pdf,
            FlutterBookFormat::Epub => Self::Epub,
            FlutterBookFormat::Cbz => Self::Cbz,
        }
    }
}

impl From<BookFormat> for FlutterBookFormat {
    fn from(value: BookFormat) -> Self {
        match value {
            BookFormat::Pdf => Self::Pdf,
            BookFormat::Epub => Self::Epub,
            BookFormat::Cbz => Self::Cbz,
        }
    }
}

#[derive(Debug, Clone)]
pub struct FlutterOpenRequest {
    pub local_id: String,
    pub path_key: String,
    pub format_hint: Option<FlutterBookFormat>,
}

#[derive(Debug, Clone)]
pub struct FlutterLibraryBook {
    pub book_id: i64,
    pub title: String,
    pub author: Option<String>,
    pub format: FlutterBookFormat,
    pub path_key: String,
    pub managed: bool,
    pub cover: Option<Vec<u8>>,
    pub progress: f64,
    pub date_added: String,
    pub last_read: Option<String>,
}
impl From<LibraryBookDto> for FlutterLibraryBook {
    fn from(v: LibraryBookDto) -> Self {
        Self {
            book_id: v.book_id,
            title: v.title,
            author: v.author,
            format: v.format.into(),
            path_key: v.path_key,
            managed: v.managed,
            cover: v.cover,
            progress: v.progress,
            date_added: v.date_added,
            last_read: v.last_read,
        }
    }
}
#[derive(Debug, Clone)]
pub struct FlutterLibraryPage {
    pub books: Vec<FlutterLibraryBook>,
    pub has_more: bool,
}
#[derive(Debug, Clone)]
pub struct FlutterImportItem {
    pub path_key: String,
    pub book: Option<FlutterLibraryBook>,
    pub error: Option<String>,
}
impl From<ImportItemDto> for FlutterImportItem {
    fn from(v: ImportItemDto) -> Self {
        Self {
            path_key: v.path_key,
            book: v.book.map(Into::into),
            error: v.error,
        }
    }
}
#[derive(Debug, Clone)]
pub struct FlutterImportReport {
    pub imported: usize,
    pub failed: usize,
    pub cancelled: bool,
    pub items: Vec<FlutterImportItem>,
}
impl From<ImportReportDto> for FlutterImportReport {
    fn from(v: ImportReportDto) -> Self {
        Self {
            imported: v.imported,
            failed: v.failed,
            cancelled: v.cancelled,
            items: v.items.into_iter().map(Into::into).collect(),
        }
    }
}
#[derive(Debug, Clone)]
pub struct FlutterSearchMatch {
    pub unit: usize,
    pub offset: usize,
    pub length: usize,
    pub context: String,
}
impl From<SearchMatch> for FlutterSearchMatch {
    fn from(v: SearchMatch) -> Self {
        Self {
            unit: v.page,
            offset: v.offset,
            length: v.length,
            context: v.context,
        }
    }
}
#[derive(Debug, Clone)]
pub struct FlutterBookmark {
    pub id: i64,
    pub book_id: Option<i64>,
    pub unit: usize,
    pub offset: Option<usize>,
    pub title: Option<String>,
    pub note: Option<String>,
    pub color: String,
    pub created_at: String,
}
impl From<BookmarkDto> for FlutterBookmark {
    fn from(v: BookmarkDto) -> Self {
        Self {
            id: v.id,
            book_id: v.book_id,
            unit: v.unit,
            offset: v.offset,
            title: v.title,
            note: v.note,
            color: v.color,
            created_at: v.created_at,
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlutterReadingState {
    pub unit: usize,
    pub offset: Option<usize>,
    pub zoom: f32,
}
impl From<ReadingStateDto> for FlutterReadingState {
    fn from(v: ReadingStateDto) -> Self {
        Self {
            unit: v.unit,
            offset: v.offset,
            zoom: v.zoom,
        }
    }
}
impl From<FlutterReadingState> for ReadingStateDto {
    fn from(v: FlutterReadingState) -> Self {
        Self {
            unit: v.unit,
            offset: v.offset,
            zoom: v.zoom,
        }
    }
}
#[derive(Debug, Clone, PartialEq)]
pub struct FlutterReaderSettings {
    pub continuous: bool,
    pub theme: String,
    pub epub_font_size: f32,
    pub epub_line_spacing: f32,
    pub pdf_zoom: f32,
}
impl From<ReaderSettingsDto> for FlutterReaderSettings {
    fn from(v: ReaderSettingsDto) -> Self {
        Self {
            continuous: v.continuous,
            theme: v.theme,
            epub_font_size: v.epub_font_size,
            epub_line_spacing: v.epub_line_spacing,
            pdf_zoom: v.pdf_zoom,
        }
    }
}
impl From<FlutterReaderSettings> for ReaderSettingsDto {
    fn from(v: FlutterReaderSettings) -> Self {
        Self {
            continuous: v.continuous,
            theme: v.theme,
            epub_font_size: v.epub_font_size,
            epub_line_spacing: v.epub_line_spacing,
            pdf_zoom: v.pdf_zoom,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlutterDocumentHandle {
    pub registry: u64,
    pub id: u64,
}

impl From<DocumentHandle> for FlutterDocumentHandle {
    fn from(value: DocumentHandle) -> Self {
        Self {
            registry: value.registry,
            id: value.id,
        }
    }
}

impl From<FlutterDocumentHandle> for DocumentHandle {
    fn from(value: FlutterDocumentHandle) -> Self {
        Self {
            registry: value.registry,
            id: value.id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlutterBufferHandle {
    pub registry: u64,
    pub id: u64,
}

impl From<BufferHandle> for FlutterBufferHandle {
    fn from(value: BufferHandle) -> Self {
        Self {
            registry: value.registry,
            id: value.id,
        }
    }
}

impl From<FlutterBufferHandle> for BufferHandle {
    fn from(value: FlutterBufferHandle) -> Self {
        Self {
            registry: value.registry,
            id: value.id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlutterSelectionHandle {
    pub registry: u64,
    pub id: u64,
}

impl From<SelectionHandle> for FlutterSelectionHandle {
    fn from(value: SelectionHandle) -> Self {
        Self {
            registry: value.registry,
            id: value.id,
        }
    }
}

impl From<FlutterSelectionHandle> for SelectionHandle {
    fn from(value: FlutterSelectionHandle) -> Self {
        Self {
            registry: value.registry,
            id: value.id,
        }
    }
}

#[derive(Debug, Clone)]
pub struct FlutterDocumentSummary {
    pub handle: FlutterDocumentHandle,
    pub book_id: Option<i64>,
    pub format: FlutterBookFormat,
    pub title: Option<String>,
    pub logical_unit_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlutterRenderedBuffer {
    pub handle: FlutterBufferHandle,
    pub width: u32,
    pub height: u32,
    pub byte_len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlutterSelectionRect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlutterSelectionEndpoint {
    pub offset: usize,
    pub range_start: usize,
    pub range_end: usize,
    pub rect: FlutterSelectionRect,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FlutterSelectionCaret {
    pub offset: usize,
    pub x: f32,
    pub along_line: f32,
    pub vertical: bool,
    pub top: f32,
    pub bottom: f32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FlutterSelectionVisualLine {
    pub carets: Vec<FlutterSelectionCaret>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FlutterSelectionSurface {
    pub handle: FlutterSelectionHandle,
    pub width: f32,
    pub height: f32,
    pub text: String,
    pub copy_eligible: bool,
    pub resource_path: Option<String>,
    pub raster: Option<FlutterRenderedBuffer>,
    pub endpoints: Vec<FlutterSelectionEndpoint>,
    pub grapheme_boundaries: Vec<u32>,
    pub word_boundaries: Vec<u32>,
    pub visual_lines: Vec<FlutterSelectionVisualLine>,
}

impl From<SelectionSurface> for FlutterSelectionSurface {
    fn from(value: SelectionSurface) -> Self {
        Self {
            handle: value.handle.into(),
            width: value.width,
            height: value.height,
            text: value.text,
            copy_eligible: value.copy_eligible,
            resource_path: value.resource_path,
            raster: value.raster.map(|raster| FlutterRenderedBuffer {
                handle: raster.handle.into(),
                width: raster.width,
                height: raster.height,
                byte_len: raster.byte_len,
            }),
            endpoints: value
                .endpoints
                .into_iter()
                .map(|endpoint| FlutterSelectionEndpoint {
                    offset: endpoint.offset,
                    range_start: endpoint.range_start,
                    range_end: endpoint.range_end,
                    rect: FlutterSelectionRect {
                        left: endpoint.rect.left,
                        top: endpoint.rect.top,
                        right: endpoint.rect.right,
                        bottom: endpoint.rect.bottom,
                    },
                })
                .collect(),
            grapheme_boundaries: value
                .grapheme_boundaries
                .into_iter()
                .map(|offset| offset as u32)
                .collect(),
            word_boundaries: value
                .word_boundaries
                .into_iter()
                .map(|offset| offset as u32)
                .collect(),
            visual_lines: value
                .visual_lines
                .into_iter()
                .map(|line| FlutterSelectionVisualLine {
                    carets: line
                        .carets
                        .into_iter()
                        .map(|caret| FlutterSelectionCaret {
                            offset: caret.offset,
                            x: caret.x,
                            along_line: caret.along_line,
                            vertical: caret.vertical,
                            top: caret.top,
                            bottom: caret.bottom,
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlutterBridgeErrorKind {
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

#[derive(Debug, Error)]
#[error("{message}")]
pub struct FlutterBridgeError {
    pub kind: FlutterBridgeErrorKind,
    pub message: String,
}

impl From<BridgeError> for FlutterBridgeError {
    fn from(value: BridgeError) -> Self {
        let kind = match value.kind() {
            shosai_core::bridge::BridgeErrorKind::Cancelled => FlutterBridgeErrorKind::Cancelled,
            shosai_core::bridge::BridgeErrorKind::NotFound => FlutterBridgeErrorKind::NotFound,
            shosai_core::bridge::BridgeErrorKind::Inaccessible => {
                FlutterBridgeErrorKind::Inaccessible
            }
            shosai_core::bridge::BridgeErrorKind::Unsupported => {
                FlutterBridgeErrorKind::Unsupported
            }
            shosai_core::bridge::BridgeErrorKind::InvalidRequest => {
                FlutterBridgeErrorKind::InvalidRequest
            }
            shosai_core::bridge::BridgeErrorKind::Malformed => FlutterBridgeErrorKind::Malformed,
            shosai_core::bridge::BridgeErrorKind::LimitExceeded => {
                FlutterBridgeErrorKind::LimitExceeded
            }
            shosai_core::bridge::BridgeErrorKind::BackendUnavailable => {
                FlutterBridgeErrorKind::BackendUnavailable
            }
            shosai_core::bridge::BridgeErrorKind::RenderFailed => {
                FlutterBridgeErrorKind::RenderFailed
            }
        };
        Self {
            kind,
            message: value.to_string(),
        }
    }
}

#[derive(Debug)]
pub struct FlutterBridge {
    bridge: Bridge,
    next_cancellation: AtomicU64,
    cancellations: Mutex<HashMap<u64, Cancellation>>,
}

impl Default for FlutterBridge {
    fn default() -> Self {
        Self::new()
    }
}

impl FlutterBridge {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new() -> Self {
        Self::from_bridge(Bridge::new())
    }

    /// Construct a bridge with a host-provided SQLite database path.
    #[flutter_rust_bridge::frb(sync)]
    pub fn with_database_path(database_path: String) -> Self {
        Self::from_bridge(Bridge::with_database_path(database_path.into()))
    }

    fn from_bridge(bridge: Bridge) -> Self {
        Self {
            bridge,
            next_cancellation: AtomicU64::new(1),
            cancellations: Mutex::new(HashMap::new()),
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn create_cancellation(&self) -> Result<u64, FlutterBridgeError> {
        let mut cancellations = self
            .cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if cancellations.len() >= MAX_CANCELLATIONS {
            return Err(invalid_request("too many cancellation tokens"));
        }
        let id = self.next_cancellation.fetch_add(1, Ordering::Relaxed);
        if id == 0 {
            return Err(invalid_request("cancellation token IDs are exhausted"));
        }
        cancellations.insert(id, Cancellation::new());
        Ok(id)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn cancel(&self, id: u64) -> bool {
        let cancellation = self
            .cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&id)
            .cloned();
        cancellation.is_some_and(|cancellation| {
            cancellation.cancel();
            true
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn release_cancellation(&self, id: u64) -> bool {
        self.cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&id)
            .is_some()
    }

    pub async fn open_document(
        &self,
        request: FlutterOpenRequest,
        cancellation_id: u64,
    ) -> Result<FlutterDocumentSummary, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        let summary = self
            .bridge
            .open_document(
                OpenRequest {
                    book_id: None,
                    local_id: request.local_id,
                    path_key: request.path_key,
                    format_hint: request.format_hint.map(Into::into),
                },
                cancellation,
            )
            .await?;
        Ok(FlutterDocumentSummary {
            handle: summary.handle.into(),
            book_id: summary.book_id,
            format: summary.format.into(),
            title: summary.title,
            logical_unit_count: summary.logical_unit_count,
        })
    }

    pub async fn library_page(
        &self,
        query: Option<String>,
        format: Option<FlutterBookFormat>,
        limit: u32,
        offset: u32,
        cancellation_id: u64,
    ) -> Result<FlutterLibraryPage, FlutterBridgeError> {
        self.bridge
            .library_page_cancellable(
                query,
                format.map(Into::into),
                limit,
                offset,
                self.cancellation(cancellation_id)?,
            )
            .await
            .map(|v| FlutterLibraryPage {
                books: v.books.into_iter().map(Into::into).collect(),
                has_more: v.has_more,
            })
            .map_err(Into::into)
    }

    pub async fn library_cover(
        &self,
        book_id: i64,
        cancellation_id: u64,
    ) -> Result<Option<Vec<u8>>, FlutterBridgeError> {
        self.bridge
            .library_cover(book_id, self.cancellation(cancellation_id)?)
            .await
            .map_err(Into::into)
    }

    pub async fn import_paths(
        &self,
        path_keys: Vec<String>,
        managed: bool,
        cancellation_id: u64,
    ) -> Result<Vec<FlutterImportItem>, FlutterBridgeError> {
        self.bridge
            .import_paths(path_keys, managed, self.cancellation(cancellation_id)?)
            .await
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }

    pub async fn import_directory(
        &self,
        path_key: String,
        managed: bool,
        cancellation_id: u64,
    ) -> Result<FlutterImportReport, FlutterBridgeError> {
        self.bridge
            .import_directory(path_key, managed, self.cancellation(cancellation_id)?)
            .await
            .map(Into::into)
            .map_err(Into::into)
    }

    pub async fn open_library_book(
        &self,
        book_id: i64,
        cancellation_id: u64,
    ) -> Result<FlutterDocumentSummary, FlutterBridgeError> {
        let v = self
            .bridge
            .open_library_book(book_id, self.cancellation(cancellation_id)?)
            .await?;
        Ok(FlutterDocumentSummary {
            handle: v.handle.into(),
            book_id: v.book_id,
            format: v.format.into(),
            title: v.title,
            logical_unit_count: v.logical_unit_count,
        })
    }

    pub async fn search_document(
        &self,
        document: FlutterDocumentHandle,
        query: String,
        cancellation_id: u64,
    ) -> Result<Vec<FlutterSearchMatch>, FlutterBridgeError> {
        self.bridge
            .search_document(document.into(), query, self.cancellation(cancellation_id)?)
            .await
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }

    pub async fn list_bookmarks(
        &self,
        book_id: i64,
        cancellation_id: u64,
    ) -> Result<Vec<FlutterBookmark>, FlutterBridgeError> {
        self.bridge
            .list_bookmarks_cancellable(book_id, self.cancellation(cancellation_id)?)
            .await
            .map(|v| v.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }
    pub async fn toggle_bookmark(
        &self,
        book_id: i64,
        unit: usize,
        offset: Option<usize>,
        title: Option<String>,
        note: Option<String>,
    ) -> Result<Option<FlutterBookmark>, FlutterBridgeError> {
        self.bridge
            .toggle_bookmark(book_id, unit, offset, title, note)
            .await
            .map(|v| v.map(Into::into))
            .map_err(Into::into)
    }
    pub async fn update_bookmark(
        &self,
        id: i64,
        title: Option<String>,
        note: Option<String>,
    ) -> Result<(), FlutterBridgeError> {
        self.bridge
            .update_bookmark(id, title, note)
            .await
            .map_err(Into::into)
    }
    pub async fn update_bookmark_note(
        &self,
        id: i64,
        note: Option<String>,
    ) -> Result<(), FlutterBridgeError> {
        self.bridge
            .update_bookmark_note(id, note)
            .await
            .map_err(Into::into)
    }
    pub async fn delete_bookmark(&self, id: i64) -> Result<(), FlutterBridgeError> {
        self.bridge.delete_bookmark(id).await.map_err(Into::into)
    }
    pub async fn export_bookmarks(&self, book_id: i64) -> Result<String, FlutterBridgeError> {
        self.bridge
            .export_bookmarks(book_id)
            .await
            .map_err(Into::into)
    }
    pub async fn load_reading_state(
        &self,
        book_id: i64,
        cancellation_id: u64,
    ) -> Result<Option<FlutterReadingState>, FlutterBridgeError> {
        self.bridge
            .load_reading_state_cancellable(book_id, self.cancellation(cancellation_id)?)
            .await
            .map(|v| v.map(Into::into))
            .map_err(Into::into)
    }
    pub async fn save_reading_state(
        &self,
        book_id: i64,
        value: FlutterReadingState,
        unit_count: u64,
    ) -> Result<(), FlutterBridgeError> {
        let unit_count = usize::try_from(unit_count).map_err(|_| FlutterBridgeError {
            kind: FlutterBridgeErrorKind::InvalidRequest,
            message: "unit count exceeds this platform's range".into(),
        })?;
        self.bridge
            .save_reading_state_with_unit_count(book_id, value.into(), unit_count)
            .await
            .map_err(Into::into)
    }
    pub async fn load_reader_settings(
        &self,
        cancellation_id: u64,
    ) -> Result<FlutterReaderSettings, FlutterBridgeError> {
        self.bridge
            .load_reader_settings_cancellable(self.cancellation(cancellation_id)?)
            .await
            .map(Into::into)
            .map_err(Into::into)
    }
    pub async fn save_reader_settings(
        &self,
        value: FlutterReaderSettings,
    ) -> Result<(), FlutterBridgeError> {
        self.bridge
            .save_reader_settings(value.into())
            .await
            .map_err(Into::into)
    }
    pub async fn remove_library_book(&self, book_id: i64) -> Result<bool, FlutterBridgeError> {
        self.bridge
            .remove_library_book(book_id)
            .await
            .map_err(Into::into)
    }

    pub async fn render_page(
        &self,
        document: FlutterDocumentHandle,
        page: usize,
        scale: f32,
        cancellation_id: u64,
    ) -> Result<FlutterRenderedBuffer, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        let rendered = self
            .bridge
            .render_page(
                RenderRequest {
                    document: document.into(),
                    page,
                    scale,
                },
                cancellation,
            )
            .await?;
        Ok(FlutterRenderedBuffer {
            handle: rendered.handle.into(),
            width: rendered.width,
            height: rendered.height,
            byte_len: rendered.byte_len,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn selection_surface(
        &self,
        document: FlutterDocumentHandle,
        unit: usize,
        scale: f32,
        width: f32,
        font_size: f32,
        line_spacing: f32,
        cancellation_id: u64,
    ) -> Result<FlutterSelectionSurface, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        self.bridge
            .selection_surface_with_line_spacing(
                document.into(),
                unit,
                scale,
                width,
                font_size,
                line_spacing,
                cancellation,
            )
            .await
            .map(Into::into)
            .map_err(Into::into)
    }

    /// Diagnostic round trip for measuring generated-code DTO transfer and
    /// Dart materialization independently of document layout.
    #[flutter_rust_bridge::frb(sync)]
    pub fn round_trip_visible_scene(
        &self,
        scene: FlutterSelectionSurface,
    ) -> FlutterSelectionSurface {
        scene
    }

    #[allow(clippy::too_many_arguments)] // FRB exposes these as named Dart arguments.
    pub async fn create_annotation(
        &self,
        document: FlutterDocumentHandle,
        unit: usize,
        start: usize,
        end: usize,
        display_scale: f32,
        color: FlutterHighlightColor,
        body: Option<String>,
        cancellation_id: u64,
    ) -> Result<FlutterAnnotation, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        self.bridge
            .create_annotation(
                CreateAnnotationRequest {
                    document: document.into(),
                    unit,
                    start,
                    end,
                    display_scale,
                    color: color.into(),
                    body,
                },
                cancellation,
            )
            .await
            .map(Into::into)
            .map_err(Into::into)
    }

    pub async fn list_annotations(
        &self,
        document: FlutterDocumentHandle,
        scale: f32,
        cancellation_id: u64,
    ) -> Result<Vec<FlutterAnnotation>, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        self.bridge
            .list_annotations(document.into(), scale, cancellation)
            .await
            .map(|items| items.into_iter().map(Into::into).collect())
            .map_err(Into::into)
    }

    pub async fn list_annotation_association_sources(
        &self,
        target: FlutterDocumentHandle,
        cursor: Option<String>,
        limit: usize,
        cancellation_id: u64,
    ) -> Result<FlutterAnnotationAssociationSourcePage, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        self.bridge
            .list_annotation_association_sources(
                target.into(),
                cursor.as_deref(),
                limit,
                cancellation,
            )
            .await
            .map(Into::into)
            .map_err(Into::into)
    }

    pub async fn associate_annotation_version(
        &self,
        source_version_id: String,
        target: FlutterDocumentHandle,
        cancellation_id: u64,
    ) -> Result<FlutterAnnotationAssociationOutcome, FlutterBridgeError> {
        let cancellation = self.cancellation(cancellation_id)?;
        self.bridge
            .associate_annotation_version(&source_version_id, target.into(), cancellation)
            .await
            .map(Into::into)
            .map_err(Into::into)
    }

    pub async fn update_annotation(
        &self,
        document: FlutterDocumentHandle,
        id: String,
        color: FlutterHighlightColor,
        body: Option<String>,
    ) -> Result<bool, FlutterBridgeError> {
        self.bridge
            .update_annotation(document.into(), &id, color.into(), body)
            .await
            .map_err(Into::into)
    }

    pub async fn delete_annotation(
        &self,
        document: FlutterDocumentHandle,
        id: String,
    ) -> Result<bool, FlutterBridgeError> {
        self.bridge
            .delete_annotation(document.into(), &id)
            .await
            .map_err(Into::into)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn take_buffer(&self, handle: FlutterBufferHandle) -> Result<Vec<u8>, FlutterBridgeError> {
        self.bridge.take_buffer(handle.into()).map_err(Into::into)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn release_document(&self, handle: FlutterDocumentHandle) -> bool {
        self.bridge.release_document(handle.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn release_buffer(&self, handle: FlutterBufferHandle) -> bool {
        self.bridge.release_buffer(handle.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn release_selection(&self, handle: FlutterSelectionHandle) -> bool {
        self.bridge.release_selection(handle.into())
    }

    fn cancellation(&self, id: u64) -> Result<Cancellation, FlutterBridgeError> {
        self.cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&id)
            .cloned()
            .ok_or_else(|| invalid_request("unknown or released cancellation token"))
    }
}

fn invalid_request(message: impl Into<String>) -> FlutterBridgeError {
    FlutterBridgeError {
        kind: FlutterBridgeErrorKind::InvalidRequest,
        message: message.into(),
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancellation_registry_is_bounded_and_releases_tokens() {
        let bridge = FlutterBridge::new();
        let mut ids = Vec::new();
        for _ in 0..MAX_CANCELLATIONS {
            ids.push(bridge.create_cancellation().unwrap());
        }
        assert!(bridge.create_cancellation().is_err());
        assert!(bridge.cancel(ids[0]));
        assert!(bridge.release_cancellation(ids[0]));
        assert!(!bridge.cancel(ids[0]));
        assert!(bridge.create_cancellation().is_ok());
    }
}
