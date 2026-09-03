use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use iced::advanced::widget::{Id as WidgetId, operation};
use iced::keyboard;
use iced::widget::{
    button, center, checkbox, column, container, grid, image, mouse_area, opaque, pick_list,
    responsive, row, scrollable, sensor, text_input,
};
use iced::{Element, Length, Point, Size, Subscription, Task, window};
use tokio::sync::oneshot;

use shosai_core::application::{DeviceFileLocator, OpenDocument, OpenDocumentError};
use shosai_core::bookmarks::{Bookmark, BookmarkStore};
use shosai_core::cbz::CbzDoc;
use shosai_core::document::{Document, RenderedPage};
use shosai_core::epub::EpubDoc;
use shosai_core::library::{
    Book, BookPage, ImportCancellation, ImportCandidate, ImportDiscoveryProgress,
    ImportDiscoveryProgressSnapshot, ImportDuplicate, ImportFailure, ImportReport, Library,
    ManagedPathChange, ManagedStorageSummary, PreparedManagedImport,
};
use shosai_core::path_from_key;
use shosai_core::reader::{
    BoundedCache, CacheBudget, CachePermit, ReaderLocation, ReaderPreferences, ReaderSession,
    ReadingMode, nearby_chapters, prioritized_pages,
};
use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
use shosai_core::search::{SearchCancellation, SearchError, SearchLimits, SearchMatch};
use shosai_core::state_writer::{
    StateSave as ReadingStateSave, StateWriter, StateWriterMessage as ReadingStateWriterMessage,
    StateWriterSendError, start_state_writer as start_reading_state_writer,
};

#[cfg(test)]
use crate::epub::PageNode as EpubPageNode;
use crate::epub::{
    BLOCKQUOTE_SPACING as EPUB_BLOCKQUOTE_SPACING, EPUB_TABLE_CELL_PADDING,
    EPUB_TABLE_CELL_SPACING, EPUB_TABLE_ROW_SPACING, EpubPaginationBudget,
    PAGE_NUMBER_SIZE as EPUB_PAGE_NUMBER_SIZE, Page as EpubPage, content_node_text_len,
    content_starts_with_heading,
};
use crate::i18n::{I18n, LanguagePreference};
use crate::pdf::ZoomMode;
use crate::theme::ReaderTheme;
use crate::{theme as app_theme, typography, widgets};
#[cfg(test)]
use shosai_core::pdf::PdfDoc;

mod dispatch;
mod epub_navigation;
mod epub_view;
mod message;
mod perf;

pub use dispatch::update;
use epub_navigation::*;
use epub_view::{
    continuous_epub_content_view, decode_epub_images, epub_chapter_view, epub_image_byte_len,
    epub_image_paths, epub_image_transient_byte_len,
};
pub use message::Message;

fn text<'a>(value: impl iced::widget::text::IntoFragment<'a>) -> iced::widget::Text<'a> {
    let fragment = value.into_fragment();
    let font = typography::font_for_text(fragment.as_ref());
    iced::widget::text(fragment).font(font)
}

fn editable_text_font(value: &str, placeholder: &str) -> iced::Font {
    typography::font_for_text(if value.is_empty() { placeholder } else { value })
}

fn language_menu_font() -> iced::Font {
    typography::NOTO_SANS_JP
}

const LANGUAGE_PREFERENCE_KEY: &str = "language";
const ADD_BOOK_BEHAVIOR_KEY: &str = "library.add_behavior";
const DEFAULT_READING_MODE_KEY: &str = "reader.default_mode";
const DEFAULT_READER_THEME_KEY: &str = "reader.default_theme";
const DEFAULT_EPUB_FONT_SIZE_KEY: &str = "reader.default_epub_font_size";
const DEFAULT_EPUB_LINE_SPACING_KEY: &str = "reader.default_epub_line_spacing";
const DEFAULT_PDF_ZOOM_KEY: &str = "reader.default_pdf_zoom";
const MANAGED_IMPORT_PREPARATION_CONCURRENCY: usize = 4;
const REVIEW_GROUP_ROW_HEIGHT: f32 = 28.0;
const REVIEW_BOOK_ROW_HEIGHT: f32 = 58.0;
const REVIEW_VIRTUAL_OVERSCAN: f32 = 180.0;
const REVIEW_DEFAULT_VIEWPORT_HEIGHT: f32 = 420.0;

#[derive(Debug, Clone, PartialEq, Eq)]
struct SelectOption<T> {
    value: T,
    label: String,
}

impl<T> std::fmt::Display for SelectOption<T> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.label)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AppError {
    Storage(String),
    Open {
        format: &'static str,
        detail: String,
    },
    UnsupportedFormat(String),
    Render(String),
    EpubEmpty,
    MissingBook,
    Library(String),
    Import(String),
}

impl AppError {
    fn localized(&self, i18n: &I18n) -> String {
        match self {
            Self::Storage(detail) => {
                i18n.text_with_args("failed-storage", [("error", detail.clone().into())])
            }
            Self::Open { format, detail } => i18n.text_with_args(
                "failed-open",
                [
                    ("format", (*format).into()),
                    ("error", detail.clone().into()),
                ],
            ),
            Self::UnsupportedFormat(extension) => i18n.text_with_args(
                "unsupported-format",
                [("extension", extension.clone().into())],
            ),
            Self::Render(detail) => {
                i18n.text_with_args("failed-render", [("error", detail.clone().into())])
            }
            Self::EpubEmpty => i18n.text("epub-empty"),
            Self::MissingBook => i18n.text("missing-book"),
            Self::Library(detail) => {
                i18n.text_with_args("library-error", [("error", detail.clone().into())])
            }
            Self::Import(detail) => detail.clone(),
        }
    }

    fn diagnostic(&self) -> String {
        match self {
            Self::Storage(detail) => format!("failed to initialize storage: {detail}"),
            Self::Open { format, detail } => format!("failed to open {format}: {detail}"),
            Self::UnsupportedFormat(extension) => {
                format!("unsupported file format: .{extension}")
            }
            Self::Render(detail) => format!("failed to render page: {detail}"),
            Self::EpubEmpty => "EPUB contains no readable content".to_string(),
            Self::MissingBook => "book file is missing".to_string(),
            Self::Library(detail) => format!("library operation failed: {detail}"),
            Self::Import(detail) => format!("book import incomplete: {detail}"),
        }
    }
}

fn import_report_error(report: &ImportReport, i18n: &I18n) -> Option<AppError> {
    let first = report.failures.first()?;
    let file = first
        .path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| first.path.display().to_string());
    let key = if report.books.is_empty() {
        "books-import-failed"
    } else {
        "books-import-partial"
    };
    Some(AppError::Import(i18n.text_with_args(
        key,
        [
            ("added", (report.books.len() as i64).into()),
            ("failed", (report.failures.len() as i64).into()),
            ("file", file.into()),
            ("error", first.error.clone().into()),
        ],
    )))
}

#[derive(Clone)]
pub(crate) struct RasterImageHandle(image::Handle);

impl std::fmt::Debug for RasterImageHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_tuple("RasterImageHandle")
            .field(&self.0.id())
            .finish()
    }
}

#[derive(Clone)]
enum EpubImageHandle {
    Raster(image::Handle),
    Svg {
        handle: iced::widget::svg::Handle,
        _permit: CachePermit,
    },
}

#[derive(Debug, Clone)]
pub(crate) enum DecodedEpubImage {
    Raster {
        width: u32,
        height: u32,
        pixels: Vec<u8>,
        permit: CachePermit,
    },
    Svg {
        data: Vec<u8>,
        permit: CachePermit,
    },
}

impl DecodedEpubImage {
    fn into_handle(self) -> EpubImageHandle {
        match self {
            Self::Raster {
                width,
                height,
                pixels,
                permit,
            } => EpubImageHandle::Raster(image::Handle::from_rgba(
                width,
                height,
                bytes::Bytes::from_owner(PermittedPixels {
                    pixels: pixels.into(),
                    _permit: permit,
                }),
            )),
            Self::Svg { data, permit } => EpubImageHandle::Svg {
                handle: iced::widget::svg::Handle::from_memory(data),
                _permit: permit,
            },
        }
    }
}

impl std::fmt::Debug for EpubImageHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_tuple("EpubImageHandle")
            .field(&match self {
                Self::Raster(handle) => format!("raster:{:?}", handle.id()),
                Self::Svg { .. } => "svg".to_owned(),
            })
            .finish()
    }
}

#[cfg(test)]
impl EpubImageHandle {
    fn raster_id(&self) -> iced::advanced::image::Id {
        let Self::Raster(handle) = self else {
            panic!("expected raster handle")
        };
        handle.id()
    }
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
enum Screen {
    Library,
    Reader,
    Settings,
}

#[derive(Debug, Clone)]
enum AddBooksSource {
    Files(Vec<PathBuf>),
    Folder(PathBuf),
}

#[derive(Debug, Clone)]
struct StagedImport {
    candidate: ImportCandidate,
    selected: bool,
}

#[derive(Debug, Clone)]
enum AddBooksReviewRow {
    Group(String),
    Book(usize),
}

impl AddBooksReviewRow {
    fn height(&self) -> f32 {
        match self {
            Self::Group(_) => REVIEW_GROUP_ROW_HEIGHT,
            Self::Book(_) => REVIEW_BOOK_ROW_HEIGHT,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum AddBookBehavior {
    #[default]
    Ask,
    Copy,
    CurrentLocation,
}

impl AddBookBehavior {
    fn from_stored(value: Option<&str>) -> Self {
        match value {
            Some("copy") => Self::Copy,
            Some("current-location") => Self::CurrentLocation,
            _ => Self::Ask,
        }
    }

    fn stored(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Copy => "copy",
            Self::CurrentLocation => "current-location",
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct ReaderDefaults {
    reading_mode: ReadingMode,
    theme: ReaderTheme,
    epub_font_size: f32,
    epub_line_spacing: f32,
    pdf_zoom: ZoomMode,
}

impl Default for ReaderDefaults {
    fn default() -> Self {
        Self {
            reading_mode: ReadingMode::Paginated,
            theme: ReaderTheme::Light,
            epub_font_size: 16.0,
            epub_line_spacing: 1.6,
            pdf_zoom: ZoomMode::FitPage,
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct ReaderOverrides {
    reading_mode: bool,
    theme: bool,
    epub_font_size: bool,
    pdf_zoom: bool,
}

#[derive(Debug, Clone)]
struct LibraryMovePlan {
    destination: PathBuf,
    summary: ManagedStorageSummary,
}

const LIBRARY_PAGE_SIZE: u32 = 40;
const LIBRARY_LOAD_AHEAD_PX: u32 = 600;
const LIBRARY_COVER_MAX_WIDTH: u32 = 440;
const LIBRARY_COVER_MAX_HEIGHT: u32 = 420;
const SEARCH_DEBOUNCE: std::time::Duration = std::time::Duration::from_millis(200);
const DOCUMENT_OPEN_NOTICE_DELAY: std::time::Duration = std::time::Duration::from_millis(200);
const LIBRARY_ACTIVITY_TICK: std::time::Duration = std::time::Duration::from_millis(16);
const LIBRARY_ACTIVITY_STEP: f32 = 16.0 / 300.0;
const LIBRARY_ACTIVITY_FADE_STEP: f32 = 16.0 / 300.0;
const PAGE_CACHE_CAPACITY: usize = 8;
const PAGE_CACHE_BYTE_CAPACITY: usize = 128 * 1024 * 1024;
const EPUB_IMAGE_BYTE_CAPACITY: usize = 128 * 1024 * 1024;
const EPUB_IMAGE_WORKERS: usize = 1;
// Source, decode, and resized output share one process budget; worst-case jobs
// serialize when two cannot fit together.
const TRANSIENT_DECODE_BYTE_CAPACITY: usize = 320 * 1024 * 1024;
const CONTINUOUS_PAGE_CACHE_CAPACITY: usize = 8;
const CONTINUOUS_RASTER_BYTE_CAPACITY: usize = 128 * 1024 * 1024;
const RASTER_RENDER_WORKERS: usize = 2;
const CBZ_DIMENSION_WORKERS: usize = 1;
const RETAINED_DOCUMENT_COUNT_CAPACITY: usize = 16;
const RETAINED_DOCUMENT_BYTE_CAPACITY: usize = 3 * 1024 * 1024 * 1024;
const DOCUMENT_OPEN_WORKERS: usize = 2;
const SEARCH_WORKERS: usize = 2;
const PDF_MIN_RASTER_DENSITY: f32 = 2.0;
const MIN_TWO_PAGE_WIDTH: f32 = 720.0;
const READER_HORIZONTAL_PADDING: f32 = 112.0;
const READER_VERTICAL_CHROME: f32 = 148.0;
const READER_SEARCH_HEIGHT: f32 = 52.0;
const COMPACT_READER_SEARCH_HEIGHT: f32 = 88.0;
const READER_MORE_HEIGHT: f32 = 58.0;
const COMPACT_READER_MORE_HEIGHT: f32 = 84.0;
const PAGE_GUTTER: f32 = 20.0;
const BOOKMARKS_PANEL_WIDTH: f32 = 300.0;
const WINDOW_WIDTH_KEY: &str = "window.width";
const WINDOW_HEIGHT_KEY: &str = "window.height";
const WINDOW_X_KEY: &str = "window.x";
const WINDOW_Y_KEY: &str = "window.y";

fn continuous_item_id(tab_id: u64, activation: u64, index: usize) -> WidgetId {
    WidgetId::from(format!(
        "continuous-reader-{tab_id}-{activation}-item-{index}"
    ))
}

fn continuous_epub_title_id(tab_id: u64, activation: u64, chapter: usize) -> WidgetId {
    WidgetId::from(format!(
        "continuous-reader-{tab_id}-{activation}-chapter-{chapter}-title"
    ))
}

fn continuous_epub_node_id(tab_id: u64, activation: u64, chapter: usize, node: usize) -> WidgetId {
    WidgetId::from(format!(
        "continuous-reader-{tab_id}-{activation}-chapter-{chapter}-node-{node}"
    ))
}

#[derive(Debug, Clone)]
struct ContinuousMeasuredItem {
    id: WidgetId,
    page: usize,
    start: usize,
    end: usize,
}

#[derive(Debug)]
struct ContinuousMeasurementIndex {
    tab_id: u64,
    activation: u64,
    items: Vec<ContinuousMeasuredItem>,
    item_indexes: HashMap<WidgetId, usize>,
}

impl ContinuousMeasurementIndex {
    fn new(tab_id: u64, activation: u64, items: Vec<ContinuousMeasuredItem>) -> Self {
        let item_indexes = items
            .iter()
            .enumerate()
            .map(|(index, item)| (item.id.clone(), index))
            .collect();
        Self {
            tab_id,
            activation,
            items,
            item_indexes,
        }
    }
}

struct ContinuousItemOperation {
    index: Arc<ContinuousMeasurementIndex>,
    scroll_id: WidgetId,
    item_bounds: Vec<Option<iced::Rectangle>>,
    content_top: Option<f32>,
    content_height: Option<f32>,
    viewport_height: Option<f32>,
    current_tail_extent: f32,
    requested_offset: Option<f32>,
    target: Option<(usize, usize)>,
}

impl ContinuousItemOperation {
    fn resolve(index: Arc<ContinuousMeasurementIndex>, scroll_id: WidgetId, offset: f32) -> Self {
        let item_count = index.items.len();
        Self {
            index,
            scroll_id,
            item_bounds: vec![None; item_count],
            content_top: None,
            content_height: None,
            viewport_height: None,
            current_tail_extent: 0.0,
            requested_offset: Some(offset),
            target: None,
        }
    }

    fn locate(
        index: Arc<ContinuousMeasurementIndex>,
        scroll_id: WidgetId,
        target: (usize, usize),
        current_tail_extent: f32,
    ) -> Self {
        let item_count = index.items.len();
        Self {
            index,
            scroll_id,
            item_bounds: vec![None; item_count],
            content_top: None,
            content_height: None,
            viewport_height: None,
            current_tail_extent,
            requested_offset: None,
            target: Some(target),
        }
    }
}

impl operation::Operation<(usize, usize, f32, f32)> for ContinuousItemOperation {
    fn traverse(
        &mut self,
        operate: &mut dyn FnMut(&mut dyn operation::Operation<(usize, usize, f32, f32)>),
    ) {
        operate(self);
    }

    fn container(&mut self, id: Option<&WidgetId>, bounds: iced::Rectangle) {
        if let Some(index) = id.and_then(|id| self.index.item_indexes.get(id)).copied() {
            self.item_bounds[index] = Some(bounds);
        }
    }

    fn scrollable(
        &mut self,
        id: Option<&WidgetId>,
        bounds: iced::Rectangle,
        content_bounds: iced::Rectangle,
        _translation: iced::Vector,
        _state: &mut dyn operation::Scrollable,
    ) {
        if id == Some(&self.scroll_id) {
            self.content_top = Some(content_bounds.y);
            self.content_height = Some(content_bounds.height);
            self.viewport_height = Some(bounds.height);
        }
    }

    fn finish(&self) -> operation::Outcome<(usize, usize, f32, f32)> {
        let Some(content_top) = self.content_top else {
            return operation::Outcome::None;
        };
        if let Some((target_page, target_offset)) = self.target {
            let measured = || {
                self.index
                    .items
                    .iter()
                    .zip(&self.item_bounds)
                    .filter_map(|(item, bounds)| bounds.map(|bounds| (item, bounds)))
                    .filter(|(item, _)| item.page == target_page)
            };
            let target = if target_offset == 0 {
                measured()
                    .find(|(item, _)| item.start == 0 && item.end == 0)
                    .or_else(|| measured().find(|(item, _)| item.start == 0))
            } else {
                measured().rfind(|(item, _)| item.start <= target_offset)
            };
            if let Some((item, bounds)) = target {
                let progress = if item.end > item.start {
                    (target_offset.min(item.end) - item.start) as f32
                        / (item.end - item.start) as f32
                } else {
                    0.0
                };
                let offset = (bounds.y + bounds.height * progress - content_top).max(0.0);
                let tail_extent = self
                    .content_height
                    .zip(self.viewport_height)
                    .map(|(content_height, viewport_height)| {
                        (offset + viewport_height - (content_height - self.current_tail_extent))
                            .max(0.0)
                    })
                    .unwrap_or(0.0);
                return operation::Outcome::Some((target_page, target_offset, offset, tail_extent));
            }
        }
        let Some(offset) = self.requested_offset else {
            return operation::Outcome::None;
        };
        let viewport_y = content_top + offset;
        let measured = || {
            self.index
                .items
                .iter()
                .zip(&self.item_bounds)
                .filter_map(|(item, bounds)| bounds.map(|bounds| (item, bounds)))
        };
        let Some((item, bounds)) = measured()
            .rfind(|(_, bounds)| bounds.y <= viewport_y + 1.0)
            .or_else(|| measured().next())
        else {
            return operation::Outcome::None;
        };
        let progress = if bounds.height > 0.0 && item.end > item.start {
            ((viewport_y - bounds.y) / bounds.height).clamp(0.0, 1.0)
        } else {
            0.0
        };
        let resolved_offset =
            item.start + ((item.end - item.start) as f32 * progress).round() as usize;
        operation::Outcome::Some((item.page, resolved_offset.min(item.end), offset, 0.0))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct EpubLayoutKey {
    width: u32,
    height: u32,
    font_size: u32,
    line_spacing: u32,
}

impl EpubLayoutKey {
    fn new(page_size: Size, font_size: f32, line_spacing: f32) -> Self {
        Self {
            width: page_size.width.to_bits(),
            height: page_size.height.to_bits(),
            font_size: font_size.to_bits(),
            line_spacing: line_spacing.to_bits(),
        }
    }
}

#[derive(Debug, Clone)]
struct ReaderTab {
    id: u64,
    session: ReaderSession,
    display_title: String,
    total_pages: usize,
    rendered_page: Option<RenderedPage>,
    rendered_page_index: Option<usize>,
    rendered_page_handle: Option<RasterImageHandle>,
    rendered_facing_page: Option<(usize, RenderedPage)>,
    rendered_facing_page_handle: Option<RasterImageHandle>,
    page_cache: BoundedCache<PageCacheKey, RenderedPage>,
    paginated_pending: Vec<PageCacheKey>,
    paginated_requested: Vec<PageCacheKey>,
    epub_image_handles: HashMap<String, EpubImageHandle>,
    epub_images_pending: HashSet<String>,
    epub_images_desired: HashSet<String>,
    epub_images_failed: HashSet<String>,
    epub_image_decode_active: bool,
    epub_image_generation: u64,
    epub_pages: Arc<Vec<EpubPage>>,
    epub_layout_key: Option<EpubLayoutKey>,
    epub_layout_pending: Option<EpubLayoutKey>,
    epub_layout_requested: Option<EpubLayoutKey>,
    epub_page: usize,
    continuous_pages: Vec<Option<RenderedPage>>,
    continuous_pending: BTreeMap<usize, ContinuousRequest>,
    continuous_visible: BTreeSet<usize>,
    continuous_tail_extent: f32,
    render_generation: u64,
    page_input: String,
    error: Option<AppError>,
    theme: ReaderTheme,
    reader_overrides: ReaderOverrides,
    bookmarks: Vec<Bookmark>,
    show_bookmarks_panel: bool,
    show_reader_settings: bool,
    show_reader_more: bool,
    current_page_bookmarked: bool,
    editing_note_id: Option<i64>,
    editing_note_text: String,
    show_search_bar: bool,
    search_query: String,
    search_results: Vec<SearchMatch>,
    search_current: usize,
    document_permit: RetainedDocumentPermit,
}

#[derive(Debug, Clone)]
struct RetainedDocumentPermit {
    _count: CachePermit,
    _bytes: CachePermit,
    open_worker: Option<CachePermit>,
}

fn retain_document_for_worker(state: &State) -> RetainedDocumentPermit {
    state
        .document_permit
        .clone()
        .expect("an open document must retain its admission permit")
}

#[derive(Debug, Clone)]
struct DocumentAdmission {
    count: CacheBudget,
    bytes: CacheBudget,
    open_workers: CacheBudget,
}

impl DocumentAdmission {
    fn new(count: usize, bytes: usize, open_workers: usize) -> Self {
        Self {
            count: CacheBudget::new(count),
            bytes: CacheBudget::new(bytes),
            open_workers: CacheBudget::new(open_workers),
        }
    }
}

impl Default for DocumentAdmission {
    fn default() -> Self {
        Self::new(
            RETAINED_DOCUMENT_COUNT_CAPACITY,
            RETAINED_DOCUMENT_BYTE_CAPACITY,
            DOCUMENT_OPEN_WORKERS,
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ContinuousRequest {
    id: u64,
    generation: u64,
    byte_len: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum RasterJob {
    Paginated {
        tab_id: u64,
        generation: u64,
        key: PageCacheKey,
    },
    Continuous {
        tab_id: u64,
        request: ContinuousRequest,
        page: usize,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum RasterFailure {
    Paginated {
        tab_id: u64,
        key: PageCacheKey,
    },
    Continuous {
        tab_id: u64,
        page: usize,
        byte_len: usize,
    },
}

impl RasterJob {
    fn failure(&self) -> RasterFailure {
        match self {
            Self::Paginated { tab_id, key, .. } => RasterFailure::Paginated {
                tab_id: *tab_id,
                key: key.clone(),
            },
            Self::Continuous {
                tab_id,
                request,
                page,
            } => RasterFailure::Continuous {
                tab_id: *tab_id,
                page: *page,
                byte_len: request.byte_len,
            },
        }
    }
}

struct PermittedPixels {
    pixels: bytes::Bytes,
    _permit: CachePermit,
}

impl AsRef<[u8]> for PermittedPixels {
    fn as_ref(&self) -> &[u8] {
        &self.pixels
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct EpubJob {
    tab_id: u64,
    generation: u64,
    layout_key: EpubLayoutKey,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct CbzDimensionJob {
    tab_id: u64,
    generation: u64,
    page: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct EpubImageJob {
    tab_id: u64,
    generation: u64,
    path: String,
}

#[derive(Debug, Clone)]
pub struct InitializedState {
    store: ReadingStateStore,
    window_geometry: Option<(Size, Point)>,
    language_preference: LanguagePreference,
    managed_books_dir: PathBuf,
    add_book_behavior: AddBookBehavior,
    reader_defaults: ReaderDefaults,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct PageCacheKey {
    page: usize,
    scale_bits: u32,
    highlights: Vec<(usize, usize, bool)>,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct DocumentOpenPreview {
    title: String,
    cover: Option<RasterImageHandle>,
}

#[derive(Debug)]
pub struct State {
    screen: Screen,
    i18n: I18n,

    // -- Reader state --
    book_id: Option<i64>,
    display_title: Option<String>,
    file_path: Option<PathBuf>,
    document: Option<OpenDocument>,
    document_permit: Option<RetainedDocumentPermit>,
    pending_document_permits: HashMap<u64, RetainedDocumentPermit>,
    current_page: usize,
    total_pages: usize,
    zoom: ZoomMode,
    rendered_page: Option<RenderedPage>,
    rendered_page_index: Option<usize>,
    rendered_page_handle: Option<RasterImageHandle>,
    rendered_facing_page: Option<(usize, RenderedPage)>,
    rendered_facing_page_handle: Option<RasterImageHandle>,
    page_cache: BoundedCache<PageCacheKey, RenderedPage>,
    paginated_pending: Vec<PageCacheKey>,
    paginated_requested: Vec<PageCacheKey>,
    render_generation: u64,
    epub_image_handles: HashMap<String, EpubImageHandle>,
    epub_images_pending: HashSet<String>,
    epub_images_desired: HashSet<String>,
    epub_images_failed: HashSet<String>,
    epub_image_decode_active: bool,
    epub_image_generation: u64,
    epub_image_budget: CacheBudget,
    transient_decode_budget: CacheBudget,
    epub_image_jobs: HashSet<EpubImageJob>,
    epub_pages: Arc<Vec<EpubPage>>,
    epub_layout_key: Option<EpubLayoutKey>,
    epub_layout_pending: Option<EpubLayoutKey>,
    epub_layout_requested: Option<EpubLayoutKey>,
    epub_page: usize,
    epub_offset: usize,
    continuous_pages: Vec<Option<RenderedPage>>,
    continuous_pending: BTreeMap<usize, ContinuousRequest>,
    continuous_visible: BTreeSet<usize>,
    continuous_tail_extent: f32,
    continuous_activation: u64,
    continuous_measurement_index: Option<Arc<ContinuousMeasurementIndex>>,
    next_continuous_request_id: u64,
    raster_budget: CacheBudget,
    raster_jobs: HashMap<RasterJob, CachePermit>,
    raster_failures: HashSet<RasterFailure>,
    cbz_dimension_jobs: HashMap<CbzDimensionJob, CachePermit>,
    cbz_dimension_failures: HashSet<CbzDimensionJob>,
    epub_jobs: HashSet<EpubJob>,
    page_input: String,
    error: Option<AppError>,
    font_size: f32,
    line_spacing: f32,
    theme: ReaderTheme,
    reading_mode: ReadingMode,
    reader_overrides: ReaderOverrides,
    tabs: Vec<ReaderTab>,
    active_tab: Option<usize>,
    active_tab_id: Option<u64>,
    next_tab_id: u64,
    open_error: Option<AppError>,
    document_open_generation: u64,
    document_opening: bool,
    document_open_notice_visible: bool,
    document_open_preview: Option<DocumentOpenPreview>,
    missing_book_id: Option<i64>,
    document_admission: DocumentAdmission,
    show_reader_settings: bool,
    show_reader_more: bool,

    // -- Shared --
    reading_state: Option<ReadingStateStore>,
    reading_state_saves: Option<StateWriter>,
    library: Option<Library>,
    bookmark_store: Option<BookmarkStore>,

    // -- Bookmarks --
    bookmarks: Vec<Bookmark>,
    show_bookmarks_panel: bool,
    current_page_bookmarked: bool,
    editing_note_id: Option<i64>,
    editing_note_text: String,

    // -- In-document search --
    show_search_bar: bool,
    search_query: String,
    search_results: Vec<SearchMatch>,
    search_current: usize, // index into search_results
    search_loading: bool,
    search_waiting: bool,
    search_cancellation: Option<SearchCancellation>,
    search_admission: CacheBudget,
    search_document_generation: u64,
    search_query_generation: u64,

    // -- Library state --
    library_books: Vec<Book>,
    library_cover_handles: HashMap<i64, RasterImageHandle>,
    library_search: String,
    library_search_pending: bool,
    library_filter: Option<shosai_core::library::BookFormat>,
    library_has_more: bool,
    library_loading: bool,
    library_activity_progress: f32,
    library_activity_opacity: f32,
    library_generation: u64,
    library_offset: usize,
    book_menu: Option<i64>,
    pending_remove_book: Option<i64>,
    removing_book: Option<i64>,
    add_books_open: bool,
    add_books_source: Option<AddBooksSource>,
    add_books_discovering: bool,
    add_books_generation: u64,
    add_books_cancellation: Option<ImportCancellation>,
    add_books_progress: Option<ImportDiscoveryProgress>,
    staged_imports: Vec<StagedImport>,
    add_books_review_search: String,
    add_books_review_rows: Vec<AddBooksReviewRow>,
    add_books_review_revision: u64,
    add_books_review_offset: f32,
    add_books_review_viewport_height: f32,
    import_discovery_failures: Vec<ImportFailure>,
    add_books_copy: Option<bool>,
    adding_books: bool,
    pending_book_imports: VecDeque<(usize, ImportCandidate)>,
    prepared_book_imports:
        BTreeMap<usize, Result<(PathBuf, Arc<PreparedManagedImport>), ImportFailure>>,
    book_import_preparing: usize,
    book_import_next_commit: usize,
    book_import_committing: bool,
    book_import_copy: bool,
    book_import_prepared: usize,
    book_import_completed: usize,
    book_import_total: usize,
    book_import_report: ImportReport,
    library_error: Option<AppError>,

    // -- Settings state --
    add_book_behavior: AddBookBehavior,
    reader_defaults: ReaderDefaults,
    pending_library_move: Option<LibraryMovePlan>,
    moving_library: bool,
    settings_error: Option<String>,
    storage_initializing: bool,
    storage_error: Option<AppError>,
    pending_open: Option<PathBuf>,
    window_id: Option<window::Id>,
    window_size: Size,
    window_scale_factor: f32,
    window_scale_generation: u64,
    window_position: Option<Point>,
    saved_window_geometry: Option<(Size, Point)>,
    window_geometry_generation: u64,
    window_geometry_dirty: bool,
    window_geometry_saving: bool,
    close_after_geometry_save: Option<window::Id>,
    performance: perf::Performance,
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

pub fn boot() -> (State, Task<Message>) {
    let (performance, performance_file) = perf::Performance::from_environment();
    let state = State {
        screen: Screen::Library,
        i18n: I18n::new(LanguagePreference::System),

        book_id: None,
        display_title: None,
        file_path: None,
        document: None,
        document_permit: None,
        pending_document_permits: HashMap::new(),
        current_page: 0,
        total_pages: 0,
        zoom: ZoomMode::default(),
        rendered_page: None,
        rendered_page_index: None,
        rendered_page_handle: None,
        rendered_facing_page: None,
        rendered_facing_page_handle: None,
        page_cache: BoundedCache::new(PAGE_CACHE_CAPACITY),
        paginated_pending: Vec::new(),
        paginated_requested: Vec::new(),
        render_generation: 0,
        epub_image_handles: HashMap::new(),
        epub_images_pending: HashSet::new(),
        epub_images_desired: HashSet::new(),
        epub_images_failed: HashSet::new(),
        epub_image_decode_active: false,
        epub_image_generation: 0,
        epub_image_budget: CacheBudget::new(EPUB_IMAGE_BYTE_CAPACITY),
        transient_decode_budget: CacheBudget::new(TRANSIENT_DECODE_BYTE_CAPACITY),
        epub_image_jobs: HashSet::new(),
        epub_pages: Arc::new(Vec::new()),
        epub_layout_key: None,
        epub_layout_pending: None,
        epub_layout_requested: None,
        epub_page: 0,
        epub_offset: 0,
        continuous_pages: Vec::new(),
        continuous_pending: BTreeMap::new(),
        continuous_visible: BTreeSet::new(),
        continuous_tail_extent: 0.0,
        continuous_activation: 0,
        continuous_measurement_index: None,
        next_continuous_request_id: 1,
        raster_budget: CacheBudget::new(PAGE_CACHE_BYTE_CAPACITY),
        raster_jobs: HashMap::new(),
        raster_failures: HashSet::new(),
        cbz_dimension_jobs: HashMap::new(),
        cbz_dimension_failures: HashSet::new(),
        epub_jobs: HashSet::new(),
        page_input: String::new(),
        error: None,
        font_size: 16.0,
        line_spacing: 1.6,
        theme: ReaderTheme::default(),
        reading_mode: ReadingMode::default(),
        reader_overrides: ReaderOverrides::default(),
        tabs: Vec::new(),
        active_tab: None,
        active_tab_id: None,
        next_tab_id: 1,
        open_error: None,
        document_open_generation: 0,
        document_opening: false,
        document_open_notice_visible: false,
        document_open_preview: None,
        missing_book_id: None,
        document_admission: DocumentAdmission::default(),
        show_reader_settings: false,
        show_reader_more: false,

        bookmark_store: None,

        reading_state: None,
        reading_state_saves: None,
        library: None,

        bookmarks: Vec::new(),
        show_bookmarks_panel: false,
        current_page_bookmarked: false,
        editing_note_id: None,
        editing_note_text: String::new(),

        show_search_bar: false,
        search_query: String::new(),
        search_results: Vec::new(),
        search_current: 0,
        search_loading: false,
        search_waiting: false,
        search_cancellation: None,
        search_admission: CacheBudget::new(SEARCH_WORKERS),
        search_document_generation: 0,
        search_query_generation: 0,

        library_books: Vec::new(),
        library_cover_handles: HashMap::new(),
        library_search: String::new(),
        library_search_pending: false,
        library_filter: None,
        library_has_more: false,
        library_loading: true,
        library_activity_progress: 0.0,
        library_activity_opacity: 1.0,
        library_generation: 0,
        library_offset: 0,
        book_menu: None,
        pending_remove_book: None,
        removing_book: None,
        add_books_open: false,
        add_books_source: None,
        add_books_discovering: false,
        add_books_generation: 0,
        add_books_cancellation: None,
        add_books_progress: None,
        staged_imports: Vec::new(),
        add_books_review_search: String::new(),
        add_books_review_rows: Vec::new(),
        add_books_review_revision: 0,
        add_books_review_offset: 0.0,
        add_books_review_viewport_height: REVIEW_DEFAULT_VIEWPORT_HEIGHT,
        import_discovery_failures: Vec::new(),
        add_books_copy: None,
        adding_books: false,
        pending_book_imports: VecDeque::new(),
        prepared_book_imports: BTreeMap::new(),
        book_import_preparing: 0,
        book_import_next_commit: 0,
        book_import_committing: false,
        book_import_copy: false,
        book_import_prepared: 0,
        book_import_completed: 0,
        book_import_total: 0,
        book_import_report: ImportReport::default(),
        library_error: None,
        add_book_behavior: AddBookBehavior::default(),
        reader_defaults: ReaderDefaults::default(),
        pending_library_move: None,
        moving_library: false,
        settings_error: None,
        storage_initializing: true,
        storage_error: None,
        pending_open: performance_file,
        window_id: None,
        window_size: Size::new(900.0, 700.0),
        window_scale_factor: 1.0,
        window_scale_generation: 0,
        window_position: None,
        saved_window_geometry: None,
        window_geometry_generation: 0,
        window_geometry_dirty: false,
        window_geometry_saving: false,
        close_after_geometry_save: None,
        performance,
    };
    let initialize = Task::perform(
        async {
            let started = std::time::Instant::now();
            let store = ReadingStateStore::open_async_deferred_backfill()
                .await
                .map_err(|error| error.to_string())?;
            let preferences = store.get_prefs_async().await;
            let pref_int = |key: &str| {
                preferences
                    .get(key)
                    .and_then(|value| value.parse::<i64>().ok())
            };
            let geometry = match (
                pref_int(WINDOW_WIDTH_KEY),
                pref_int(WINDOW_HEIGHT_KEY),
                pref_int(WINDOW_X_KEY),
                pref_int(WINDOW_Y_KEY),
            ) {
                (Some(width), Some(height), Some(x), Some(y)) if width >= 480 && height >= 360 => {
                    Some((
                        Size::new(width as f32, height as f32),
                        Point::new(x as f32, y as f32),
                    ))
                }
                _ => None,
            };
            let language_preference = LanguagePreference::from_stored(
                preferences.get(LANGUAGE_PREFERENCE_KEY).map(String::as_str),
            );
            let managed_books_dir = preferences
                .get(shosai_core::library::MANAGED_LIBRARY_DIR_PREFERENCE)
                .map(|path| path_from_key(path))
                .unwrap_or_else(|| store.managed_books_dir());
            if managed_books_dir != store.managed_books_dir() {
                shosai_core::reading_state::validate_managed_library_directory(&managed_books_dir)
                    .map_err(|error| error.to_string())?;
            }
            let add_book_behavior = AddBookBehavior::from_stored(
                preferences.get(ADD_BOOK_BEHAVIOR_KEY).map(String::as_str),
            );
            let reader_defaults = ReaderDefaults {
                reading_mode: ReadingMode::from_stored(
                    preferences
                        .get(DEFAULT_READING_MODE_KEY)
                        .map(String::as_str),
                ),
                theme: ReaderTheme::from_stored(
                    preferences
                        .get(DEFAULT_READER_THEME_KEY)
                        .map(String::as_str),
                ),
                epub_font_size: stored_f32(
                    preferences.get(DEFAULT_EPUB_FONT_SIZE_KEY).cloned(),
                    16.0,
                    8.0..=48.0,
                ),
                epub_line_spacing: stored_f32(
                    preferences.get(DEFAULT_EPUB_LINE_SPACING_KEY).cloned(),
                    1.6,
                    1.0..=2.4,
                ),
                pdf_zoom: match preferences.get(DEFAULT_PDF_ZOOM_KEY).map(String::as_str) {
                    Some("fit-width") => ZoomMode::FitWidth,
                    _ => ZoomMode::FitPage,
                },
            };
            eprintln!(
                "startup: database and preferences initialized in {} ms",
                started.elapsed().as_millis()
            );
            Ok(InitializedState {
                store,
                window_geometry: geometry,
                language_preference,
                managed_books_dir,
                add_book_behavior,
                reader_defaults,
            })
        },
        Message::Initialized,
    );
    (state, initialize)
}

fn stored_f32(value: Option<String>, fallback: f32, range: std::ops::RangeInclusive<f32>) -> f32 {
    value
        .and_then(|value| value.parse::<f32>().ok())
        .filter(|value| range.contains(value))
        .unwrap_or(fallback)
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

fn load_library_page(state: &mut State, append: bool) -> Task<Message> {
    let Some(library) = state.library.clone() else {
        state.library_loading = false;
        return Task::none();
    };
    let offset = if append { state.library_offset } else { 0 };
    let generation = state.library_generation;
    let search = state.library_search.clone();
    let filter = state.library_filter;
    state.library_loading = true;

    Task::perform(
        async move {
            library
                .page(Some(&search), filter, LIBRARY_PAGE_SIZE, offset as u32)
                .await
                .unwrap_or(BookPage {
                    books: Vec::new(),
                    has_more: false,
                })
        },
        move |page| Message::LibraryLoaded {
            generation,
            offset,
            next_offset: offset + page.books.len(),
            page,
        },
    )
}

fn decode_library_covers_task(
    generation: u64,
    offset: usize,
    covers: Vec<(i64, Vec<u8>)>,
) -> Task<Message> {
    if covers.is_empty() {
        return Task::none();
    }
    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                covers
                    .into_iter()
                    .filter_map(|(id, data)| {
                        decode_library_cover(Some(&data)).map(|cover| (id, cover))
                    })
                    .collect()
            })
            .await
            .unwrap_or_default()
        },
        move |cover_handles| Message::LibraryCoversLoaded {
            generation,
            offset,
            cover_handles,
        },
    )
}

fn decode_library_cover(data: Option<&[u8]>) -> Option<RasterImageHandle> {
    let image = ::image::load_from_memory(data?)
        .ok()?
        .thumbnail(LIBRARY_COVER_MAX_WIDTH, LIBRARY_COVER_MAX_HEIGHT);
    let rgba = image.to_rgba8();
    let (width, height) = rgba.dimensions();
    Some(RasterImageHandle(image::Handle::from_rgba(
        width,
        height,
        rgba.into_raw(),
    )))
}

fn reset_library(state: &mut State) -> Task<Message> {
    state.library_generation = state.library_generation.wrapping_add(1);
    state.library_search_pending = false;
    state.library_offset = 0;
    state.library_has_more = false;
    state.book_menu = None;
    state.pending_remove_book = None;
    state.library_error = None;
    if state.library.is_none() {
        state.library_loading = false;
        return Task::none();
    }
    state.library_loading = true;
    state.library_activity_progress = 0.0;
    state.library_activity_opacity = 1.0;
    load_library_page(state, false)
}

fn library_load_sensor_key(state: &State) -> Option<(u64, usize)> {
    state
        .library_has_more
        .then_some((state.library_generation, state.library_offset))
}

fn library_activity_active(state: &State) -> bool {
    state.screen == Screen::Library
        && (state.library_search_pending
            || state.add_books_discovering
            || state.adding_books
            || (state.library_loading && state.library_offset == 0))
}

fn capture_reader_tab(state: &State) -> Option<ReaderTab> {
    let file_path = state.file_path.clone()?;
    let document = state.document.clone()?;
    Some(ReaderTab {
        id: state.active_tab_id?,
        session: ReaderSession {
            book_id: state.book_id,
            locator: DeviceFileLocator::from_path(&file_path),
            document,
            location: ReaderLocation {
                page: state.current_page,
                offset: current_epub_offset(state),
            },
            preferences: ReaderPreferences {
                reading_mode: state.reading_mode,
                epub_font_size: state.font_size,
                epub_line_spacing: state.line_spacing,
                pdf_zoom: state.zoom,
            },
        },
        display_title: state
            .display_title
            .clone()
            .or_else(|| current_book_title(state))?,
        total_pages: state.total_pages,
        rendered_page: state.rendered_page.clone(),
        rendered_page_index: state.rendered_page_index,
        rendered_page_handle: state.rendered_page_handle.clone(),
        rendered_facing_page: state.rendered_facing_page.clone(),
        rendered_facing_page_handle: state.rendered_facing_page_handle.clone(),
        page_cache: state.page_cache.clone(),
        paginated_pending: state.paginated_pending.clone(),
        paginated_requested: state.paginated_requested.clone(),
        epub_image_handles: state.epub_image_handles.clone(),
        epub_images_pending: state.epub_images_pending.clone(),
        epub_images_desired: state.epub_images_desired.clone(),
        epub_images_failed: state.epub_images_failed.clone(),
        epub_image_decode_active: state.epub_image_decode_active,
        epub_image_generation: state.epub_image_generation,
        epub_pages: state.epub_pages.clone(),
        epub_layout_key: state.epub_layout_key,
        epub_layout_pending: state.epub_layout_pending,
        epub_layout_requested: state.epub_layout_requested,
        epub_page: state.epub_page,
        continuous_pages: state.continuous_pages.clone(),
        continuous_pending: state.continuous_pending.clone(),
        continuous_visible: BTreeSet::new(),
        continuous_tail_extent: state.continuous_tail_extent,
        render_generation: state.render_generation,
        page_input: state.page_input.clone(),
        error: state.error.clone(),
        theme: state.theme,
        reader_overrides: state.reader_overrides,
        bookmarks: state.bookmarks.clone(),
        show_bookmarks_panel: state.show_bookmarks_panel,
        show_reader_settings: state.show_reader_settings,
        show_reader_more: state.show_reader_more,
        current_page_bookmarked: state.current_page_bookmarked,
        editing_note_id: state.editing_note_id,
        editing_note_text: state.editing_note_text.clone(),
        show_search_bar: state.show_search_bar,
        search_query: state.search_query.clone(),
        search_results: state.search_results.clone(),
        search_current: state.search_current,
        document_permit: state.document_permit.clone()?,
    })
}

fn restore_reader_tab(state: &mut State, tab: ReaderTab) {
    cancel_active_search(state);
    state.active_tab_id = Some(tab.id);
    state.book_id = tab.session.book_id;
    state.display_title = Some(tab.display_title);
    state.file_path = Some(tab.session.locator.path().to_path_buf());
    state.document = Some(tab.session.document);
    state.document_permit = Some(tab.document_permit);
    state.current_page = tab.session.location.page;
    state.total_pages = tab.total_pages;
    state.zoom = tab.session.preferences.pdf_zoom;
    state.rendered_page = tab.rendered_page;
    state.rendered_page_index = tab.rendered_page_index;
    state.rendered_page_handle = tab.rendered_page_handle;
    state.rendered_facing_page = tab.rendered_facing_page;
    state.rendered_facing_page_handle = tab.rendered_facing_page_handle;
    state.page_cache = tab.page_cache;
    state.paginated_pending = tab.paginated_pending;
    state.paginated_requested = tab.paginated_requested;
    state.epub_image_handles = tab.epub_image_handles;
    state.epub_images_pending = tab.epub_images_pending;
    state.epub_images_desired = tab.epub_images_desired;
    state.epub_images_failed = tab.epub_images_failed;
    state.epub_image_decode_active = tab.epub_image_decode_active;
    state.epub_image_generation = tab.epub_image_generation;
    state.epub_pages = tab.epub_pages;
    state.epub_layout_key = tab.epub_layout_key;
    state.epub_layout_pending = tab.epub_layout_pending;
    state.epub_layout_requested = tab.epub_layout_requested;
    state.epub_page = tab.epub_page;
    state.epub_offset = tab.session.location.offset.unwrap_or_default();
    state.continuous_pages = tab.continuous_pages;
    state.continuous_pending = tab.continuous_pending;
    state.continuous_visible = tab.continuous_visible;
    state.continuous_tail_extent = tab.continuous_tail_extent;
    state.page_input = tab.page_input;
    state.error = tab.error;
    state.font_size = tab.session.preferences.epub_font_size;
    state.line_spacing = tab.session.preferences.epub_line_spacing;
    state.theme = tab.theme;
    state.reading_mode = tab.session.preferences.reading_mode;
    state.reader_overrides = tab.reader_overrides;
    state.bookmarks = tab.bookmarks;
    state.show_bookmarks_panel = tab.show_bookmarks_panel;
    state.show_reader_settings = tab.show_reader_settings;
    state.show_reader_more = tab.show_reader_more;
    state.current_page_bookmarked = tab.current_page_bookmarked;
    state.editing_note_id = tab.editing_note_id;
    state.editing_note_text = tab.editing_note_text;
    state.show_search_bar = tab.show_search_bar;
    state.search_query = tab.search_query;
    state.search_results = tab.search_results;
    state.search_current = tab.search_current;
    state.render_generation = tab.render_generation;
    state.search_document_generation = state.search_document_generation.wrapping_add(1);
    state.search_query_generation = state.search_query_generation.wrapping_add(1);
}

fn save_active_tab(state: &mut State) {
    if let (Some(index), Some(tab)) = (state.active_tab, capture_reader_tab(state))
        && index < state.tabs.len()
    {
        state.tabs[index] = tab;
    }
}

fn apply_managed_path_changes(state: &mut State, changes: &[ManagedPathChange]) {
    for change in changes {
        let path_key = DeviceFileLocator::from_path(&change.new_path)
            .local_id()
            .to_owned();
        if state.book_id == Some(change.book_id) {
            state.file_path = Some(change.new_path.clone());
            for bookmark in &mut state.bookmarks {
                bookmark.file_path = path_key.clone();
            }
        }
        for tab in &mut state.tabs {
            if tab.session.book_id == Some(change.book_id) {
                tab.session.locator = DeviceFileLocator::from_path(&change.new_path);
                for bookmark in &mut tab.bookmarks {
                    bookmark.file_path = path_key.clone();
                }
            }
        }
        if let Some(book) = state
            .library_books
            .iter_mut()
            .find(|book| book.id == change.book_id)
        {
            book.file_path = path_key;
        }
    }
}

fn select_tab(state: &mut State, index: usize) -> Task<Message> {
    if index >= state.tabs.len() {
        return Task::none();
    }
    if state.active_tab == Some(index) {
        state.screen = Screen::Reader;
        return Task::none();
    }
    save_active_tab(state);
    let tab = state.tabs[index].clone();
    restore_reader_tab(state, tab);
    state.continuous_activation = state.continuous_activation.wrapping_add(1);
    state.continuous_measurement_index = None;
    state.active_tab = Some(index);
    state.screen = Screen::Reader;
    let search_task = if state.show_search_bar && !state.search_query.is_empty() {
        perform_search(state)
    } else {
        Task::none()
    };
    let content_task = if state.reading_mode == ReadingMode::Continuous {
        let raster_needs_render = matches!(
            state.document,
            Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
        ) && state
            .continuous_pages
            .get(state.current_page)
            .and_then(Option::as_ref)
            .is_none();
        if raster_needs_render {
            refresh_content(state)
        } else {
            scroll_to_current_page(state)
        }
    } else if matches!(state.document, Some(OpenDocument::Epub(_))) {
        if state.epub_layout_key == Some(epub_layout_key(state)) {
            Task::none()
        } else {
            refresh_content(state)
        }
    } else if state.rendered_page.is_some() {
        Task::none()
    } else {
        refresh_content(state)
    };
    let bookmarks_task = if state.show_bookmarks_panel {
        refresh_bookmarks(state)
    } else {
        Task::none()
    };
    let image_task = load_epub_images_task(state);
    Task::batch([content_task, image_task, search_task, bookmarks_task])
}

fn close_tab(state: &mut State, index: usize) -> Task<Message> {
    if index >= state.tabs.len() {
        return Task::none();
    }
    let previous_active = state.active_tab;
    save_active_tab(state);
    state.tabs.remove(index);
    if state.tabs.is_empty() {
        state.active_tab = None;
        state.active_tab_id = None;
        state.book_id = None;
        state.display_title = None;
        state.file_path = None;
        state.document = None;
        state.document_permit = None;
        state.rendered_page = None;
        state.rendered_page_index = None;
        state.rendered_page_handle = None;
        state.rendered_facing_page = None;
        state.rendered_facing_page_handle = None;
        state.epub_image_handles.clear();
        state.epub_images_pending.clear();
        state.epub_images_desired.clear();
        state.epub_images_failed.clear();
        state.epub_image_decode_active = false;
        state.epub_pages = Arc::new(Vec::new());
        state.epub_layout_key = None;
        state.epub_page = 0;
        state.epub_offset = 0;
        state.continuous_pages.clear();
        state.screen = Screen::Library;
        state.render_generation = state.render_generation.wrapping_add(1);
        cancel_active_search(state);
        state.search_document_generation = state.search_document_generation.wrapping_add(1);
        return Task::done(Message::RefreshLibrary);
    }
    let next = match previous_active {
        Some(active) if active > index => active - 1,
        Some(active) if active < state.tabs.len() => active,
        _ => index.min(state.tabs.len() - 1),
    };
    state.active_tab = None;
    select_tab(state, next)
}

fn open_document(state: &mut State, path: PathBuf, book_id: Option<i64>) -> Task<Message> {
    if let Some(index) = state.tabs.iter().position(|tab| {
        book_id.is_some() && tab.session.book_id == book_id || tab.session.locator.path() == path
    }) && state.tabs[index].session.locator.path() == path
    {
        state.document_open_generation = state.document_open_generation.wrapping_add(1);
        state.document_opening = false;
        state.document_open_notice_visible = false;
        state.document_open_preview = None;
        if let Some(book_id) = book_id {
            state.tabs[index].session.book_id = Some(book_id);
            if let Some(title) = state
                .library_books
                .iter()
                .find(|book| book.id == book_id)
                .map(|book| book.title.trim())
                .filter(|title| !title.is_empty())
            {
                state.tabs[index].display_title = title.to_owned();
            }
            if state.active_tab == Some(index) {
                state.book_id = Some(book_id);
                state.display_title = Some(state.tabs[index].display_title.clone());
            }
        }
        return select_tab(state, index);
    }

    state.document_open_generation = state.document_open_generation.wrapping_add(1);
    let generation = state.document_open_generation;
    let Some(count) = state.document_admission.count.try_reserve(1) else {
        state.open_error = Some(AppError::Open {
            format: "document",
            detail: "retained document count limit exceeded".to_owned(),
        });
        return Task::none();
    };
    let Some(bytes) = state.document_admission.bytes.try_reserve(0) else {
        state.open_error = Some(AppError::Open {
            format: "document",
            detail: "retained document byte limit exceeded".to_owned(),
        });
        return Task::none();
    };
    let Some(open_worker) = state.document_admission.open_workers.try_reserve(1) else {
        state.open_error = Some(AppError::Open {
            format: "document",
            detail: "document open worker limit exceeded".to_owned(),
        });
        return Task::none();
    };
    state.pending_document_permits.insert(
        generation,
        RetainedDocumentPermit {
            _count: count,
            _bytes: bytes,
            open_worker: Some(open_worker),
        },
    );
    state.document_opening = true;
    state.document_open_notice_visible = false;
    let book =
        book_id.and_then(|book_id| state.library_books.iter().find(|book| book.id == book_id));
    state.document_open_preview = Some(DocumentOpenPreview {
        title: book.map_or_else(
            || {
                path.file_stem()
                    .and_then(|title| title.to_str())
                    .map(str::to_owned)
                    .unwrap_or_else(|| state.i18n.text("opening-document"))
            },
            |book| book.title.clone(),
        ),
        cover: book_id.and_then(|book_id| state.library_cover_handles.get(&book_id).cloned()),
    });
    state.open_error = None;
    state.missing_book_id = None;
    let task_path = path.clone();
    let open = Task::perform(
        async move {
            tokio::task::spawn_blocking(move || load_document(&task_path))
                .await
                .unwrap_or_else(|error| {
                    Err(AppError::Open {
                        format: "document",
                        detail: format!("document loader stopped unexpectedly: {error}"),
                    })
                })
        },
        move |result| Message::DocumentOpened {
            generation,
            path,
            book_id,
            result,
        },
    );
    let notice = Task::perform(
        async move { tokio::time::sleep(DOCUMENT_OPEN_NOTICE_DELAY).await },
        move |_| Message::ShowDocumentOpenNotice(generation),
    );
    Task::batch([open, notice])
}

fn finish_open_document(
    state: &mut State,
    path: PathBuf,
    book_id: Option<i64>,
    document: OpenDocument,
) -> Task<Message> {
    let Some(document_permit) = state
        .pending_document_permits
        .remove(&state.document_open_generation)
    else {
        // Synchronous test opens do not pass through open_document; admit them
        // conservatively from the already-read source file.
        let retained_bytes = std::fs::metadata(&path)
            .ok()
            .and_then(|metadata| usize::try_from(metadata.len()).ok())
            .unwrap_or_default();
        let Some(count) = state.document_admission.count.try_reserve(1) else {
            state.open_error = Some(AppError::Open {
                format: "document",
                detail: "retained document count limit exceeded".to_owned(),
            });
            return Task::none();
        };
        let Some(bytes) = state.document_admission.bytes.try_reserve(retained_bytes) else {
            state.open_error = Some(AppError::Open {
                format: "document",
                detail: "retained document byte limit exceeded".to_owned(),
            });
            return Task::none();
        };
        return finish_open_document_with_permit(
            state,
            path,
            book_id,
            document,
            RetainedDocumentPermit {
                _count: count,
                _bytes: bytes,
                open_worker: None,
            },
        );
    };
    finish_open_document_with_permit(state, path, book_id, document, document_permit)
}

fn finish_open_document_with_permit(
    state: &mut State,
    path: PathBuf,
    book_id: Option<i64>,
    document: OpenDocument,
    mut document_permit: RetainedDocumentPermit,
) -> Task<Message> {
    let Some(retained_bytes) = document.retained_byte_len() else {
        state.open_error = Some(AppError::Open {
            format: "document",
            detail: "retained document byte charge overflowed".to_owned(),
        });
        return Task::none();
    };
    let placeholder = state
        .document_admission
        .bytes
        .try_reserve(0)
        .expect("zero-byte document reservation must fit");
    let previous = std::mem::replace(&mut document_permit._bytes, placeholder);
    let resized = match state
        .document_admission
        .bytes
        .try_reserve_replacing(retained_bytes, vec![previous])
    {
        Ok(resized) => resized,
        Err(mut previous) => {
            document_permit._bytes = previous
                .pop()
                .expect("document reservation must be returned");
            state.open_error = Some(AppError::Open {
                format: "document",
                detail: "retained document byte limit exceeded".to_owned(),
            });
            return Task::none();
        }
    };
    document_permit._bytes = resized;
    document_permit.open_worker = None;

    if let Some(index) = state.tabs.iter().position(|tab| {
        book_id.is_some() && tab.session.book_id == book_id || tab.session.locator.path() == path
    }) {
        let retained_display_title = state.tabs[index].display_title.clone();
        let display_title = relocated_book_title(
            book_id,
            &document,
            &path,
            &state.library_books,
            &retained_display_title,
        );
        save_active_tab(state);
        state.tabs[index].session.book_id = book_id;
        state.tabs[index]
            .session
            .replace_document(DeviceFileLocator::from_path(&path), document.clone());
        let relocated_tab = state.tabs[index].clone();
        restore_reader_tab(state, relocated_tab);
        let retained_preferences = state.tabs[index].session.preferences;
        let retained_location = state.tabs[index].session.location;
        state.active_tab = Some(index);
        state.continuous_activation = state.continuous_activation.wrapping_add(1);
        state.open_error = None;
        state.missing_book_id = None;
        install_document(state, path, book_id, document);
        state.document_permit = Some(document_permit);
        state.zoom = retained_preferences.pdf_zoom;
        state.font_size = retained_preferences.epub_font_size;
        state.line_spacing = retained_preferences.epub_line_spacing;
        state.reading_mode = retained_preferences.reading_mode;
        state.current_page = retained_location
            .page
            .min(state.total_pages.saturating_sub(1));
        state.epub_offset = retained_location.offset.unwrap_or_default();
        state.page_input = format!("{}", state.current_page + 1);
        state.display_title = display_title;
        let task = refresh_content(state);
        if let Some(tab) = capture_reader_tab(state) {
            state.tabs[index] = tab;
            state.screen = Screen::Reader;
        }
        return task;
    }

    save_active_tab(state);
    let tab_id = state.next_tab_id;
    state.next_tab_id = state.next_tab_id.wrapping_add(1);
    state.active_tab_id = Some(tab_id);
    state.continuous_activation = state.continuous_activation.wrapping_add(1);
    state.open_error = None;
    state.missing_book_id = None;
    install_document(state, path, book_id, document);
    state.document_permit = Some(document_permit);
    apply_reader_defaults(state);
    let task = refresh_content(state);
    if let Some(tab) = capture_reader_tab(state) {
        state.tabs.push(tab);
        state.active_tab = Some(state.tabs.len() - 1);
        state.screen = Screen::Reader;
    }
    task
}

fn apply_reader_defaults(state: &mut State) {
    state.reading_mode = state.reader_defaults.reading_mode;
    state.theme = state.reader_defaults.theme;
    state.font_size = state.reader_defaults.epub_font_size;
    state.line_spacing = state.reader_defaults.epub_line_spacing;
    state.reader_overrides = ReaderOverrides::default();
    if matches!(state.document, Some(OpenDocument::Pdf(_))) {
        state.zoom = state.reader_defaults.pdf_zoom;
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct AppliedReaderDefaultChanges {
    reading_mode: bool,
    epub_typography: bool,
    pdf_zoom: bool,
}

fn apply_reader_defaults_to_open_tabs(state: &mut State) -> AppliedReaderDefaultChanges {
    let defaults = state.reader_defaults;
    let mut changes = AppliedReaderDefaultChanges::default();

    if state.document.is_some() {
        if !state.reader_overrides.reading_mode && state.reading_mode != defaults.reading_mode {
            state.reading_mode = defaults.reading_mode;
            changes.reading_mode = true;
        }
        if !state.reader_overrides.theme {
            state.theme = defaults.theme;
        }
        if matches!(state.document, Some(OpenDocument::Epub(_))) {
            if !state.reader_overrides.epub_font_size && state.font_size != defaults.epub_font_size
            {
                state.font_size = defaults.epub_font_size;
                changes.epub_typography = true;
            }
            if state.line_spacing != defaults.epub_line_spacing {
                state.line_spacing = defaults.epub_line_spacing;
                changes.epub_typography = true;
            }
        }
        if matches!(state.document, Some(OpenDocument::Pdf(_)))
            && !state.reader_overrides.pdf_zoom
            && state.zoom != defaults.pdf_zoom
        {
            state.zoom = defaults.pdf_zoom;
            changes.pdf_zoom = true;
        }
    }

    for tab in &mut state.tabs {
        if !tab.reader_overrides.reading_mode
            && tab.session.preferences.reading_mode != defaults.reading_mode
        {
            tab.session.preferences.reading_mode = defaults.reading_mode;
            tab.continuous_pages.clear();
            tab.continuous_pending.clear();
            tab.continuous_visible.clear();
            tab.render_generation = tab.render_generation.wrapping_add(1);
        }
        if !tab.reader_overrides.theme {
            tab.theme = defaults.theme;
        }
        if matches!(tab.session.document, OpenDocument::Epub(_)) {
            if !tab.reader_overrides.epub_font_size {
                tab.session.preferences.epub_font_size = defaults.epub_font_size;
            }
            tab.session.preferences.epub_line_spacing = defaults.epub_line_spacing;
        }
        if matches!(tab.session.document, OpenDocument::Pdf(_))
            && !tab.reader_overrides.pdf_zoom
            && tab.session.preferences.pdf_zoom != defaults.pdf_zoom
        {
            tab.session.preferences.pdf_zoom = defaults.pdf_zoom;
            tab.rendered_page = None;
            tab.rendered_page_index = None;
            tab.rendered_page_handle = None;
            tab.rendered_facing_page = None;
            tab.rendered_facing_page_handle = None;
            tab.continuous_pages.clear();
            tab.continuous_pending.clear();
            tab.page_cache.clear();
            tab.render_generation = tab.render_generation.wrapping_add(1);
        }
    }

    changes
}

fn reader_defaults_changed_task(
    state: &mut State,
    changes: AppliedReaderDefaultChanges,
) -> Task<Message> {
    if changes.reading_mode {
        invalidate_continuous_layout(state);
        state.continuous_pages.clear();
        state.continuous_visible.clear();
        state.render_generation = state.render_generation.wrapping_add(1);
    }
    if changes.epub_typography {
        perf::begin_relayout(state);
        invalidate_continuous_layout(state);
    }
    if changes.pdf_zoom {
        invalidate_continuous_rasters(state);
    }
    if changes.reading_mode || changes.epub_typography || changes.pdf_zoom {
        let task = refresh_content(state);
        state.page_input = if uses_paginated_epub_layout(state) {
            (state.epub_page + 1).to_string()
        } else {
            (state.current_page + 1).to_string()
        };
        task
    } else {
        Task::none()
    }
}

fn load_document(path: &PathBuf) -> Result<OpenDocument, AppError> {
    match OpenDocument::open(&DeviceFileLocator::from_path(path)) {
        Ok(document) => Ok(document),
        Err(OpenDocumentError::UnsupportedFormat(extension)) => {
            Err(AppError::UnsupportedFormat(extension))
        }
        Err(OpenDocumentError::NotFound) => Err(AppError::MissingBook),
        Err(OpenDocumentError::Inaccessible(detail)) => Err(AppError::Open {
            format: "document",
            detail,
        }),
        Err(
            OpenDocumentError::Open { format, detail }
            | OpenDocumentError::LimitExceeded { format, detail }
            | OpenDocumentError::BackendUnavailable { format, detail },
        ) => Err(AppError::Open {
            format: format.display_name(),
            detail,
        }),
    }
}

fn install_document(
    state: &mut State,
    path: PathBuf,
    book_id: Option<i64>,
    document: OpenDocument,
) {
    cancel_active_search(state);
    state.display_title = book_title(book_id, &document, Some(&path), &state.library_books);
    state.search_document_generation = state.search_document_generation.wrapping_add(1);
    state.search_query_generation = state.search_query_generation.wrapping_add(1);
    state.render_generation = state.render_generation.wrapping_add(1);
    state.error = None;
    state.rendered_page = None;
    state.rendered_page_index = None;
    state.rendered_page_handle = None;
    state.rendered_facing_page = None;
    state.rendered_facing_page_handle = None;
    state.page_cache.clear();
    state.paginated_pending.clear();
    state.paginated_requested.clear();
    if let Some(tab_id) = state.active_tab_id {
        state.raster_failures.retain(|failure| match failure {
            RasterFailure::Paginated {
                tab_id: failed_tab, ..
            }
            | RasterFailure::Continuous {
                tab_id: failed_tab, ..
            } => *failed_tab != tab_id,
        });
        state
            .cbz_dimension_failures
            .retain(|failure| failure.tab_id != tab_id);
    }
    state.epub_image_generation = state.epub_image_generation.wrapping_add(1);
    state.epub_image_handles.clear();
    state.epub_images_pending.clear();
    state.epub_images_desired.clear();
    state.epub_images_failed.clear();
    state.epub_image_decode_active = false;
    state.epub_pages = Arc::new(Vec::new());
    state.epub_layout_key = None;
    state.epub_layout_pending = None;
    state.epub_layout_requested = None;
    state.epub_page = 0;
    state.epub_offset = 0;
    state.continuous_pages.clear();
    state.continuous_pending.clear();
    state.continuous_visible.clear();
    state.continuous_tail_extent = 0.0;
    state.show_reader_settings = false;
    state.show_reader_more = false;
    state.show_search_bar = false;
    state.search_query.clear();
    state.search_results.clear();
    state.search_current = 0;

    let saved = state.reading_state.as_ref().and_then(|store| {
        book_id
            .and_then(|id| store.get_for_book(id))
            .or_else(|| store.get(&path))
    });
    let session = ReaderSession::new(
        book_id,
        DeviceFileLocator::from_path(&path),
        document,
        saved.as_ref(),
        ReaderPreferences {
            pdf_zoom: ZoomMode::FitPage,
            reading_mode: state.reading_mode,
            epub_font_size: state.font_size,
            epub_line_spacing: state.line_spacing,
        },
    );
    state.total_pages = session.document.page_count();
    state.current_page = session.location.page;
    state.epub_offset = session.location.offset.unwrap_or_default();
    state.zoom = session.preferences.pdf_zoom;
    state.book_id = session.book_id;
    state.file_path = Some(session.locator.path().to_path_buf());
    state.document = Some(session.document);

    state.page_input = format!("{}", state.current_page + 1);
    if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
        state.bookmarks = book_id
            .map(|id| store.list_for_book(id))
            .unwrap_or_else(|| store.list_for_file(path))
            .unwrap_or_default();
    }
    update_bookmark_status(state);
}

fn handle_key_event(state: &State, event: keyboard::Event) -> Task<Message> {
    if state.moving_library {
        return Task::none();
    }
    if let keyboard::Event::KeyPressed { key, modifiers, .. } = event {
        if let keyboard::Key::Character(c) = key.as_ref() {
            if c == "o" && modifiers.command() {
                return Task::done(Message::OpenFile);
            }
            if c == "l" && modifiers.command() {
                return Task::done(Message::ShowLibrary);
            }
            if c == "w"
                && modifiers.command()
                && state.screen == Screen::Reader
                && let Some(index) = state.active_tab
            {
                return Task::done(Message::CloseTab(index));
            }
            if c == "b" && modifiers.command() && state.screen == Screen::Reader {
                return Task::done(Message::ToggleBookmark);
            }
            if c == "f" && modifiers.command() && state.screen == Screen::Reader {
                return Task::done(Message::ToggleSearchBar);
            }
            if modifiers.command()
                && let Ok(number) = c.parse::<usize>()
                && (1..=state.tabs.len()).contains(&number)
            {
                return Task::done(Message::SelectTab(number - 1));
            }
            if c == "/" && state.screen == Screen::Library {
                return iced::widget::operation::focus(library_search_input_id());
            }
        }

        if key.as_ref() == keyboard::Key::Named(keyboard::key::Named::Tab) && modifiers.control() {
            return Task::done(Message::NextTab);
        }

        if state.screen != Screen::Reader {
            return Task::none();
        }

        match key.as_ref() {
            keyboard::Key::Named(keyboard::key::Named::ArrowRight)
            | keyboard::Key::Named(keyboard::key::Named::PageDown) => {
                return Task::done(Message::NextPage);
            }
            keyboard::Key::Named(keyboard::key::Named::ArrowLeft)
            | keyboard::Key::Named(keyboard::key::Named::PageUp) => {
                return Task::done(Message::PrevPage);
            }

            keyboard::Key::Named(keyboard::key::Named::Home) => {
                return Task::done(Message::FirstPage);
            }
            keyboard::Key::Named(keyboard::key::Named::End) => {
                return Task::done(Message::LastPage);
            }

            keyboard::Key::Character(c) if c == "=" || c == "+" => {
                return Task::done(Message::ZoomIn);
            }
            keyboard::Key::Character("-") => {
                return Task::done(Message::ZoomOut);
            }

            // B: toggle bookmarks panel
            keyboard::Key::Character(c) if c == "b" && !modifiers.command() => {
                if state.screen == Screen::Reader {
                    return Task::done(Message::ToggleBookmarksPanel);
                }
            }

            // C: switch between paginated and continuous reading.
            keyboard::Key::Character(c) if c == "c" && !modifiers.command() => {
                return Task::done(Message::ToggleReadingMode);
            }

            // Escape: close search bar if open, otherwise go to library
            keyboard::Key::Named(keyboard::key::Named::Escape) => {
                if state.show_search_bar {
                    return Task::done(Message::CloseSearch);
                } else if state.screen == Screen::Reader {
                    return Task::done(Message::ShowLibrary);
                }
            }

            _ => {}
        }
    }
    Task::none()
}

/// Refresh the visible content for the current page/chapter.
fn refresh_content(state: &mut State) -> Task<Message> {
    retain_relevant_raster_failures(state);
    update_bookmark_status(state);

    if state.reading_mode == ReadingMode::Continuous {
        match &state.document {
            Some(OpenDocument::Pdf(_)) => {
                state.rendered_page = None;
                state.rendered_page_index = None;
                state.rendered_page_handle = None;
                state.rendered_facing_page = None;
                state.rendered_facing_page_handle = None;
                if state.continuous_pages.len() != state.total_pages {
                    state.continuous_pages = vec![None; state.total_pages];
                }
                if !has_current_raster_failure(state) {
                    state.error = None;
                }
                return Task::batch([
                    reconcile_continuous_rasters(state),
                    scroll_to_current_page(state),
                ]);
            }
            Some(OpenDocument::Epub(_)) => {
                state.rendered_page = None;
                state.rendered_page_index = None;
                state.rendered_page_handle = None;
                state.rendered_facing_page = None;
                state.rendered_facing_page_handle = None;
                state.error = None;
                return Task::batch([load_epub_images_task(state), scroll_to_current_page(state)]);
            }
            Some(OpenDocument::Cbz(_)) => {
                state.rendered_page = None;
                state.rendered_page_index = None;
                state.rendered_page_handle = None;
                state.rendered_facing_page = None;
                state.rendered_facing_page_handle = None;
                if state.continuous_pages.len() != state.total_pages {
                    state.continuous_pages = vec![None; state.total_pages];
                }
                if !has_current_raster_failure(state) {
                    state.error = None;
                }
                return Task::batch([
                    reconcile_continuous_rasters(state),
                    scroll_to_current_page(state),
                ]);
            }
            None => return Task::none(),
        }
    }

    state.render_generation = state.render_generation.wrapping_add(1);
    let generation = state.render_generation;
    let tab_id = state.active_tab_id.unwrap_or(0);

    match &state.document {
        Some(OpenDocument::Pdf(doc)) => {
            let doc = Arc::clone(doc);
            let pages = paginated_raster_pages(state);
            let scale = raster_render_scale(state, paginated_raster_scale(state, &pages));
            state.paginated_requested = pages
                .iter()
                .map(|page| PageCacheKey {
                    page: *page,
                    scale_bits: scale.to_bits(),
                    highlights: search_highlights_for_page(state, *page),
                })
                .collect();
            if !has_current_raster_failure(state) {
                state.error = None;
            }
            let spread_changed = show_cached_paginated_spread(state);
            if !state.paginated_pending.is_empty() {
                return Task::none();
            }
            let mut tasks = Vec::new();
            for key in state.paginated_requested.clone() {
                if state.raster_jobs.len() >= RASTER_RENDER_WORKERS {
                    break;
                }
                if !is_page_cached(state, &key) {
                    let page = key.page;
                    let job = RasterJob::Paginated {
                        tab_id,
                        generation,
                        key: key.clone(),
                    };
                    if state.raster_failures.contains(&job.failure()) {
                        continue;
                    }
                    let highlights = key.highlights.clone();
                    let permit = match reserve_raster(state, page, scale) {
                        RasterAdmission::Ready(permit) => permit,
                        RasterAdmission::Busy => continue,
                        RasterAdmission::Rejected(error) => {
                            record_raster_failure(state, &job, error);
                            continue;
                        }
                    };
                    let transient_permit = match reserve_render_transient(state, page, scale) {
                        RenderTransientAdmission::Ready(permit) => permit,
                        RenderTransientAdmission::Busy => continue,
                        RenderTransientAdmission::Rejected(error) => {
                            record_raster_failure(state, &job, error);
                            continue;
                        }
                    };
                    let doc = Arc::clone(&doc);
                    tasks.push(render_page_task(
                        tab_id,
                        generation,
                        key.clone(),
                        Some(transient_permit),
                        retain_document_for_worker(state),
                        move || doc.render_page_with_highlights(page, scale, &highlights),
                    ));
                    state.paginated_pending.push(key.clone());
                    state.raster_jobs.insert(job, permit);
                }
            }
            if tasks.is_empty() && spread_changed {
                tasks.push(prefetch_next_paginated_spread(state));
            }
            return Task::batch(tasks);
        }
        Some(OpenDocument::Epub(doc)) => {
            let doc = Arc::clone(doc);
            let layout_key = epub_layout_key(state);
            state.epub_layout_requested = Some(layout_key);
            state.rendered_page = None;
            state.rendered_page_index = None;
            state.rendered_page_handle = None;
            state.rendered_facing_page = None;
            state.rendered_facing_page_handle = None;
            state.error = None;
            if state.epub_layout_pending.is_some()
                || (state.epub_layout_key == Some(layout_key) && !state.epub_pages.is_empty())
            {
                return load_epub_images_task(state);
            }
            if !state.epub_jobs.is_empty() {
                return load_epub_images_task(state);
            }
            state.epub_layout_pending = Some(layout_key);
            state.epub_jobs.insert(EpubJob {
                tab_id,
                generation,
                layout_key,
            });
            return Task::batch([
                paginate_epub_task(
                    tab_id,
                    generation,
                    doc,
                    retain_document_for_worker(state),
                    layout_key,
                    state.current_page,
                ),
                load_epub_images_task(state),
            ]);
        }
        Some(OpenDocument::Cbz(doc)) => {
            let doc = Arc::clone(doc);
            let pages = paginated_raster_pages(state);
            if pages
                .iter()
                .any(|page| doc.cached_page_size(*page).is_none())
            {
                if !has_current_raster_failure(state) {
                    state.error = None;
                }
                return schedule_cbz_dimension(state, doc, pages);
            }
            let scale = paginated_raster_scale(state, &pages);
            state.paginated_requested = pages
                .iter()
                .map(|page| PageCacheKey {
                    page: *page,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                })
                .collect();
            if !has_current_raster_failure(state) {
                state.error = None;
            }
            let spread_changed = show_cached_paginated_spread(state);
            if !state.paginated_pending.is_empty() {
                return Task::none();
            }
            let mut tasks = Vec::new();
            for key in state.paginated_requested.clone() {
                if state.raster_jobs.len() >= RASTER_RENDER_WORKERS {
                    break;
                }
                if !is_page_cached(state, &key) {
                    let page = key.page;
                    let job = RasterJob::Paginated {
                        tab_id,
                        generation,
                        key: key.clone(),
                    };
                    if state.raster_failures.contains(&job.failure()) {
                        continue;
                    }
                    let permit = match reserve_raster(state, page, scale) {
                        RasterAdmission::Ready(permit) => permit,
                        RasterAdmission::Busy => continue,
                        RasterAdmission::Rejected(error) => {
                            record_raster_failure(state, &job, error);
                            continue;
                        }
                    };
                    let transient_permit = match reserve_render_transient(state, page, scale) {
                        RenderTransientAdmission::Ready(permit) => permit,
                        RenderTransientAdmission::Busy => continue,
                        RenderTransientAdmission::Rejected(error) => {
                            record_raster_failure(state, &job, error);
                            continue;
                        }
                    };
                    let doc = Arc::clone(&doc);
                    tasks.push(render_page_task(
                        tab_id,
                        generation,
                        key.clone(),
                        Some(transient_permit),
                        retain_document_for_worker(state),
                        move || doc.render_page(page, scale),
                    ));
                    state.paginated_pending.push(key.clone());
                    state.raster_jobs.insert(job, permit);
                }
            }
            if tasks.is_empty() && spread_changed {
                tasks.push(prefetch_next_paginated_spread(state));
            }
            return Task::batch(tasks);
        }
        None => {}
    }

    Task::none()
}

fn schedule_cbz_dimension(
    state: &mut State,
    document: Arc<CbzDoc>,
    pages: Vec<usize>,
) -> Task<Message> {
    if state.cbz_dimension_jobs.len() >= CBZ_DIMENSION_WORKERS {
        return Task::none();
    }
    let tab_id = state.active_tab_id.unwrap_or(0);
    let generation = state.render_generation;
    let Some(page) = pages.into_iter().find(|page| {
        let job = CbzDimensionJob {
            tab_id,
            generation,
            page: *page,
        };
        document.cached_page_size(*page).is_none()
            && !state.cbz_dimension_jobs.contains_key(&job)
            && !state
                .cbz_dimension_failures
                .iter()
                .any(|failed| failed.tab_id == tab_id && failed.page == *page)
    }) else {
        return Task::none();
    };
    let Some(byte_len) = document.page_source_byte_len(page) else {
        return Task::none();
    };
    let Some(permit) = reserve_raster_bytes(state, byte_len) else {
        return Task::none();
    };
    state.cbz_dimension_jobs.insert(
        CbzDimensionJob {
            tab_id,
            generation,
            page,
        },
        permit,
    );
    let document_permit = retain_document_for_worker(state);
    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let _document_permit = document_permit;
                document
                    .page_size(page)
                    .map_err(|error| error.to_string())?;
                Ok(())
            })
            .await
            .unwrap_or_else(|error| Err(error.to_string()))
        },
        move |result| Message::CbzDimensionsLoaded {
            tab_id,
            generation,
            page,
            result,
        },
    )
}

pub(super) fn load_epub_images_task(state: &mut State) -> Task<Message> {
    let Some(OpenDocument::Epub(document)) = &state.document else {
        return Task::none();
    };
    let chapters = document.presentation().chapters();
    if chapters.is_empty() {
        return Task::none();
    }

    let current_chapter = state.current_page.min(chapters.len() - 1);
    let nearby_range = nearby_chapters(current_chapter, chapters.len(), 1);
    let nearby = epub_image_paths(
        chapters[nearby_range.clone()]
            .iter()
            .flat_map(|chapter| chapter.nodes()),
    );
    state
        .epub_image_handles
        .retain(|path, _| nearby.contains(path));
    state
        .epub_images_failed
        .retain(|path| nearby.contains(path));
    state.epub_images_desired = nearby
        .into_iter()
        .filter(|path| {
            !state.epub_image_handles.contains_key(path) && !state.epub_images_failed.contains(path)
        })
        .collect();
    if state.epub_image_decode_active {
        return Task::none();
    }
    if state.epub_image_jobs.len() >= EPUB_IMAGE_WORKERS {
        return Task::none();
    }

    // HashSet iteration is deliberately not used for scheduling: the chapter being
    // read always wins over speculative neighbours, with document order as the tie-breaker.
    let ordered_paths = std::iter::once(current_chapter)
        .chain(nearby_range.filter(|chapter| *chapter != current_chapter))
        .flat_map(|chapter| epub_image_paths(chapters[chapter].nodes()).into_iter());
    let Some(path) = ordered_paths
        .into_iter()
        .find(|path| state.epub_images_desired.contains(path))
    else {
        return Task::none();
    };
    state.epub_images_pending = [path.clone()].into_iter().collect();
    state.epub_image_decode_active = true;
    let document = Arc::clone(document);
    let tab_id = state.active_tab_id.unwrap_or(0);
    let generation = state.epub_image_generation;
    state.epub_image_jobs.insert(EpubImageJob {
        tab_id,
        generation,
        path: path.clone(),
    });
    let probe_path = path.clone();
    let document_permit = retain_document_for_worker(state);
    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let _document_permit = document_permit;
                epub_image_byte_len(&document, &probe_path)
            })
            .await
            .unwrap_or_default()
        },
        move |byte_len| Message::EpubImageSizeLoaded {
            tab_id,
            generation,
            path,
            byte_len,
        },
    )
}

fn decode_epub_image_task(
    state: &mut State,
    job: EpubImageJob,
    byte_len: usize,
) -> Option<Task<Message>> {
    let Some(OpenDocument::Epub(document)) = &state.document else {
        return None;
    };
    let document = Arc::clone(document);
    let transient_byte_len = epub_image_transient_byte_len(&document, &job.path)?;
    let reserve = |state: &State| {
        let permit = state.epub_image_budget.try_reserve(byte_len)?;
        let transient = state
            .transient_decode_budget
            .try_reserve(transient_byte_len)?;
        Some((permit, transient))
    };
    let (permit, transient_permit) = if let Some(permits) = reserve(state) {
        permits
    } else {
        // Inactive tabs and images outside the current chapter are speculative.
        for tab in &mut state.tabs {
            tab.epub_image_handles.clear();
        }
        let chapters = document.presentation().chapters();
        let current_paths =
            epub_image_paths(chapters[state.current_page.min(chapters.len() - 1)].nodes());
        state
            .epub_image_handles
            .retain(|path, _| current_paths.contains(path));
        reserve(state)?
    };
    let path = job.path.clone();
    let document_permit = retain_document_for_worker(state);
    Some(Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let _document_permit = document_permit;
                let _transient_permit = transient_permit;
                decode_epub_images(&document, [(path, permit)])
            })
            .await
            .unwrap_or_default()
        },
        move |images| Message::EpubImagesDecoded {
            tab_id: job.tab_id,
            generation: job.generation,
            path: job.path,
            images,
        },
    ))
}

fn epub_uses_spread(state: &State) -> bool {
    state.reading_mode == ReadingMode::Paginated
        && matches!(state.document, Some(OpenDocument::Epub(_)))
        && available_reader_size(state).width >= MIN_TWO_PAGE_WIDTH
}

fn epub_page_size(state: &State) -> Size {
    let available = available_reader_size(state);
    let page = crate::epub::page_size(
        crate::epub::LayoutSize::new(available.width, available.height),
        epub_uses_spread(state),
        PAGE_GUTTER,
        state.font_size,
        state.line_spacing,
    );
    Size::new(page.width, page.height)
}

fn epub_layout_key(state: &State) -> EpubLayoutKey {
    EpubLayoutKey::new(epub_page_size(state), state.font_size, state.line_spacing)
}

fn epub_layout_key_for_tab(state: &State, tab: &ReaderTab) -> EpubLayoutKey {
    let available_size = available_reader_size_with_panels(
        state,
        tab.show_bookmarks_panel,
        tab.show_search_bar,
        tab.show_reader_settings,
        tab.show_reader_more,
    );
    let uses_spread = tab.session.preferences.reading_mode == ReadingMode::Paginated
        && matches!(tab.session.document, OpenDocument::Epub(_))
        && available_size.width >= MIN_TWO_PAGE_WIDTH;
    let page_size = crate::epub::page_size(
        crate::epub::LayoutSize::new(available_size.width, available_size.height),
        uses_spread,
        PAGE_GUTTER,
        tab.session.preferences.epub_font_size,
        tab.session.preferences.epub_line_spacing,
    );
    EpubLayoutKey::new(
        Size::new(page_size.width, page_size.height),
        tab.session.preferences.epub_font_size,
        tab.session.preferences.epub_line_spacing,
    )
}

fn epub_spread_start(state: &State, page: usize) -> usize {
    crate::epub::spread_start(page, state.epub_pages.len(), epub_uses_spread(state))
}

fn epub_visible_pages(state: &State) -> Vec<usize> {
    crate::epub::visible_pages(
        state.epub_page,
        state.epub_pages.len(),
        epub_uses_spread(state),
    )
}

fn search_highlights_for_page(state: &State, page: usize) -> Vec<(usize, usize, bool)> {
    state
        .search_results
        .iter()
        .enumerate()
        .filter(|(_, result)| result.page == page)
        .map(|(index, result)| (result.offset, result.length, index == state.search_current))
        .collect()
}

fn render_continuous_page_task(
    tab_id: u64,
    request: ContinuousRequest,
    page: usize,
    transient_permit: Option<CachePermit>,
    document_permit: RetainedDocumentPermit,
    render: impl FnOnce() -> anyhow::Result<RenderedPage> + Send + 'static,
) -> Task<Message> {
    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let _document_permit = document_permit;
                let _transient_permit = transient_permit;
                render()
            })
            .await
            .map_err(|error| error.to_string())
            .and_then(|result| result.map_err(|error| error.to_string()))
        },
        move |result| Message::ContinuousPageRendered {
            tab_id,
            request,
            page,
            result,
        },
    )
}

fn paginate_epub_task(
    tab_id: u64,
    generation: u64,
    document: Arc<EpubDoc>,
    document_permit: RetainedDocumentPermit,
    layout_key: EpubLayoutKey,
    current_chapter: usize,
) -> Task<Message> {
    let font_size = f32::from_bits(layout_key.font_size);
    let line_spacing = f32::from_bits(layout_key.line_spacing);
    let page_size = crate::epub::LayoutSize::new(
        f32::from_bits(layout_key.width),
        f32::from_bits(layout_key.height),
    );
    let pagination = iced::futures::stream::unfold(
        Some((document, document_permit, false)),
        move |state| async move {
            let (document, document_permit, complete) = state?;
            let worker_document = Arc::clone(&document);
            let worker_permit = document_permit.clone();
            let pages = tokio::task::spawn_blocking(move || {
                let _document_permit = worker_permit;
                if complete {
                    crate::epub::paginate_document(
                        &worker_document,
                        font_size,
                        line_spacing,
                        page_size,
                    )
                } else {
                    let mut budget = EpubPaginationBudget::for_document(
                        worker_document.presentation().chapters().len(),
                    );
                    crate::epub::paginate_document_chapter(
                        &worker_document,
                        current_chapter,
                        font_size,
                        line_spacing,
                        page_size,
                        &mut budget,
                    )
                }
            })
            .await
            .unwrap_or_default();
            let next = (!complete).then_some((document, document_permit, true));
            Some(((complete, pages), next))
        },
    );
    Task::run(pagination, move |(complete, pages)| {
        Message::EpubPaginated {
            tab_id,
            generation,
            layout_key,
            complete,
            pages: Arc::new(pages),
        }
    })
}

fn continuous_scroll_id(tab_id: u64, activation: u64) -> iced::widget::Id {
    iced::widget::Id::from(format!("continuous-reader-{tab_id}-{activation}"))
}

fn continuous_measured_items(
    state: &State,
    tab_id: u64,
    activation: u64,
) -> Vec<ContinuousMeasuredItem> {
    let Some(OpenDocument::Epub(document)) = &state.document else {
        return (0..state.total_pages)
            .map(|page| ContinuousMeasuredItem {
                id: continuous_item_id(tab_id, activation, page),
                page,
                start: 0,
                end: 0,
            })
            .collect();
    };

    document
        .presentation()
        .chapters()
        .iter()
        .enumerate()
        .flat_map(|(chapter_index, presentation)| {
            let nodes = presentation.nodes();
            let has_title = document
                .chapter(chapter_index)
                .and_then(|chapter| chapter.title.as_deref())
                .is_some_and(|title| !content_starts_with_heading(nodes, title));
            let mut items = Vec::with_capacity(nodes.len() + usize::from(has_title));
            if has_title {
                items.push(ContinuousMeasuredItem {
                    id: continuous_epub_title_id(tab_id, activation, chapter_index),
                    page: chapter_index,
                    start: 0,
                    end: 0,
                });
            }
            let mut offset = 0;
            for (node_index, node) in nodes.iter().enumerate() {
                let end = offset + content_node_text_len(node) + 1;
                items.push(ContinuousMeasuredItem {
                    id: continuous_epub_node_id(tab_id, activation, chapter_index, node_index),
                    page: chapter_index,
                    start: offset,
                    end,
                });
                offset = end;
            }
            if items.is_empty() {
                items.push(ContinuousMeasuredItem {
                    id: continuous_item_id(tab_id, activation, chapter_index),
                    page: chapter_index,
                    start: 0,
                    end: 0,
                });
            }
            items
        })
        .collect()
}

fn continuous_measurement_index(
    state: &mut State,
    tab_id: u64,
    activation: u64,
) -> Arc<ContinuousMeasurementIndex> {
    if let Some(index) = &state.continuous_measurement_index
        && index.tab_id == tab_id
        && index.activation == activation
    {
        return Arc::clone(index);
    }
    let index = Arc::new(ContinuousMeasurementIndex::new(
        tab_id,
        activation,
        continuous_measured_items(state, tab_id, activation),
    ));
    state.continuous_measurement_index = Some(Arc::clone(&index));
    index
}

fn scroll_to_current_page(state: &mut State) -> Task<Message> {
    if state.reading_mode != ReadingMode::Continuous {
        return Task::none();
    }
    let Some(tab_id) = state.active_tab_id else {
        return Task::none();
    };
    let activation = state.continuous_activation;
    let index = continuous_measurement_index(state, tab_id, activation);
    iced::advanced::widget::operate(ContinuousItemOperation::locate(
        index,
        continuous_scroll_id(tab_id, activation),
        (state.current_page, state.epub_offset),
        state.continuous_tail_extent,
    ))
    .map(
        move |(_, _, offset, tail_extent)| Message::ContinuousNavigationMeasured {
            tab_id,
            activation,
            offset,
            tail_extent,
        },
    )
}

fn reconcile_continuous_rasters(state: &mut State) -> Task<Message> {
    if !matches!(
        state.document,
        Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
    ) || state.reading_mode != ReadingMode::Continuous
    {
        return Task::none();
    }
    let Some(tab_id) = state.active_tab_id else {
        return Task::none();
    };
    let desired = prioritized_pages(
        state.continuous_visible.iter().copied(),
        state.current_page,
        state.continuous_pages.len(),
        CONTINUOUS_PAGE_CACHE_CAPACITY,
    )
    .into_iter()
    .collect::<BTreeSet<_>>();

    for (page, rendered) in state.continuous_pages.iter_mut().enumerate() {
        if !desired.contains(&page) {
            *rendered = None;
        }
    }

    if let Some(OpenDocument::Cbz(document)) = &state.document {
        let document = Arc::clone(document);
        let pages = desired.iter().copied().collect::<Vec<_>>();
        if pages
            .iter()
            .any(|page| document.cached_page_size(*page).is_none())
        {
            return schedule_cbz_dimension(state, document, pages);
        }
    }
    let available_worker_slots = RASTER_RENDER_WORKERS.saturating_sub(state.raster_jobs.len());
    let active_ready = state
        .continuous_pages
        .iter()
        .filter(|page| page.is_some())
        .count();
    let pending = state.continuous_pending.len()
        + state
            .tabs
            .iter()
            .filter(|tab| Some(tab.id) != state.active_tab_id)
            .map(|tab| tab.continuous_pending.len())
            .sum::<usize>();
    for tab in state
        .tabs
        .iter_mut()
        .filter(|tab| Some(tab.id) != state.active_tab_id)
    {
        tab.continuous_pages.fill(None);
    }
    let mut occupied = active_ready + pending;
    let mut occupied_bytes = retained_continuous_raster_bytes(state)
        + state
            .continuous_pending
            .values()
            .chain(
                state
                    .tabs
                    .iter()
                    .filter(|tab| Some(tab.id) != state.active_tab_id)
                    .flat_map(|tab| tab.continuous_pending.values()),
            )
            .map(|request| request.byte_len)
            .sum::<usize>();
    let mut tasks = Vec::new();
    for page in desired {
        if occupied >= CONTINUOUS_PAGE_CACHE_CAPACITY || tasks.len() >= available_worker_slots {
            break;
        }
        if state.continuous_pages[page].is_none() && !state.continuous_pending.contains_key(&page) {
            if has_continuous_raster_failure(state, tab_id, page) {
                continue;
            }
            let byte_len = match raster_request_byte_len(state, page) {
                Ok(byte_len) => byte_len,
                Err(error) => {
                    let job = RasterJob::Continuous {
                        tab_id,
                        request: ContinuousRequest {
                            id: state.next_continuous_request_id,
                            generation: state.render_generation,
                            byte_len: 0,
                        },
                        page,
                    };
                    record_raster_failure(state, &job, error);
                    continue;
                }
            };
            let next_occupied_bytes = match occupied_bytes.checked_add(byte_len) {
                Some(bytes) => bytes,
                None => {
                    let job = RasterJob::Continuous {
                        tab_id,
                        request: ContinuousRequest {
                            id: state.next_continuous_request_id,
                            generation: state.render_generation,
                            byte_len,
                        },
                        page,
                    };
                    record_raster_failure(
                        state,
                        &job,
                        "continuous raster byte charge overflowed".to_owned(),
                    );
                    continue;
                }
            };
            let request = ContinuousRequest {
                id: state.next_continuous_request_id,
                generation: state.render_generation,
                byte_len,
            };
            let job = RasterJob::Continuous {
                tab_id,
                request,
                page,
            };
            if state.raster_failures.contains(&job.failure()) {
                continue;
            }
            if next_occupied_bytes > CONTINUOUS_RASTER_BYTE_CAPACITY {
                record_raster_failure(
                    state,
                    &job,
                    format!(
                        "continuous rasters require {next_occupied_bytes} bytes, exceeding the {CONTINUOUS_RASTER_BYTE_CAPACITY} byte limit"
                    ),
                );
                continue;
            }
            let permit = match reserve_raster_output_bytes(state, byte_len) {
                RasterAdmission::Ready(permit) => permit,
                RasterAdmission::Busy => continue,
                RasterAdmission::Rejected(error) => {
                    record_raster_failure(state, &job, error);
                    continue;
                }
            };
            let transient_permit = match reserve_render_transient(
                state,
                page,
                raster_render_scale(state, state.zoom.scale()),
            ) {
                RenderTransientAdmission::Ready(permit) => permit,
                RenderTransientAdmission::Busy => continue,
                RenderTransientAdmission::Rejected(error) => {
                    record_raster_failure(state, &job, error);
                    continue;
                }
            };
            state.next_continuous_request_id = state.next_continuous_request_id.wrapping_add(1);
            state.continuous_pending.insert(page, request);
            state.raster_jobs.insert(job, permit);
            occupied += 1;
            occupied_bytes = next_occupied_bytes;
            tasks.push(start_continuous_page_task(
                state,
                tab_id,
                request,
                page,
                Some(transient_permit),
            ));
        }
    }
    Task::batch(tasks)
}

fn start_continuous_page_task(
    state: &State,
    tab_id: u64,
    request: ContinuousRequest,
    page: usize,
    transient_permit: Option<CachePermit>,
) -> Task<Message> {
    let scale = raster_render_scale(state, state.zoom.scale());
    match &state.document {
        Some(OpenDocument::Pdf(document)) => {
            let document = Arc::clone(document);
            let highlights = search_highlights_for_page(state, page);
            render_continuous_page_task(
                tab_id,
                request,
                page,
                transient_permit,
                retain_document_for_worker(state),
                move || document.render_page_with_highlights(page, scale, &highlights),
            )
        }
        Some(OpenDocument::Cbz(document)) => {
            let document = Arc::clone(document);
            render_continuous_page_task(
                tab_id,
                request,
                page,
                transient_permit,
                retain_document_for_worker(state),
                move || document.render_page(page, scale),
            )
        }
        _ => Task::none(),
    }
}

fn pump_raster_queue(state: &mut State) -> Task<Message> {
    retain_relevant_raster_failures(state);
    if state.reading_mode == ReadingMode::Continuous
        && matches!(
            state.document,
            Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
        )
    {
        return reconcile_continuous_rasters(state);
    }
    if state.reading_mode == ReadingMode::Paginated
        && matches!(
            state.document,
            Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
        )
        && state.paginated_pending.is_empty()
        && state.paginated_requested.iter().any(|requested| {
            !is_page_cached(state, requested)
                && !state.raster_failures.contains(&RasterFailure::Paginated {
                    tab_id: state.active_tab_id.unwrap_or(0),
                    key: requested.clone(),
                })
        })
    {
        return refresh_content(state);
    }
    Task::none()
}

fn retain_relevant_raster_failures(state: &mut State) {
    state.raster_failures.retain(|failure| match failure {
        RasterFailure::Paginated { tab_id, key } => {
            if state.active_tab_id == Some(*tab_id) {
                state.paginated_requested.contains(key)
            } else {
                state
                    .tabs
                    .iter()
                    .any(|tab| tab.id == *tab_id && tab.paginated_requested.contains(key))
            }
        }
        RasterFailure::Continuous { tab_id, page, .. } => {
            if state.active_tab_id == Some(*tab_id) {
                state.reading_mode == ReadingMode::Continuous
                    && (*page == state.current_page || state.continuous_visible.contains(page))
            } else {
                state
                    .tabs
                    .iter()
                    .any(|tab| tab.id == *tab_id && tab.continuous_visible.contains(page))
            }
        }
    });

    state.cbz_dimension_failures.retain(|failure| {
        if state.active_tab_id == Some(failure.tab_id) {
            true
        } else {
            state.tabs.iter().any(|tab| tab.id == failure.tab_id)
        }
    });
}

fn retained_continuous_raster_bytes(state: &State) -> usize {
    state
        .continuous_pages
        .iter()
        .chain(
            state
                .tabs
                .iter()
                .filter(|tab| Some(tab.id) != state.active_tab_id)
                .flat_map(|tab| tab.continuous_pages.iter()),
        )
        .filter_map(|page| page.as_ref())
        .map(|page| page.pixels.len())
        .sum()
}

fn raster_request_byte_len(state: &State, page: usize) -> Result<usize, String> {
    raster_byte_len(state, page, raster_render_scale(state, state.zoom.scale()))
}

fn raster_byte_len(state: &State, page: usize, scale: f32) -> Result<usize, String> {
    match state
        .document
        .as_ref()
        .ok_or_else(|| "no document is open".to_owned())?
    {
        OpenDocument::Pdf(document) => document
            .rendered_byte_len(page, scale)
            .map_err(|error| error.to_string()),
        OpenDocument::Cbz(document) => {
            let (width, height) = document
                .page_size(page)
                .map_err(|error| error.to_string())?;
            let width = (f64::from(width) * f64::from(scale)).floor() as usize;
            let height = (f64::from(height) * f64::from(scale)).floor() as usize;
            width
                .checked_mul(height)
                .and_then(|pixels| pixels.checked_mul(4))
                .ok_or_else(|| "rendered page byte charge overflowed".to_owned())
        }
        OpenDocument::Epub(_) => Err("EPUB does not use raster page rendering".to_owned()),
    }
}

enum RasterAdmission {
    Ready(CachePermit),
    Busy,
    Rejected(String),
}

fn reserve_raster(state: &mut State, page: usize, scale: f32) -> RasterAdmission {
    let byte_len = match raster_byte_len(state, page, scale) {
        Ok(byte_len) => byte_len,
        Err(error) => return RasterAdmission::Rejected(error),
    };
    reserve_raster_output_bytes(state, byte_len)
}

fn reserve_raster_output_bytes(state: &mut State, byte_len: usize) -> RasterAdmission {
    if byte_len > state.raster_budget.limit() {
        return RasterAdmission::Rejected(format!(
            "rendered page requires {byte_len} bytes, exceeding the {} byte limit",
            state.raster_budget.limit()
        ));
    }
    reserve_raster_bytes(state, byte_len).map_or(RasterAdmission::Busy, RasterAdmission::Ready)
}

fn record_raster_failure(state: &mut State, job: &RasterJob, error: String) {
    state.raster_failures.insert(job.failure());
    state.error = Some(AppError::Render(error));
}

fn has_continuous_raster_failure(state: &State, tab_id: u64, page: usize) -> bool {
    state.raster_failures.iter().any(|failure| {
        matches!(
            failure,
            RasterFailure::Continuous {
                tab_id: failed_tab,
                page: failed_page,
                ..
            } if *failed_tab == tab_id && *failed_page == page
        )
    })
}

fn has_current_raster_failure(state: &State) -> bool {
    let Some(tab_id) = state.active_tab_id else {
        return false;
    };
    state.raster_failures.iter().any(|failure| match failure {
        RasterFailure::Paginated {
            tab_id: failed_tab,
            key,
        } => *failed_tab == tab_id && state.paginated_requested.contains(key),
        RasterFailure::Continuous {
            tab_id: failed_tab,
            page,
            ..
        } => {
            *failed_tab == tab_id
                && state.reading_mode == ReadingMode::Continuous
                && (*page == state.current_page || state.continuous_visible.contains(page))
        }
    }) || state
        .cbz_dimension_failures
        .iter()
        .any(|failure| failure.tab_id == tab_id && failure.page == state.current_page)
}

enum RenderTransientAdmission {
    Ready(CachePermit),
    Busy,
    Rejected(String),
}

fn reserve_render_transient(state: &State, page: usize, scale: f32) -> RenderTransientAdmission {
    let Some(document) = state.document.as_ref() else {
        return RenderTransientAdmission::Rejected("no document is open".to_owned());
    };
    let byte_len = match document {
        OpenDocument::Pdf(document) => match document.render_transient_byte_len(page, scale) {
            Ok(byte_len) => byte_len,
            Err(error) => return RenderTransientAdmission::Rejected(error.to_string()),
        },
        // CBZ admission includes the compressed source entry as well as the
        // conservative decode and resize allocations.
        OpenDocument::Cbz(document) => {
            let Some(byte_len) = document.render_admission_byte_len_at_scale(page, scale) else {
                return RenderTransientAdmission::Rejected(
                    "CBZ render memory requirement could not be bounded".to_owned(),
                );
            };
            byte_len
        }
        OpenDocument::Epub(_) => {
            return RenderTransientAdmission::Rejected(
                "EPUB does not use raster page rendering".to_owned(),
            );
        }
    };
    if byte_len > state.transient_decode_budget.limit() {
        return RenderTransientAdmission::Rejected(format!(
            "page render requires {byte_len} transient bytes, exceeding the {} byte limit",
            state.transient_decode_budget.limit()
        ));
    }
    state.transient_decode_budget.try_reserve(byte_len).map_or(
        RenderTransientAdmission::Busy,
        RenderTransientAdmission::Ready,
    )
}

pub(super) fn pump_background_work(state: &mut State) -> Task<Message> {
    Task::batch([pump_raster_queue(state), load_epub_images_task(state)])
}

fn reserve_raster_bytes(state: &mut State, byte_len: usize) -> Option<CachePermit> {
    loop {
        if let Some(permit) = state.raster_budget.try_reserve(byte_len) {
            return Some(permit);
        }
        // The budget is shared by every tab. Release inactive displays/caches
        // before sacrificing the currently visible page.
        if let Some(tab) = state.tabs.iter_mut().find(|tab| {
            !tab.page_cache.is_empty()
                || tab.rendered_page.is_some()
                || tab.rendered_facing_page.is_some()
                || tab.continuous_pages.iter().any(Option::is_some)
        }) {
            tab.page_cache.clear();
            tab.rendered_page = None;
            tab.rendered_page_handle = None;
            tab.rendered_facing_page = None;
            tab.rendered_facing_page_handle = None;
            tab.continuous_pages.fill(None);
            continue;
        }
        // A navigation request supersedes this display. Clear its pixel clones
        // before evicting the cache entry whose permit accounts for them.
        if state.rendered_page.is_some() || state.rendered_facing_page.is_some() {
            state.rendered_page = None;
            state.rendered_page_handle = None;
            state.rendered_facing_page = None;
            state.rendered_facing_page_handle = None;
            continue;
        }
        if state.page_cache.pop_oldest().is_some() {
            continue;
        }
        return None;
    }
}

fn attach_raster_permit(page: RenderedPage, permit: CachePermit) -> Option<RenderedPage> {
    if page.pixels.len() > permit.weight() {
        return None;
    }
    Some(RenderedPage {
        width: page.width,
        height: page.height,
        pixels: bytes::Bytes::from_owner(PermittedPixels {
            pixels: page.pixels,
            _permit: permit,
        }),
    })
}

fn invalidate_continuous_rasters(state: &mut State) {
    state.continuous_pages.fill(None);
    if let Some(tab_id) = state.active_tab_id {
        state.raster_failures.retain(|failure| {
            !matches!(failure, RasterFailure::Continuous { tab_id: failed_tab, .. } if *failed_tab == tab_id)
        });
    }
    state.render_generation = state.render_generation.wrapping_add(1);
}

fn update_window_scale_factor(state: &mut State, scale_factor: f32) -> Task<Message> {
    if !scale_factor.is_finite()
        || scale_factor <= 0.0
        || (state.window_scale_factor - scale_factor).abs() <= f32::EPSILON
    {
        return Task::none();
    }
    state.window_scale_factor = scale_factor;

    for tab in &mut state.tabs {
        if matches!(tab.session.document, OpenDocument::Pdf(_)) {
            tab.rendered_page = None;
            tab.rendered_page_index = None;
            tab.rendered_page_handle = None;
            tab.rendered_facing_page = None;
            tab.rendered_facing_page_handle = None;
            tab.page_cache.clear();
            tab.continuous_pages.fill(None);
            tab.continuous_pending.clear();
            tab.render_generation = tab.render_generation.wrapping_add(1);
        }
    }

    if !matches!(state.document, Some(OpenDocument::Pdf(_))) {
        return Task::none();
    }
    state.rendered_page = None;
    state.rendered_page_index = None;
    state.rendered_page_handle = None;
    state.rendered_facing_page = None;
    state.rendered_facing_page_handle = None;
    state.page_cache.clear();
    state.continuous_pages.fill(None);
    state.continuous_pending.clear();
    state.render_generation = state.render_generation.wrapping_add(1);
    refresh_content(state)
}

fn invalidate_continuous_layout(state: &mut State) {
    state.continuous_tail_extent = 0.0;
    state.continuous_activation = state.continuous_activation.wrapping_add(1);
    state.continuous_measurement_index = None;
    state.continuous_visible.clear();
}

fn content_navigation_task(state: &mut State) -> Task<Message> {
    if state.reading_mode == ReadingMode::Continuous {
        update_bookmark_status(state);
        scroll_to_current_page(state)
    } else {
        refresh_content(state)
    }
}

fn uses_paginated_raster_layout(state: &State) -> bool {
    state.reading_mode == ReadingMode::Paginated
        && matches!(
            state.document,
            Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
        )
}

fn uses_paginated_epub_layout(state: &State) -> bool {
    state.reading_mode == ReadingMode::Paginated
        && matches!(state.document, Some(OpenDocument::Epub(_)))
}

fn reader_layout_changed_task(state: &mut State) -> Task<Message> {
    if uses_paginated_raster_layout(state) || uses_paginated_epub_layout(state) {
        refresh_content(state)
    } else {
        scroll_to_current_page(state)
    }
}

fn uses_page_spreads(state: &State) -> bool {
    uses_paginated_raster_layout(state)
        && available_reader_size(state).width >= MIN_TWO_PAGE_WIDTH
        && state.total_pages > 1
}

fn available_reader_size(state: &State) -> Size {
    available_reader_size_with_panels(
        state,
        state.show_bookmarks_panel,
        state.show_search_bar,
        state.show_reader_settings,
        state.show_reader_more,
    )
}

fn available_reader_size_with_panels(
    state: &State,
    show_bookmarks_panel: bool,
    show_search_bar: bool,
    show_reader_settings: bool,
    show_reader_more: bool,
) -> Size {
    let window_size = state.performance.window_size().unwrap_or(state.window_size);
    let compact = uses_compact_reader_layout(window_size.width);
    let bookmarks_width = if show_bookmarks_panel {
        BOOKMARKS_PANEL_WIDTH
    } else {
        0.0
    };
    let search_height = if show_search_bar {
        reader_search_height(compact)
    } else {
        0.0
    };
    let settings_height = if show_reader_settings { 62.0 } else { 0.0 };
    let more_height = if show_reader_more {
        reader_more_height(compact)
    } else {
        0.0
    };
    Size::new(
        (window_size.width - bookmarks_width - READER_HORIZONTAL_PADDING).max(1.0),
        (window_size.height
            - READER_VERTICAL_CHROME
            - search_height
            - settings_height
            - more_height)
            .max(1.0),
    )
}

fn reader_search_height(compact: bool) -> f32 {
    if compact {
        COMPACT_READER_SEARCH_HEIGHT
    } else {
        READER_SEARCH_HEIGHT
    }
}

fn reader_more_height(compact: bool) -> f32 {
    if compact {
        COMPACT_READER_MORE_HEIGHT
    } else {
        READER_MORE_HEIGHT
    }
}

fn paginated_raster_pages(state: &State) -> Vec<usize> {
    paginated_raster_pages_at(state, state.current_page)
}

fn paginated_raster_pages_at(state: &State, page: usize) -> Vec<usize> {
    crate::pdf::visible_pages(state.total_pages, page, uses_page_spreads(state))
}

fn raster_page_size(state: &State, page: usize) -> Option<(f32, f32)> {
    match &state.document {
        Some(OpenDocument::Pdf(document)) => document.page_size(page).ok(),
        Some(OpenDocument::Cbz(document)) => document.cached_page_size(page),
        _ => None,
    }
}

fn paginated_raster_scale(state: &State, pages: &[usize]) -> f32 {
    if let ZoomMode::Manual(scale) = state.zoom {
        return scale;
    }
    let sizes = pages
        .iter()
        .filter_map(|page| raster_page_size(state, *page))
        .collect::<Vec<_>>();
    if sizes.is_empty() {
        return 1.0;
    }
    match state.zoom {
        ZoomMode::FitWidth => {
            crate::pdf::fit_scale(&sizes, available_reader_size(state), PAGE_GUTTER, false)
        }
        ZoomMode::FitPage => {
            crate::pdf::fit_scale(&sizes, available_reader_size(state), PAGE_GUTTER, true)
        }
        ZoomMode::Manual(_) => unreachable!(),
    }
}

fn raster_render_scale(state: &State, layout_scale: f32) -> f32 {
    if matches!(state.document, Some(OpenDocument::Pdf(_))) {
        layout_scale * pdf_raster_density(state)
    } else {
        layout_scale
    }
}

fn raster_logical_size(
    state: &State,
    page: usize,
    rendered: &RenderedPage,
    layout_scale: f32,
) -> Size {
    if matches!(state.document, Some(OpenDocument::Pdf(_)))
        && let Some((width, height)) = raster_page_size(state, page)
    {
        return Size::new(width * layout_scale, height * layout_scale);
    }
    Size::new(rendered.width as f32, rendered.height as f32)
}

fn uses_exact_paginated_raster_size(state: &State) -> bool {
    matches!(state.document, Some(OpenDocument::Pdf(_))) || state.zoom != ZoomMode::FitPage
}

fn pdf_raster_density(state: &State) -> f32 {
    state.window_scale_factor.max(PDF_MIN_RASTER_DENSITY)
}

fn zoom_step_scale(state: &State, step: f32) -> f32 {
    let current = if uses_paginated_raster_layout(state) {
        let pages = paginated_raster_pages(state);
        paginated_raster_scale(state, &pages)
    } else {
        state.zoom.scale()
    };
    (current + step).clamp(0.25, 5.0)
}

fn raster_page_slot_width(state: &State, page_count: usize, rendered_width: f32) -> f32 {
    crate::pdf::slot_width(
        available_reader_size(state).width,
        page_count,
        PAGE_GUTTER,
        rendered_width,
    )
}

fn next_page_location(state: &State) -> Option<usize> {
    state.document.as_ref()?;
    crate::pdf::next_page(
        state.total_pages,
        state.current_page,
        uses_page_spreads(state),
    )
}

fn previous_page_location(state: &State) -> Option<usize> {
    state.document.as_ref()?;
    crate::pdf::previous_page(state.current_page, uses_page_spreads(state))
}

fn render_page_task(
    tab_id: u64,
    generation: u64,
    key: PageCacheKey,
    transient_permit: Option<CachePermit>,
    document_permit: RetainedDocumentPermit,
    render: impl FnOnce() -> anyhow::Result<RenderedPage> + Send + 'static,
) -> Task<Message> {
    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let _document_permit = document_permit;
                let _transient_permit = transient_permit;
                render()
            })
            .await
            .map_err(|error| error.to_string())
            .and_then(|result| result.map_err(|error| error.to_string()))
        },
        move |result| Message::PageRendered {
            tab_id,
            generation,
            key,
            result,
        },
    )
}

fn prefetch_next_paginated_spread(state: &mut State) -> Task<Message> {
    let Some(next_page) = next_page_location(state) else {
        return Task::none();
    };
    let pages = paginated_raster_pages_at(state, next_page);
    let scale = raster_render_scale(state, paginated_raster_scale(state, &pages));
    let tab_id = state.active_tab_id.unwrap_or(0);
    let generation = state.render_generation;
    let mut tasks = Vec::new();

    for page in pages {
        if state.raster_jobs.len() >= RASTER_RENDER_WORKERS {
            break;
        }
        let highlights = if matches!(state.document, Some(OpenDocument::Pdf(_))) {
            search_highlights_for_page(state, page)
        } else {
            Vec::new()
        };
        let key = PageCacheKey {
            page,
            scale_bits: scale.to_bits(),
            highlights: highlights.clone(),
        };
        if is_page_cached(state, &key) {
            continue;
        }
        let job = RasterJob::Paginated {
            tab_id,
            generation,
            key: key.clone(),
        };
        if state.raster_failures.contains(&job.failure()) {
            continue;
        }
        match &state.document {
            Some(OpenDocument::Pdf(document)) => {
                let document = Arc::clone(document);
                let permit = match reserve_raster(state, page, scale) {
                    RasterAdmission::Ready(permit) => permit,
                    RasterAdmission::Busy => continue,
                    RasterAdmission::Rejected(_) => {
                        state.raster_failures.insert(job.failure());
                        continue;
                    }
                };
                let transient_permit = match reserve_render_transient(state, page, scale) {
                    RenderTransientAdmission::Ready(permit) => permit,
                    RenderTransientAdmission::Busy => continue,
                    RenderTransientAdmission::Rejected(_) => {
                        state.raster_failures.insert(job.failure());
                        continue;
                    }
                };
                tasks.push(render_page_task(
                    tab_id,
                    generation,
                    key.clone(),
                    Some(transient_permit),
                    retain_document_for_worker(state),
                    move || document.render_page_with_highlights(page, scale, &highlights),
                ));
                state.paginated_pending.push(key.clone());
                state.raster_jobs.insert(job, permit);
            }
            Some(OpenDocument::Cbz(document)) => {
                let document = Arc::clone(document);
                let permit = match reserve_raster(state, page, scale) {
                    RasterAdmission::Ready(permit) => permit,
                    RasterAdmission::Busy => continue,
                    RasterAdmission::Rejected(_) => {
                        state.raster_failures.insert(job.failure());
                        continue;
                    }
                };
                let transient_permit = match reserve_render_transient(state, page, scale) {
                    RenderTransientAdmission::Ready(permit) => permit,
                    RenderTransientAdmission::Busy => continue,
                    RenderTransientAdmission::Rejected(_) => {
                        state.raster_failures.insert(job.failure());
                        continue;
                    }
                };
                tasks.push(render_page_task(
                    tab_id,
                    generation,
                    key.clone(),
                    Some(transient_permit),
                    retain_document_for_worker(state),
                    move || document.render_page(page, scale),
                ));
                state.paginated_pending.push(key.clone());
                state.raster_jobs.insert(job, permit);
            }
            _ => return Task::none(),
        }
    }

    Task::batch(tasks)
}

fn is_page_cached(state: &State, key: &PageCacheKey) -> bool {
    state
        .page_cache
        .iter()
        .any(|(cached_key, _)| cached_key == key)
}

fn cache_rendered_page(state: &mut State, key: PageCacheKey, page: RenderedPage) {
    state.page_cache.insert(key, page);
}

fn raster_image_handle(rendered: &RenderedPage) -> RasterImageHandle {
    RasterImageHandle(image::Handle::from_rgba(
        rendered.width,
        rendered.height,
        rendered.pixels.clone(),
    ))
}

fn show_cached_paginated_spread(state: &mut State) -> bool {
    let pages = paginated_raster_pages(state);
    let target_pages = pages.clone();
    let scale = raster_render_scale(state, paginated_raster_scale(state, &pages));
    let rendered = pages
        .iter()
        .map(|page| {
            let highlights = if matches!(state.document, Some(OpenDocument::Pdf(_))) {
                search_highlights_for_page(state, *page)
            } else {
                Vec::new()
            };
            let key = PageCacheKey {
                page: *page,
                scale_bits: scale.to_bits(),
                highlights,
            };
            state
                .page_cache
                .iter()
                .find(|(cached_key, _)| cached_key == &key)
                .map(|(_, rendered)| (*page, rendered.clone()))
        })
        .collect::<Option<Vec<_>>>();
    let Some(rendered) = rendered else {
        return false;
    };

    let previous_pages = state.rendered_page_index.map(|page| {
        let mut pages = vec![page];
        if let Some((facing_page, _)) = state.rendered_facing_page.as_ref() {
            pages.push(*facing_page);
            pages.sort_unstable();
        }
        pages
    });

    state.rendered_page = rendered
        .iter()
        .find(|(page, _)| *page == state.current_page)
        .map(|(_, rendered)| rendered.clone());
    state.rendered_page_index = state.rendered_page.as_ref().map(|_| state.current_page);
    state.rendered_page_handle = state.rendered_page.as_ref().map(raster_image_handle);
    state.rendered_facing_page = rendered
        .into_iter()
        .find(|(page, _)| *page != state.current_page);
    state.rendered_facing_page_handle = state
        .rendered_facing_page
        .as_ref()
        .map(|(_, rendered)| raster_image_handle(rendered));
    previous_pages.as_ref() != Some(&target_pages)
}

fn displayed_paginated_raster_pages(state: &State) -> Vec<usize> {
    let Some(page) = state.rendered_page_index else {
        return paginated_raster_pages(state);
    };
    let mut pages = vec![page];
    if let Some((facing_page, _)) = state.rendered_facing_page.as_ref() {
        pages.push(*facing_page);
        pages.sort_unstable();
    }
    pages
}

fn refresh_bookmarks(state: &State) -> Task<Message> {
    if let (Some(tab_id), Some(path), Some(store)) =
        (state.active_tab_id, &state.file_path, &state.bookmark_store)
    {
        let store = store.clone();
        let path = path.clone();
        let book_id = state.book_id;
        let result_path = path.clone();
        Task::perform(
            async move {
                if let Some(book_id) = book_id {
                    store.list_for_book_async(book_id).await.unwrap_or_default()
                } else {
                    store.list_for_file_async(&path).await.unwrap_or_default()
                }
            },
            move |bookmarks| Message::BookmarksLoaded {
                tab_id,
                file_path: result_path.clone(),
                book_id,
                bookmarks,
            },
        )
    } else {
        Task::none()
    }
}

fn update_bookmark_status(state: &mut State) {
    let location_offset = current_epub_offset(state);
    state.current_page_bookmarked = state.bookmarks.iter().any(|bookmark| {
        bookmark.page == state.current_page
            && bookmark.location_offset == location_offset
            && bookmark.note.is_none()
    });
}

fn save_reading_state(state: &mut State) {
    if let (Some(path), Some(saves)) = (&state.file_path, &state.reading_state_saves) {
        let save = ReadingStateSave {
            book_id: state.book_id,
            path: path.clone(),
            reading: FileReadingState {
                page: state.current_page,
                location_offset: current_epub_offset(state),
                zoom: state.zoom.scale(),
            },
        };
        if let Err(error) = saves.send(ReadingStateWriterMessage::Save(save)) {
            state.open_error = Some(state_writer_send_error(error));
        }
    }

    // Also update library progress so the library sort/order stays current.
    if let (Some(saves), Some(book_id)) = (&state.reading_state_saves, state.book_id)
        && state.total_pages > 0
    {
        let progress = (state.current_page + 1) as f64 / state.total_pages as f64;
        let progress = progress.clamp(0.0, 1.0);
        if let Err(error) = saves.send(ReadingStateWriterMessage::Progress { book_id, progress }) {
            state.open_error = Some(state_writer_send_error(error));
        }
    }
}

fn save_preference(state: &mut State, key: &'static str, value: impl Into<String>) {
    if let Some(saves) = &state.reading_state_saves
        && let Err(error) = saves.send(ReadingStateWriterMessage::Preference(
            key.to_owned(),
            value.into(),
        ))
    {
        state.open_error = Some(state_writer_send_error(error));
    }
}

fn state_writer_send_error(error: StateWriterSendError) -> AppError {
    let detail = match error {
        StateWriterSendError::Stopped => "state writer stopped unexpectedly",
        StateWriterSendError::Full => {
            "state persistence queue is full; latest change was not saved"
        }
    };
    AppError::Storage(detail.to_owned())
}

fn flush_reading_state_before_close(state: &State, id: window::Id) -> Task<Message> {
    let Some(saves) = &state.reading_state_saves else {
        return window::close(id);
    };
    let saves = saves.clone();
    Task::perform(
        async move { saves.flush().await.map_err(|error| error.to_string()) },
        move |result| Message::ReadingStateFlushed { id, result },
    )
}

fn persist_window_geometry(state: &mut State) -> Task<Message> {
    if state.window_geometry_saving {
        return Task::none();
    }
    let Some(store) = state.reading_state.clone() else {
        return state
            .close_after_geometry_save
            .take()
            .map(window::close)
            .unwrap_or_else(Task::none);
    };
    state.window_geometry_dirty = false;
    state.window_geometry_saving = true;
    let size = state.window_size;
    let position = state.window_position;
    Task::perform(
        async move {
            let mut values = vec![
                (WINDOW_WIDTH_KEY, size.width.round() as i64),
                (WINDOW_HEIGHT_KEY, size.height.round() as i64),
            ];
            if let Some(position) = position {
                values.extend([
                    (WINDOW_X_KEY, position.x.round() as i64),
                    (WINDOW_Y_KEY, position.y.round() as i64),
                ]);
            }
            if let Err(error) = store.set_pref_ints_async(&values).await {
                eprintln!("warning: failed to save window geometry: {error}");
            }
        },
        |_| Message::WindowGeometryPersisted,
    )
}

fn perform_search(state: &mut State) -> Task<Message> {
    let query = state.search_query.clone();
    let document_generation = state.search_document_generation;
    let query_generation = state.search_query_generation;
    let Some(tab_id) = state.active_tab_id else {
        return Task::none();
    };
    let Some(document) = state.document.clone() else {
        return Task::none();
    };
    if !matches!(document, OpenDocument::Pdf(_) | OpenDocument::Epub(_)) {
        return Task::none();
    }
    let Some(worker) = state.search_admission.try_reserve(1) else {
        state.search_waiting = true;
        return Task::none();
    };
    let cancellation = SearchCancellation::new();
    state.search_cancellation = Some(cancellation.clone());
    state.search_loading = true;
    state.search_waiting = false;
    let document_permit = retain_document_for_worker(state);

    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let _document_permit = document_permit;
                let _worker = worker;
                match document {
                    OpenDocument::Pdf(document) => shosai_core::search::search_pdf_with(
                        &document,
                        &query,
                        SearchLimits::default(),
                        &cancellation,
                    ),
                    OpenDocument::Epub(document) => shosai_core::search::search_epub_with(
                        &document,
                        &query,
                        SearchLimits::default(),
                        &cancellation,
                    ),
                    OpenDocument::Cbz(_) => unreachable!("CBZ search is not scheduled"),
                }
            })
            .await
            .unwrap_or_else(|error| {
                Err(SearchError::Document(format!(
                    "search worker stopped unexpectedly: {error}"
                )))
            })
        },
        move |result| Message::SearchPerformed {
            tab_id,
            document_generation,
            query_generation,
            result,
        },
    )
}

fn cancel_active_search(state: &mut State) {
    if let Some(cancellation) = state.search_cancellation.take() {
        cancellation.cancel();
    }
    state.search_loading = false;
    state.search_waiting = false;
}

fn current_epub_offset(state: &State) -> Option<usize> {
    matches!(state.document, Some(OpenDocument::Epub(_))).then_some(state.epub_offset)
}

fn refresh_pdf_search_highlights_if_changed(
    state: &mut State,
    previous_highlights: &[SearchHighlight],
) -> Task<Message> {
    if matches!(state.document, Some(OpenDocument::Pdf(_)))
        && (state.reading_mode == ReadingMode::Continuous
            || previous_highlights != current_page_search_highlights(state))
    {
        if state.reading_mode == ReadingMode::Continuous {
            invalidate_continuous_rasters(state);
        }
        return refresh_content(state);
    }
    Task::none()
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

pub fn view(state: &State) -> Element<'_, Message> {
    match state.screen {
        Screen::Library => library_view(state),
        Screen::Reader => reader_view(state),
        Screen::Settings => settings_view(state),
    }
}

const COMPACT_READER_WIDTH: f32 = 860.0;

fn reader_view(state: &State) -> Element<'_, Message> {
    container(responsive(move |size| {
        reader_layout(state, uses_compact_reader_layout(size.width))
    }))
    .width(Length::Fill)
    .height(Length::Fill)
    .style(app_theme::app_background)
    .into()
}

fn uses_compact_reader_layout(width: f32) -> bool {
    width < COMPACT_READER_WIDTH
}

fn reader_layout(state: &State, compact: bool) -> Element<'_, Message> {
    let loading = state.document_open_notice_visible;
    let main_content = if loading {
        document_opening_view(state)
    } else {
        reader_surface(state, compact)
    };
    let body: Element<'_, Message> = if !loading && state.show_bookmarks_panel {
        if compact {
            bookmarks_panel(state, Length::Fill)
        } else {
            row![
                container(main_content)
                    .width(Length::Fill)
                    .height(Length::Fill),
                bookmarks_panel(state, Length::Fixed(300.0)),
            ]
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
        }
    } else {
        main_content
    };

    let mut layout = column![tabs_view(state), reader_header(state, compact)].spacing(0);

    if !loading && state.show_reader_settings {
        layout = layout.push(reader_settings(state, compact));
    }

    if !loading && state.show_reader_more {
        layout = layout.push(reader_more_panel(state, compact));
    }

    if !loading && state.show_search_bar {
        layout = layout.push(search_bar(state, compact));
    }

    if let Some(error) = &state.open_error {
        let mut alert = row![
            text(error.localized(&state.i18n))
                .size(13)
                .color(iced::Color::from_rgb8(0xA5, 0x43, 0x43)),
            iced::widget::Space::new().width(Length::Fill),
        ]
        .spacing(8)
        .align_y(iced::Alignment::Center);
        if let Some(book_id) = state.missing_book_id {
            let removing = state.removing_book == Some(book_id);
            alert = alert.push(widgets::primary_button(
                state.i18n.text("locate-file"),
                (!removing).then_some(Message::LocateBook(book_id)),
                state.i18n.ui_font(),
            ));
            alert = alert.push(widgets::secondary_button(
                state.i18n.text(if removing {
                    "removing"
                } else {
                    "remove-from-library"
                }),
                (!removing).then_some(Message::RemoveBook(book_id)),
                state.i18n.ui_font(),
            ));
        }
        layout = layout.push(
            container(alert)
                .padding([7, 14])
                .width(Length::Fill)
                .style(app_theme::reader_alert),
        );
    }

    layout = layout.push(body);
    if !loading {
        layout = layout.push(status_bar(state));
    }

    layout.width(Length::Fill).height(Length::Fill).into()
}

fn document_opening_view(state: &State) -> Element<'_, Message> {
    let preview = state.document_open_preview.as_ref();
    let title = preview
        .map(|preview| preview.title.clone())
        .unwrap_or_else(|| state.i18n.text("opening-document"));
    let cover: Element<'_, Message> =
        if let Some(handle) = preview.and_then(|preview| preview.cover.as_ref()) {
            image(handle.0.clone())
                .width(Length::Fixed(140.0))
                .height(Length::Fixed(200.0))
                .content_fit(iced::ContentFit::Contain)
                .into()
        } else {
            cover_placeholder(Length::Fixed(140.0), 200.0, &title)
        };

    center(
        column![
            container(cover)
                .width(Length::Fixed(140.0))
                .height(Length::Fixed(200.0))
                .style(app_theme::book_cover),
            text(title)
                .size(16)
                .width(Length::Fill)
                .align_x(iced::alignment::Horizontal::Center)
                .wrapping(iced::widget::text::Wrapping::WordOrGlyph),
            text(state.i18n.text("opening-document"))
                .size(13)
                .color(app_theme::TEXT_MUTED),
        ]
        .spacing(14)
        .align_x(iced::Alignment::Center)
        .width(Length::Fill)
        .max_width(320),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

fn reader_surface(state: &State, compact: bool) -> Element<'_, Message> {
    let content = container(content_view(state))
        .width(Length::Fill)
        .height(Length::Fill);

    if state.document.is_none() || state.reading_mode == ReadingMode::Continuous {
        return content.into();
    }

    let can_prev = if uses_paginated_epub_layout(state) {
        can_turn_epub_page(state, false)
    } else {
        previous_page_location(state).is_some()
    };
    let can_next = if uses_paginated_epub_layout(state) {
        can_turn_epub_page(state, true)
    } else {
        next_page_location(state).is_some()
    };

    row![
        reader_edge_button("‹", can_prev.then_some(Message::PrevPage), compact),
        content,
        reader_edge_button("›", can_next.then_some(Message::NextPage), compact),
    ]
    .align_y(iced::Alignment::Center)
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

fn reader_edge_button(
    label: &'static str,
    message: Option<Message>,
    compact: bool,
) -> iced::widget::Button<'static, Message> {
    button(
        container(text(label).size(if compact { 28 } else { 36 }))
            .height(Length::Fill)
            .center_y(Length::Fill),
    )
    .on_press_maybe(message)
    .padding([12, if compact { 8 } else { 16 }])
    .height(Length::Fill)
    .style(app_theme::reader_edge_button)
}

fn tabs_view(state: &State) -> Element<'_, Message> {
    let mut tabs = row![].spacing(3).padding([5, 10]);
    for (index, tab) in state.tabs.iter().enumerate() {
        let title = reader_tab_title(state, tab);
        let selected = state.active_tab == Some(index);
        tabs = tabs.push(
            container(
                row![
                    button(text(truncate_reader_label(&title, 34)).size(12))
                        .on_press(Message::SelectTab(index))
                        .padding(iced::Padding {
                            top: 6.0,
                            right: 4.0,
                            bottom: 6.0,
                            left: 10.0,
                        })
                        .style(app_theme::reader_tab_label(selected)),
                    button(text("×").size(12))
                        .padding(iced::Padding {
                            top: 6.0,
                            right: 8.0,
                            bottom: 6.0,
                            left: 4.0,
                        })
                        .on_press(Message::CloseTab(index))
                        .style(app_theme::reader_tab_close),
                ]
                .spacing(0)
                .align_y(iced::Alignment::Center),
            )
            .style(app_theme::reader_tab(selected)),
        );
    }
    container(
        scrollable(tabs).direction(scrollable::Direction::Horizontal(
            scrollable::Scrollbar::hidden(),
        )),
    )
    .width(Length::Fill)
    .style(app_theme::reader_tab_strip)
    .into()
}

fn truncate_reader_label(label: &str, max_chars: usize) -> String {
    if label.chars().count() <= max_chars {
        return label.to_string();
    }

    let mut shortened = label
        .chars()
        .take(max_chars.saturating_sub(1))
        .collect::<String>();
    shortened.push('…');
    shortened
}

fn status_bar(state: &State) -> Element<'_, Message> {
    let percentage = if uses_paginated_epub_layout(state) {
        reading_progress_percentage(state.epub_page, state.epub_pages.len())
    } else {
        reading_progress_percentage(state.current_page, state.total_pages)
    };
    let location = if uses_paginated_epub_layout(state) {
        let visible = epub_visible_pages(state);
        let first = visible.first().copied().unwrap_or(0) + 1;
        let last = visible.last().copied().unwrap_or(0) + 1;
        if first == last {
            state.i18n.text_with_args(
                "single-page-status",
                [("page", first.into()), ("percentage", percentage.into())],
            )
        } else {
            state.i18n.text_with_args(
                "page-range-status",
                [
                    ("first", first.into()),
                    ("last", last.into()),
                    ("percentage", percentage.into()),
                ],
            )
        }
    } else if state.document.is_some() {
        state.i18n.text_with_args(
            "single-page-status",
            [
                ("page", state.current_page.saturating_add(1).into()),
                ("percentage", percentage.into()),
            ],
        )
    } else {
        state.i18n.text("no-book-open")
    };

    container(
        column![
            container(widgets::reading_progress(f64::from(percentage) / 100.0))
                .width(Length::Fixed(280.0)),
            text(location).size(11).color(app_theme::TEXT_MUTED),
        ]
        .align_x(iced::Alignment::Center)
        .spacing(5),
    )
    .padding([7, 12])
    .width(Length::Fill)
    .center_x(Length::Fill)
    .style(app_theme::reader_status)
    .into()
}

fn reading_progress_percentage(current_page: usize, total_pages: usize) -> u32 {
    if total_pages == 0 {
        0
    } else {
        (((current_page + 1) as f32 / total_pages as f32) * 100.0).round() as u32
    }
}

fn reader_header(state: &State, compact: bool) -> Element<'_, Message> {
    let title = current_book_title(state).unwrap_or_else(|| state.i18n.text("reader"));
    let title = truncate_reader_label(&title, if compact { 24 } else { 58 });
    let actions = row![
        reader_control_button(
            state.i18n.text("contents"),
            state
                .document
                .as_ref()
                .map(|_| Message::ToggleBookmarksPanel),
            state.show_bookmarks_panel,
        ),
        reader_control_button(
            "Aa",
            state
                .document
                .as_ref()
                .map(|_| Message::ToggleReaderSettings),
            state.show_reader_settings,
        ),
        reader_control_button("⋯", Some(Message::ToggleReaderMore), state.show_reader_more),
    ]
    .spacing(4)
    .align_y(iced::Alignment::Center);

    container(
        row![
            widgets::secondary_button(
                state.i18n.text("back-library"),
                Some(Message::ShowLibrary),
                state.i18n.ui_font(),
            ),
            container(text(title).size(if compact { 15 } else { 17 }))
                .width(Length::Fill)
                .center_x(Length::Fill),
            actions,
        ]
        .spacing(if compact { 6 } else { 14 })
        .align_y(iced::Alignment::Center),
    )
    .padding([8, 14])
    .width(Length::Fill)
    .style(app_theme::reader_header)
    .into()
}

fn reader_control_button(
    label: impl Into<String>,
    message: Option<Message>,
    selected: bool,
) -> iced::widget::Button<'static, Message> {
    button(text(label.into()).size(13))
        .on_press_maybe(message)
        .padding([7, 10])
        .style(app_theme::reader_control_button(selected))
}

fn reader_settings(state: &State, compact: bool) -> Element<'_, Message> {
    let capabilities = state.document.as_ref().map(OpenDocument::capabilities);
    let is_pdf_or_cbz = capabilities.is_some_and(|capabilities| !capabilities.reflowable);
    let is_epub = capabilities.is_some_and(|capabilities| capabilities.reflowable);
    let mut reading = row![].spacing(5).align_y(iced::Alignment::Center);
    let mode_label = match state.reading_mode {
        ReadingMode::Paginated => state.i18n.text("paginated"),
        ReadingMode::Continuous => state.i18n.text("continuous"),
    };
    reading = reading.push(reader_control_button(
        mode_label,
        Some(Message::ToggleReadingMode),
        true,
    ));

    if is_pdf_or_cbz {
        reading = reading
            .push(reader_control_button("−", Some(Message::ZoomOut), false))
            .push(
                text(zoom_label(state))
                    .size(12)
                    .width(70)
                    .color(app_theme::TEXT_MUTED),
            )
            .push(reader_control_button("+", Some(Message::ZoomIn), false))
            .push(reader_control_button(
                state.i18n.text("fit-width"),
                Some(Message::SetZoomFitWidth),
                state.zoom == ZoomMode::FitWidth,
            ))
            .push(reader_control_button(
                state.i18n.text("fit-page"),
                Some(Message::SetZoomFitPage),
                state.zoom == ZoomMode::FitPage,
            ));
    }

    if is_epub {
        reading = reading
            .push(reader_control_button(
                "A−",
                Some(Message::FontSizeDown),
                false,
            ))
            .push(
                text(format!("{}px", state.font_size as u32))
                    .size(12)
                    .color(app_theme::TEXT_MUTED),
            )
            .push(reader_control_button(
                "A+",
                Some(Message::FontSizeUp),
                false,
            ))
            .push(reader_control_button(
                theme_label(state),
                Some(Message::CycleTheme),
                false,
            ));
    }

    container(
        scrollable(
            row![
                text(if compact {
                    state.i18n.text("reading")
                } else {
                    state.i18n.text("reading-appearance")
                })
                .size(12)
                .color(app_theme::TEXT_MUTED),
                container(reading)
                    .padding(4)
                    .style(app_theme::reader_control_group),
            ]
            .spacing(10)
            .align_y(iced::Alignment::Center),
        )
        .direction(scrollable::Direction::Horizontal(
            scrollable::Scrollbar::hidden(),
        )),
    )
    .padding([7, 12])
    .width(Length::Fill)
    .style(app_theme::reader_controls)
    .into()
}

fn zoom_label(state: &State) -> String {
    match state.zoom {
        ZoomMode::Manual(scale) => format!("{}%", (scale * 100.0) as u32),
        ZoomMode::FitWidth => state.i18n.text("fit-width"),
        ZoomMode::FitPage => state.i18n.text("fit-page"),
    }
}

fn theme_label(state: &State) -> String {
    state.i18n.text(match state.theme {
        ReaderTheme::Light => "light",
        ReaderTheme::Dark => "dark",
        ReaderTheme::Sepia => "sepia",
    })
}

fn reader_more_panel(state: &State, compact: bool) -> Element<'_, Message> {
    let capabilities = state.document.as_ref().map(OpenDocument::capabilities);
    let total = if uses_paginated_epub_layout(state) {
        state.epub_pages.len()
    } else {
        state.total_pages
    };
    let location = row![
        text_input(&state.i18n.text("page"), &state.page_input)
            .font(state.i18n.ui_font())
            .on_input(Message::PageInputChanged)
            .on_submit(Message::GoToPage)
            .padding([7, 8])
            .width(64),
        text(
            state
                .i18n
                .text_with_args("of-pages", [("total", total.into())]),
        )
        .size(12)
        .color(app_theme::TEXT_MUTED),
    ]
    .spacing(6)
    .align_y(iced::Alignment::Center);

    let mut actions = row![
        reader_control_button(
            if state.current_page_bookmarked {
                state.i18n.text("saved")
            } else {
                state.i18n.text("bookmark")
            },
            state.document.as_ref().map(|_| Message::ToggleBookmark),
            state.current_page_bookmarked,
        ),
        reader_control_button(state.i18n.text("open-book"), Some(Message::OpenFile), false),
    ]
    .spacing(5)
    .align_y(iced::Alignment::Center);
    if capabilities.is_some_and(|capabilities| capabilities.searchable) {
        actions = actions.push(reader_control_button(
            state.i18n.text("search"),
            Some(Message::ToggleSearchBar),
            state.show_search_bar,
        ));
    }

    let controls: Element<'_, Message> = if compact {
        column![location, actions].spacing(7).into()
    } else {
        row![
            location,
            iced::widget::Space::new().width(Length::Fill),
            actions
        ]
        .align_y(iced::Alignment::Center)
        .into()
    };
    container(controls)
        .padding([7, 12])
        .width(Length::Fill)
        .height(reader_more_height(compact))
        .style(app_theme::reader_controls)
        .into()
}

fn bookmarks_panel(state: &State, width: Length) -> Element<'_, Message> {
    let heading = row![
        column![
            text(state.i18n.text("contents")).size(18),
            text(state.i18n.text("chapters-saved-places"))
                .size(11)
                .color(app_theme::TEXT_MUTED),
        ]
        .spacing(2),
        iced::widget::Space::new().width(Length::Fill),
        reader_control_button("×", Some(Message::ToggleBookmarksPanel), false),
    ]
    .align_y(iced::Alignment::Center);
    let mut panel = column![heading].spacing(10).padding(14).width(Length::Fill);

    if let Some(OpenDocument::Epub(document)) = &state.document {
        panel = panel.push(
            text(state.i18n.text("chapters"))
                .size(12)
                .color(app_theme::TEXT_MUTED),
        );
        let toc = epub_toc_locations(document);
        if toc.is_empty() {
            for (index, chapter) in document.content().chapters.iter().enumerate() {
                let title = chapter
                    .title
                    .clone()
                    .filter(|title| !title.trim().is_empty())
                    .unwrap_or_else(|| {
                        state
                            .i18n
                            .text_with_args("chapter-number", [("number", (index + 1).into())])
                    });
                panel = panel.push(
                    button(text(truncate_reader_label(&title, 38)).size(12))
                        .on_press(Message::GoToBookmark(index, None))
                        .padding([6, 8])
                        .width(Length::Fill)
                        .style(app_theme::bookmark_link),
                );
            }
        } else {
            for (depth, title, chapter, offset) in toc {
                panel = panel.push(
                    row![
                        iced::widget::Space::new().width((depth * 12) as f32),
                        button(text(truncate_reader_label(&title, 38)).size(12))
                            .on_press(Message::GoToBookmark(chapter, Some(offset)))
                            .padding([6, 8])
                            .width(Length::Fill)
                            .style(app_theme::bookmark_link),
                    ]
                    .width(Length::Fill),
                );
            }
        }
    }

    panel = panel.push(
        text(
            state
                .i18n
                .text_with_args("bookmark-count", [("count", state.bookmarks.len().into())]),
        )
        .size(12)
        .color(app_theme::TEXT_MUTED),
    );

    if state.bookmarks.is_empty() {
        panel = panel.push(
            container(
                column![
                    text(state.i18n.text("no-bookmarks")).size(15),
                    text(state.i18n.text("bookmark-empty-hint"))
                        .size(12)
                        .color(app_theme::TEXT_MUTED),
                ]
                .spacing(5),
            )
            .padding([18, 4]),
        );
    } else {
        for bm in &state.bookmarks {
            let title = bm.title.clone().unwrap_or_else(|| {
                state
                    .i18n
                    .text_with_args("page-short", [("page", (bm.page + 1).into())])
            });

            let is_editing = state.editing_note_id == Some(bm.id);

            let mut entry_col = column![].spacing(4);

            // Header row: title + page + delete button
            let header = row![
                button(text(title).size(12))
                    .on_press(Message::GoToBookmark(bm.page, bm.location_offset))
                    .padding([4, 6])
                    .style(app_theme::bookmark_link),
                iced::widget::Space::new().width(Length::Fill),
                text(
                    state
                        .i18n
                        .text_with_args("page-abbreviated", [("page", (bm.page + 1).into())],)
                )
                .size(10)
                .color(app_theme::TEXT_MUTED),
                button(text("\u{2715}").size(10))
                    .on_press(Message::DeleteBookmark(bm.id))
                    .padding([4, 6])
                    .style(app_theme::reader_tab_close),
            ]
            .spacing(6)
            .align_y(iced::Alignment::Center);

            entry_col = entry_col.push(header);

            if is_editing {
                // Note editing mode
                let input = text_input(
                    &state.i18n.text("add-note-placeholder"),
                    &state.editing_note_text,
                )
                .font(editable_text_font(
                    &state.editing_note_text,
                    &state.i18n.text("add-note-placeholder"),
                ))
                .on_input(Message::EditNoteChanged)
                .on_submit(Message::SaveNote)
                .size(12)
                .padding(8)
                .width(Length::Fill);
                entry_col = entry_col.push(input);
                entry_col = entry_col.push(
                    row![
                        reader_control_button(
                            state.i18n.text("save"),
                            Some(Message::SaveNote),
                            true,
                        ),
                        reader_control_button(
                            state.i18n.text("cancel"),
                            Some(Message::CancelEditNote),
                            false,
                        ),
                    ]
                    .spacing(5),
                );
            } else {
                if let Some(note) = &bm.note {
                    entry_col =
                        entry_col.push(text(note.clone()).size(11).color(app_theme::TEXT_MUTED));
                }
                let edit_label = if bm.note.is_some() {
                    state.i18n.text("edit-note")
                } else {
                    state.i18n.text("add-note")
                };
                let existing_note = bm.note.clone().unwrap_or_default();
                entry_col = entry_col.push(
                    button(text(edit_label).size(10))
                        .on_press(Message::StartEditNote(bm.id, existing_note))
                        .padding([4, 6])
                        .style(app_theme::bookmark_link),
                );
            }

            panel = panel.push(
                container(entry_col)
                    .padding(10)
                    .width(Length::Fill)
                    .style(app_theme::bookmark_entry),
            );
        }
    }

    if !state.bookmarks.is_empty() {
        panel = panel.push(widgets::secondary_button(
            state.i18n.text("export-markdown"),
            Some(Message::ExportBookmarks),
            state.i18n.ui_font(),
        ));
    }

    container(scrollable(panel).height(Length::Fill))
        .width(width)
        .height(Length::Fill)
        .style(app_theme::bookmarks_panel)
        .into()
}

fn search_bar(state: &State, compact: bool) -> Element<'_, Message> {
    let placeholder = state.i18n.text("search-document-placeholder");
    let input = text_input(&placeholder, &state.search_query)
        .font(editable_text_font(&state.search_query, &placeholder))
        .id(search_input_id())
        .on_input(Message::SearchQueryChanged)
        .on_submit(Message::SearchNext)
        .padding([8, 10])
        .width(Length::Fill);

    let result_info = if state.search_results.is_empty() {
        if state.search_query.is_empty() {
            String::new()
        } else {
            state.i18n.text("no-results")
        }
    } else {
        format!(
            "{} / {}",
            state.search_current + 1,
            state.search_results.len()
        )
    };

    let has_results = !state.search_results.is_empty();

    let actions = row![
        text(result_info).size(12).color(app_theme::TEXT_MUTED),
        reader_control_button("‹", has_results.then_some(Message::SearchPrev), false),
        reader_control_button("›", has_results.then_some(Message::SearchNext), false),
        reader_control_button("×", Some(Message::CloseSearch), false),
    ]
    .spacing(5)
    .align_y(iced::Alignment::Center);
    let bar: Element<'_, Message> = if compact {
        column![input, actions].spacing(7).into()
    } else {
        row![
            container(input).width(Length::Fill).max_width(420),
            iced::widget::Space::new().width(Length::Fill),
            actions,
        ]
        .spacing(10)
        .align_y(iced::Alignment::Center)
        .into()
    };

    container(bar)
        .padding([8, 12])
        .width(Length::Fill)
        .height(reader_search_height(compact))
        .style(app_theme::reader_search)
        .into()
}

fn search_input_id() -> iced::widget::Id {
    iced::widget::Id::new("document-search-query")
}

fn content_view(state: &State) -> Element<'_, Message> {
    if let Some(error) = &state.error {
        return center(text(error.localized(&state.i18n)).size(16))
            .width(Length::Fill)
            .height(Length::Fill)
            .into();
    }

    if state.reading_mode == ReadingMode::Continuous {
        return continuous_content_view(state);
    }

    match &state.document {
        Some(OpenDocument::Pdf(_) | OpenDocument::Cbz(_)) => pdf_page_view(state),
        Some(OpenDocument::Epub(_)) => epub_chapter_view(state),
        None => welcome_view(state),
    }
}

fn continuous_content_view(state: &State) -> Element<'_, Message> {
    let tab_id = state.active_tab_id.unwrap_or(0);
    let activation = state.continuous_activation;
    match &state.document {
        Some(OpenDocument::Pdf(_) | OpenDocument::Cbz(_)) => {
            let mut pages = column![].spacing(20).padding(20).width(Length::Fill);
            for (index, rendered) in state.continuous_pages.iter().enumerate() {
                let content: Element<'_, Message> = if let Some(rendered) = rendered {
                    let handle = image::Handle::from_rgba(
                        rendered.width,
                        rendered.height,
                        rendered.pixels.clone(),
                    );
                    let logical_size =
                        raster_logical_size(state, index, rendered, state.zoom.scale());
                    image(handle)
                        .width(Length::Fixed(logical_size.width))
                        .height(Length::Fixed(logical_size.height))
                        .into()
                } else {
                    let page_height = match &state.document {
                        Some(OpenDocument::Pdf(doc)) => doc.page_size(index).ok(),
                        Some(OpenDocument::Cbz(doc)) => doc.cached_page_size(index),
                        _ => None,
                    }
                    .map(|(_, height)| height * state.zoom.scale())
                    .unwrap_or(600.0);
                    center(text(state.i18n.text("rendering")))
                        .height(page_height)
                        .into()
                };
                let page = container(
                    column![
                        text(
                            state
                                .i18n
                                .text_with_args("page-number", [("page", (index + 1).into())],)
                        )
                        .size(12),
                        content
                    ]
                    .spacing(4)
                    .align_x(iced::Alignment::Center)
                    .width(Length::Fill),
                )
                .id(continuous_item_id(tab_id, activation, index))
                .width(Length::Fill);
                let generation = state.render_generation;
                pages = pages.push(
                    sensor(page)
                        .key((generation, index))
                        .anticipate(1000)
                        .on_show(move |_| Message::ContinuousItemVisibility {
                            tab_id,
                            activation,
                            page: index,
                            visible: true,
                        })
                        .on_hide(Message::ContinuousItemVisibility {
                            tab_id,
                            activation,
                            page: index,
                            visible: false,
                        }),
                );
            }
            pages = pages.push(iced::widget::Space::new().height(state.continuous_tail_extent));
            scrollable(pages)
                .id(continuous_scroll_id(tab_id, activation))
                .on_scroll(move |viewport| Message::ContinuousScrolled {
                    tab_id,
                    activation,
                    offset: viewport.absolute_offset().y,
                })
                .width(Length::Fill)
                .height(Length::Fill)
                .into()
        }
        Some(OpenDocument::Epub(doc)) => {
            continuous_epub_content_view(state, doc, tab_id, activation)
        }
        None => welcome_view(state),
    }
}

fn pdf_page_view(state: &State) -> Element<'_, Message> {
    let pages = displayed_paginated_raster_pages(state);
    if pages.is_empty() {
        return center(text(state.i18n.text("rendering")).size(16))
            .width(Length::Fill)
            .height(Length::Fill)
            .into();
    }

    let rendered_for = |page: usize| {
        if state.rendered_page_index == Some(page) {
            state
                .rendered_page
                .as_ref()
                .zip(state.rendered_page_handle.as_ref())
        } else {
            state
                .rendered_facing_page
                .as_ref()
                .filter(|(index, _)| *index == page)
                .map(|(_, rendered)| rendered)
                .zip(state.rendered_facing_page_handle.as_ref())
        }
    };

    let page_count = pages.len();
    let layout_scale = paginated_raster_scale(state, &pages);
    let mut spread = row![].spacing(PAGE_GUTTER).padding(20);
    for (visible_index, page) in pages.into_iter().enumerate() {
        let rendered = rendered_for(page);
        let rendered_width = rendered.map_or(0.0, |(rendered, _)| {
            raster_logical_size(state, page, rendered, layout_scale).width
        });
        let content: Element<'_, Message> = if let Some((rendered, handle)) = rendered {
            if uses_exact_paginated_raster_size(state) {
                let logical_size = raster_logical_size(state, page, rendered, layout_scale);
                image(&handle.0)
                    .width(Length::Fixed(logical_size.width))
                    .height(Length::Fixed(logical_size.height))
                    .into()
            } else {
                image(&handle.0)
                    .width(Length::Fill)
                    .height(Length::Fill)
                    .content_fit(iced::ContentFit::Contain)
                    .into()
            }
        } else {
            center(text(state.i18n.text_with_args(
                "rendering-page",
                [("page", (page + 1).into())],
            )))
            .into()
        };
        let page_container = match state.zoom {
            ZoomMode::FitPage => container(content)
                .width(Length::FillPortion(1))
                .height(Length::Fill)
                .align_x(paginated_spread_alignment(visible_index, page_count))
                .center_y(Length::Fill),
            ZoomMode::Manual(_) | ZoomMode::FitWidth => {
                let slot_width = raster_page_slot_width(state, page_count, rendered_width);
                container(content)
                    .width(Length::Fixed(slot_width))
                    .center_x(Length::Fixed(slot_width))
            }
        };
        spread = spread.push(page_container);
    }

    match state.zoom {
        ZoomMode::Manual(_) | ZoomMode::FitWidth => {
            scrollable(container(spread).center_x(Length::Fill))
                .direction(scrollable::Direction::Both {
                    vertical: scrollable::Scrollbar::default(),
                    horizontal: scrollable::Scrollbar::default(),
                })
                .width(Length::Fill)
                .height(Length::Fill)
                .into()
        }
        ZoomMode::FitPage => container(spread)
            .width(Length::Fill)
            .height(Length::Fill)
            .into(),
    }
}

fn paginated_spread_alignment(visible_index: usize, page_count: usize) -> iced::Alignment {
    match (visible_index, page_count) {
        (_, 1) => iced::Alignment::Center,
        (0, _) => iced::Alignment::End,
        _ => iced::Alignment::Start,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SearchHighlight {
    start: usize,
    end: usize,
    current: bool,
}

fn current_page_search_highlights(state: &State) -> Vec<SearchHighlight> {
    search_highlight_models_for_page(state, state.current_page)
}

fn search_highlight_models_for_page(state: &State, page: usize) -> Vec<SearchHighlight> {
    state
        .search_results
        .iter()
        .enumerate()
        .filter(|(_, result)| result.page == page)
        .map(|(index, result)| SearchHighlight {
            start: result.offset,
            end: result.offset + result.length,
            current: index == state.search_current,
        })
        .collect()
}

fn library_view(state: &State) -> Element<'_, Message> {
    container(responsive(move |size| library_layout(state, size.width)))
        .width(Length::Fill)
        .height(Length::Fill)
        .style(app_theme::app_background)
        .into()
}

fn library_layout(state: &State, available_width: f32) -> Element<'_, Message> {
    let compact = available_width < 760.0;
    let header = library_header(state, compact);
    let collection = library_collection(state);

    let content: Element<'_, Message> = if compact {
        column![header, mobile_library_filters(state), collection]
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    } else {
        column![
            header,
            row![library_sidebar(state), collection]
                .width(Length::Fill)
                .height(Length::Fill),
        ]
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
    };
    let content = if state.book_menu.is_some() {
        mouse_area(content).on_press(Message::CloseBookMenu).into()
    } else {
        content
    };

    if let Some(book) = state
        .pending_remove_book
        .and_then(|book_id| state.library_books.iter().find(|book| book.id == book_id))
    {
        return modal_overlay(
            content,
            remove_book_modal(state, book),
            Message::CancelRemoveBook,
        );
    }
    if state.add_books_open {
        return modal_overlay(content, add_books_modal(state), Message::CancelAddBooks);
    }
    content
}

fn library_header(state: &State, compact: bool) -> Element<'_, Message> {
    let placeholder = state.i18n.text("search-library-placeholder");
    let search_input = text_input(&placeholder, &state.library_search)
        .font(editable_text_font(&state.library_search, &placeholder))
        .id(library_search_input_id())
        .on_input(Message::LibrarySearchChanged)
        .padding([10, 12])
        .width(Length::Fill);
    let search = container(search_input).width(Length::Fill).max_width(380);
    let add_message = (state.library.is_some() && !state.adding_books && !state.moving_library)
        .then_some(Message::OpenAddBooks);
    let add_label = if state.adding_books && state.book_import_total > 0 {
        state.i18n.text_with_args(
            "adding-books-progress",
            [
                ("completed", (state.book_import_completed as i64).into()),
                ("total", (state.book_import_total as i64).into()),
            ],
        )
    } else if state.adding_books {
        state.i18n.text("adding-books")
    } else {
        state.i18n.text("add-books")
    };

    let content: Element<'_, Message> = if compact {
        column![
            column![
                text(state.i18n.text("library")).size(26),
                text(state.i18n.text("library-subtitle"))
                    .size(12)
                    .color(app_theme::TEXT_MUTED),
            ]
            .spacing(2),
            search,
            widgets::primary_button(add_label, add_message, state.i18n.ui_font()),
        ]
        .spacing(12)
        .into()
    } else {
        row![
            column![
                text(state.i18n.text("library")).size(26),
                text(state.i18n.text("library-subtitle"))
                    .size(12)
                    .color(app_theme::TEXT_MUTED),
            ]
            .spacing(2),
            iced::widget::Space::new().width(Length::Fill),
            search,
            widgets::primary_button(add_label, add_message, state.i18n.ui_font()),
        ]
        .spacing(16)
        .align_y(iced::Alignment::Center)
        .into()
    };

    let activity_opacity = state.library_activity_opacity;
    let activity: Element<'_, Message> =
        widgets::reading_progress(f64::from(state.library_activity_progress))
            .style(move |theme| {
                let mut style = app_theme::progress(theme);
                style.background = style.background.scale_alpha(activity_opacity);
                style.bar = style.bar.scale_alpha(activity_opacity);
                style
            })
            .into();
    let header = column![
        container(content).padding([16, 20]).width(Length::Fill),
        activity,
    ];

    container(header)
        .width(Length::Fill)
        .style(|_theme| container::Style {
            background: Some(iced::Background::Color(app_theme::SURFACE)),
            border: iced::Border {
                color: app_theme::BORDER,
                width: 0.0,
                radius: 0.0.into(),
            },
            shadow: iced::Shadow {
                color: iced::Color::from_rgba8(0x21, 0x20, 0x1E, 0.08),
                offset: iced::Vector::new(0.0, 1.0),
                blur_radius: 6.0,
            },
            ..container::Style::default()
        })
        .into()
}

fn language_selector(state: &State) -> Element<'static, Message> {
    let options = [
        SelectOption {
            value: LanguagePreference::System,
            label: state.i18n.text("language-system"),
        },
        SelectOption {
            value: LanguagePreference::English,
            label: state.i18n.text("language-english"),
        },
        SelectOption {
            value: LanguagePreference::Japanese,
            label: state.i18n.text("language-japanese"),
        },
    ];
    let selected = options
        .iter()
        .find(|option| option.value == state.i18n.preference())
        .cloned();

    pick_list(options, selected, |option| {
        Message::SelectLanguage(option.value)
    })
    .font(language_menu_font())
    .text_size(14)
    .padding([9, 12])
    .into()
}

fn settings_view(state: &State) -> Element<'_, Message> {
    container(responsive(move |size| settings_layout(state, size.width)))
        .width(Length::Fill)
        .height(Length::Fill)
        .style(app_theme::app_background)
        .into()
}

fn settings_layout(state: &State, available_width: f32) -> Element<'_, Message> {
    let compact = available_width < 760.0;
    let heading = page_header(
        state.i18n.text("settings"),
        state.i18n.text("settings-subtitle"),
    );
    let settings = settings_content(state, compact);

    let content: Element<'_, Message> = if compact {
        column![heading, mobile_library_filters(state), settings]
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    } else {
        column![
            heading,
            row![library_sidebar(state), settings]
                .width(Length::Fill)
                .height(Length::Fill),
        ]
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
    };
    if state.pending_library_move.is_some() {
        modal_overlay(
            content,
            managed_library_move_modal(state),
            Message::CancelManagedLibraryMove,
        )
    } else {
        content
    }
}

fn page_header(title: String, subtitle: String) -> Element<'static, Message> {
    container(
        column![
            text(title).size(26),
            text(subtitle).size(12).color(app_theme::TEXT_MUTED),
        ]
        .spacing(2),
    )
    .padding([16, 20])
    .width(Length::Fill)
    .style(|_theme| container::Style {
        background: Some(iced::Background::Color(app_theme::SURFACE)),
        shadow: iced::Shadow {
            color: iced::Color::from_rgba8(0x21, 0x20, 0x1E, 0.08),
            offset: iced::Vector::new(0.0, 1.0),
            blur_radius: 6.0,
        },
        ..container::Style::default()
    })
    .into()
}

fn settings_content(state: &State, compact: bool) -> Element<'_, Message> {
    let general = container(
        column![
            text(state.i18n.text("language")).size(16),
            text(state.i18n.text("language-description"))
                .size(13)
                .color(app_theme::TEXT_MUTED),
            language_selector(state),
        ]
        .spacing(10),
    )
    .padding(20)
    .width(Length::Fill)
    .style(app_theme::modal);

    let managed_path = state
        .library
        .as_ref()
        .map(|library| library.managed_dir().display().to_string())
        .unwrap_or_else(|| state.i18n.text("unavailable"));
    let library_available = state.library.is_some()
        && !state.moving_library
        && !state.adding_books
        && state.removing_book.is_none();
    let library_settings = container(
        column![
            text(state.i18n.text("managed-books-location")).size(16),
            text(state.i18n.text("managed-books-location-description"))
                .size(13)
                .color(app_theme::TEXT_MUTED),
            container(text(managed_path).size(12))
                .padding([9, 12])
                .width(Length::Fill)
                .style(app_theme::skeleton),
            row![
                widgets::secondary_button(
                    state.i18n.text("open-folder"),
                    library_available.then_some(Message::OpenManagedLibraryFolder),
                    state.i18n.ui_font(),
                ),
                widgets::secondary_button(
                    state.i18n.text("change-location"),
                    library_available.then_some(Message::ChooseManagedLibraryParent),
                    state.i18n.ui_font(),
                ),
            ]
            .spacing(8),
            iced::widget::Space::new().height(8),
            text(state.i18n.text("when-adding-books")).size(16),
            text(state.i18n.text("when-adding-books-description"))
                .size(13)
                .color(app_theme::TEXT_MUTED),
            add_book_behavior_selector(state),
        ]
        .spacing(10),
    )
    .padding(20)
    .width(Length::Fill)
    .style(app_theme::modal);

    let reading_mode = row![
        reader_control_button(
            state.i18n.text("paginated"),
            Some(Message::SelectDefaultReadingMode(ReadingMode::Paginated)),
            state.reader_defaults.reading_mode == ReadingMode::Paginated,
        ),
        reader_control_button(
            state.i18n.text("continuous"),
            Some(Message::SelectDefaultReadingMode(ReadingMode::Continuous)),
            state.reader_defaults.reading_mode == ReadingMode::Continuous,
        ),
    ]
    .spacing(5);
    let font_size = row![
        widgets::secondary_button(
            "−",
            Some(Message::DefaultEpubFontSizeDown),
            state.i18n.ui_font(),
        ),
        container(text(format!(
            "{} px",
            state.reader_defaults.epub_font_size as u32
        )))
        .padding([9, 12]),
        widgets::secondary_button(
            "+",
            Some(Message::DefaultEpubFontSizeUp),
            state.i18n.ui_font(),
        ),
    ]
    .spacing(5)
    .align_y(iced::Alignment::Center);
    let reading_settings = container(
        column![
            setting_control(
                state.i18n.text("default-reading-mode"),
                reading_mode.into(),
                compact,
            ),
            setting_control(
                state.i18n.text("default-theme"),
                reader_theme_selector(state),
                compact,
            ),
            settings_format_divider("EPUB"),
            setting_control(
                state.i18n.text("default-epub-font-size"),
                font_size.into(),
                compact,
            ),
            setting_control(
                state.i18n.text("default-epub-line-spacing"),
                line_spacing_selector(state),
                compact,
            ),
            settings_format_divider("PDF"),
            setting_control(
                state.i18n.text("default-pdf-zoom"),
                pdf_zoom_selector(state),
                compact,
            ),
        ]
        .spacing(14),
    )
    .padding(20)
    .width(Length::Fill)
    .style(app_theme::modal);

    let mut content = column![
        text(state.i18n.text("general")).size(18),
        general,
        text(state.i18n.text("library")).size(18),
        library_settings,
        text(state.i18n.text("reading-defaults")).size(18),
        text(state.i18n.text("reading-defaults-description"))
            .size(13)
            .color(app_theme::TEXT_MUTED),
        reading_settings,
    ]
    .spacing(14);
    if let Some(error) = &state.settings_error {
        content = content.push(
            container(text(error.clone()).size(12))
                .padding([8, 12])
                .width(Length::Fill)
                .style(app_theme::reader_alert),
        );
    }

    scrollable(
        container(content)
            .padding([24, 28])
            .width(Length::Fill)
            .max_width(760),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

fn settings_format_divider(label: &'static str) -> Element<'static, Message> {
    row![
        text(label).size(12).color(app_theme::TEXT_MUTED),
        container(iced::widget::Space::new())
            .height(1)
            .width(Length::Fill)
            .style(|_theme| container::Style {
                background: Some(iced::Background::Color(app_theme::BORDER)),
                ..container::Style::default()
            }),
    ]
    .spacing(10)
    .align_y(iced::Alignment::Center)
    .into()
}

fn setting_control(
    label: String,
    control: Element<'static, Message>,
    compact: bool,
) -> Element<'static, Message> {
    if compact {
        column![text(label).size(14), control].spacing(8).into()
    } else {
        row![
            text(label).size(14),
            iced::widget::Space::new().width(Length::Fill),
            control,
        ]
        .align_y(iced::Alignment::Center)
        .into()
    }
}

fn add_book_behavior_selector(state: &State) -> Element<'static, Message> {
    let options = [
        SelectOption {
            value: AddBookBehavior::Ask,
            label: state.i18n.text("add-behavior-ask"),
        },
        SelectOption {
            value: AddBookBehavior::Copy,
            label: state.i18n.text("add-behavior-copy"),
        },
        SelectOption {
            value: AddBookBehavior::CurrentLocation,
            label: state.i18n.text("add-behavior-current-location"),
        },
    ];
    let selected = options
        .iter()
        .find(|option| option.value == state.add_book_behavior)
        .cloned();
    pick_list(options, selected, |option| {
        Message::SelectAddBookBehavior(option.value)
    })
    .font(state.i18n.ui_font())
    .text_size(14)
    .padding([9, 12])
    .into()
}

fn reader_theme_selector(state: &State) -> Element<'static, Message> {
    let options = [
        SelectOption {
            value: ReaderTheme::Light,
            label: state.i18n.text("light"),
        },
        SelectOption {
            value: ReaderTheme::Dark,
            label: state.i18n.text("dark"),
        },
        SelectOption {
            value: ReaderTheme::Sepia,
            label: state.i18n.text("sepia"),
        },
    ];
    let selected = options
        .iter()
        .find(|option| option.value == state.reader_defaults.theme)
        .cloned();
    pick_list(options, selected, |option| {
        Message::SelectDefaultReaderTheme(option.value)
    })
    .font(state.i18n.ui_font())
    .text_size(14)
    .padding([9, 12])
    .into()
}

fn line_spacing_selector(state: &State) -> Element<'static, Message> {
    let options = [1.2_f32, 1.4, 1.6, 1.8, 2.0].map(|value| SelectOption {
        value,
        label: format!("{value:.1}"),
    });
    let selected = options
        .iter()
        .find(|option| option.value == state.reader_defaults.epub_line_spacing)
        .cloned()
        .or_else(|| {
            Some(SelectOption {
                value: state.reader_defaults.epub_line_spacing,
                label: format!("{:.1}", state.reader_defaults.epub_line_spacing),
            })
        });
    pick_list(options, selected, |option| {
        Message::SelectDefaultEpubLineSpacing(option.value)
    })
    .font(state.i18n.ui_font())
    .text_size(14)
    .padding([9, 12])
    .into()
}

fn pdf_zoom_selector(state: &State) -> Element<'static, Message> {
    let options = [
        SelectOption {
            value: false,
            label: state.i18n.text("fit-page"),
        },
        SelectOption {
            value: true,
            label: state.i18n.text("fit-width"),
        },
    ];
    let fit_width = state.reader_defaults.pdf_zoom == ZoomMode::FitWidth;
    let selected = options
        .iter()
        .find(|option| option.value == fit_width)
        .cloned();
    pick_list(options, selected, |option| {
        Message::SelectDefaultPdfFitWidth(option.value)
    })
    .font(state.i18n.ui_font())
    .text_size(14)
    .padding([9, 12])
    .into()
}

fn library_sidebar(state: &State) -> Element<'_, Message> {
    let content = column![
        column![
            text(state.i18n.text("collection"))
                .size(11)
                .color(app_theme::TEXT_MUTED),
            widgets::navigation_button(
                state.i18n.text("all-books"),
                state.screen == Screen::Library && state.library_filter.is_none(),
                Message::LibraryFilterChanged(None),
                state.i18n.ui_font(),
            ),
            widgets::navigation_button(
                "EPUB",
                state.screen == Screen::Library
                    && state.library_filter == Some(shosai_core::library::BookFormat::Epub),
                Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Epub)),
                state.i18n.ui_font(),
            ),
            widgets::navigation_button(
                "PDF",
                state.screen == Screen::Library
                    && state.library_filter == Some(shosai_core::library::BookFormat::Pdf),
                Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Pdf)),
                state.i18n.ui_font(),
            ),
        ]
        .spacing(6),
        iced::widget::Space::new().height(Length::Fill),
        widgets::navigation_button(
            state.i18n.text("settings"),
            state.screen == Screen::Settings,
            Message::ShowSettings,
            state.i18n.ui_font(),
        ),
    ]
    .spacing(12)
    .padding([22, 14])
    .height(Length::Fill);

    container(content)
        .width(184)
        .height(Length::Fill)
        .style(app_theme::sidebar)
        .into()
}

fn mobile_library_filters(state: &State) -> Element<'_, Message> {
    container(
        row![
            widgets::navigation_button(
                state.i18n.text("all"),
                state.screen == Screen::Library && state.library_filter.is_none(),
                Message::LibraryFilterChanged(None),
                state.i18n.ui_font(),
            ),
            widgets::navigation_button(
                "EPUB",
                state.screen == Screen::Library
                    && state.library_filter == Some(shosai_core::library::BookFormat::Epub),
                Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Epub)),
                state.i18n.ui_font(),
            ),
            widgets::navigation_button(
                "PDF",
                state.screen == Screen::Library
                    && state.library_filter == Some(shosai_core::library::BookFormat::Pdf),
                Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Pdf)),
                state.i18n.ui_font(),
            ),
            widgets::navigation_button(
                state.i18n.text("settings"),
                state.screen == Screen::Settings,
                Message::ShowSettings,
                state.i18n.ui_font(),
            ),
        ]
        .spacing(4),
    )
    .padding([8, 12])
    .width(Length::Fill)
    .into()
}

fn library_collection(state: &State) -> Element<'_, Message> {
    if state.library_loading && state.library_offset == 0 {
        return library_refresh_placeholder(state);
    }

    if state.library_books.is_empty() {
        let constrained = !state.library_search.is_empty() || state.library_filter.is_some();
        let empty_msg = if state.library_loading {
            state.i18n.text("loading-library")
        } else if let Some(error) = state
            .library_error
            .as_ref()
            .or(state.storage_error.as_ref())
        {
            error.localized(&state.i18n)
        } else if state.library_search.is_empty() && state.library_filter.is_none() {
            state.i18n.text("empty-library")
        } else {
            state.i18n.text("empty-search")
        };

        let heading = if state.library_loading {
            state.i18n.text("loading-library-heading")
        } else if constrained {
            state.i18n.text("no-matching-books")
        } else {
            state.i18n.text("empty-library-heading")
        };
        let mut empty = column![
            text(heading).size(24),
            text(empty_msg).size(14).color(app_theme::TEXT_MUTED),
        ]
        .spacing(14)
        .align_x(iced::Center);
        if !state.library_loading && !constrained && state.storage_error.is_none() {
            let message = (state.library.is_some() && !state.adding_books && !state.moving_library)
                .then_some(Message::OpenAddBooks);
            let label = if state.adding_books {
                state.i18n.text("adding-books")
            } else {
                state.i18n.text("add-first-books")
            };
            empty = empty.push(widgets::primary_button(
                label,
                message,
                state.i18n.ui_font(),
            ));
        }

        return center(empty)
            .width(Length::Fill)
            .height(Length::Fill)
            .into();
    }

    let cards = state
        .library_books
        .iter()
        .map(|book| render_book_card(state, book))
        .collect::<Vec<_>>();
    let book_grid = grid(cards).fluid(220).height(Length::Shrink).spacing(18);
    let mut sections = column![].spacing(16).width(Length::Fill);

    if let Some(error) = &state.library_error {
        sections = sections.push(
            container(
                text(error.localized(&state.i18n))
                    .size(13)
                    .color(iced::Color::from_rgb8(0xA5, 0x43, 0x43)),
            )
            .padding([7, 14])
            .width(Length::Fill)
            .style(app_theme::reader_alert),
        );
    }

    if let Some(book) = continue_reading_book(state) {
        sections = sections
            .push(text(state.i18n.text("continue-reading")).size(18))
            .push(render_continue_card(state, book))
            .push(iced::widget::Space::new().height(4));
    }

    let section_title = if state.library_search.is_empty() {
        state.i18n.text("all-books")
    } else {
        state.i18n.text("search-results")
    };
    sections = sections.push(text(section_title).size(18)).push(book_grid);

    if state.library_loading && state.library_offset > 0 {
        sections = sections.push(
            center(text(state.i18n.text("loading-more")).color(app_theme::TEXT_MUTED))
                .width(Length::Fill),
        );
    }
    if let Some(key) = library_load_sensor_key(state) {
        sections = sections.push(
            sensor(container(text("")).width(Length::Fill).height(1))
                .key(key)
                .anticipate(LIBRARY_LOAD_AHEAD_PX)
                .on_show(|_| Message::LoadMoreLibrary),
        );
    }

    scrollable(container(sections).padding([22, 24]).width(Length::Fill))
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn modal_overlay<'a>(
    content: Element<'a, Message>,
    modal: Element<'a, Message>,
    dismiss: Message,
) -> Element<'a, Message> {
    let backdrop = mouse_area(
        container(iced::widget::Space::new())
            .width(Length::Fill)
            .height(Length::Fill)
            .style(app_theme::modal_backdrop),
    )
    .on_press(dismiss);

    iced::widget::Stack::new()
        .push(content)
        .push(backdrop)
        .push(center(opaque(modal)).padding(20))
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn managed_library_move_modal(state: &State) -> Element<'_, Message> {
    let plan = state
        .pending_library_move
        .as_ref()
        .expect("move modal requires a plan");
    let current = state
        .library
        .as_ref()
        .map(|library| library.managed_dir().display().to_string())
        .unwrap_or_default();
    let summary = state.i18n.text_with_args(
        "managed-library-move-summary",
        [
            ("count", (plan.summary.book_count as i64).into()),
            ("size", format_bytes(plan.summary.total_bytes).into()),
        ],
    );
    let move_label = if state.moving_library {
        state.i18n.text("moving-library")
    } else {
        state.i18n.text("move-library")
    };
    let actions = row![
        iced::widget::Space::new().width(Length::Fill),
        widgets::secondary_button(
            state.i18n.text("cancel"),
            (!state.moving_library).then_some(Message::CancelManagedLibraryMove),
            state.i18n.ui_font(),
        ),
        widgets::primary_button(
            move_label,
            (!state.moving_library).then_some(Message::ConfirmManagedLibraryMove),
            state.i18n.ui_font(),
        ),
    ]
    .spacing(8);
    let error: Element<'_, Message> = if let Some(error) = &state.settings_error {
        container(text(error.clone()).size(12))
            .padding([8, 10])
            .width(Length::Fill)
            .style(app_theme::reader_alert)
            .into()
    } else {
        iced::widget::Space::new().height(0).into()
    };

    container(
        column![
            text(state.i18n.text("move-managed-library-heading")).size(20),
            text(state.i18n.text("move-managed-library-description"))
                .size(13)
                .color(app_theme::TEXT_MUTED),
            text(state.i18n.text("from-location")).size(12),
            container(text(current).size(12))
                .padding([8, 10])
                .width(Length::Fill)
                .style(app_theme::skeleton),
            text(state.i18n.text("to-location")).size(12),
            container(text(plan.destination.display().to_string()).size(12))
                .padding([8, 10])
                .width(Length::Fill)
                .style(app_theme::skeleton),
            text(summary).size(13),
            error,
            actions,
        ]
        .spacing(12),
    )
    .padding(24)
    .width(Length::Fill)
    .max_width(520)
    .style(app_theme::modal)
    .into()
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn import_candidate_label(source: &AddBooksSource, path: &Path) -> String {
    match source {
        AddBooksSource::Folder(root) => {
            let root = root.canonicalize().unwrap_or_else(|_| root.clone());
            path.strip_prefix(root)
                .unwrap_or(path)
                .display()
                .to_string()
        }
        AddBooksSource::Files(_) => path.display().to_string(),
    }
}

fn rebuild_add_books_review_rows(state: &mut State) {
    let query = shosai_core::library::normalize_import_text(&state.add_books_review_search);
    state.add_books_review_rows.clear();
    let mut previous_group = None;
    for (index, staged) in state.staged_imports.iter().enumerate() {
        let candidate = &staged.candidate;
        if !query.is_empty()
            && !shosai_core::library::normalize_import_text(&candidate.title).contains(&query)
            && !shosai_core::library::normalize_import_text(&candidate.path.to_string_lossy())
                .contains(&query)
            && !candidate.format.as_str().contains(&query)
        {
            continue;
        }
        if previous_group != Some(candidate.group_key.as_str()) {
            state
                .add_books_review_rows
                .push(AddBooksReviewRow::Group(candidate.title.clone()));
            previous_group = Some(candidate.group_key.as_str());
        }
        state
            .add_books_review_rows
            .push(AddBooksReviewRow::Book(index));
    }
    state.add_books_review_revision = state.add_books_review_revision.wrapping_add(1);
    state.add_books_review_offset = 0.0;
}

fn virtual_review_range(
    rows: &[AddBooksReviewRow],
    offset: f32,
    viewport_height: f32,
) -> (std::ops::Range<usize>, f32, f32) {
    let total_height: f32 = rows.iter().map(AddBooksReviewRow::height).sum();
    let viewport_height = viewport_height.max(1.0);
    let offset = offset.clamp(0.0, (total_height - viewport_height).max(0.0));
    let visible_start = (offset - REVIEW_VIRTUAL_OVERSCAN).max(0.0);
    let visible_end = offset + viewport_height + REVIEW_VIRTUAL_OVERSCAN;
    let mut top = 0.0;
    let mut start = 0;
    while start < rows.len() && top + rows[start].height() < visible_start {
        top += rows[start].height();
        start += 1;
    }
    let mut end = start;
    let mut rendered_height = 0.0;
    while end < rows.len() && top + rendered_height < visible_end {
        rendered_height += rows[end].height();
        end += 1;
    }
    let bottom = (total_height - top - rendered_height).max(0.0);
    (start..end, top, bottom)
}

fn discovery_progress_value(current: f32, progress: ImportDiscoveryProgressSnapshot) -> f32 {
    if !progress.enumerating && progress.completed_files >= progress.total_files {
        return 1.0;
    }
    let work = progress.hashed_files + progress.completed_files;
    let target = if progress.enumerating {
        0.45 * work as f32 / (work + 8).max(1) as f32
    } else {
        0.5 + 0.5 * work as f32 / (progress.total_files.max(1) * 2) as f32
    };
    current.max(target).min(0.99)
}

fn add_books_modal(state: &State) -> Element<'_, Message> {
    let cancel = button(text(state.i18n.text("cancel")))
        .on_press(Message::CancelAddBooks)
        .padding([8, 14])
        .style(app_theme::book_card_action);

    let selection = state.add_books_source.as_ref().map(|source| match source {
        AddBooksSource::Files(paths) => state.i18n.text_with_args(
            "selected-book-files",
            [("count", (paths.len() as i64).into())],
        ),
        AddBooksSource::Folder(path) => {
            let name = path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.display().to_string());
            state
                .i18n
                .text_with_args("selected-book-folder", [("folder", name.into())])
        }
    });

    let content: Element<'_, Message> = if state.add_books_discovering {
        let progress = state
            .add_books_progress
            .as_ref()
            .map(ImportDiscoveryProgress::snapshot)
            .unwrap_or(shosai_core::library::ImportDiscoveryProgressSnapshot {
                enumerating: true,
                hashed_files: 0,
                completed_files: 0,
                total_files: 0,
            });
        let progress_label = if progress.enumerating {
            state.i18n.text_with_args(
                "finding-books-progress",
                [
                    ("found", (progress.total_files as i64).into()),
                    ("read", (progress.hashed_files as i64).into()),
                ],
            )
        } else if progress.hashed_files < progress.total_files {
            state.i18n.text_with_args(
                "reading-books-progress",
                [
                    ("completed", (progress.hashed_files as i64).into()),
                    ("total", (progress.total_files as i64).into()),
                ],
            )
        } else {
            state.i18n.text_with_args(
                "checking-copies-progress",
                [
                    ("completed", (progress.completed_files as i64).into()),
                    ("total", (progress.total_files as i64).into()),
                ],
            )
        };
        let progress_value = if progress.enumerating {
            f64::from(discovery_progress_value(
                state.library_activity_progress,
                progress,
            ))
        } else {
            f64::from(state.library_activity_progress)
        };
        let progress_bar: Element<'_, Message> = widgets::reading_progress(progress_value).into();
        column![
            text(state.i18n.text("scanning-books")).size(20),
            text(selection.unwrap_or_default())
                .size(13)
                .color(app_theme::TEXT_MUTED),
            text(state.i18n.text("scanning-books-description"))
                .size(12)
                .color(app_theme::TEXT_MUTED),
            text(progress_label).size(12),
            progress_bar,
            row![
                button(text(state.i18n.text("back")))
                    .on_press(Message::ClearAddBooksSelection)
                    .padding([8, 14])
                    .style(app_theme::book_card_action),
                iced::widget::Space::new().width(Length::Fill),
                cancel,
            ],
        ]
        .spacing(12)
        .into()
    } else if let Some(source) = &state.add_books_source {
        let selected_count = state
            .staged_imports
            .iter()
            .filter(|staged| staged.selected)
            .count();
        let new_count = state
            .staged_imports
            .iter()
            .filter(|staged| staged.candidate.duplicate.is_none())
            .count();
        let all_new_selected = new_count > 0
            && state
                .staged_imports
                .iter()
                .filter(|staged| staged.candidate.duplicate.is_none())
                .all(|staged| staged.selected);
        let (visible_rows, top_spacer, bottom_spacer) = virtual_review_range(
            &state.add_books_review_rows,
            state.add_books_review_offset,
            state.add_books_review_viewport_height,
        );
        let mut candidates = column![];
        if top_spacer > 0.0 {
            candidates = candidates.push(iced::widget::Space::new().height(top_spacer));
        }
        for row in &state.add_books_review_rows[visible_rows] {
            let AddBooksReviewRow::Book(index) = row else {
                let AddBooksReviewRow::Group(title) = row else {
                    unreachable!();
                };
                candidates = candidates.push(
                    container(text(title.clone()).size(14))
                        .height(REVIEW_GROUP_ROW_HEIGHT)
                        .align_y(iced::Alignment::End),
                );
                continue;
            };
            let staged = &state.staged_imports[*index];
            let label = import_candidate_label(source, &staged.candidate.path);
            let label_font = typography::font_for_text(&label);
            let badge = container(
                text(staged.candidate.format.as_str().to_uppercase())
                    .size(10)
                    .font(state.i18n.ui_font()),
            )
            .padding([3, 6])
            .style(|_| {
                iced::widget::container::Style::default()
                    .background(app_theme::SURFACE_MUTED)
                    .border(iced::Border {
                        color: app_theme::BORDER,
                        width: 1.0,
                        radius: app_theme::RADIUS_SMALL.into(),
                    })
            });
            let details = row![
                checkbox(staged.selected)
                    .label(label)
                    .font(label_font)
                    .width(Length::Fill)
                    .on_toggle(move |selected| Message::ToggleStagedBook(*index, selected)),
                badge,
                text(format_bytes(staged.candidate.file_size))
                    .size(11)
                    .color(app_theme::TEXT_MUTED),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center);
            let duplicate: Element<'_, Message> = match &staged.candidate.duplicate {
                Some(ImportDuplicate::ExistingBook { title, .. }) => text(
                    state
                        .i18n
                        .text_with_args("already-in-library", [("title", title.clone().into())]),
                )
                .size(11)
                .color(app_theme::TEXT_MUTED)
                .into(),
                Some(ImportDuplicate::SelectedFile { path }) => {
                    let file = path
                        .file_name()
                        .map(|name| name.to_string_lossy().into_owned())
                        .unwrap_or_else(|| path.display().to_string());
                    text(
                        state
                            .i18n
                            .text_with_args("duplicate-selected-file", [("file", file.into())]),
                    )
                    .size(11)
                    .color(app_theme::TEXT_MUTED)
                    .into()
                }
                None => iced::widget::Space::new().height(0).into(),
            };
            candidates = candidates.push(
                container(column![details, duplicate].spacing(2).width(Length::Fill))
                    .padding([7, 8])
                    .width(Length::Fill)
                    .height(REVIEW_BOOK_ROW_HEIGHT)
                    .style(app_theme::surface),
            );
        }
        if bottom_spacer > 0.0 {
            candidates = candidates.push(iced::widget::Space::new().height(bottom_spacer));
        }

        let discovery_error: Element<'_, Message> =
            if let Some(failure) = state.import_discovery_failures.first() {
                let file = failure
                    .path
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_else(|| failure.path.display().to_string());
                text(state.i18n.text_with_args(
                    "book-discovery-failed",
                    [
                        (
                            "count",
                            (state.import_discovery_failures.len() as i64).into(),
                        ),
                        ("file", file.into()),
                        ("error", failure.error.clone().into()),
                    ],
                ))
                .size(11)
                .color(app_theme::TEXT_MUTED)
                .into()
            } else {
                iced::widget::Space::new().height(0).into()
            };

        let storage: Element<'_, Message> = if let Some(copy) = state.add_books_copy {
            let behavior = if copy {
                state.i18n.text("copy-into-shosai")
            } else {
                state.i18n.text("use-current-location")
            };
            column![
                text(state.i18n.text("book-storage-heading")).size(14),
                row![
                    text(behavior).size(12),
                    button(text(state.i18n.text("change-storage-choice")))
                        .on_press(Message::ChangeAddBooksStorage)
                        .padding([4, 8])
                        .style(app_theme::book_card_action),
                ]
                .spacing(8)
                .align_y(iced::Alignment::Center),
            ]
            .spacing(4)
            .into()
        } else {
            column![
                text(state.i18n.text("book-storage-heading")).size(14),
                widgets::secondary_button(
                    state.i18n.text("copy-into-shosai"),
                    Some(Message::SelectAddBooksStorage(true)),
                    state.i18n.ui_font(),
                )
                .width(Length::Fill),
                text(state.i18n.text("copy-into-shosai-description"))
                    .size(11)
                    .color(app_theme::TEXT_MUTED),
                widgets::secondary_button(
                    state.i18n.text("use-current-location"),
                    Some(Message::SelectAddBooksStorage(false)),
                    state.i18n.ui_font(),
                )
                .width(Length::Fill),
                text(state.i18n.text("use-current-location-description"))
                    .size(11)
                    .color(app_theme::TEXT_MUTED),
            ]
            .spacing(6)
            .into()
        };

        let add_message = (selected_count > 0 && state.add_books_copy.is_some())
            .then_some(Message::AddSelectedBooks);
        column![
            text(state.i18n.text("review-books-heading")).size(20),
            text(state.i18n.text_with_args(
                "review-books-summary",
                [
                    ("found", (state.staged_imports.len() as i64).into()),
                    ("selected", (selected_count as i64).into()),
                ],
            ))
            .size(12)
            .color(app_theme::TEXT_MUTED),
            text_input(
                &state.i18n.text("filter-review-books-placeholder"),
                &state.add_books_review_search,
            )
            .on_input(Message::AddBooksReviewSearchChanged)
            .padding([8, 10]),
            checkbox(all_new_selected)
                .label(state.i18n.text("select-all-new-books"))
                .font(state.i18n.ui_font())
                .on_toggle(Message::SelectAllStagedBooks),
            if state.add_books_review_rows.is_empty() {
                container(text(state.i18n.text(if state.staged_imports.is_empty() {
                    "no-supported-books-found"
                } else {
                    "no-matching-books-found"
                })))
                .padding(12)
                .width(Length::Fill)
            } else {
                container(
                    scrollable(
                        container(candidates)
                            .padding(iced::Padding {
                                right: 18.0,
                                ..iced::Padding::default()
                            })
                            .width(Length::Fill),
                    )
                    .id(WidgetId::new("add-books-review-scroll"))
                    .on_scroll(move |viewport| Message::AddBooksReviewScrolled {
                        generation: state.add_books_generation,
                        revision: state.add_books_review_revision,
                        offset: viewport.absolute_offset().y,
                        viewport_height: viewport.bounds().height,
                    })
                    .height(Length::Fill),
                )
                .height(Length::Fill)
            },
            discovery_error,
            storage,
            row![
                button(text(state.i18n.text("back")))
                    .on_press(Message::ClearAddBooksSelection)
                    .padding([8, 14])
                    .style(app_theme::book_card_action),
                iced::widget::Space::new().width(Length::Fill),
                cancel,
                widgets::primary_button(
                    state.i18n.text("add-selected-books"),
                    add_message,
                    state.i18n.ui_font(),
                ),
            ]
            .spacing(8)
            .align_y(iced::Alignment::Center),
        ]
        .spacing(10)
        .height(Length::Fill)
        .into()
    } else {
        column![
            text(state.i18n.text("add-books-heading")).size(20),
            text(state.i18n.text("add-books-description"))
                .size(13)
                .color(app_theme::TEXT_MUTED),
            widgets::primary_button(
                state.i18n.text("choose-book-files"),
                Some(Message::ChooseBookFiles),
                state.i18n.ui_font(),
            )
            .width(Length::Fill),
            widgets::secondary_button(
                state.i18n.text("choose-book-folder"),
                Some(Message::ChooseBookFolder),
                state.i18n.ui_font(),
            )
            .width(Length::Fill),
            row![iced::widget::Space::new().width(Length::Fill), cancel],
        ]
        .spacing(14)
        .into()
    };

    let modal = container(content)
        .padding(24)
        .width(Length::Fill)
        .max_width(680)
        .style(app_theme::modal);
    if !state.add_books_discovering && !state.staged_imports.is_empty() {
        modal.height(Length::Fill).max_height(760).into()
    } else {
        modal.into()
    }
}

fn remove_book_modal<'a>(state: &'a State, book: &'a Book) -> Element<'a, Message> {
    let description_key = if book.storage_kind == shosai_core::library::StorageKind::Managed {
        "remove-managed-book-description"
    } else {
        "remove-referenced-book-description"
    };
    let actions = row![
        iced::widget::Space::new().width(Length::Fill),
        button(text(state.i18n.text("cancel")))
            .on_press(Message::CancelRemoveBook)
            .padding([8, 14])
            .style(app_theme::book_card_action),
        button(text(state.i18n.text("remove")))
            .on_press(Message::RemoveBook(book.id))
            .padding([8, 14])
            .style(app_theme::danger_button),
    ]
    .spacing(8);

    container(
        column![
            text(state.i18n.text("remove-book-heading")).size(20),
            text(book.title.clone()).size(14),
            text(state.i18n.text(description_key))
                .size(12)
                .color(app_theme::TEXT_MUTED),
            actions,
        ]
        .spacing(14),
    )
    .padding(24)
    .width(Length::Fill)
    .max_width(440)
    .style(app_theme::modal)
    .into()
}

fn continue_reading_book(state: &State) -> Option<&Book> {
    if !state.library_search.is_empty() || state.library_filter.is_some() {
        return None;
    }

    state
        .library_books
        .iter()
        .take(LIBRARY_PAGE_SIZE as usize)
        .find(|book| book.last_read.is_some() && book.progress < 1.0)
}

fn library_refresh_placeholder(state: &State) -> Element<'_, Message> {
    let placeholder_count = if state.library_books.is_empty() {
        8
    } else {
        state.library_books.len().min(LIBRARY_PAGE_SIZE as usize)
    };
    let cards = (0..placeholder_count)
        .map(|_| render_loading_book_card())
        .collect::<Vec<_>>();
    let placeholders = grid(cards).fluid(220).height(Length::Shrink).spacing(18);
    let section_title = if state.library_search.is_empty() {
        state.i18n.text("all-books")
    } else {
        state.i18n.text("search-results")
    };

    scrollable(
        container(column![text(section_title).size(18), placeholders].spacing(16))
            .padding([22, 24])
            .width(Length::Fill),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

fn render_loading_book_card() -> Element<'static, Message> {
    container(
        column![
            container(iced::widget::Space::new())
                .width(Length::Fill)
                .height(210)
                .style(app_theme::skeleton),
            container(iced::widget::Space::new())
                .width(Length::Fixed(126.0))
                .height(12)
                .style(app_theme::skeleton_subtle),
            container(iced::widget::Space::new())
                .width(Length::Fixed(82.0))
                .height(9)
                .style(app_theme::skeleton_subtle),
            iced::widget::Space::new().height(Length::Fill),
            container(iced::widget::Space::new())
                .width(Length::Fill)
                .height(4)
                .style(app_theme::skeleton_subtle),
        ]
        .spacing(7)
        .height(Length::Fill),
    )
    .padding(8)
    .width(Length::Fill)
    .height(330)
    .into()
}

fn library_search_input_id() -> iced::widget::Id {
    iced::widget::Id::new("library-search-query")
}

fn render_book_card<'a>(state: &'a State, book: &'a Book) -> Element<'a, Message> {
    let file_path = book.file_path.clone();
    let book_id = book.id;
    let cover = render_book_cover(state, book, Length::Fill, 210.0);
    let title_text = text(book.title.clone())
        .size(13)
        .wrapping(iced::widget::text::Wrapping::WordOrGlyph);
    let author = text(
        book.author
            .clone()
            .unwrap_or_else(|| state.i18n.text("unknown-author")),
    )
    .size(11)
    .color(app_theme::TEXT_MUTED);
    let format_label = text(book.format.as_str().to_uppercase())
        .size(10)
        .color(app_theme::TEXT_MUTED);
    let percentage = (book.progress.clamp(0.0, 1.0) * 100.0).round() as u32;
    let progress_label = text(if percentage == 0 {
        state.i18n.text("not-started")
    } else {
        state
            .i18n
            .text_with_args("percent", [("percentage", percentage.into())])
    })
    .size(10)
    .color(app_theme::TEXT_MUTED);

    let is_removing = state.removing_book == Some(book_id);
    let menu_open = state.book_menu == Some(book_id);
    let mut cover_layers = iced::widget::Stack::new()
        .push(container(cover).style(app_theme::book_cover))
        .width(Length::Fill)
        .height(210);

    if !is_removing {
        if menu_open {
            let menu = column![
                iced::widget::Space::new().height(38),
                container(
                    button(text(state.i18n.text("remove-from-library-menu")).size(11))
                        .on_press(Message::RequestRemoveBook(book_id))
                        .padding([7, 10])
                        .width(Length::Fixed(164.0))
                        .style(app_theme::book_menu_action),
                )
                .padding(4)
                .style(app_theme::book_action_menu),
            ]
            .align_x(iced::Alignment::End);
            cover_layers = cover_layers.push(opaque(
                container(menu)
                    .padding([0, 8])
                    .align_right(Length::Fill)
                    .align_top(210),
            ));
        }
        let menu_trigger = button(text("•••").size(13))
            .on_press_maybe(
                state
                    .removing_book
                    .is_none()
                    .then_some(Message::ToggleBookMenu(book_id)),
            )
            .padding([5, 8])
            .style(app_theme::book_card_action);
        cover_layers = cover_layers.push(
            container(menu_trigger)
                .padding(8)
                .align_right(Length::Fill)
                .align_top(210),
        );
    }

    let mut metadata = row![format_label]
        .spacing(6)
        .align_y(iced::Alignment::Center);
    if is_removing {
        metadata = metadata
            .push(iced::widget::Space::new().width(Length::Fill))
            .push(
                button(text(state.i18n.text("removing")).size(10))
                    .padding([3, 6])
                    .style(app_theme::book_card_action),
            );
    } else {
        metadata = metadata
            .push(iced::widget::Space::new().width(Length::Fill))
            .push(progress_label);
    }

    let card = column![
        cover_layers,
        container(title_text).height(32),
        container(author).height(28),
        iced::widget::Space::new().height(Length::Fill),
        metadata,
        widgets::reading_progress(book.progress),
    ]
    .spacing(4)
    .height(Length::Fill)
    .width(Length::Fill);

    widgets::book_button(
        card,
        (!is_removing && state.pending_remove_book.is_none() && !menu_open)
            .then_some(Message::OpenLibraryBook(book_id, file_path)),
    )
    .height(330)
    .into()
}

fn render_continue_card<'a>(state: &'a State, book: &'a Book) -> Element<'a, Message> {
    let file_path = book.file_path.clone();
    let book_id = book.id;
    let percentage = (book.progress.clamp(0.0, 1.0) * 100.0).round() as u32;
    let details = column![
        text(book.title.clone()).size(16),
        text(
            book.author
                .clone()
                .unwrap_or_else(|| state.i18n.text("unknown-author")),
        )
        .size(12)
        .color(app_theme::TEXT_MUTED),
        iced::widget::Space::new().height(Length::Fill),
        text(
            state
                .i18n
                .text_with_args("percent-complete", [("percentage", percentage.into())]),
        )
        .size(11)
        .color(app_theme::TEXT_MUTED),
        widgets::reading_progress(book.progress),
    ]
    .spacing(6)
    .height(100)
    .width(Length::Fill);
    let content = row![
        render_book_cover(state, book, Length::Fixed(72.0), 100.0),
        details,
        text(state.i18n.text("continue"))
            .size(13)
            .color(app_theme::ACCENT),
    ]
    .spacing(14)
    .align_y(iced::Alignment::Center);

    container(widgets::book_button(
        content,
        (state.removing_book != Some(book_id))
            .then_some(Message::OpenLibraryBook(book_id, file_path)),
    ))
    .width(Length::Fill)
    .max_width(620)
    .style(app_theme::surface)
    .into()
}

fn render_book_cover<'a>(
    state: &'a State,
    book: &'a Book,
    width: Length,
    height: f32,
) -> Element<'a, Message> {
    if let Some(handle) = state.library_cover_handles.get(&book.id) {
        return image(handle.0.clone())
            .width(width)
            .height(Length::Fixed(height))
            .content_fit(iced::ContentFit::Contain)
            .into();
    }
    cover_placeholder(width, height, &book.title)
}

fn cover_placeholder(width: Length, height: f32, title: &str) -> Element<'static, Message> {
    let label = text(title.chars().take(20).collect::<String>())
        .size(14)
        .color(iced::Color::WHITE);

    container(center(label))
        .width(width)
        .height(Length::Fixed(height))
        .style(|_theme| container::Style {
            background: Some(iced::Background::Color(iced::Color::from_rgb(
                0.3, 0.3, 0.4,
            ))),
            border: iced::Border {
                radius: 4.0.into(),
                ..Default::default()
            },
            ..Default::default()
        })
        .into()
}

fn welcome_view(state: &State) -> Element<'_, Message> {
    center(
        column![
            text(state.i18n.text("welcome-title")).size(32),
            text(state.i18n.text("welcome-message")).size(16),
            button(text(state.i18n.text("open-file"))).on_press(Message::OpenFile),
        ]
        .spacing(20)
        .align_x(iced::Center),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

// ---------------------------------------------------------------------------
// Title
// ---------------------------------------------------------------------------

fn book_title(
    book_id: Option<i64>,
    document: &OpenDocument,
    file_path: Option<&Path>,
    library_books: &[Book],
) -> Option<String> {
    book_id
        .and_then(|book_id| {
            library_books
                .iter()
                .find(|book| book.id == book_id)
                .map(|book| book.title.clone())
        })
        .filter(|title| !title.trim().is_empty())
        .or_else(|| match document {
            OpenDocument::Pdf(document) => document.metadata().title,
            OpenDocument::Epub(document) => document.metadata().title,
            OpenDocument::Cbz(document) => document.metadata().title,
        })
        .filter(|title| !title.trim().is_empty())
        .or_else(|| {
            file_path
                .and_then(|path| path.file_stem())
                .map(|name| name.to_string_lossy().into_owned())
        })
}

fn relocated_book_title(
    book_id: Option<i64>,
    document: &OpenDocument,
    file_path: &Path,
    library_books: &[Book],
    retained_display_title: &str,
) -> Option<String> {
    book_id
        .and_then(|book_id| {
            library_books
                .iter()
                .find(|book| book.id == book_id)
                .map(|book| book.title.clone())
        })
        .filter(|title| !title.trim().is_empty())
        .or_else(|| {
            (!retained_display_title.trim().is_empty()).then(|| retained_display_title.to_owned())
        })
        .or_else(|| {
            match document {
                OpenDocument::Pdf(document) => document.metadata().title,
                OpenDocument::Epub(document) => document.metadata().title,
                OpenDocument::Cbz(document) => document.metadata().title,
            }
            .filter(|title| !title.trim().is_empty())
        })
        .or_else(|| {
            file_path
                .file_stem()
                .map(|name| name.to_string_lossy().into_owned())
        })
}

fn current_book_title(state: &State) -> Option<String> {
    state.display_title.clone().or_else(|| {
        book_title(
            state.book_id,
            state.document.as_ref()?,
            state.file_path.as_deref(),
            &state.library_books,
        )
    })
}

fn reader_tab_title(_state: &State, tab: &ReaderTab) -> String {
    tab.display_title.clone()
}

pub fn title(state: &State) -> String {
    current_book_title(state)
        .map(|title| format!("{title} - Shosai"))
        .unwrap_or_else(|| "Shosai".to_string())
}

// ---------------------------------------------------------------------------
// Subscription
// ---------------------------------------------------------------------------

pub fn subscription(state: &State) -> Subscription<Message> {
    Subscription::batch([
        keyboard::listen().map(Message::KeyPressed),
        window::events().map(|(id, event)| Message::WindowEvent(id, event)),
        perf::subscription(state),
        if library_activity_active(state) || state.library_activity_opacity > 0.0 {
            iced::time::every(LIBRARY_ACTIVITY_TICK).map(|_| Message::LibraryActivityTick)
        } else {
            Subscription::none()
        },
    ])
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};

    use super::*;
    use iced::advanced::widget::Operation;
    use shosai_core::epub::render::ContentNode;
    use zip::CompressionMethod;
    use zip::ZipWriter;
    use zip::write::SimpleFileOptions;

    fn open_document_now(state: &mut State, path: PathBuf, book_id: Option<i64>) -> Task<Message> {
        match load_document(&path) {
            Ok(document) => finish_open_document(state, path, book_id, document),
            Err(error) => {
                state.open_error = Some(error);
                Task::none()
            }
        }
    }

    fn epub_with_chapter(chapter: &[u8]) -> Vec<u8> {
        epub_with_title_and_chapter("Limits", chapter)
    }

    fn epub_with_title_and_chapter(title: &str, chapter: &[u8]) -> Vec<u8> {
        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        for (path, bytes) in [
            ("mimetype", b"application/epub+zip".as_slice()),
            (
                "META-INF/container.xml",
                br#"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
            ),
            ("OPS/chapter.xhtml", chapter),
        ] {
            archive.start_file(path, options).unwrap();
            archive.write_all(bytes).unwrap();
        }
        archive.start_file("OPS/content.opf", options).unwrap();
        write!(archive, r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>"#).unwrap();
        archive.finish().unwrap().into_inner()
    }

    fn epub_with_image_chapters(chapter_count: usize) -> Vec<u8> {
        let mut image_bytes = Vec::new();
        ::image::DynamicImage::ImageRgba8(::image::RgbaImage::from_pixel(
            1,
            1,
            ::image::Rgba([1, 2, 3, 255]),
        ))
        .write_to(
            &mut Cursor::new(&mut image_bytes),
            ::image::ImageFormat::Png,
        )
        .unwrap();

        let mut archive = ZipWriter::new(Cursor::new(Vec::new()));
        let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        archive.start_file("mimetype", options).unwrap();
        archive.write_all(b"application/epub+zip").unwrap();
        archive
            .start_file("META-INF/container.xml", options)
            .unwrap();
        archive.write_all(br#"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#).unwrap();

        for chapter in 0..chapter_count {
            archive
                .start_file(format!("OPS/chapter-{chapter}.xhtml"), options)
                .unwrap();
            write!(
                archive,
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><img src=\"image-{chapter}.png\"/></body></html>"
            )
            .unwrap();
            archive
                .start_file(format!("OPS/image-{chapter}.png"), options)
                .unwrap();
            archive.write_all(&image_bytes).unwrap();
        }

        archive.start_file("OPS/content.opf", options).unwrap();
        write!(archive, r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Images</dc:title></metadata><manifest>"#).unwrap();
        for chapter in 0..chapter_count {
            write!(archive, r#"<item id="chapter-{chapter}" href="chapter-{chapter}.xhtml" media-type="application/xhtml+xml"/><item id="image-{chapter}" href="image-{chapter}.png" media-type="image/png"/>"#).unwrap();
        }
        archive.write_all(b"</manifest><spine>").unwrap();
        for chapter in 0..chapter_count {
            write!(archive, r#"<itemref idref="chapter-{chapter}"/>"#).unwrap();
        }
        archive.write_all(b"</spine></package>").unwrap();
        archive.finish().unwrap().into_inner()
    }

    #[test]
    fn boot_defers_storage_initialization() {
        let (state, task) = boot();

        assert!(state.reading_state.is_none());
        assert!(state.library_loading);
        assert!(task.units() > 0);
    }

    #[test]
    fn status_progress_is_page_based_and_handles_empty_documents() {
        assert_eq!(reading_progress_percentage(0, 0), 0);
        assert_eq!(reading_progress_percentage(0, 4), 25);
        assert_eq!(reading_progress_percentage(2, 4), 75);
        assert_eq!(reading_progress_percentage(3, 4), 100);
    }

    #[test]
    fn reader_layout_compacts_below_its_toolbar_breakpoint() {
        assert!(uses_compact_reader_layout(COMPACT_READER_WIDTH - 1.0));
        assert!(!uses_compact_reader_layout(COMPACT_READER_WIDTH));
    }

    #[test]
    fn compact_reader_panels_reserve_their_stacked_height() {
        let (mut state, _) = boot();
        state.window_size = Size::new(COMPACT_READER_WIDTH - 1.0, 700.0);
        let baseline = available_reader_size(&state).height;

        state.show_search_bar = true;
        assert_eq!(baseline - available_reader_size(&state).height, 88.0);

        state.show_search_bar = false;
        state.show_reader_more = true;
        assert_eq!(baseline - available_reader_size(&state).height, 84.0);
    }

    #[test]
    fn reader_labels_truncate_without_splitting_unicode() {
        assert_eq!(truncate_reader_label("短い題名", 8), "短い題名");
        assert_eq!(truncate_reader_label("長い日本語の書名", 5), "長い日本…");
    }

    #[test]
    fn managed_book_window_title_uses_document_metadata_instead_of_content_hash() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let expected = epub.metadata().title.expect("fixture should have a title");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from(
            "/managed/books/1f5f42f7234d111f9aec67d61b2790c85e3054c5efa284c859c6519a7e7ff753.epub",
        ));

        assert_eq!(title(&state), format!("{expected} - Shosai"));
    }

    #[test]
    fn blank_library_title_falls_back_to_document_metadata() {
        let epub = EpubDoc::from_bytes(epub_with_title_and_chapter(
            "Publisher title",
            b"<html><body>text</body></html>",
        ))
        .expect("fixture should be a valid EPUB");
        let mut book = test_book(42);
        book.title = "   ".to_string();

        assert_eq!(
            book_title(
                Some(42),
                &OpenDocument::Epub(Arc::new(epub)),
                Some(Path::new("/managed/books/content-hash.epub")),
                &[book],
            )
            .as_deref(),
            Some("Publisher title")
        );
    }

    #[test]
    fn managed_book_tab_uses_document_metadata_instead_of_content_hash() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let expected = epub.metadata().title.expect("fixture should have a title");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from(
            "/managed/books/1f5f42f7234d111f9aec67d61b2790c85e3054c5efa284c859c6519a7e7ff753.epub",
        ));
        let tab = capture_reader_tab(&state).expect("reader state should create a tab");

        assert_eq!(reader_tab_title(&state, &tab), expected);
    }

    #[test]
    fn managed_book_window_title_survives_library_page_eviction() {
        let bytes = epub_with_title_and_chapter("", b"<html><body>text</body></html>");
        let epub = Arc::new(EpubDoc::from_bytes(bytes).expect("fixture should be a valid EPUB"));
        assert!(epub.metadata().title.is_none());
        let mut state = state_with_document(OpenDocument::Epub(Arc::clone(&epub)));
        let mut book = test_book(42);
        book.title = "Original library title".to_string();
        state.library_books = vec![book];
        install_document(
            &mut state,
            PathBuf::from("/managed/books/content-hash.epub"),
            Some(42),
            OpenDocument::Epub(epub),
        );

        state.library_books.clear();

        assert_eq!(title(&state), "Original library title - Shosai");
    }

    #[test]
    fn managed_book_tab_title_survives_library_page_replacement() {
        let bytes = epub_with_title_and_chapter("", b"<html><body>text</body></html>");
        let epub = Arc::new(EpubDoc::from_bytes(bytes).expect("fixture should be a valid EPUB"));
        assert!(epub.metadata().title.is_none());
        let mut state = state_with_document(OpenDocument::Epub(Arc::clone(&epub)));
        let mut book = test_book(42);
        book.title = "Original library title".to_string();
        state.library_books = vec![book];
        install_document(
            &mut state,
            PathBuf::from("/managed/books/content-hash.epub"),
            Some(42),
            OpenDocument::Epub(epub),
        );
        let tab = capture_reader_tab(&state).expect("reader state should create a tab");

        state.library_books = vec![test_book(7)];

        assert_eq!(reader_tab_title(&state, &tab), "Original library title");
    }

    #[test]
    fn reader_chrome_builds_for_wide_and_compact_bookmark_layouts() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("長い日本語の書名.epub"));

        let _ = reader_layout(&state, false);
        state.show_bookmarks_panel = true;
        let _ = reader_layout(&state, true);
    }

    #[test]
    fn reader_header_panels_are_mutually_exclusive() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let _ = update(&mut state, Message::ToggleReaderSettings);
        assert!(state.show_reader_settings);
        assert!(!state.show_reader_more);
        assert!(!state.show_bookmarks_panel);

        let _ = update(&mut state, Message::ToggleReaderMore);
        assert!(!state.show_reader_settings);
        assert!(state.show_reader_more);
        assert!(!state.show_bookmarks_panel);

        let _ = update(&mut state, Message::ToggleBookmarksPanel);
        assert!(!state.show_reader_settings);
        assert!(!state.show_reader_more);
        assert!(state.show_bookmarks_panel);
    }

    #[test]
    fn switching_tabs_restores_exclusive_reader_panels() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        state.file_path = Some(PathBuf::from("contents.epub"));
        state.show_bookmarks_panel = true;
        let contents = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("settings.epub"));
        state.show_bookmarks_panel = false;
        state.show_reader_settings = true;
        let settings = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(3);
        state.file_path = Some(PathBuf::from("more.epub"));
        state.show_reader_settings = false;
        state.show_reader_more = true;
        let more = capture_reader_tab(&state).unwrap();

        state.tabs = vec![contents, settings, more];
        state.active_tab = Some(2);

        let _ = update(&mut state, Message::SelectTab(0));
        assert_eq!(
            (
                state.show_reader_settings,
                state.show_reader_more,
                state.show_bookmarks_panel,
            ),
            (false, false, true)
        );

        let _ = update(&mut state, Message::SelectTab(1));
        assert_eq!(
            (
                state.show_reader_settings,
                state.show_reader_more,
                state.show_bookmarks_panel,
            ),
            (true, false, false)
        );

        let _ = update(&mut state, Message::SelectTab(2));
        assert_eq!(
            (
                state.show_reader_settings,
                state.show_reader_more,
                state.show_bookmarks_panel,
            ),
            (false, true, false)
        );
    }

    #[test]
    fn continuous_position_uses_measured_item_boundaries() {
        let items = (0..3)
            .map(|page| ContinuousMeasuredItem {
                id: continuous_item_id(1, 0, page),
                page,
                start: 0,
                end: 0,
            })
            .collect::<Vec<_>>();
        let index = Arc::new(ContinuousMeasurementIndex::new(1, 0, items));
        let mut operation =
            ContinuousItemOperation::resolve(Arc::clone(&index), continuous_scroll_id(1, 0), 500.0);
        operation.content_top = Some(100.0);
        operation.item_bounds = vec![
            Some(iced::Rectangle::new(
                Point::new(0.0, 100.0),
                Size::new(100.0, 800.0),
            )),
            Some(iced::Rectangle::new(
                Point::new(0.0, 900.0),
                Size::new(100.0, 100.0),
            )),
            Some(iced::Rectangle::new(
                Point::new(0.0, 1000.0),
                Size::new(100.0, 100.0),
            )),
        ];

        assert!(matches!(
            operation.finish(),
            operation::Outcome::Some((0, 0, _, _))
        ));

        let mut navigation =
            ContinuousItemOperation::locate(index, continuous_scroll_id(1, 0), (1, 0), 0.0);
        navigation.content_top = operation.content_top;
        navigation.item_bounds = operation.item_bounds;
        navigation.content_height = Some(1000.0);
        navigation.viewport_height = Some(700.0);
        assert!(matches!(
            navigation.finish(),
            operation::Outcome::Some((1, 0, offset, tail_extent))
                if offset == 800.0 && tail_extent == 500.0
        ));
    }

    #[test]
    fn continuous_epub_position_interpolates_character_offsets_within_nodes() {
        let items = vec![ContinuousMeasuredItem {
            id: continuous_epub_node_id(1, 0, 0, 0),
            page: 0,
            start: 0,
            end: 100,
        }];
        let bounds = Some(iced::Rectangle::new(
            Point::new(0.0, 100.0),
            Size::new(100.0, 1000.0),
        ));
        let index = Arc::new(ContinuousMeasurementIndex::new(1, 0, items));
        let mut resolve =
            ContinuousItemOperation::resolve(Arc::clone(&index), continuous_scroll_id(1, 0), 500.0);
        resolve.content_top = Some(100.0);
        resolve.item_bounds = vec![bounds];
        assert!(matches!(
            resolve.finish(),
            operation::Outcome::Some((0, 50, _, _))
        ));

        let mut locate =
            ContinuousItemOperation::locate(index, continuous_scroll_id(1, 0), (0, 75), 0.0);
        locate.content_top = Some(100.0);
        locate.content_height = Some(1100.0);
        locate.viewport_height = Some(200.0);
        locate.item_bounds = vec![bounds];
        assert!(matches!(
            locate.finish(),
            operation::Outcome::Some((0, 75, offset, _)) if offset == 750.0
        ));
    }

    #[test]
    fn continuous_measurement_index_is_reused_until_layout_invalidation() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let first = continuous_measurement_index(&mut state, 1, 0);
        let second = continuous_measurement_index(&mut state, 1, 0);

        assert!(Arc::ptr_eq(&first, &second));
        invalidate_continuous_layout(&mut state);
        let activation = state.continuous_activation;
        let rebuilt = continuous_measurement_index(&mut state, 1, activation);
        assert!(!Arc::ptr_eq(&first, &rebuilt));
    }

    #[test]
    fn continuous_epub_items_cover_the_shared_search_text_offsets() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let items = continuous_measured_items(&state, 1, 0);
        let Some(OpenDocument::Epub(document)) = &state.document else {
            panic!("expected EPUB document");
        };
        for (chapter, presentation) in document.presentation().chapters().iter().enumerate() {
            let chapter_items = items
                .iter()
                .filter(|item| item.page == chapter && item.end > item.start)
                .collect::<Vec<_>>();
            assert_eq!(chapter_items.first().map(|item| item.start), Some(0));
            assert_eq!(
                chapter_items.last().map(|item| item.end),
                Some(presentation.search_text().chars().count())
            );
        }
    }

    fn state_with_document(document: OpenDocument) -> State {
        let (mut state, _) = boot();
        state.document_permit = Some(RetainedDocumentPermit {
            _count: state.document_admission.count.try_reserve(1).unwrap(),
            _bytes: state.document_admission.bytes.try_reserve(0).unwrap(),
            open_worker: None,
        });
        state.screen = Screen::Reader;
        state.active_tab_id = Some(1);
        state.next_tab_id = 2;
        state.document = Some(document);
        state.total_pages = 1;
        state.page_input = "1".to_string();
        state.library_loading = false;
        state.storage_initializing = false;
        state
    }

    #[test]
    fn worker_document_permit_keeps_admission_until_worker_finishes() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.document_admission.count = CacheBudget::new(1);
        state.document_permit.as_mut().unwrap()._count =
            state.document_admission.count.try_reserve(1).unwrap();

        let worker_permit = retain_document_for_worker(&state);
        state.document_permit = None;

        assert!(state.document_admission.count.try_reserve(1).is_none());
        drop(worker_permit);
        assert!(state.document_admission.count.try_reserve(1).is_some());
    }

    fn admit_test_raster(state: &mut State, job: RasterJob, bytes: usize) {
        let permit = state.raster_budget.try_reserve(bytes).unwrap();
        state.raster_jobs.insert(job, permit);
    }

    fn complete_epub_pagination(state: &mut State) {
        let Some(OpenDocument::Epub(document)) = &state.document else {
            panic!("expected EPUB document");
        };
        let page_size = epub_page_size(state);
        let pages = crate::epub::paginate_document(
            document,
            state.font_size,
            state.line_spacing,
            crate::epub::LayoutSize::new(page_size.width, page_size.height),
        );
        let layout_key = epub_layout_key(state);
        state.epub_jobs.insert(EpubJob {
            tab_id: state.active_tab_id.unwrap(),
            generation: state.render_generation,
            layout_key,
        });
        let _ = update(
            state,
            Message::EpubPaginated {
                tab_id: state.active_tab_id.unwrap(),
                generation: state.render_generation,
                layout_key,
                complete: true,
                pages: Arc::new(pages),
            },
        );
    }

    #[test]
    fn paginated_raster_navigation_moves_between_two_page_spreads() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = 5;

        assert_eq!(next_page_location(&state), Some(2));
        assert_eq!(previous_page_location(&state), None);

        state.current_page = 3;
        assert_eq!(next_page_location(&state), Some(4));
        assert_eq!(previous_page_location(&state), Some(0));

        state.current_page = 4;
        assert_eq!(next_page_location(&state), None);
        assert_eq!(previous_page_location(&state), Some(2));
    }

    #[test]
    fn continuous_raster_navigation_still_moves_one_page() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = 5;
        state.current_page = 2;
        state.reading_mode = ReadingMode::Continuous;

        assert_eq!(next_page_location(&state), Some(3));
        assert_eq!(previous_page_location(&state), Some(1));
    }

    #[test]
    fn narrow_reader_falls_back_to_single_page_navigation() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = 5;
        state.window_size.width = 700.0;

        assert_eq!(paginated_raster_pages(&state), vec![0]);
        assert_eq!(next_page_location(&state), Some(1));
    }

    #[test]
    fn pdf_rasters_use_physical_pixels_but_keep_logical_layout_size() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.window_scale_factor = 2.0;
        let rendered = RenderedPage {
            width: 1_200,
            height: 1_600,
            pixels: bytes::Bytes::new(),
        };

        assert_eq!(raster_render_scale(&state, 1.25), 2.5);
        let (page_width, page_height) = raster_page_size(&state, 0).unwrap();
        assert_eq!(
            raster_logical_size(&state, 0, &rendered, 1.25),
            Size::new(page_width * 1.25, page_height * 1.25)
        );
    }

    #[test]
    fn pdf_rasters_use_two_x_supersampling_on_low_density_displays() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        let rendered = RenderedPage {
            width: 1_200,
            height: 1_600,
            pixels: bytes::Bytes::new(),
        };

        assert_eq!(state.window_scale_factor, 1.0);
        for (window_scale, expected_density) in [(1.0, 2.0), (1.5, 2.0), (2.0, 2.0), (2.5, 2.5)] {
            state.window_scale_factor = window_scale;
            assert_eq!(pdf_raster_density(&state), expected_density);
        }
        state.window_scale_factor = 1.0;
        let (page_width, page_height) = raster_page_size(&state, 0).unwrap();
        assert_eq!(
            raster_logical_size(&state, 0, &rendered, 1.25),
            Size::new(page_width * 1.25, page_height * 1.25)
        );
    }

    #[test]
    fn rounded_pdf_rasters_keep_the_same_logical_size_across_display_densities() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        let two_x_render = RenderedPage {
            width: 601,
            height: 801,
            pixels: bytes::Bytes::new(),
        };
        let two_and_a_half_x_render = RenderedPage {
            width: 751,
            height: 1_001,
            pixels: bytes::Bytes::new(),
        };

        state.window_scale_factor = 2.0;
        let two_x_size = raster_logical_size(&state, 0, &two_x_render, 1.001);
        state.window_scale_factor = 2.5;
        let two_and_a_half_x_size = raster_logical_size(&state, 0, &two_and_a_half_x_render, 1.001);

        assert_eq!(two_x_size, two_and_a_half_x_size);
    }

    #[test]
    fn cbz_fit_page_keeps_contain_presentation() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.zoom = ZoomMode::FitPage;

        assert!(!uses_exact_paginated_raster_size(&state));
    }

    #[test]
    fn continuous_cbz_view_does_not_read_uncached_archive_entries() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        let mut state = state_with_document(OpenDocument::Cbz(Arc::clone(&document)));
        state.reading_mode = ReadingMode::Continuous;
        state.total_pages = document.page_count();
        state.continuous_pages = vec![None; state.total_pages];

        drop(continuous_content_view(&state));

        assert_eq!(document.cached_page_size(0), None);
        assert_eq!(document.cached_page_size(1), None);
        assert_eq!(document.cached_page_size(2), None);
    }

    #[test]
    fn continuous_cbz_dimensions_are_coalesced_before_raster_work() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        let mut state = state_with_document(OpenDocument::Cbz(Arc::clone(&document)));
        state.reading_mode = ReadingMode::Continuous;
        state.total_pages = document.page_count();
        state.continuous_pages = vec![None; state.total_pages];
        state.continuous_visible.extend(0..state.total_pages);

        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 1);
        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 0);
        assert_eq!(state.cbz_dimension_jobs.len(), CBZ_DIMENSION_WORKERS);
        assert!(state.continuous_pending.is_empty());
        assert!(state.raster_jobs.is_empty());
    }

    #[test]
    fn paginated_cbz_loads_dimensions_before_scheduling_a_render() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        let mut state = state_with_document(OpenDocument::Cbz(Arc::clone(&document)));
        state.total_pages = document.page_count();

        let dimensions = refresh_content(&mut state);

        assert_eq!(dimensions.units(), 1);
        assert_eq!(refresh_content(&mut state).units(), 0);
        assert_eq!(state.cbz_dimension_jobs.len(), 1);
        assert_eq!(document.cached_page_size(0), None);
        assert!(state.rendered_page.is_none());

        let first_job = *state.cbz_dimension_jobs.keys().next().unwrap();
        document.page_size(first_job.page).unwrap();
        let render = update(
            &mut state,
            Message::CbzDimensionsLoaded {
                tab_id: first_job.tab_id,
                generation: first_job.generation,
                page: first_job.page,
                result: Ok(()),
            },
        );

        assert_eq!(render.units(), 1);
        assert_eq!(state.cbz_dimension_jobs.len(), 1);
        let second_job = *state.cbz_dimension_jobs.keys().next().unwrap();
        assert_ne!(second_job.page, first_job.page);
        assert_eq!(document.cached_page_size(second_job.page), None);

        document.page_size(second_job.page).unwrap();
        let render = update(
            &mut state,
            Message::CbzDimensionsLoaded {
                tab_id: second_job.tab_id,
                generation: second_job.generation,
                page: second_job.page,
                result: Ok(()),
            },
        );

        assert!(render.units() > 0);
        assert!(state.cbz_dimension_jobs.is_empty());
        assert!(!state.paginated_pending.is_empty());
    }

    #[test]
    fn cbz_render_waits_for_transient_decode_admission() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        document.page_size(0).unwrap();
        let mut state = state_with_document(OpenDocument::Cbz(document));
        state.transient_decode_budget = CacheBudget::new(0);

        let task = refresh_content(&mut state);

        assert_eq!(task.units(), 0);
        assert!(state.raster_jobs.is_empty());
        assert!(state.paginated_pending.is_empty());
    }

    #[test]
    fn cbz_render_reports_intrinsic_transient_overflow_at_the_budget_boundary() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        document.page_size(0).unwrap();
        let required = document.render_admission_byte_len_at_scale(0, 1.0).unwrap();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::clone(&document)));
        state.transient_decode_budget = CacheBudget::new(required);
        let RenderTransientAdmission::Ready(permit) = reserve_render_transient(&state, 0, 1.0)
        else {
            panic!("an exact-boundary render must be admitted");
        };
        drop(permit);

        state.transient_decode_budget = CacheBudget::new(required - 1);
        let RenderTransientAdmission::Rejected(error) = reserve_render_transient(&state, 0, 1.0)
        else {
            panic!("an intrinsically oversized render must be rejected");
        };
        assert!(error.contains("exceeding"));
    }

    #[test]
    fn pdf_render_waits_for_transient_decode_admission() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.transient_decode_budget = CacheBudget::new(0);

        let task = refresh_content(&mut state);

        assert_eq!(task.units(), 0);
        assert!(state.raster_jobs.is_empty());
        assert!(state.paginated_pending.is_empty());
    }

    #[test]
    fn unknown_cbz_dimension_completion_does_not_release_the_worker() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        let mut state = state_with_document(OpenDocument::Cbz(document));

        assert_eq!(refresh_content(&mut state).units(), 1);
        assert_eq!(state.cbz_dimension_jobs.len(), 1);
        let generation = state.render_generation;

        let task = update(
            &mut state,
            Message::CbzDimensionsLoaded {
                tab_id: 1,
                generation,
                page: 99,
                result: Ok(()),
            },
        );

        assert_eq!(task.units(), 0);
        assert_eq!(state.cbz_dimension_jobs.len(), 1);
    }

    #[test]
    fn inactive_cbz_dimension_completion_pumps_active_dimension_work() {
        let document = Arc::new(
            CbzDoc::open(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../shosai-core/tests/fixtures/sample.cbz"
            ))
            .expect("fixture should open"),
        );
        let mut state = state_with_document(OpenDocument::Cbz(Arc::clone(&document)));
        state.total_pages = document.page_count();
        state.file_path = Some(PathBuf::from("first.cbz"));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None; state.total_pages];
        state.continuous_visible.extend(0..2);
        assert!(refresh_content(&mut state).units() > 0);
        assert_eq!(state.cbz_dimension_jobs.len(), CBZ_DIMENSION_WORKERS);
        let completed = *state.cbz_dimension_jobs.keys().next().unwrap();
        document.page_size(completed.page).unwrap();
        let first = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.cbz"));
        state.reading_mode = ReadingMode::Paginated;
        state.current_page = 2;
        state.continuous_visible.clear();
        state.continuous_pending.clear();
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);
        assert_eq!(refresh_content(&mut state).units(), 0);
        assert!(!state.cbz_dimension_jobs.keys().any(|job| job.tab_id == 2));

        let task = update(
            &mut state,
            Message::CbzDimensionsLoaded {
                tab_id: completed.tab_id,
                generation: completed.generation,
                page: completed.page,
                result: Ok(()),
            },
        );

        assert!(task.units() > 0);
        assert!(
            state
                .cbz_dimension_jobs
                .keys()
                .any(|job| job.tab_id == 2 && job.page == 2)
        );
    }

    #[test]
    fn display_scale_change_invalidates_pdf_rasters_and_schedules_a_rerender() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.window_scale_factor = 2.0;
        state.file_path = Some(PathBuf::from("sample.pdf"));
        let page = RenderedPage {
            width: 10,
            height: 10,
            pixels: bytes::Bytes::from(vec![0; 400]),
        };
        state.rendered_page = Some(page.clone());
        state.rendered_page_index = Some(0);
        cache_rendered_page(
            &mut state,
            PageCacheKey {
                page: 0,
                scale_bits: 1.0_f32.to_bits(),
                highlights: Vec::new(),
            },
            page,
        );
        state.tabs.push(capture_reader_tab(&state).unwrap());
        let generation = state.window_scale_generation;

        let task = update(
            &mut state,
            Message::WindowScaleFactorLoaded {
                generation,
                scale_factor: 2.5,
            },
        );

        assert_eq!(state.window_scale_factor, 2.5);
        assert_eq!(pdf_raster_density(&state), 2.5);
        assert!(state.rendered_page.is_none());
        assert!(state.page_cache.is_empty());
        assert!(state.tabs[0].rendered_page.is_none());
        assert!(state.tabs[0].page_cache.is_empty());
        assert!(task.units() > 0);
    }

    #[test]
    fn selecting_an_invalidated_continuous_pdf_restarts_its_render() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let document = OpenDocument::Pdf(Arc::new(pdf));
        let mut state = state_with_document(document.clone());
        state.file_path = Some(PathBuf::from("first.pdf"));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.error = Some(AppError::Render("stale render error".to_string()));
        let stale_request = ContinuousRequest {
            id: 1,
            generation: state.render_generation,
            byte_len: 4,
        };
        state.continuous_pending.insert(0, stale_request);
        let first = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.pdf"));
        state.error = None;
        state.continuous_pending.clear();
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        let _ = update(
            &mut state,
            Message::WindowEvent(window::Id::unique(), window::Event::Rescaled(2.0)),
        );
        let _ = update(
            &mut state,
            Message::ContinuousPageRendered {
                tab_id: 1,
                request: stale_request,
                page: 0,
                result: Ok(RenderedPage {
                    width: 10,
                    height: 10,
                    pixels: bytes::Bytes::from(vec![0; 400]),
                }),
            },
        );
        assert!(state.tabs[0].continuous_pages[0].is_none());

        let task = update(&mut state, Message::SelectTab(0));

        assert!(state.error.is_none());
        assert!(state.continuous_pending.contains_key(&0));
        assert_ne!(
            state.continuous_pending.get(&0).copied(),
            Some(stale_request)
        );
        assert!(task.units() > 0);
    }

    #[test]
    fn stale_initial_scale_query_does_not_override_a_rescale_event() {
        let (mut state, _) = boot();
        let id = window::Id::unique();
        let initial_generation = state.window_scale_generation;

        let _ = update(
            &mut state,
            Message::WindowEvent(id, window::Event::Rescaled(2.0)),
        );
        let _ = update(
            &mut state,
            Message::WindowScaleFactorLoaded {
                generation: initial_generation,
                scale_factor: 1.0,
            },
        );

        assert_eq!(state.window_scale_factor, 2.0);
    }

    #[test]
    fn fit_page_scale_keeps_the_complete_spread_in_the_reader() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        for page in 0..2 {
            cbz.page_size(page).unwrap();
        }
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;

        let pages = paginated_raster_pages(&state);
        let scale = paginated_raster_scale(&state, &pages);
        let available = available_reader_size(&state);
        let sizes = pages
            .iter()
            .map(|page| raster_page_size(&state, *page).unwrap())
            .collect::<Vec<_>>();
        let width = sizes.iter().map(|(width, _)| width * scale).sum::<f32>()
            + PAGE_GUTTER * sizes.len().saturating_sub(1) as f32;
        let height = sizes
            .iter()
            .map(|(_, height)| height * scale)
            .fold(0.0_f32, f32::max);

        assert_eq!(pages.len(), 2);
        assert!(width <= available.width + 0.01);
        assert!(height <= available.height + 0.01);
    }

    #[test]
    fn fit_page_spread_aligns_pages_at_the_inner_gutter() {
        assert_eq!(paginated_spread_alignment(0, 2), iced::Alignment::End);
        assert_eq!(paginated_spread_alignment(1, 2), iced::Alignment::Start);
        assert_eq!(paginated_spread_alignment(0, 1), iced::Alignment::Center);
    }

    #[test]
    fn zoom_step_starts_from_the_actual_fitted_scale() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        for page in 0..2 {
            cbz.page_size(page).unwrap();
        }
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        let fitted = paginated_raster_scale(&state, &paginated_raster_pages(&state));

        assert!((zoom_step_scale(&state, 0.25) - (fitted + 0.25)).abs() < 0.001);
        assert!((zoom_step_scale(&state, -0.25) - (fitted - 0.25).max(0.25)).abs() < 0.001);
    }

    #[test]
    fn page_slot_stays_fixed_while_the_raster_fits_inside_it() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = 2;
        let slot_width = raster_page_slot_width(&state, 2, 0.0);

        assert_eq!(
            raster_page_slot_width(&state, 2, slot_width * 0.5),
            slot_width
        );
        assert_eq!(raster_page_slot_width(&state, 2, slot_width), slot_width);
        assert_eq!(
            raster_page_slot_width(&state, 2, slot_width + 1.0),
            slot_width + 1.0
        );
    }

    #[test]
    fn raster_spread_refresh_schedules_both_visible_pages() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        for page in 0..2 {
            cbz.page_size(page).unwrap();
        }
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        // This test isolates worker scheduling from transient-byte admission.
        state.transient_decode_budget = CacheBudget::new(usize::MAX);

        let task = refresh_content(&mut state);

        assert_eq!(task.units(), 2);
        assert!(state.rendered_page.is_none());
        assert!(state.rendered_facing_page.is_none());
    }

    #[test]
    fn completed_spread_prefetches_the_next_page_turn() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        cbz.page_size(0).unwrap();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        let scale = paginated_raster_scale(&state, &[0, 1]);
        for page in [0, 1] {
            let permit = reserve_raster_bytes(&mut state, 10 * 20 * 4).unwrap();
            let rendered = attach_raster_permit(
                RenderedPage {
                    width: 10,
                    height: 20,
                    pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
                },
                permit,
            )
            .unwrap();
            cache_rendered_page(
                &mut state,
                PageCacheKey {
                    page,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
                rendered,
            );
        }

        assert!(show_cached_paginated_spread(&mut state));
        assert_eq!(prefetch_next_paginated_spread(&mut state).units(), 1);
    }

    #[test]
    fn rebuilding_the_view_reuses_visible_raster_handles() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        let scale = paginated_raster_scale(&state, &[0, 1]);
        for page in [0, 1] {
            let permit = reserve_raster_bytes(&mut state, 10 * 20 * 4).unwrap();
            let rendered = attach_raster_permit(
                RenderedPage {
                    width: 10,
                    height: 20,
                    pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
                },
                permit,
            )
            .unwrap();
            cache_rendered_page(
                &mut state,
                PageCacheKey {
                    page,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
                rendered,
            );
        }
        assert!(show_cached_paginated_spread(&mut state));
        let first_id = state.rendered_page_handle.as_ref().unwrap().0.id();
        let facing_id = state.rendered_facing_page_handle.as_ref().unwrap().0.id();

        drop(view(&state));
        drop(view(&state));

        assert_eq!(
            state.rendered_page_handle.as_ref().unwrap().0.id(),
            first_id
        );
        assert_eq!(
            state.rendered_facing_page_handle.as_ref().unwrap().0.id(),
            facing_id
        );

        let prefetch_scale = paginated_raster_scale(&state, &[2]);
        let generation = state.render_generation;
        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation,
                key: PageCacheKey {
                    page: 2,
                    scale_bits: prefetch_scale.to_bits(),
                    highlights: Vec::new(),
                },
                result: Ok(RenderedPage {
                    width: 10,
                    height: 20,
                    pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
                }),
            },
        );

        assert_eq!(
            state.rendered_page_handle.as_ref().unwrap().0.id(),
            first_id
        );
        assert_eq!(
            state.rendered_facing_page_handle.as_ref().unwrap().0.id(),
            facing_id
        );
        state.page_cache.clear();
        assert_eq!(state.raster_budget.used(), 2 * 10 * 20 * 4);
        state.rendered_page = None;
        state.rendered_page_handle = None;
        state.rendered_facing_page = None;
        state.rendered_facing_page_handle = None;
        assert_eq!(state.raster_budget.used(), 0);
    }

    #[test]
    fn raster_spread_is_published_only_after_both_pages_finish() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        let _ = refresh_content(&mut state);
        let generation = state.render_generation;
        let scale = raster_render_scale(&state, paginated_raster_scale(&state, &[0, 1]));
        let keys = [0, 1].map(|page| PageCacheKey {
            page,
            scale_bits: scale.to_bits(),
            highlights: Vec::new(),
        });
        for key in &keys {
            admit_test_raster(
                &mut state,
                RasterJob::Paginated {
                    tab_id: 1,
                    generation,
                    key: key.clone(),
                },
                20 * 20 * 4,
            );
        }
        let rendered = |width| RenderedPage {
            width,
            height: 20,
            pixels: bytes::Bytes::from(vec![0; width as usize * 20 * 4]),
        };

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation,
                key: keys.iter().find(|key| key.page == 0).unwrap().clone(),
                result: Ok(rendered(10)),
            },
        );
        assert!(state.rendered_page.is_none());
        assert!(state.rendered_facing_page.is_none());

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation,
                key: keys.iter().find(|key| key.page == 1).unwrap().clone(),
                result: Ok(rendered(20)),
            },
        );
        assert_eq!(
            state.rendered_page.as_ref().map(|page| page.width),
            Some(10)
        );
        assert_eq!(
            state
                .rendered_facing_page
                .as_ref()
                .map(|(index, page)| (*index, page.width)),
            Some((1, 20))
        );
    }

    #[test]
    fn page_turn_keeps_the_previous_spread_until_the_next_is_ready() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        state.rendered_page_index = Some(0);
        state.rendered_page = Some(RenderedPage {
            width: 10,
            height: 20,
            pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
        });
        state.rendered_facing_page = Some((
            1,
            RenderedPage {
                width: 10,
                height: 20,
                pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
            },
        ));
        state.current_page = 2;

        let task = refresh_content(&mut state);
        let generation = state.render_generation;
        let scale = raster_render_scale(&state, paginated_raster_scale(&state, &[2]));
        let key = PageCacheKey {
            page: 2,
            scale_bits: scale.to_bits(),
            highlights: Vec::new(),
        };
        admit_test_raster(
            &mut state,
            RasterJob::Paginated {
                tab_id: 1,
                generation,
                key: key.clone(),
            },
            20 * 30 * 4,
        );

        assert_eq!(task.units(), 1);
        assert_eq!(displayed_paginated_raster_pages(&state), vec![0, 1]);

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation,
                key,
                result: Ok(RenderedPage {
                    width: 20,
                    height: 30,
                    pixels: bytes::Bytes::from(vec![0; 20 * 30 * 4]),
                }),
            },
        );

        assert_eq!(displayed_paginated_raster_pages(&state), vec![2]);
        assert_eq!(state.rendered_page_index, Some(2));
    }

    #[test]
    fn saved_manual_zoom_does_not_override_fit_page_on_reopen() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let store = runtime
            .block_on(ReadingStateStore::open_at_async(
                &directory.path().join("state.db"),
            ))
            .unwrap();
        let path = directory.path().join("book.cbz");
        runtime
            .block_on(store.set_async(
                &path,
                &FileReadingState {
                    page: 1,
                    location_offset: None,
                    zoom: 2.5,
                },
            ))
            .unwrap();
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let (mut state, _) = boot();
        state.reading_state = Some(store);

        let _runtime = runtime.enter();
        install_document(&mut state, path, None, OpenDocument::Cbz(Arc::new(cbz)));

        assert_eq!(state.current_page, 1);
        assert_eq!(state.zoom, ZoomMode::FitPage);
    }

    #[test]
    fn saved_epub_offset_is_clamped_when_the_document_is_installed() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let directory = tempfile::tempdir().unwrap();
        let store = runtime
            .block_on(ReadingStateStore::open_at_async(
                &directory.path().join("state.db"),
            ))
            .unwrap();
        let path = directory.path().join("book.epub");
        runtime
            .block_on(store.set_async(
                &path,
                &FileReadingState {
                    page: 0,
                    location_offset: Some(usize::MAX),
                    zoom: 1.0,
                },
            ))
            .unwrap();
        let document = OpenDocument::Epub(Arc::new(
            EpubDoc::from_bytes(
                include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
            )
            .expect("fixture should be a valid EPUB"),
        ));
        let expected = document.max_location_offset(0).unwrap();
        let (mut state, _) = boot();
        state.reading_state = Some(store);

        let _runtime = runtime.enter();
        install_document(&mut state, path, None, document);

        assert_eq!(state.epub_offset, expected);
    }

    fn test_book(id: i64) -> Book {
        Book {
            id,
            title: format!("Book {id}"),
            author: None,
            format: shosai_core::library::BookFormat::Epub,
            file_path: format!("/book-{id}.epub"),
            storage_kind: shosai_core::library::StorageKind::Referenced,
            original_path: None,
            content_hash: None,
            file_size: None,
            cover: None,
            progress: 0.0,
            date_added: "2026-01-01".to_string(),
            last_read: None,
        }
    }

    #[test]
    fn switching_tabs_preserves_each_documents_reader_state() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("first.epub"));
        state.current_page = 1;
        let first = capture_reader_tab(&state).unwrap();

        state.file_path = Some(PathBuf::from("second.epub"));
        state.active_tab_id = Some(2);
        state.current_page = 0;
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        let _ = update(&mut state, Message::SelectTab(0));
        assert_eq!(
            state.file_path.as_deref(),
            Some(std::path::Path::new("first.epub"))
        );
        assert_eq!(state.current_page, 1);

        let _ = update(&mut state, Message::SelectTab(1));
        assert_eq!(
            state.file_path.as_deref(),
            Some(std::path::Path::new("second.epub"))
        );
        assert_eq!(state.current_page, 0);
    }

    #[test]
    fn closing_a_background_tab_keeps_the_active_document() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("first.epub"));
        let first = capture_reader_tab(&state).unwrap();
        state.file_path = Some(PathBuf::from("second.epub"));
        state.active_tab_id = Some(2);
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        let _ = update(&mut state, Message::CloseTab(0));

        assert_eq!(state.tabs.len(), 1);
        assert_eq!(state.active_tab, Some(0));
        assert_eq!(
            state.file_path.as_deref(),
            Some(std::path::Path::new("second.epub"))
        );
    }

    #[test]
    fn continuous_epub_mode_reuses_the_shared_chapter_presentation() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let chapter_count = epub.chapter_count();
        let first_chapter = epub.presentation().chapter(0).unwrap() as *const _;
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.total_pages = chapter_count;

        let _ = update(&mut state, Message::ToggleReadingMode);

        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        let Some(OpenDocument::Epub(epub)) = &state.document else {
            panic!("expected EPUB document");
        };
        assert_eq!(epub.presentation().chapters().len(), chapter_count);
        assert_eq!(
            epub.presentation().chapter(0).unwrap() as *const _,
            first_chapter
        );
        assert!(
            epub.presentation()
                .chapters()
                .iter()
                .all(|chapter| !chapter.nodes().is_empty())
        );
    }

    #[test]
    fn continuous_raster_cache_is_bounded_around_visible_pages() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.continuous_pages = (0..12)
            .map(|_| {
                Some(RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: bytes::Bytes::from(vec![0; 4]),
                })
            })
            .collect();
        state.continuous_visible.extend(0..12);

        state.reading_mode = ReadingMode::Continuous;
        let _ = reconcile_continuous_rasters(&mut state);

        assert_eq!(
            state
                .continuous_pages
                .iter()
                .filter(|page| page.is_some())
                .count(),
            CONTINUOUS_PAGE_CACHE_CAPACITY
        );
        assert!(state.continuous_pages[6].is_some());
    }

    #[test]
    fn continuous_scheduler_bounds_pending_and_ready_rasters_together() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = 12;
        state.current_page = 6;
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None; 12];
        state.continuous_visible.extend(0..12);

        let task = reconcile_continuous_rasters(&mut state);

        assert!(task.units() > 0);
        assert!(task.units() <= CONTINUOUS_PAGE_CACHE_CAPACITY);
        assert!(
            state
                .continuous_pending
                .values()
                .map(|request| request.byte_len)
                .sum::<usize>()
                <= CONTINUOUS_RASTER_BYTE_CAPACITY
        );
        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 0);
    }

    #[test]
    fn continuous_scheduler_rejects_work_above_the_byte_budget() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        cbz.page_size(0).expect("fixture page should decode");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        state.zoom = ZoomMode::Manual(10_000.0);

        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 0);
        assert!(state.continuous_pending.is_empty());
    }

    #[test]
    fn continuous_render_waits_for_a_global_worker_slot() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        cbz.page_size(0).expect("fixture page should decode");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        for page in 0..RASTER_RENDER_WORKERS {
            admit_test_raster(
                &mut state,
                RasterJob::Paginated {
                    tab_id: 2,
                    generation: 1,
                    key: PageCacheKey {
                        page,
                        scale_bits: 1.0_f32.to_bits(),
                        highlights: Vec::new(),
                    },
                },
                4,
            );
        }

        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 0);
        assert!(state.continuous_pending.is_empty());
        assert_eq!(state.raster_jobs.len(), RASTER_RENDER_WORKERS);

        let completed = state.raster_jobs.keys().next().unwrap().clone();
        let RasterJob::Paginated {
            tab_id,
            generation,
            key,
        } = completed
        else {
            unreachable!();
        };
        let task = update(
            &mut state,
            Message::PageRendered {
                tab_id,
                generation,
                key,
                result: Err("obsolete render".to_owned()),
            },
        );

        assert!(task.units() > 0);
        assert!(state.continuous_pending.contains_key(&0));
        assert_eq!(state.raster_jobs.len(), RASTER_RENDER_WORKERS);
        assert!(
            state
                .raster_jobs
                .keys()
                .any(|job| matches!(job, RasterJob::Continuous { page: 0, .. }))
        );
    }

    #[test]
    fn unknown_and_duplicate_completions_do_not_release_live_raster_jobs() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        for page in 0..RASTER_RENDER_WORKERS {
            admit_test_raster(
                &mut state,
                RasterJob::Paginated {
                    tab_id: 1,
                    generation: 1,
                    key: PageCacheKey {
                        page,
                        scale_bits: 1.0_f32.to_bits(),
                        highlights: Vec::new(),
                    },
                },
                4,
            );
        }
        let unknown = Message::PageRendered {
            tab_id: 1,
            generation: 1,
            key: PageCacheKey {
                page: 99,
                scale_bits: 1.0_f32.to_bits(),
                highlights: Vec::new(),
            },
            result: Err("duplicate".to_owned()),
        };

        let _ = update(&mut state, unknown.clone());
        let _ = update(&mut state, unknown);

        assert_eq!(state.raster_jobs.len(), RASTER_RENDER_WORKERS);
    }

    #[test]
    fn in_flight_continuous_render_is_rescheduled_after_tab_reactivation() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let document = OpenDocument::Pdf(Arc::new(pdf));
        let mut state = state_with_document(document.clone());
        state.file_path = Some(PathBuf::from("first.pdf"));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 1);
        let request = state.continuous_pending[&0];
        let first = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.pdf"));
        state.document = Some(document);
        state.continuous_pending.clear();
        state.continuous_visible.clear();
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        assert!(
            update(
                &mut state,
                Message::ContinuousPageRendered {
                    tab_id: 1,
                    request,
                    page: 0,
                    result: Err("inactive render".to_owned()),
                }
            )
            .units()
                > 0
        );
        assert!(state.tabs[0].continuous_pending.is_empty());

        let task = update(&mut state, Message::SelectTab(0));

        assert!(task.units() > 0);
        assert!(state.continuous_pending.contains_key(&0));
    }

    #[test]
    fn stale_continuous_completion_releases_its_pending_slot() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        cbz.page_size(0).expect("fixture page should decode");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        let request = ContinuousRequest {
            id: 1,
            generation: 1,
            byte_len: 4,
        };
        state.continuous_pending.insert(0, request);
        admit_test_raster(
            &mut state,
            RasterJob::Continuous {
                tab_id: 1,
                request,
                page: 0,
            },
            4,
        );
        state.render_generation = 2;

        let task = update(
            &mut state,
            Message::ContinuousPageRendered {
                tab_id: 1,
                request,
                page: 0,
                result: Ok(RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: bytes::Bytes::from(vec![0; 4]),
                }),
            },
        );

        assert_eq!(
            task.units(),
            1,
            "the page must be eligible for resubmission"
        );
        assert!(state.continuous_pending.contains_key(&0));
        assert!(state.continuous_pages[0].is_none());
    }

    #[test]
    fn mode_change_releases_an_in_flight_continuous_job() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 1);
        let request = state.continuous_pending[&0];
        let generation = state.render_generation;
        admit_test_raster(
            &mut state,
            RasterJob::Continuous {
                tab_id: 1,
                request: ContinuousRequest {
                    id: 99,
                    generation,
                    byte_len: 4,
                },
                page: 99,
            },
            4,
        );
        assert_eq!(state.raster_jobs.len(), RASTER_RENDER_WORKERS);
        state.reading_mode = ReadingMode::Paginated;
        state.continuous_pages.clear();
        state.render_generation = state.render_generation.wrapping_add(1);
        assert_eq!(refresh_content(&mut state).units(), 0);

        let task = update(
            &mut state,
            Message::ContinuousPageRendered {
                tab_id: 1,
                request,
                page: 0,
                result: Err("obsolete render".to_owned()),
            },
        );

        assert!(task.units() > 0);
        assert!(
            state
                .raster_jobs
                .keys()
                .any(|job| matches!(job, RasterJob::Paginated { .. }))
        );
        assert!(!state.raster_jobs.keys().any(|job| matches!(
            job,
            RasterJob::Continuous {
                tab_id: 1,
                request: admitted,
                page: 0,
            } if *admitted == request
        )));
        assert!(state.continuous_pending.is_empty());
    }

    #[test]
    fn completion_from_a_closed_tab_releases_its_continuous_job() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 1);
        let request = state.continuous_pending[&0];
        state.active_tab_id = Some(2);
        state.continuous_pending.clear();

        let _ = update(
            &mut state,
            Message::ContinuousPageRendered {
                tab_id: 1,
                request,
                page: 0,
                result: Err("closed tab render".to_owned()),
            },
        );

        assert!(!state.raster_jobs.keys().any(|job| matches!(
            job,
            RasterJob::Continuous {
                tab_id: 1,
                request: admitted,
                page: 0,
            } if *admitted == request
        )));
    }

    #[test]
    fn old_continuous_completion_cannot_remove_a_newer_request() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        for page in 0..cbz.page_count() {
            cbz.page_size(page).unwrap();
        }
        let page_count = cbz.page_count();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = page_count;
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None; state.total_pages];
        state.continuous_visible.extend(0..state.total_pages);
        let old_request = ContinuousRequest {
            id: 1,
            generation: 1,
            byte_len: 4,
        };
        let new_request = ContinuousRequest {
            id: 2,
            generation: 1,
            byte_len: 4,
        };
        state.continuous_pending.insert(0, new_request);
        let blocker_request = ContinuousRequest {
            id: 3,
            generation: 1,
            byte_len: 4,
        };
        state.continuous_pending.insert(1, blocker_request);
        admit_test_raster(
            &mut state,
            RasterJob::Continuous {
                tab_id: 1,
                request: old_request,
                page: 0,
            },
            4,
        );
        admit_test_raster(
            &mut state,
            RasterJob::Continuous {
                tab_id: 1,
                request: blocker_request,
                page: 1,
            },
            4,
        );

        let task = update(
            &mut state,
            Message::ContinuousPageRendered {
                tab_id: 1,
                request: old_request,
                page: 0,
                result: Ok(RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: bytes::Bytes::from(vec![0; 4]),
                }),
            },
        );

        assert!(task.units() > 0);
        assert_eq!(state.continuous_pending.get(&0), Some(&new_request));
        assert!(state.continuous_pages[0].is_none());
        assert!(
            state
                .raster_jobs
                .keys()
                .any(|job| matches!(job, RasterJob::Continuous { page: 2, .. }))
        );
    }

    #[test]
    fn continuous_completion_is_dropped_while_its_tab_is_inactive() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.file_path = Some(PathBuf::from("first.cbz"));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        let request = ContinuousRequest {
            id: 1,
            generation: state.render_generation,
            byte_len: 4,
        };
        state.continuous_pending.insert(0, request);
        admit_test_raster(
            &mut state,
            RasterJob::Continuous {
                tab_id: 1,
                request,
                page: 0,
            },
            4,
        );
        let first = capture_reader_tab(&state).unwrap();
        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.cbz"));
        state.continuous_pending.clear();
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        let _ = update(
            &mut state,
            Message::ContinuousPageRendered {
                tab_id: 1,
                request,
                page: 0,
                result: Ok(RenderedPage {
                    width: 7,
                    height: 7,
                    pixels: bytes::Bytes::from(vec![0; 7 * 7 * 4]),
                }),
            },
        );

        assert!(state.tabs[0].continuous_pending.is_empty());
        assert!(state.tabs[0].continuous_pages[0].is_none());
    }

    #[test]
    fn continuous_pdf_search_navigation_invalidates_cached_highlights() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![Some(RenderedPage {
            width: 1,
            height: 1,
            pixels: bytes::Bytes::from(vec![0; 4]),
        })];
        state.continuous_visible.insert(0);
        state.search_results = vec![
            SearchMatch {
                page: 0,
                offset: 0,
                length: 3,
                context: "first".to_string(),
            },
            SearchMatch {
                page: 0,
                offset: 4,
                length: 3,
                context: "second".to_string(),
            },
        ];
        let previous_highlights = current_page_search_highlights(&state);
        let previous_generation = state.render_generation;
        state.search_current = 1;

        let task = navigate_to_current_search_result(&mut state, &previous_highlights);

        assert!(state.render_generation > previous_generation);
        assert!(state.continuous_pages[0].is_none());
        assert!(state.continuous_pending.contains_key(&0));
        assert!(task.units() > 0);
    }

    #[test]
    fn closing_continuous_pdf_search_invalidates_other_pages() {
        let pdf = PdfDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
        )
        .expect("fixture should be a valid PDF");
        let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![
            Some(RenderedPage {
                width: 1,
                height: 1,
                pixels: bytes::Bytes::from(vec![0; 4]),
            }),
            Some(RenderedPage {
                width: 1,
                height: 1,
                pixels: bytes::Bytes::from(vec![0; 4]),
            }),
        ];
        state.total_pages = 2;
        state.search_results = vec![SearchMatch {
            page: 1,
            offset: 0,
            length: 3,
            context: "other page".to_string(),
        }];
        let previous_highlights = current_page_search_highlights(&state);
        state.search_results.clear();

        let _ = refresh_pdf_search_highlights_if_changed(&mut state, &previous_highlights);

        assert!(state.continuous_pages.iter().all(Option::is_none));
    }

    #[test]
    fn continuous_position_messages_are_scoped_to_the_active_tab() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.reading_mode = ReadingMode::Continuous;
        state.total_pages = 2;
        let activation = state.continuous_activation;

        let _ = update(
            &mut state,
            Message::ContinuousItemResolved {
                tab_id: 2,
                activation,
                page: 1,
                epub_offset: Some(0),
            },
        );

        assert_eq!(state.current_page, 0);
    }

    #[test]
    fn continuous_position_messages_are_scoped_to_the_activation() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.reading_mode = ReadingMode::Continuous;
        state.total_pages = 2;
        state.continuous_activation = 3;

        let _ = update(
            &mut state,
            Message::ContinuousItemResolved {
                tab_id: 1,
                activation: 2,
                page: 1,
                epub_offset: Some(0),
            },
        );

        assert_eq!(state.current_page, 0);
    }

    #[test]
    fn removing_or_resizing_continuous_view_invalidates_its_layout_epoch() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_tail_extent = 500.0;
        let first_activation = state.continuous_activation;

        let _ = update(&mut state, Message::ToggleReadingMode);
        assert!(state.continuous_activation > first_activation);
        assert_eq!(state.continuous_tail_extent, 0.0);

        let second_activation = state.continuous_activation;
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_tail_extent = 300.0;
        let task = update(
            &mut state,
            Message::WindowEvent(
                window::Id::unique(),
                window::Event::Resized(Size::new(800.0, 600.0)),
            ),
        );
        assert!(state.continuous_activation > second_activation);
        assert_eq!(state.continuous_tail_extent, 0.0);
        assert!(task.units() > 1, "resize must persist and remeasure layout");
    }

    #[test]
    fn continuous_home_and_end_keyboard_navigation_is_dispatched() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.reading_mode = ReadingMode::Continuous;
        state.total_pages = 2;

        for key in [keyboard::key::Named::Home, keyboard::key::Named::End] {
            let task = handle_key_event(
                &state,
                keyboard::Event::KeyPressed {
                    key: keyboard::Key::Named(key),
                    modified_key: keyboard::Key::Named(key),
                    physical_key: keyboard::key::Physical::Unidentified(
                        keyboard::key::NativeCode::Unidentified,
                    ),
                    location: keyboard::Location::Standard,
                    modifiers: keyboard::Modifiers::empty(),
                    text: None,
                    repeat: false,
                },
            );
            assert!(task.units() > 0);
        }

        state.current_page = 1;
        assert!(update(&mut state, Message::FirstPage).units() > 0);
        assert_eq!(state.current_page, 0);
        assert!(update(&mut state, Message::LastPage).units() > 0);
        assert_eq!(state.current_page, 1);
    }

    #[test]
    fn tab_switch_preserves_completed_continuous_rasters() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("first.epub"));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![Some(RenderedPage {
            width: 7,
            height: 7,
            pixels: bytes::Bytes::from(vec![0; 7 * 7 * 4]),
        })];
        let first = capture_reader_tab(&state).unwrap();
        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.epub"));
        state.continuous_pages.clear();
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        let _ = update(&mut state, Message::SelectTab(0));

        assert_eq!(
            state.continuous_pages[0].as_ref().map(|page| page.width),
            Some(7)
        );
    }

    #[test]
    fn stale_bookmark_completion_cannot_replace_another_tabs_bookmarks() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.epub"));

        let _ = update(
            &mut state,
            Message::BookmarksLoaded {
                tab_id: 1,
                file_path: PathBuf::from("first.epub"),
                book_id: None,
                bookmarks: vec![Bookmark {
                    id: 1,
                    file_path: "first.epub".to_string(),
                    book_id: None,
                    page: 0,
                    location_offset: None,
                    title: None,
                    note: None,
                    color: "yellow".to_string(),
                    created_at: "now".to_string(),
                }],
            },
        );

        assert!(state.bookmarks.is_empty());
    }

    #[test]
    fn bookmark_completion_with_a_removed_identity_is_rejected() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("removed.epub"));
        state.book_id = None;

        let _ = update(
            &mut state,
            Message::BookmarksLoaded {
                tab_id: 1,
                file_path: PathBuf::from("removed.epub"),
                book_id: Some(42),
                bookmarks: vec![Bookmark {
                    id: 1,
                    file_path: "removed.epub".to_string(),
                    book_id: Some(42),
                    page: 0,
                    location_offset: None,
                    title: None,
                    note: None,
                    color: "yellow".to_string(),
                    created_at: "now".to_string(),
                }],
            },
        );

        assert!(state.bookmarks.is_empty());
    }

    #[test]
    fn restoring_a_tab_restarts_its_interrupted_search() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("first.epub"));
        state.show_search_bar = true;
        state.search_query = "chapter".to_string();
        state.search_loading = true;
        let first = capture_reader_tab(&state).unwrap();
        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.epub"));
        state.show_search_bar = false;
        state.search_query.clear();
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);

        let task = update(&mut state, Message::SelectTab(0));

        assert!(!state.search_loading || task.units() > 0);
        assert!(
            task.units() > 0,
            "restored query must have a live search task"
        );
    }

    #[test]
    fn window_geometry_writes_are_debounced() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let id = window::Id::unique();

        let first = update(
            &mut state,
            Message::WindowEvent(id, window::Event::Resized(Size::new(800.0, 600.0))),
        );
        let first_generation = state.window_geometry_generation;
        let second = update(
            &mut state,
            Message::WindowEvent(id, window::Event::Resized(Size::new(900.0, 700.0))),
        );

        assert!(first.units() > 0 && second.units() > 0);
        assert!(state.window_geometry_generation > first_generation);
        assert_eq!(
            update(&mut state, Message::PersistWindowGeometry(first_generation)).units(),
            0,
            "an obsolete debounce must not write geometry"
        );
    }

    #[tokio::test]
    async fn close_flushes_the_latest_geometry_after_an_inflight_save() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let directory = tempfile::tempdir().unwrap();
        state.reading_state = Some(
            ReadingStateStore::open_at_async(&directory.path().join("state.db"))
                .await
                .unwrap(),
        );
        let id = window::Id::unique();
        state.window_geometry_dirty = true;
        state.window_geometry_saving = true;

        assert_eq!(
            update(
                &mut state,
                Message::WindowEvent(id, window::Event::CloseRequested)
            )
            .units(),
            0,
            "close must wait for the in-flight snapshot"
        );
        assert_eq!(state.close_after_geometry_save, Some(id));
        assert!(state.window_geometry_dirty);

        let latest_save = update(&mut state, Message::WindowGeometryPersisted);
        assert!(latest_save.units() > 0);
        assert!(state.window_geometry_saving);
        assert_eq!(state.close_after_geometry_save, Some(id));

        let close = update(&mut state, Message::WindowGeometryPersisted);
        assert!(close.units() > 0);
        assert!(!state.window_geometry_saving);
        assert!(state.close_after_geometry_save.is_none());
    }

    #[test]
    fn stale_library_results_do_not_replace_a_newer_query() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.library_generation = 2;
        state.library_loading = true;

        let _ = update(
            &mut state,
            Message::LibraryLoaded {
                generation: 1,
                offset: 0,
                next_offset: 1,
                page: BookPage {
                    books: vec![test_book(1)],
                    has_more: false,
                },
            },
        );

        assert!(state.library_books.is_empty());
        assert!(state.library_loading);
    }

    #[test]
    fn removing_a_library_book_requires_confirmation() {
        let (mut state, _) = boot();
        let book = test_book(42);

        let menu = update(&mut state, Message::ToggleBookMenu(42));

        assert_eq!(menu.units(), 0);
        assert_eq!(state.book_menu, Some(42));
        drop(render_book_card(&state, &book));

        let request = update(&mut state, Message::RequestRemoveBook(42));

        assert_eq!(request.units(), 0);
        assert_eq!(state.book_menu, None);
        assert_eq!(state.pending_remove_book, Some(42));
        state.library_books.push(book.clone());
        drop(library_layout(&state, 900.0));

        let cancel = update(&mut state, Message::CancelRemoveBook);

        assert_eq!(cancel.units(), 0);
        assert_eq!(state.pending_remove_book, None);
        drop(render_book_card(&state, &book));
    }

    #[test]
    fn clicking_outside_a_book_menu_closes_it() {
        let (mut state, _) = boot();
        state.library_books.push(test_book(42));
        let _ = update(&mut state, Message::ToggleBookMenu(42));

        drop(library_layout(&state, 900.0));
        let close = update(&mut state, Message::CloseBookMenu);

        assert_eq!(close.units(), 0);
        assert_eq!(state.book_menu, None);
    }

    #[test]
    fn settings_navigation_works_in_both_layouts() {
        let (mut state, _) = boot();

        let _ = update(&mut state, Message::ShowSettings);

        assert_eq!(state.screen, Screen::Settings);
        drop(settings_layout(&state, 900.0));
        drop(settings_layout(&state, 600.0));

        let _ = update(&mut state, Message::LibraryFilterChanged(None));

        assert_eq!(state.screen, Screen::Library);
    }

    #[test]
    fn editable_and_cross_script_controls_use_bundled_glyph_coverage() {
        assert_eq!(
            editable_text_font("日本語", "Search"),
            typography::NOTO_SANS_JP
        );
        assert_eq!(editable_text_font("", "検索"), typography::NOTO_SANS_JP);
        assert_eq!(language_menu_font(), typography::NOTO_SANS_JP);
    }

    #[test]
    fn partial_import_completion_keeps_successes_visible_and_surfaces_failures() {
        let (mut state, _) = boot();
        state.adding_books = true;
        state.book_import_total = 1;
        let report = ImportReport {
            books: vec![test_book(42)],
            failures: vec![shosai_core::library::ImportFailure {
                path: PathBuf::from("corrupt.epub"),
                error: "invalid archive".to_string(),
            }],
        };

        let task = update(&mut state, Message::BookAddedToBatch(report));

        assert_eq!(task.units(), 0);
        assert!(!state.adding_books);
        let Some(AppError::Import(error)) = state.library_error else {
            panic!("partial import should surface its failures");
        };
        assert_eq!(
            error.replace(['\u{2068}', '\u{2069}'], ""),
            "Books added or already present: 1. Files not imported: 1. corrupt.epub: invalid archive"
        );
    }

    #[test]
    fn review_virtualization_builds_only_the_visible_window() {
        let rows: Vec<_> = (0..1_000)
            .flat_map(|index| {
                [
                    AddBooksReviewRow::Group(format!("Book {index}")),
                    AddBooksReviewRow::Book(index),
                ]
            })
            .collect();
        let (range, top, bottom) = virtual_review_range(&rows, 30_000.0, 420.0);
        let rendered: f32 = rows[range.clone()]
            .iter()
            .map(AddBooksReviewRow::height)
            .sum();
        let total: f32 = rows.iter().map(AddBooksReviewRow::height).sum();

        assert!(range.len() < 30);
        assert!(top > 0.0);
        assert!(bottom > 0.0);
        assert!((top + rendered + bottom - total).abs() < f32::EPSILON);
    }

    #[test]
    fn review_search_filters_without_losing_original_book_indices() {
        let (mut state, _) = boot();
        state.staged_imports = [
            ("Rust", "guide.epub", shosai_core::library::BookFormat::Epub),
            (
                "Systems",
                "manual.pdf",
                shosai_core::library::BookFormat::Pdf,
            ),
        ]
        .into_iter()
        .enumerate()
        .map(|(index, (title, path, format))| StagedImport {
            selected: true,
            candidate: ImportCandidate {
                path: PathBuf::from(path),
                title: title.to_string(),
                group_key: format!("group-{index}"),
                format,
                file_size: 100,
                content_hash: format!("hash-{index}"),
                duplicate: None,
            },
        })
        .collect();
        state.add_books_review_search = "PDF".to_string();

        rebuild_add_books_review_rows(&mut state);

        assert_eq!(state.add_books_review_rows.len(), 2);
        assert!(matches!(
            state.add_books_review_rows[1],
            AddBooksReviewRow::Book(1)
        ));
    }

    #[test]
    fn review_search_uses_unicode_normalization_and_case_folding() {
        let (mut state, _) = boot();
        state.staged_imports = ["Straße.pdf", "か\u{3099}.epub"]
            .into_iter()
            .enumerate()
            .map(|(index, path)| StagedImport {
                selected: true,
                candidate: ImportCandidate {
                    path: PathBuf::from(path),
                    title: path.to_string(),
                    group_key: format!("group-{index}"),
                    format: shosai_core::library::BookFormat::Epub,
                    file_size: 100,
                    content_hash: format!("hash-{index}"),
                    duplicate: None,
                },
            })
            .collect();

        state.add_books_review_search = "STRASSE".to_string();
        rebuild_add_books_review_rows(&mut state);
        assert!(matches!(
            state.add_books_review_rows[1],
            AddBooksReviewRow::Book(0)
        ));

        state.add_books_review_search = "が".to_string();
        rebuild_add_books_review_rows(&mut state);
        assert!(matches!(
            state.add_books_review_rows[1],
            AddBooksReviewRow::Book(1)
        ));
    }

    #[test]
    fn virtual_review_range_clamps_stale_offsets_to_short_content() {
        let rows = vec![
            AddBooksReviewRow::Group("Book".to_string()),
            AddBooksReviewRow::Book(0),
        ];

        let (range, _, _) = virtual_review_range(&rows, 30_000.0, 420.0);

        assert_eq!(range, 0..2);
    }

    #[test]
    fn stale_review_scroll_message_cannot_replace_the_current_offset() {
        let (mut state, _) = boot();
        state.add_books_open = true;
        state.add_books_generation = 4;
        state.add_books_review_revision = 2;

        let _ = update(
            &mut state,
            Message::AddBooksReviewScrolled {
                generation: 4,
                revision: 1,
                offset: 30_000.0,
                viewport_height: 420.0,
            },
        );

        assert_eq!(state.add_books_review_offset, 0.0);
    }

    #[tokio::test]
    async fn add_books_flow_stages_candidates_before_importing() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));

        let _ = update(&mut state, Message::OpenAddBooks);
        assert!(state.add_books_open);
        assert!(state.add_books_source.is_none());
        drop(add_books_modal(&state));

        state.add_book_behavior = AddBookBehavior::Copy;
        state.library_activity_opacity = 0.0;
        let paths = vec![PathBuf::from("one.epub"), PathBuf::from("two.pdf")];
        let generation = state.add_books_generation;
        let discover = update(
            &mut state,
            Message::AddBookFilesSelected { generation, paths },
        );
        assert!(discover.units() > 0);
        assert!(matches!(
            state.add_books_source,
            Some(AddBooksSource::Files(ref paths)) if paths.len() == 2
        ));
        assert!(state.add_books_discovering);
        assert_eq!(state.library_activity_opacity, 1.0);
        assert!(state.add_books_progress.is_some());
        assert!(state.staged_imports.is_empty());
        drop(add_books_modal(&state));

        let generation = state.add_books_generation;
        let _ = update(
            &mut state,
            Message::BooksDiscovered {
                generation,
                discovery: shosai_core::library::ImportDiscovery {
                    candidates: vec![
                        ImportCandidate {
                            path: PathBuf::from("one.epub"),
                            title: "one".to_string(),
                            group_key: "one".to_string(),
                            format: shosai_core::library::BookFormat::Epub,
                            file_size: 100,
                            content_hash: "one-hash".to_string(),
                            duplicate: None,
                        },
                        ImportCandidate {
                            path: PathBuf::from("two.pdf"),
                            title: "two".to_string(),
                            group_key: "two".to_string(),
                            format: shosai_core::library::BookFormat::Pdf,
                            file_size: 200,
                            content_hash: "two-hash".to_string(),
                            duplicate: Some(ImportDuplicate::ExistingBook {
                                book_id: 7,
                                title: "Two".to_string(),
                            }),
                        },
                    ],
                    failures: Vec::new(),
                },
            },
        );
        assert!(!state.add_books_discovering);
        assert!(state.add_books_progress.is_none());
        assert_eq!(state.staged_imports.len(), 2);
        assert!(state.staged_imports[0].selected);
        assert!(!state.staged_imports[1].selected);
        assert_eq!(state.add_books_copy, Some(true));
        drop(add_books_modal(&state));

        let _ = update(&mut state, Message::ToggleStagedBook(1, true));
        let _ = update(&mut state, Message::SelectAllStagedBooks(false));
        assert!(!state.staged_imports[0].selected);
        assert!(state.staged_imports[1].selected);
        let _ = update(&mut state, Message::SelectAllStagedBooks(true));
        assert!(state.staged_imports[0].selected);
        assert!(state.staged_imports[1].selected);

        let _ = update(&mut state, Message::ChangeAddBooksStorage);
        assert_eq!(state.add_books_copy, None);
        let _ = update(&mut state, Message::SelectAddBooksStorage(false));
        assert_eq!(state.add_books_copy, Some(false));
        drop(add_books_modal(&state));

        let stale_generation = state.add_books_generation;
        let _ = update(&mut state, Message::ClearAddBooksSelection);
        assert!(state.add_books_source.is_none());
        assert!(state.staged_imports.is_empty());
        assert_eq!(state.add_books_copy, None);
        let _ = update(
            &mut state,
            Message::BooksDiscovered {
                generation: stale_generation,
                discovery: shosai_core::library::ImportDiscovery {
                    candidates: vec![ImportCandidate {
                        path: PathBuf::from("stale.epub"),
                        title: "stale".to_string(),
                        group_key: "stale".to_string(),
                        format: shosai_core::library::BookFormat::Epub,
                        file_size: 100,
                        content_hash: "stale-hash".to_string(),
                        duplicate: None,
                    }],
                    failures: Vec::new(),
                },
            },
        );
        assert!(state.staged_imports.is_empty());

        let generation = state.add_books_generation;
        let discover = update(
            &mut state,
            Message::AddBookFolderSelected {
                generation,
                path: Some(PathBuf::from("books")),
            },
        );
        assert!(discover.units() > 0);
        assert!(matches!(
            state.add_books_source,
            Some(AddBooksSource::Folder(ref path)) if path == &PathBuf::from("books")
        ));
        assert!(state.add_books_discovering);
        let cancellation = state.add_books_cancellation.clone().unwrap();

        let _ = update(&mut state, Message::CancelAddBooks);
        assert!(!state.add_books_open);
        assert!(state.add_books_source.is_none());
        assert!(!state.add_books_discovering);
        assert!(state.add_books_progress.is_none());
        assert!(cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn batch_import_updates_progress_and_library_before_completion() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.library_loading = false;
        state.adding_books = true;
        state.book_import_total = 2;
        state.pending_book_imports.push_back((
            1,
            ImportCandidate {
                path: PathBuf::from("second.epub"),
                title: "second".to_string(),
                group_key: "second".to_string(),
                format: shosai_core::library::BookFormat::Epub,
                file_size: 100,
                content_hash: "second-hash".to_string(),
                duplicate: None,
            },
        ));

        let task = update(
            &mut state,
            Message::BookAddedToBatch(ImportReport {
                books: vec![test_book(42)],
                failures: Vec::new(),
            }),
        );

        assert!(task.units() > 0);
        assert!(state.adding_books);
        assert_eq!(state.book_import_completed, 1);
        assert_eq!(state.library_activity_progress, 0.5);
        assert_eq!(state.library_books.len(), 1);
        assert_eq!(state.library_books[0].id, 42);
    }

    #[tokio::test]
    async fn managed_import_starts_only_four_preparations() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.add_books_open = true;
        state.add_books_copy = Some(true);
        state.staged_imports = (0..6)
            .map(|index| StagedImport {
                selected: true,
                candidate: ImportCandidate {
                    path: PathBuf::from(format!("book-{index}.epub")),
                    title: format!("book-{index}"),
                    group_key: format!("book-{index}"),
                    format: shosai_core::library::BookFormat::Epub,
                    file_size: 100,
                    content_hash: format!("hash-{index}"),
                    duplicate: None,
                },
            })
            .collect();
        state.library_activity_opacity = 0.0;

        let task = update(&mut state, Message::AddSelectedBooks);

        assert_eq!(task.units(), MANAGED_IMPORT_PREPARATION_CONCURRENCY);
        assert_eq!(state.library_activity_opacity, 1.0);
        assert_eq!(state.book_import_preparing, 4);
        assert_eq!(state.pending_book_imports.len(), 2);
        assert!(state.prepared_book_imports.is_empty());
        assert!(!state.book_import_committing);
    }

    #[tokio::test]
    async fn managed_import_bounds_completed_preparations_behind_a_slow_first_book() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.add_books_open = true;
        state.add_books_copy = Some(true);
        state.staged_imports = (0..8)
            .map(|index| StagedImport {
                selected: true,
                candidate: ImportCandidate {
                    path: PathBuf::from(format!("book-{index}.epub")),
                    title: format!("book-{index}"),
                    group_key: format!("book-{index}"),
                    format: shosai_core::library::BookFormat::Epub,
                    file_size: 100,
                    content_hash: format!("hash-{index}"),
                    duplicate: None,
                },
            })
            .collect();
        let _ = update(&mut state, Message::AddSelectedBooks);

        for index in 1..4 {
            let _ = update(
                &mut state,
                Message::ManagedBookPrepared {
                    index,
                    result: Err(ImportFailure {
                        path: PathBuf::from(format!("book-{index}.epub")),
                        error: "test failure".to_string(),
                    }),
                },
            );
        }

        assert_eq!(state.pending_book_imports.len(), 4);
        assert_eq!(state.book_import_preparing, 1);
        assert_eq!(state.prepared_book_imports.len(), 3);
        assert_eq!(state.library_activity_progress, 3.0 / 16.0);
    }

    #[tokio::test]
    async fn stale_book_picker_results_cannot_replace_a_newer_session() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));

        let _ = update(&mut state, Message::OpenAddBooks);
        let old_session = state.add_books_generation;
        let _ = update(&mut state, Message::CancelAddBooks);
        let _ = update(&mut state, Message::OpenAddBooks);
        let _ = update(
            &mut state,
            Message::AddBookFilesSelected {
                generation: old_session,
                paths: vec![PathBuf::from("old.epub")],
            },
        );
        assert!(state.add_books_source.is_none());

        let _ = update(&mut state, Message::ChooseBookFiles);
        let older_picker = state.add_books_generation;
        let _ = update(&mut state, Message::ChooseBookFolder);
        let newer_picker = state.add_books_generation;
        let _ = update(
            &mut state,
            Message::AddBookFilesSelected {
                generation: older_picker,
                paths: vec![PathBuf::from("older.epub")],
            },
        );
        assert!(state.add_books_source.is_none());
        let task = update(
            &mut state,
            Message::AddBookFolderSelected {
                generation: newer_picker,
                path: Some(PathBuf::from("newer")),
            },
        );
        assert!(task.units() > 0);
        assert!(matches!(
            state.add_books_source,
            Some(AddBooksSource::Folder(ref path)) if path == &PathBuf::from("newer")
        ));
    }

    #[test]
    fn import_candidate_labels_distinguish_nested_and_individual_files() {
        let directory = tempfile::tempdir().unwrap();
        let nested = directory.path().join("publisher").join("book.epub");
        std::fs::create_dir_all(nested.parent().unwrap()).unwrap();
        std::fs::write(&nested, b"book").unwrap();
        let canonical = nested.canonicalize().unwrap();

        assert_eq!(
            import_candidate_label(
                &AddBooksSource::Folder(directory.path().to_path_buf()),
                &canonical,
            ),
            PathBuf::from("publisher")
                .join("book.epub")
                .display()
                .to_string()
        );
        assert_eq!(
            import_candidate_label(&AddBooksSource::Files(vec![nested]), &canonical),
            canonical.display().to_string()
        );
    }

    #[tokio::test]
    async fn settings_preferences_are_persisted_and_update_open_books() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.reading_state_saves = Some(start_reading_state_writer(store.clone()));
        let _ = update(
            &mut state,
            Message::SelectAddBookBehavior(AddBookBehavior::Copy),
        );
        let _ = update(
            &mut state,
            Message::SelectDefaultReadingMode(ReadingMode::Continuous),
        );
        let _ = update(
            &mut state,
            Message::SelectDefaultReaderTheme(ReaderTheme::Sepia),
        );
        let _ = update(&mut state, Message::DefaultEpubFontSizeUp);
        let _ = update(&mut state, Message::SelectDefaultEpubLineSpacing(1.8));
        let _ = update(&mut state, Message::SelectDefaultPdfFitWidth(true));
        let (flushed, wait) = oneshot::channel();
        state
            .reading_state_saves
            .as_ref()
            .unwrap()
            .send(ReadingStateWriterMessage::Flush(flushed))
            .unwrap();
        wait.await.unwrap().unwrap();

        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        assert_eq!(state.theme, ReaderTheme::Sepia);
        assert_eq!(state.font_size, 18.0);
        assert_eq!(state.line_spacing, 1.8);
        assert_eq!(
            store.get_pref_async(ADD_BOOK_BEHAVIOR_KEY).await.as_deref(),
            Some("copy")
        );
        assert_eq!(
            store
                .get_pref_async(DEFAULT_READING_MODE_KEY)
                .await
                .as_deref(),
            Some("continuous")
        );
        assert_eq!(
            store
                .get_pref_async(DEFAULT_READER_THEME_KEY)
                .await
                .as_deref(),
            Some("sepia")
        );
        assert_eq!(
            store
                .get_pref_async(DEFAULT_EPUB_FONT_SIZE_KEY)
                .await
                .as_deref(),
            Some("18")
        );
        assert_eq!(
            store
                .get_pref_async(DEFAULT_EPUB_LINE_SPACING_KEY)
                .await
                .as_deref(),
            Some("1.8")
        );
        assert_eq!(
            store.get_pref_async(DEFAULT_PDF_ZOOM_KEY).await.as_deref(),
            Some("fit-width")
        );
    }

    #[test]
    fn local_reader_overrides_only_protect_the_setting_changed_for_that_book() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let _ = update(&mut state, Message::ToggleReadingMode);
        let _ = update(&mut state, Message::FontSizeUp);
        let _ = update(&mut state, Message::CycleTheme);
        let local_mode = state.reading_mode;
        let local_font_size = state.font_size;
        let local_theme = state.theme;

        let _ = update(
            &mut state,
            Message::SelectDefaultReadingMode(ReadingMode::Paginated),
        );
        let _ = update(
            &mut state,
            Message::SelectDefaultReaderTheme(ReaderTheme::Dark),
        );
        let _ = update(&mut state, Message::DefaultEpubFontSizeUp);
        let _ = update(&mut state, Message::DefaultEpubFontSizeUp);
        let _ = update(&mut state, Message::SelectDefaultEpubLineSpacing(1.8));

        assert_eq!(state.reading_mode, local_mode);
        assert_eq!(state.font_size, local_font_size);
        assert_eq!(state.theme, local_theme);
        assert_eq!(state.line_spacing, 1.8);
    }

    #[test]
    fn defaults_update_inactive_tabs_before_they_are_selected_again() {
        let directory = tempfile::tempdir().unwrap();
        let epub_path = directory.path().join("book.epub");
        let pdf_path = directory.path().join("book.pdf");
        std::fs::copy(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../shosai-core/tests/fixtures/sample.epub"),
            &epub_path,
        )
        .unwrap();
        std::fs::copy(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../shosai-core/tests/fixtures/sample.pdf"),
            &pdf_path,
        )
        .unwrap();
        let (mut state, _) = boot();

        let _ = open_document_now(&mut state, epub_path, None);
        let _ = open_document_now(&mut state, pdf_path, None);
        let _ = update(&mut state, Message::DefaultEpubFontSizeUp);
        let _ = update(&mut state, Message::SelectDefaultEpubLineSpacing(1.8));
        let _ = update(&mut state, Message::SelectDefaultPdfFitWidth(true));

        assert_eq!(state.zoom, ZoomMode::FitWidth);
        let _ = select_tab(&mut state, 0);
        assert_eq!(state.font_size, 18.0);
        assert_eq!(state.line_spacing, 1.8);
    }

    #[test]
    fn reader_defaults_seed_new_tabs() {
        let directory = tempfile::tempdir().unwrap();
        let epub_path = directory.path().join("book.epub");
        let pdf_path = directory.path().join("book.pdf");
        std::fs::copy(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../shosai-core/tests/fixtures/sample.epub"),
            &epub_path,
        )
        .unwrap();
        std::fs::copy(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../shosai-core/tests/fixtures/sample.pdf"),
            &pdf_path,
        )
        .unwrap();
        let (mut state, _) = boot();
        state.reader_defaults = ReaderDefaults {
            reading_mode: ReadingMode::Continuous,
            theme: ReaderTheme::Sepia,
            epub_font_size: 20.0,
            epub_line_spacing: 1.8,
            pdf_zoom: ZoomMode::FitWidth,
        };

        let _ = open_document_now(&mut state, epub_path, None);
        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        assert_eq!(state.theme, ReaderTheme::Sepia);
        assert_eq!(state.font_size, 20.0);
        assert_eq!(state.line_spacing, 1.8);

        let _ = open_document_now(&mut state, pdf_path, None);
        assert_eq!(state.zoom, ZoomMode::FitWidth);
    }

    #[test]
    fn removal_confirmation_describes_managed_and_referenced_storage() {
        let (mut state, _) = boot();
        state.pending_remove_book = Some(42);
        let referenced = test_book(42);
        let mut managed = test_book(42);
        managed.storage_kind = shosai_core::library::StorageKind::Managed;

        state.library_books = vec![referenced];
        drop(library_layout(&state, 900.0));
        state.library_books = vec![managed];
        drop(library_layout(&state, 600.0));

        for preference in [LanguagePreference::English, LanguagePreference::Japanese] {
            let i18n = I18n::new(preference);
            assert!(!i18n.text("remove-managed-book-description").is_empty());
            assert!(!i18n.text("remove-referenced-book-description").is_empty());
        }
    }

    #[tokio::test]
    async fn successful_book_removal_detaches_matching_reader_tabs() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.book_id = Some(42);
        state.file_path = Some(PathBuf::from("removed.epub"));
        state.library_books = vec![test_book(42), test_book(7)];
        state.current_page = 3;
        state.epub_offset = 17;
        state.reading_state_saves = Some(start_reading_state_writer(store.clone()));
        let matching = capture_reader_tab(&state).unwrap();
        let mut unrelated = matching.clone();
        unrelated.id = 2;
        unrelated.session.book_id = Some(7);
        unrelated.session.locator = DeviceFileLocator::from_path("other.epub");
        state.tabs = vec![matching, unrelated];
        state.removing_book = Some(42);

        let _ = update(
            &mut state,
            Message::BookRemoved {
                id: 42,
                result: Ok(()),
            },
        );

        assert_eq!(state.book_id, None);
        assert_eq!(state.tabs[0].session.book_id, None);
        assert_eq!(state.tabs[1].session.book_id, Some(7));
        assert_eq!(state.removing_book, None);
        assert_eq!(
            state
                .library_books
                .iter()
                .map(|book| book.id)
                .collect::<Vec<_>>(),
            vec![7]
        );
        let (flushed, wait) = oneshot::channel();
        state
            .reading_state_saves
            .as_ref()
            .unwrap()
            .send(ReadingStateWriterMessage::Flush(flushed))
            .unwrap();
        wait.await.unwrap().unwrap();
        let save = store
            .get_async(Path::new("removed.epub"))
            .await
            .expect("removal should persist path-backed reading state");
        assert_eq!(save.page, 3);
        assert_eq!(save.location_offset, Some(17));
    }

    #[test]
    fn failed_book_removal_keeps_the_book_and_surfaces_the_error() {
        let (mut state, _) = boot();
        state.library_books.push(test_book(42));
        state.removing_book = Some(42);

        let task = update(
            &mut state,
            Message::BookRemoved {
                id: 42,
                result: Err("database unavailable".to_string()),
            },
        );

        assert_eq!(task.units(), 0);
        assert_eq!(state.removing_book, None);
        assert_eq!(state.library_books.len(), 1);
        assert_eq!(
            state.library_error,
            Some(AppError::Library("database unavailable".to_string()))
        );
        drop(library_collection(&state));
    }

    #[tokio::test]
    async fn book_removal_stays_disabled_while_the_operation_is_in_flight() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.pending_remove_book = Some(42);
        let book = test_book(42);

        let removal = update(&mut state, Message::RemoveBook(42));

        assert!(removal.units() > 0);
        assert_eq!(state.pending_remove_book, None);
        assert_eq!(state.removing_book, Some(42));
        drop(render_book_card(&state, &book));
        drop(render_continue_card(&state, &book));

        let duplicate = update(&mut state, Message::RemoveBook(42));
        let other_request = update(&mut state, Message::RequestRemoveBook(7));
        let locate = update(&mut state, Message::LocateBook(42));

        assert_eq!(duplicate.units(), 0);
        assert_eq!(other_request.units(), 0);
        assert_eq!(locate.units(), 0);
        assert_eq!(state.pending_remove_book, None);
        assert_eq!(state.removing_book, Some(42));
    }

    #[test]
    fn missing_book_removal_failure_is_shown_on_the_current_screen() {
        let (mut reader_state, _) = boot();
        reader_state.screen = Screen::Reader;
        reader_state.missing_book_id = Some(42);
        reader_state.open_error = Some(AppError::MissingBook);
        reader_state.removing_book = Some(42);
        drop(reader_view(&reader_state));

        let _ = update(
            &mut reader_state,
            Message::BookRemoved {
                id: 42,
                result: Err("reader failure".to_string()),
            },
        );

        assert_eq!(reader_state.removing_book, None);
        assert_eq!(
            reader_state.open_error,
            Some(AppError::Library("reader failure".to_string()))
        );

        let (mut library_state, _) = boot();
        library_state.screen = Screen::Reader;
        library_state.missing_book_id = Some(42);
        library_state.open_error = Some(AppError::MissingBook);
        let _ = update(&mut library_state, Message::ShowLibrary);
        library_state.removing_book = Some(42);

        let _ = update(
            &mut library_state,
            Message::BookRemoved {
                id: 42,
                result: Err("library failure".to_string()),
            },
        );

        assert_eq!(library_state.screen, Screen::Library);
        assert_eq!(
            library_state.library_error,
            Some(AppError::Library("library failure".to_string()))
        );
    }

    #[tokio::test]
    async fn library_refresh_keeps_visible_books_until_the_replacement_is_ready() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.library_books.push(test_book(1));
        state.library_loading = false;

        let task = reset_library(&mut state);

        assert!(task.units() > 0);
        assert_eq!(state.library_books.len(), 1);
        assert!(state.library_loading);
        assert!(!state.library_has_more);
    }

    #[tokio::test]
    async fn changing_library_filter_starts_loading_in_the_same_update() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.library_books.push(test_book(1));
        state.library_loading = false;
        state.library_activity_opacity = 0.0;
        let generation = state.library_generation;

        let task = update(
            &mut state,
            Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Pdf)),
        );

        assert!(task.units() > 0);
        assert!(state.library_loading);
        assert_eq!(state.library_activity_opacity, 1.0);
        assert_eq!(state.library_generation, generation.wrapping_add(1));
        assert_eq!(state.library_books.len(), 1);
    }

    #[tokio::test]
    async fn library_search_waits_for_the_latest_debounce_before_querying() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(
            store.pool().clone(),
            store.managed_books_dir(),
        ));
        state.library_loading = false;
        state.library_activity_opacity = 0.0;

        let debounce = update(
            &mut state,
            Message::LibrarySearchChanged("machine".to_string()),
        );
        let generation = state.library_generation;

        assert!(debounce.units() > 0);
        assert!(!state.library_loading);
        assert_eq!(state.library_activity_opacity, 1.0);
        let _ = update(&mut state, Message::LibraryActivityTick);
        assert_eq!(state.library_activity_opacity, 1.0);
        state.library_activity_progress = 0.25;
        let _ = update(
            &mut state,
            Message::LibrarySearchChanged("machine learning".to_string()),
        );
        let latest_generation = state.library_generation;
        assert_eq!(state.library_activity_progress, 0.25);
        assert_eq!(
            update(&mut state, Message::LibrarySearchDebounced(generation)).units(),
            0
        );

        let query = update(
            &mut state,
            Message::LibrarySearchDebounced(latest_generation),
        );
        assert!(query.units() > 0);
        assert!(state.library_loading);
    }

    #[test]
    fn library_metadata_is_installed_before_cover_decoding_finishes() {
        let (mut state, _) = boot();
        let generation = state.library_generation;
        let mut book = test_book(1);
        book.cover = Some(include_bytes!("../../../assets/shosai-icon.png").to_vec());

        let cover_task = update(
            &mut state,
            Message::LibraryLoaded {
                generation,
                offset: 0,
                next_offset: 1,
                page: BookPage {
                    books: vec![book],
                    has_more: false,
                },
            },
        );

        assert_eq!(cover_task.units(), 1);
        assert_eq!(state.library_books.len(), 1);
        assert!(state.library_cover_handles.is_empty());

        let cover = decode_library_cover(Some(include_bytes!("../../../assets/shosai-icon.png")))
            .expect("application icon should decode as a cover");
        let cover_id = cover.0.id();
        let _ = update(
            &mut state,
            Message::LibraryCoversLoaded {
                generation,
                offset: 0,
                cover_handles: HashMap::from([(1, cover)]),
            },
        );

        assert_eq!(state.library_cover_handles[&1].0.id(), cover_id);
    }

    #[test]
    fn malformed_library_cover_is_rejected_before_view_construction() {
        assert!(decode_library_cover(Some(b"not an image")).is_none());
        assert!(decode_library_cover(None).is_none());
    }

    #[test]
    fn library_activity_advances_only_while_loading() {
        let (mut state, _) = boot();

        let _ = update(&mut state, Message::LibraryActivityTick);
        assert!(state.library_activity_progress > 0.0);

        state.library_loading = false;
        let progress = state.library_activity_progress;
        let _ = update(&mut state, Message::LibraryActivityTick);
        assert_eq!(state.library_activity_progress, progress);
    }

    #[test]
    fn library_activity_does_not_advance_during_pagination() {
        let (mut state, _) = boot();
        state.library_offset = LIBRARY_PAGE_SIZE as usize;

        let _ = update(&mut state, Message::LibraryActivityTick);

        assert_eq!(state.library_activity_progress, 0.0);
    }

    #[test]
    fn library_activity_stops_at_the_right_edge() {
        let (mut state, _) = boot();
        state.library_activity_progress = 0.99;

        let _ = update(&mut state, Message::LibraryActivityTick);

        assert_eq!(state.library_activity_progress, 1.0);
    }

    #[test]
    fn completed_library_activity_fades_out() {
        let (mut state, _) = boot();
        state.library_loading = false;
        state.library_activity_progress = 1.0;

        for _ in 0..18 {
            let _ = update(&mut state, Message::LibraryActivityTick);
        }

        assert_eq!(state.library_activity_progress, 1.0);
        assert!(state.library_activity_opacity > 0.0);

        let _ = update(&mut state, Message::LibraryActivityTick);

        assert_eq!(state.library_activity_opacity, 0.0);
    }

    #[test]
    fn active_library_work_restores_activity_bar_visibility() {
        let (mut state, _) = boot();
        state.library_activity_opacity = 0.0;

        let _ = update(&mut state, Message::LibraryActivityTick);

        assert_eq!(state.library_activity_opacity, 1.0);
    }

    #[test]
    fn initial_library_load_completes_the_activity_bar() {
        let (mut state, _) = boot();
        state.library_activity_progress = 0.75;
        let generation = state.library_generation;

        let _ = update(
            &mut state,
            Message::LibraryLoaded {
                generation,
                offset: 0,
                next_offset: 1,
                page: BookPage {
                    books: vec![test_book(1)],
                    has_more: false,
                },
            },
        );

        assert_eq!(state.library_activity_progress, 1.0);
    }

    #[test]
    fn discovery_activity_is_monotonic_and_reaches_completion() {
        let snapshots = [
            ImportDiscoveryProgressSnapshot {
                enumerating: true,
                hashed_files: 1,
                completed_files: 0,
                total_files: 4,
            },
            ImportDiscoveryProgressSnapshot {
                enumerating: true,
                hashed_files: 3,
                completed_files: 0,
                total_files: 20,
            },
            ImportDiscoveryProgressSnapshot {
                enumerating: false,
                hashed_files: 20,
                completed_files: 4,
                total_files: 20,
            },
            ImportDiscoveryProgressSnapshot {
                enumerating: false,
                hashed_files: 20,
                completed_files: 20,
                total_files: 20,
            },
        ];
        let mut value = 0.0;
        for snapshot in snapshots {
            let next = discovery_progress_value(value, snapshot);
            assert!(next >= value);
            value = next;
        }
        assert_eq!(value, 1.0);
    }

    #[test]
    fn later_library_pages_do_not_introduce_continue_reading() {
        let (mut state, _) = boot();
        state.library_books = (0..LIBRARY_PAGE_SIZE)
            .map(|id| {
                let mut book = test_book(i64::from(id));
                book.progress = 1.0;
                book.last_read = Some("2026-01-01".to_string());
                book
            })
            .collect();
        let mut later_book = test_book(i64::from(LIBRARY_PAGE_SIZE));
        later_book.progress = 0.5;
        later_book.last_read = Some("2026-01-02".to_string());
        state.library_books.push(later_book);

        assert!(continue_reading_book(&state).is_none());
    }

    #[test]
    fn empty_first_library_page_clears_books_from_the_previous_filter() {
        let (mut state, _) = boot();
        state.library_generation = 2;
        state.library_books.push(test_book(1));
        state.library_loading = true;

        let _ = update(
            &mut state,
            Message::LibraryLoaded {
                generation: 2,
                offset: 0,
                next_offset: 0,
                page: BookPage {
                    books: Vec::new(),
                    has_more: false,
                },
            },
        );

        assert!(state.library_books.is_empty());
        assert!(!state.library_loading);
        assert!(!state.library_has_more);
    }

    #[test]
    fn library_append_requires_the_requested_offset() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.library_generation = 1;
        state.library_books.push(test_book(1));
        state.library_offset = 1;
        state.library_loading = true;

        let _ = update(
            &mut state,
            Message::LibraryLoaded {
                generation: 1,
                offset: 0,
                next_offset: 1,
                page: BookPage {
                    books: vec![test_book(2)],
                    has_more: false,
                },
            },
        );

        assert_eq!(state.library_books.len(), 1);
        assert_eq!(state.library_books[0].id, 1);
        assert!(state.library_loading);
    }

    #[test]
    fn infinite_scroll_sensor_exists_even_when_the_first_page_does_not_overflow() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.library_generation = 4;
        state.library_books = (0..40).map(test_book).collect();
        state.library_offset = 40;
        state.library_has_more = true;

        assert_eq!(library_load_sensor_key(&state), Some((4, 40)));
    }

    #[test]
    fn missing_library_book_offers_recovery_instead_of_a_parser_error() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let missing = tempfile::tempdir().unwrap().path().join("moved.epub");

        let task = update(
            &mut state,
            Message::OpenLibraryBook(42, missing.to_string_lossy().into_owned()),
        );

        assert_eq!(task.units(), 0);
        assert_eq!(state.open_error, Some(AppError::MissingBook));
        assert_eq!(state.missing_book_id, Some(42));
    }

    #[test]
    fn reopening_a_relocated_book_replaces_its_existing_identity_tab() {
        let directory = tempfile::tempdir().unwrap();
        let original = directory.path().join("original.epub");
        let replacement = directory.path().join("replacement.epub");
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../shosai-core/tests/fixtures/sample.epub");
        std::fs::copy(&fixture, &original).unwrap();
        std::fs::copy(&fixture, &replacement).unwrap();
        let (mut state, _) = boot();
        state.library_loading = false;
        state.storage_initializing = false;

        let _ = open_document_now(&mut state, original, Some(42));
        let old_document = match state.document.as_ref().unwrap() {
            OpenDocument::Epub(document) => Arc::clone(document),
            _ => panic!("expected EPUB document"),
        };
        let _ = open_document_now(&mut state, replacement.clone(), Some(42));

        assert_eq!(state.tabs.len(), 1);
        assert_eq!(state.active_tab, Some(0));
        assert_eq!(state.book_id, Some(42));
        assert_eq!(state.file_path.as_ref(), Some(&replacement));
        assert_eq!(state.tabs[0].session.locator.path(), replacement);
        let Some(OpenDocument::Epub(document)) = &state.document else {
            panic!("expected EPUB document");
        };
        assert!(!Arc::ptr_eq(document, &old_document));
    }

    #[test]
    fn relocating_inactive_tab_preserves_that_tabs_reader_settings() {
        let directory = tempfile::tempdir().unwrap();
        let first = directory.path().join("first.epub");
        let relocated = directory.path().join("relocated.epub");
        let second = directory.path().join("second.epub");
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../shosai-core/tests/fixtures/sample.epub");
        std::fs::copy(&fixture, &first).unwrap();
        std::fs::copy(&fixture, &relocated).unwrap();
        std::fs::copy(&fixture, &second).unwrap();
        let (mut state, _) = boot();
        state.library_loading = false;
        state.storage_initializing = false;

        let _ = open_document_now(&mut state, first, Some(42));
        state.current_page = 1;
        state.epub_offset = 25;
        state.font_size = 22.0;
        state.line_spacing = 1.8;
        state.theme = ReaderTheme::Dark;
        state.reading_mode = ReadingMode::Continuous;
        state.reader_overrides = ReaderOverrides {
            reading_mode: true,
            theme: true,
            epub_font_size: true,
            pdf_zoom: false,
        };
        let _ = open_document_now(&mut state, second, Some(43));
        state.font_size = 12.0;
        state.line_spacing = 1.2;
        state.theme = ReaderTheme::Sepia;
        state.reading_mode = ReadingMode::Paginated;

        let _ = open_document_now(&mut state, relocated, Some(42));

        assert_eq!(state.active_tab, Some(0));
        assert_eq!(state.font_size, 22.0);
        assert_eq!(state.line_spacing, 1.8);
        assert_eq!(state.theme, ReaderTheme::Dark);
        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        assert_eq!((state.current_page, state.epub_offset), (1, 25));
        assert!(state.reader_overrides.reading_mode);
        assert!(state.reader_overrides.theme);
        assert!(state.reader_overrides.epub_font_size);
    }

    #[test]
    fn relocating_active_pdf_preserves_its_local_zoom() {
        let directory = tempfile::tempdir().unwrap();
        let original = directory.path().join("original.pdf");
        let relocated = directory.path().join("relocated.pdf");
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../shosai-core/tests/fixtures/sample.pdf");
        std::fs::copy(&fixture, &original).unwrap();
        std::fs::copy(&fixture, &relocated).unwrap();
        let (mut state, _) = boot();
        state.library_loading = false;
        state.storage_initializing = false;

        let _ = open_document_now(&mut state, original, Some(42));
        state.zoom = ZoomMode::FitWidth;
        state.reader_overrides.pdf_zoom = true;
        let _ = open_document_now(&mut state, relocated, Some(42));

        assert_eq!(state.zoom, ZoomMode::FitWidth);
        assert!(state.reader_overrides.pdf_zoom);
        assert_eq!(
            state.tabs[0].session.preferences.pdf_zoom,
            ZoomMode::FitWidth
        );
    }

    #[test]
    fn relocating_evicted_managed_tab_retains_its_display_title() {
        let directory = tempfile::tempdir().unwrap();
        let original = directory.path().join("original.epub");
        let replacement = directory.path().join("content-hash.epub");
        let bytes = epub_with_title_and_chapter("", b"<html><body>text</body></html>");
        std::fs::write(&original, &bytes).unwrap();
        std::fs::write(&replacement, bytes).unwrap();
        let (mut state, _) = boot();
        state.library_loading = false;
        state.storage_initializing = false;
        let mut book = test_book(42);
        book.title = "Retained library title".to_string();
        state.library_books = vec![book];

        let _ = open_document_now(&mut state, original, Some(42));
        state.library_books.clear();
        let _ = open_document_now(&mut state, replacement, Some(42));

        assert_eq!(
            state.display_title.as_deref(),
            Some("Retained library title")
        );
        assert_eq!(state.tabs[0].display_title, "Retained library title");
    }

    #[test]
    fn relocating_evicted_managed_tab_prefers_retained_title_to_document_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let original = directory.path().join("original.epub");
        let replacement = directory.path().join("content-hash.epub");
        std::fs::write(
            &original,
            epub_with_title_and_chapter("Publisher title", b"<html><body>text</body></html>"),
        )
        .unwrap();
        std::fs::copy(&original, &replacement).unwrap();
        let (mut state, _) = boot();
        state.library_loading = false;
        state.storage_initializing = false;
        let mut book = test_book(42);
        book.title = "Curated library title".to_string();
        state.library_books = vec![book];

        let _ = open_document_now(&mut state, original, Some(42));
        state.library_books.clear();
        let _ = open_document_now(&mut state, replacement, Some(42));

        assert_eq!(
            state.display_title.as_deref(),
            Some("Curated library title")
        );
        assert_eq!(state.tabs[0].display_title, "Curated library title");
    }

    #[test]
    fn queued_file_selection_preserves_open_without_import_semantics() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.storage_initializing = true;

        let _ = update(
            &mut state,
            Message::FileSelected(Some(PathBuf::from("selected.epub"))),
        );

        assert!(matches!(
            state.pending_open,
            Some(ref path) if path == &PathBuf::from("selected.epub")
        ));
    }

    #[test]
    fn failed_storage_keeps_import_actions_disabled() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.storage_error = Some(AppError::Storage("storage failed".to_string()));

        let task = update(&mut state, Message::OpenAddBooks);

        assert_eq!(task.units(), 0);
        assert!(!state.add_books_open);
        assert!(state.library.is_none());
        assert!(matches!(
            state.storage_error,
            Some(AppError::Storage(ref detail)) if detail == "storage failed"
        ));
    }

    #[test]
    fn opening_search_requests_focus_for_the_query_input() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let task = update(&mut state, Message::ToggleSearchBar);

        assert!(state.show_search_bar);
        assert!(
            task.units() > 0,
            "opening search must issue a task that focuses the query input"
        );
    }

    #[test]
    fn search_bar_does_not_open_for_unsupported_cbz_documents() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));

        let _ = update(&mut state, Message::ToggleSearchBar);

        assert!(!state.show_search_bar);
    }

    #[test]
    fn stale_search_completions_do_not_replace_current_state() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("book.epub"));
        state.search_document_generation = 2;
        state.search_query_generation = 3;
        state.search_query = "same query again".to_string();
        state.search_loading = true;
        let _ = update(
            &mut state,
            Message::SearchPerformed {
                tab_id: 1,
                document_generation: 2,
                query_generation: 1,
                result: Ok(vec![SearchMatch {
                    page: 0,
                    offset: 0,
                    length: 5,
                    context: "stale".to_string(),
                }]),
            },
        );

        assert!(state.search_loading);
        assert!(state.search_results.is_empty());
    }

    #[test]
    fn epub_search_uses_the_loaded_shared_presentation() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.search_query = "sample".to_string();

        let task = perform_search(&mut state);

        assert!(task.units() > 0);
        assert!(state.search_loading);
    }

    #[test]
    fn superseding_search_cancels_the_active_worker() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.search_query = "first".to_owned();
        let task = perform_search(&mut state);
        let cancellation = state.search_cancellation.clone().unwrap();

        let _ = update(&mut state, Message::SearchQueryChanged("second".to_owned()));

        assert!(cancellation.is_cancelled());
        assert!(!state.search_loading);
        assert_eq!(state.search_admission.used(), 1);
        drop(task);
        assert_eq!(state.search_admission.used(), 0);
    }

    #[test]
    fn completed_search_worker_wakes_the_latest_waiting_query() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.search_admission = CacheBudget::new(1);
        state.search_query = "latest".to_owned();
        state.search_query_generation = 2;
        let held = state.search_admission.try_reserve(1).unwrap();

        assert_eq!(perform_search(&mut state).units(), 0);
        assert!(state.search_waiting);
        drop(held);
        let tab_id = state.active_tab_id.unwrap();
        let document_generation = state.search_document_generation;
        let task = update(
            &mut state,
            Message::SearchPerformed {
                tab_id,
                document_generation,
                query_generation: 1,
                result: Err(SearchError::Cancelled),
            },
        );

        assert!(task.units() > 0);
        assert!(state.search_loading);
        assert!(!state.search_waiting);
        assert_eq!(state.search_admission.used(), 1);
    }

    #[test]
    fn stale_page_renders_do_not_replace_the_latest_request() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        cbz.page_size(0).unwrap();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        // Keep both synthetic generations admitted while their tasks remain
        // unpolled so this test exercises supersession rather than budgeting.
        state.transient_decode_budget = CacheBudget::new(usize::MAX);

        let first_task = refresh_content(&mut state);
        let first_generation = state.render_generation;
        let first_key = state.paginated_pending[0].clone();
        state.zoom = ZoomMode::Manual(1.25);
        let second_task = refresh_content(&mut state);
        let second_generation = state.render_generation;
        let latest_key = state.paginated_requested[0].clone();

        assert!(first_task.units() > 0);
        assert_eq!(second_task.units(), 0);
        assert!(second_generation > first_generation);
        assert_eq!(state.paginated_pending, vec![first_key.clone()]);

        let stale_page = RenderedPage {
            width: 10,
            height: 10,
            pixels: bytes::Bytes::from(vec![0; 400]),
        };
        let latest_task = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation: first_generation,
                key: first_key,
                result: Ok(stale_page),
            },
        );

        assert!(state.rendered_page.is_none());
        assert!(latest_task.units() > 0);
        assert_eq!(state.paginated_pending, vec![latest_key.clone()]);
        let latest_generation = state.render_generation;

        let latest_page = RenderedPage {
            width: 20,
            height: 20,
            pixels: bytes::Bytes::from(vec![0; 1600]),
        };
        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation: latest_generation,
                key: latest_key,
                result: Ok(latest_page),
            },
        );

        assert_eq!(
            state.rendered_page.as_ref().map(|page| page.width),
            Some(20)
        );
    }

    #[test]
    fn stale_epub_pagination_does_not_replace_the_latest_layout() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.render_generation = 2;
        let current = Arc::clone(&state.epub_pages);
        let layout_key = epub_layout_key(&state);

        let _ = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: 1,
                generation: 1,
                layout_key,
                complete: true,
                pages: Arc::new(vec![EpubPage {
                    chapter: 0,
                    title: None,
                    nodes: Vec::new(),
                }]),
            },
        );

        assert!(Arc::ptr_eq(&state.epub_pages, &current));
    }

    #[test]
    fn epub_relayout_coalesces_to_one_in_flight_and_the_latest_request() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let first = refresh_content(&mut state);
        let first_generation = state.render_generation;
        let first_key = state.epub_layout_pending.unwrap();
        state.font_size = 24.0;
        let coalesced = refresh_content(&mut state);
        let requested_key = state.epub_layout_requested.unwrap();

        assert!(first.units() > 0);
        assert_eq!(coalesced.units(), 0);
        assert_ne!(first_key, requested_key);
        assert_eq!(state.epub_layout_pending, Some(first_key));

        let latest = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: 1,
                generation: first_generation,
                layout_key: first_key,
                complete: true,
                pages: Arc::new(Vec::new()),
            },
        );

        assert!(latest.units() > 0);
        assert_eq!(state.epub_layout_pending, Some(requested_key));
    }

    #[test]
    fn epub_pagination_preserves_navigation_that_happened_while_it_ran() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.render_generation = 2;
        state.current_page = 1;
        state.epub_offset = 25;
        let layout_key = epub_layout_key(&state);
        state.epub_jobs.insert(EpubJob {
            tab_id: 1,
            generation: 2,
            layout_key,
        });

        let _ = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: 1,
                generation: 2,
                layout_key,
                complete: true,
                pages: Arc::new(vec![
                    EpubPage {
                        chapter: 0,
                        title: None,
                        nodes: Vec::new(),
                    },
                    EpubPage {
                        chapter: 1,
                        title: None,
                        nodes: Vec::new(),
                    },
                ]),
            },
        );

        assert_eq!((state.current_page, state.epub_offset), (1, 25));
        assert_eq!(state.epub_page, 1);
    }

    #[test]
    fn initial_epub_pagination_cannot_replace_a_completed_layout() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let layout_key = epub_layout_key(&state);
        let complete_pages = Arc::new(vec![
            EpubPage {
                chapter: 0,
                title: None,
                nodes: Vec::new(),
            },
            EpubPage {
                chapter: 1,
                title: None,
                nodes: Vec::new(),
            },
        ]);
        state.epub_pages = Arc::clone(&complete_pages);
        state.epub_layout_key = Some(layout_key);
        let generation = state.render_generation;

        let _ = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: 1,
                generation,
                layout_key,
                complete: false,
                pages: Arc::new(vec![EpubPage {
                    chapter: 0,
                    title: None,
                    nodes: Vec::new(),
                }]),
            },
        );

        assert!(Arc::ptr_eq(&state.epub_pages, &complete_pages));
    }

    #[test]
    fn installing_epub_clears_stale_layout_state_and_resumes_after_old_job() {
        let first = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(first)));
        state.file_path = Some(PathBuf::from("first.epub"));
        assert!(refresh_content(&mut state).units() > 0);
        let old_job = *state.epub_jobs.iter().next().unwrap();
        assert!(state.epub_layout_pending.is_some());

        let second = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .unwrap();
        install_document(
            &mut state,
            PathBuf::from("second.epub"),
            None,
            OpenDocument::Epub(Arc::new(second)),
        );
        assert_eq!(state.epub_layout_pending, None);
        assert_eq!(state.epub_layout_requested, None);
        assert_eq!(refresh_content(&mut state).units(), 0);
        let requested = state.epub_layout_requested.unwrap();

        let task = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: old_job.tab_id,
                generation: old_job.generation,
                layout_key: old_job.layout_key,
                complete: true,
                pages: Arc::new(Vec::new()),
            },
        );

        assert!(task.units() > 0);
        assert_eq!(state.epub_layout_pending, Some(requested));
        assert!(state.epub_pages.is_empty());
        assert!(state.epub_jobs.iter().any(|job| {
            job.layout_key == requested && job.generation == state.render_generation
        }));
    }

    #[test]
    fn epub_pagination_completes_for_an_inactive_tab() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let document = OpenDocument::Epub(Arc::new(epub));
        let mut state = state_with_document(document.clone());
        state.file_path = Some(PathBuf::from("first.epub"));
        state.render_generation = 4;
        let first = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.epub"));
        state.document = Some(document);
        state.show_bookmarks_panel = true;
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);
        let layout_key = epub_layout_key_for_tab(&state, &state.tabs[0]);
        state.epub_jobs.insert(EpubJob {
            tab_id: 1,
            generation: 4,
            layout_key,
        });

        let _ = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: 1,
                generation: 4,
                layout_key,
                complete: true,
                pages: Arc::new(vec![EpubPage {
                    chapter: 0,
                    title: None,
                    nodes: Vec::new(),
                }]),
            },
        );

        assert_eq!(state.tabs[0].epub_pages.len(), 1);
    }

    #[test]
    fn inactive_epub_rejects_pagination_from_obsolete_window_geometry() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let document = OpenDocument::Epub(Arc::new(epub));
        let mut state = state_with_document(document.clone());
        state.file_path = Some(PathBuf::from("first.epub"));
        state.render_generation = 4;
        state.window_size = Size::new(700.0, 600.0);
        let obsolete_layout = epub_layout_key(&state);
        let first = capture_reader_tab(&state).unwrap();

        state.active_tab_id = Some(2);
        state.file_path = Some(PathBuf::from("second.epub"));
        state.document = Some(document);
        state.show_bookmarks_panel = true;
        let second = capture_reader_tab(&state).unwrap();
        state.tabs = vec![first, second];
        state.active_tab = Some(1);
        state.window_size = Size::new(1_000.0, 600.0);

        let _ = update(
            &mut state,
            Message::EpubPaginated {
                tab_id: 1,
                generation: 4,
                layout_key: obsolete_layout,
                complete: true,
                pages: Arc::new(vec![EpubPage {
                    chapter: 0,
                    title: None,
                    nodes: Vec::new(),
                }]),
            },
        );

        assert!(state.tabs[0].epub_pages.is_empty());
        assert!(update(&mut state, Message::SelectTab(0)).units() > 0);
    }

    #[test]
    fn epub_bookmark_navigation_sets_location_before_initial_pagination() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.total_pages = 2;

        let _ = update(&mut state, Message::GoToBookmark(1, Some(9)));

        assert_eq!((state.current_page, state.epub_offset), (1, 9));
    }

    #[test]
    fn render_completion_from_another_tab_is_rejected() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.render_generation = 4;

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 2,
                generation: 4,
                key: PageCacheKey {
                    page: 0,
                    scale_bits: 1.0_f32.to_bits(),
                    highlights: Vec::new(),
                },
                result: Ok(RenderedPage {
                    width: 99,
                    height: 99,
                    pixels: bytes::Bytes::from(vec![0; 99 * 99 * 4]),
                }),
            },
        );

        assert!(state.rendered_page.is_none());
    }

    #[test]
    fn document_open_notice_is_delayed_and_scoped_to_the_latest_request() {
        let (mut state, _) = boot();
        state.library_books = vec![test_book(42)];
        state.library_cover_handles.insert(
            42,
            RasterImageHandle(image::Handle::from_rgba(1, 1, vec![0, 0, 0, 255])),
        );
        let first = open_document(&mut state, PathBuf::from("first.epub"), None);
        let first_generation = state.document_open_generation;

        assert_eq!(first.units(), 2);
        assert!(state.document_opening);
        assert!(!state.document_open_notice_visible);
        assert_eq!(state.screen, Screen::Library);
        assert_eq!(
            state
                .document_open_preview
                .as_ref()
                .map(|preview| preview.title.as_str()),
            Some("first")
        );

        let _ = open_document(&mut state, PathBuf::from("second.epub"), Some(42));
        let second_generation = state.document_open_generation;
        let _ = update(
            &mut state,
            Message::ShowDocumentOpenNotice(first_generation),
        );
        assert!(!state.document_open_notice_visible);

        let _ = update(
            &mut state,
            Message::ShowDocumentOpenNotice(second_generation),
        );
        assert!(state.document_open_notice_visible);
        assert_eq!(state.screen, Screen::Reader);
        assert_eq!(
            state
                .document_open_preview
                .as_ref()
                .map(|preview| preview.title.as_str()),
            Some("Book 42")
        );
        assert!(
            state
                .document_open_preview
                .as_ref()
                .and_then(|preview| preview.cover.as_ref())
                .is_some()
        );
        state.library_books.clear();
        state.library_cover_handles.clear();
        drop(document_opening_view(&state));

        let _ = update(
            &mut state,
            Message::DocumentOpened {
                generation: second_generation,
                path: PathBuf::from("second.epub"),
                book_id: Some(42),
                result: Err(AppError::UnsupportedFormat("epub".to_string())),
            },
        );
        assert!(!state.document_opening);
        assert!(!state.document_open_notice_visible);
        assert!(state.document_open_preview.is_none());
    }

    #[test]
    fn failed_open_preserves_the_active_document_and_render_state() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));

        let render_task = refresh_content(&mut state);
        let old_generation = state.render_generation;
        let render_key = PageCacheKey {
            page: 0,
            scale_bits: 1.0_f32.to_bits(),
            highlights: Vec::new(),
        };
        admit_test_raster(
            &mut state,
            RasterJob::Paginated {
                tab_id: 1,
                generation: old_generation,
                key: render_key.clone(),
            },
            400,
        );
        let old_document = state.document.clone();
        let path = PathBuf::from("unsupported.txt");
        let open_task = open_document(&mut state, path.clone(), None);
        let open_generation = state.document_open_generation;

        assert!(render_task.units() > 0);
        assert!(open_task.units() > 0);
        assert!(state.document_opening);
        assert_eq!(state.render_generation, old_generation);
        assert!(matches!(
            (&state.document, &old_document),
            (Some(OpenDocument::Cbz(_)), Some(OpenDocument::Cbz(_)))
        ));

        let _ = update(
            &mut state,
            Message::DocumentOpened {
                generation: open_generation,
                path,
                book_id: None,
                result: Err(AppError::UnsupportedFormat("txt".to_string())),
            },
        );

        assert!(!state.document_opening);
        assert!(matches!(
            state.open_error,
            Some(AppError::UnsupportedFormat(ref format)) if format == "txt"
        ));

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation: old_generation,
                key: render_key,
                result: Ok(RenderedPage {
                    width: 10,
                    height: 10,
                    pixels: bytes::Bytes::from(vec![0; 400]),
                }),
            },
        );

        assert_eq!(
            state.rendered_page.as_ref().map(|page| page.width),
            Some(10)
        );
    }

    #[test]
    fn document_admission_uses_production_limits_in_tests() {
        let admission = DocumentAdmission::default();

        assert_eq!(admission.count.limit(), RETAINED_DOCUMENT_COUNT_CAPACITY);
        assert_eq!(admission.bytes.limit(), RETAINED_DOCUMENT_BYTE_CAPACITY);
        assert_eq!(admission.open_workers.limit(), DOCUMENT_OPEN_WORKERS);
    }

    #[test]
    fn document_count_and_worker_admission_reject_without_replacing_the_reader() {
        for (admission, expected) in [
            (
                DocumentAdmission::new(1, RETAINED_DOCUMENT_BYTE_CAPACITY, 1),
                "retained document count limit exceeded",
            ),
            (
                DocumentAdmission::new(2, RETAINED_DOCUMENT_BYTE_CAPACITY, 1),
                "document open worker limit exceeded",
            ),
        ] {
            let active = Arc::new(
                PdfDoc::from_bytes(
                    include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
                )
                .unwrap(),
            );
            let mut state = state_with_document(OpenDocument::Pdf(Arc::clone(&active)));
            state.file_path = Some(PathBuf::from("active.pdf"));
            let held = if expected.starts_with("retained") {
                admission.count.try_reserve(1).unwrap()
            } else {
                admission.open_workers.try_reserve(1).unwrap()
            };
            state.document_admission = admission;

            assert_eq!(
                open_document(&mut state, PathBuf::from("other.pdf"), None).units(),
                0
            );
            assert!(matches!(
                &state.open_error,
                Some(AppError::Open { detail, .. }) if detail == expected
            ));
            assert!(matches!(
                &state.document,
                Some(OpenDocument::Pdf(document)) if Arc::ptr_eq(document, &active)
            ));
            assert_eq!(state.file_path.as_deref(), Some(Path::new("active.pdf")));
            drop(held);
        }
    }

    #[test]
    fn retained_document_byte_admission_rejects_parsed_replacement() {
        let active = Arc::new(
            PdfDoc::from_bytes(
                include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
            )
            .unwrap(),
        );
        let replacement = OpenDocument::Pdf(Arc::new(
            PdfDoc::from_bytes(
                include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
            )
            .unwrap(),
        ));
        let retained_bytes = replacement.retained_byte_len().unwrap();
        let mut state = state_with_document(OpenDocument::Pdf(Arc::clone(&active)));
        state.file_path = Some(PathBuf::from("active.pdf"));
        state.document_admission = DocumentAdmission::new(2, retained_bytes - 1, 1);

        assert!(open_document(&mut state, PathBuf::from("other.pdf"), None).units() > 0);
        assert_eq!(state.document_admission.open_workers.used(), 1);
        assert_eq!(
            finish_open_document(&mut state, PathBuf::from("other.pdf"), None, replacement).units(),
            0
        );

        assert!(matches!(
            state.open_error,
            Some(AppError::Open { ref detail, .. }) if detail == "retained document byte limit exceeded"
        ));
        assert!(matches!(
            &state.document,
            Some(OpenDocument::Pdf(document)) if Arc::ptr_eq(document, &active)
        ));
        assert_eq!(state.file_path.as_deref(), Some(Path::new("active.pdf")));
        assert_eq!(state.document_admission.count.used(), 0);
        assert_eq!(state.document_admission.bytes.used(), 0);
        assert_eq!(state.document_admission.open_workers.used(), 0);
    }

    #[test]
    fn failed_document_open_releases_all_admission_for_retry() {
        let (mut state, _) = boot();
        state.document_admission = DocumentAdmission::new(1, 1, 1);
        let path = PathBuf::from("missing.pdf");

        assert!(open_document(&mut state, path.clone(), None).units() > 0);
        assert_eq!(state.document_admission.count.used(), 1);
        assert_eq!(state.document_admission.open_workers.used(), 1);
        let generation = state.document_open_generation;
        let _ = update(
            &mut state,
            Message::DocumentOpened {
                generation,
                path: path.clone(),
                book_id: None,
                result: Err(AppError::Open {
                    format: "PDF",
                    detail: "test failure".to_owned(),
                }),
            },
        );

        assert_eq!(state.document_admission.count.used(), 0);
        assert_eq!(state.document_admission.bytes.used(), 0);
        assert_eq!(state.document_admission.open_workers.used(), 0);
        assert!(open_document(&mut state, path, None).units() > 0);
    }

    #[test]
    fn stale_document_open_completion_cannot_replace_a_newer_request() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        let old_document = match state.document.as_ref() {
            Some(OpenDocument::Cbz(document)) => Arc::clone(document),
            _ => panic!("expected active CBZ"),
        };
        state.document_open_generation = 2;
        state.document_opening = true;
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");

        let task = update(
            &mut state,
            Message::DocumentOpened {
                generation: 1,
                path: PathBuf::from("stale.epub"),
                book_id: None,
                result: Ok(OpenDocument::Epub(Arc::new(epub))),
            },
        );

        assert_eq!(task.units(), 0);
        assert!(state.document_opening);
        let Some(OpenDocument::Cbz(document)) = &state.document else {
            panic!("stale open replaced the active document");
        };
        assert!(Arc::ptr_eq(document, &old_document));
    }

    #[test]
    fn corrupt_and_oversized_epubs_report_actionable_open_errors() {
        let directory = tempfile::tempdir().unwrap();
        let corrupt = directory.path().join("corrupt.epub");
        std::fs::write(&corrupt, b"not a ZIP archive").unwrap();

        let corrupt_error = load_document(&corrupt).unwrap_err();
        let AppError::Open {
            format,
            detail: corrupt_detail,
        } = &corrupt_error
        else {
            panic!("corrupt EPUB returned an unexpected error: {corrupt_error:?}");
        };
        assert_eq!(*format, "EPUB");
        assert!(
            corrupt_detail.contains("EPUB archive is corrupt")
                && corrupt_detail.contains("end-of-central-directory record is missing"),
            "corrupt EPUB error was not actionable: {corrupt_detail}"
        );

        let oversized = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../shosai-core/tests/fixtures/epub-conformance/resource-limits.epub");
        let oversized_error = load_document(&oversized).unwrap_err();
        let AppError::Open {
            format,
            detail: oversized_detail,
        } = &oversized_error
        else {
            panic!("oversized EPUB returned an unexpected error: {oversized_error:?}");
        };
        assert_eq!(*format, "EPUB");
        assert!(
            oversized_detail.contains("OEBPS/Images/huge.svg")
                && oversized_detail.contains("dimension limit"),
            "oversized EPUB error was not actionable: {oversized_detail}"
        );

        let localized = oversized_error
            .localized(&I18n::new(LanguagePreference::English))
            .replace(['\u{2068}', '\u{2069}'], "");
        assert!(localized.starts_with("Failed to open EPUB:"));
        assert!(localized.contains("OEBPS/Images/huge.svg"));
        assert!(localized.contains("dimension limit"));
    }

    #[test]
    fn wrapped_epub_limits_and_structural_zip_errors_keep_their_causes() {
        let directory = tempfile::tempdir().unwrap();
        let oversized_xml = directory.path().join("oversized-xml.epub");
        let mut chapter =
            br#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><p>"#
                .to_vec();
        chapter.extend(std::iter::repeat_n(b'x', 4 * 1024 * 1024 + 1));
        chapter.extend_from_slice(b"</p></body></html>");
        std::fs::write(&oversized_xml, epub_with_chapter(&chapter)).unwrap();

        let error = load_document(&oversized_xml).unwrap_err();
        let AppError::Open { detail, .. } = error else {
            panic!("oversized chapter returned an unexpected error: {error:?}");
        };
        assert!(
            detail.contains("OPS/chapter.xhtml"),
            "missing path: {detail}"
        );
        assert!(detail.contains("text limit"), "missing limit: {detail}");

        let malformed_zip = directory.path().join("malformed-directory.epub");
        let mut archive = epub_with_chapter(
            br#"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>ok</p></body></html>"#,
        );
        let central = archive
            .windows(4)
            .position(|bytes| bytes == b"PK\x01\x02")
            .expect("fixture ZIP must have a central directory");
        archive[central..central + 4].copy_from_slice(b"BAD!");
        std::fs::write(&malformed_zip, archive).unwrap();

        let error = load_document(&malformed_zip).unwrap_err();
        let AppError::Open { detail, .. } = error else {
            panic!("malformed ZIP returned an unexpected error: {error:?}");
        };
        assert!(detail.contains("EPUB archive is corrupt"), "{detail}");
        assert!(detail.contains("ZIP archive"), "{detail}");
    }

    #[test]
    fn rejected_epub_preserves_the_active_document() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        let old_generation = state.render_generation;
        let old_document = state.document.clone();
        let old_document = match old_document {
            Some(OpenDocument::Cbz(document)) => document,
            _ => panic!("expected CBZ document"),
        };
        state.rendered_page = Some(RenderedPage {
            width: 7,
            height: 11,
            pixels: bytes::Bytes::from(vec![0; 7 * 11 * 4]),
        });
        state.page_cache.insert(
            PageCacheKey {
                page: 0,
                scale_bits: 1.0_f32.to_bits(),
                highlights: Vec::new(),
            },
            RenderedPage {
                width: 13,
                height: 17,
                pixels: bytes::Bytes::from(vec![0; 13 * 17 * 4]),
            },
        );
        let rejected = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../shosai-core/tests/fixtures/epub-conformance/resource-limits.epub");

        let task = open_document_now(&mut state, rejected, None);

        assert_eq!(task.units(), 0);
        assert_eq!(state.render_generation, old_generation);
        let Some(OpenDocument::Cbz(current_document)) = &state.document else {
            panic!("rejected EPUB replaced the active CBZ");
        };
        assert!(Arc::ptr_eq(current_document, &old_document));
        assert_eq!(state.rendered_page.as_ref().map(|page| page.width), Some(7));
        assert_eq!(state.page_cache.len(), 1);
        assert_eq!(state.page_cache.iter().next().unwrap().1.width, 13);
        assert!(matches!(
            &state.open_error,
            Some(AppError::Open { format: "EPUB", detail })
                if detail.contains("OEBPS/Images/huge.svg")
                    && detail.contains("dimension limit")
        ));
    }

    #[test]
    fn epub_refresh_paginates_off_the_ui_thread() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let task = refresh_content(&mut state);

        assert!(task.units() > 0);
        assert!(state.epub_pages.is_empty());
        assert!(state.error.is_none());
    }

    #[tokio::test]
    async fn epub_refresh_paginates_the_current_chapter_before_the_whole_document() {
        use iced::futures::StreamExt;

        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.current_page = 1;

        let task = refresh_content(&mut state);
        let mut messages = iced_runtime::task::into_stream(task).expect("pagination task");
        let mut pagination = Vec::new();
        while pagination.len() < 2 {
            let iced_runtime::Action::Output(message) =
                messages.next().await.expect("pagination message")
            else {
                continue;
            };
            if matches!(message, Message::EpubPaginated { .. }) {
                pagination.push(message);
            }
        }
        let complete = pagination.pop().unwrap();
        let initial = pagination.pop().unwrap();

        let Message::EpubPaginated {
            complete: false,
            pages: initial_pages,
            ..
        } = initial
        else {
            panic!("first message should contain initial EPUB pages");
        };
        assert!(!initial_pages.is_empty());
        assert!(initial_pages.iter().all(|page| page.chapter == 1));

        let Message::EpubPaginated {
            complete: true,
            pages: complete_pages,
            ..
        } = complete
        else {
            panic!("second message should contain the complete EPUB layout");
        };
        assert!(complete_pages.iter().any(|page| page.chapter == 0));
        assert!(complete_pages.iter().any(|page| page.chapter == 1));
    }

    #[test]
    fn epub_image_loading_decodes_one_nearby_resource_at_a_time() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(5)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.current_page = 2;

        let task = load_epub_images_task(&mut state);

        assert_eq!(task.units(), 1);
        assert!(state.epub_image_handles.is_empty());
        assert_eq!(state.epub_images_desired.len(), 3);
        assert_eq!(state.epub_images_pending.len(), 1);
        assert!(
            state
                .epub_images_desired
                .iter()
                .all(|path| !path.ends_with("image-0.png") && !path.ends_with("image-4.png"))
        );
    }

    #[test]
    fn epub_image_completion_is_scoped_to_the_document_not_relayout() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(1)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let _ = load_epub_images_task(&mut state);
        let path = state.epub_images_pending.iter().next().unwrap().clone();
        let generation = state.epub_image_generation;
        state.render_generation = state.render_generation.wrapping_add(1);
        let permit = state.epub_image_budget.try_reserve(4).unwrap();

        let _ = update(
            &mut state,
            Message::EpubImagesDecoded {
                tab_id: 1,
                generation,
                path: path.clone(),
                images: vec![(
                    path.clone(),
                    Some(DecodedEpubImage::Raster {
                        width: 1,
                        height: 1,
                        pixels: vec![1, 2, 3, 255],
                        permit,
                    }),
                )],
            },
        );

        assert!(!state.epub_images_pending.contains(&path));
        assert!(state.epub_image_handles.contains_key(&path));
        assert_eq!(state.epub_image_budget.used(), 4);
        state.epub_image_handles.clear();
        assert_eq!(state.epub_image_budget.used(), 0);
    }

    #[test]
    fn epub_image_decode_waits_for_aggregate_memory_admission() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(1)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.epub_image_budget = CacheBudget::new(0);

        assert_eq!(load_epub_images_task(&mut state).units(), 1);
        let job = state.epub_image_jobs.iter().next().unwrap().clone();
        let task = update(
            &mut state,
            Message::EpubImageSizeLoaded {
                tab_id: job.tab_id,
                generation: job.generation,
                path: job.path,
                byte_len: Some(4),
            },
        );

        assert_eq!(task.units(), 0);
        assert!(!state.epub_image_decode_active);
        assert!(state.epub_images_pending.is_empty());
        assert!(state.epub_image_jobs.is_empty());
        assert_eq!(state.epub_images_failed.len(), 1);
    }

    #[test]
    fn unadmittable_epub_image_pumps_the_next_resource() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(2)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.epub_image_budget = CacheBudget::new(0);
        assert_eq!(load_epub_images_task(&mut state).units(), 1);
        let job = state.epub_image_jobs.iter().next().unwrap().clone();

        let task = update(
            &mut state,
            Message::EpubImageSizeLoaded {
                tab_id: job.tab_id,
                generation: job.generation,
                path: job.path,
                byte_len: Some(4),
            },
        );

        assert_eq!(task.units(), 1);
        assert_eq!(state.epub_images_failed.len(), 1);
        assert_eq!(state.epub_image_jobs.len(), 1);
    }

    #[test]
    fn current_epub_images_use_a_deterministic_first_fit_policy() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(1)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.epub_image_budget = CacheBudget::new(6);
        let first_image = state.epub_image_budget.try_reserve(4).unwrap();
        assert_eq!(load_epub_images_task(&mut state).units(), 1);
        let job = state.epub_image_jobs.iter().next().unwrap().clone();

        let task = update(
            &mut state,
            Message::EpubImageSizeLoaded {
                tab_id: job.tab_id,
                generation: job.generation,
                path: job.path.clone(),
                byte_len: Some(4),
            },
        );

        assert_eq!(task.units(), 0);
        assert!(state.epub_images_failed.contains(&job.path));
        assert!(!state.epub_images_desired.contains(&job.path));
        drop(first_image);
    }

    #[test]
    fn stale_raster_completion_wakes_epub_after_transient_contention() {
        let epub = Arc::new(EpubDoc::from_bytes(epub_with_image_chapters(1)).unwrap());
        let mut state = state_with_document(OpenDocument::Epub(Arc::clone(&epub)));
        assert_eq!(load_epub_images_task(&mut state).units(), 1);
        let image_job = state.epub_image_jobs.iter().next().unwrap().clone();
        let transient_bytes = epub_image_transient_byte_len(&epub, &image_job.path).unwrap();
        state.transient_decode_budget = CacheBudget::new(transient_bytes);
        let transient = state
            .transient_decode_budget
            .try_reserve(transient_bytes)
            .unwrap();

        assert_eq!(
            update(
                &mut state,
                Message::EpubImageSizeLoaded {
                    tab_id: image_job.tab_id,
                    generation: image_job.generation,
                    path: image_job.path.clone(),
                    byte_len: Some(4),
                },
            )
            .units(),
            0
        );
        assert!(state.epub_images_desired.contains(&image_job.path));
        drop(transient);

        let key = PageCacheKey {
            page: 0,
            scale_bits: 1.0_f32.to_bits(),
            highlights: Vec::new(),
        };
        let raster_job = RasterJob::Paginated {
            tab_id: 99,
            generation: 0,
            key: key.clone(),
        };
        state
            .raster_jobs
            .insert(raster_job, state.raster_budget.try_reserve(4).unwrap());
        let task = update(
            &mut state,
            Message::PageRendered {
                tab_id: 99,
                generation: 0,
                key,
                result: Err("stale".to_owned()),
            },
        );

        assert_eq!(task.units(), 1);
        assert!(state.epub_image_decode_active);
    }

    #[test]
    fn stale_and_failed_rasters_release_output_admission_before_pumping() {
        for stale in [false, true] {
            let pdf = PdfDoc::from_bytes(
                include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
            )
            .unwrap();
            let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
            let page = 0;
            let scale = raster_render_scale(&state, state.zoom.scale());
            let byte_len = raster_byte_len(&state, page, scale).unwrap();
            state.raster_budget = CacheBudget::new(byte_len);
            state.render_generation = 2;
            let key = PageCacheKey {
                page,
                scale_bits: scale.to_bits(),
                highlights: Vec::new(),
            };
            state.paginated_requested = vec![key.clone()];
            let tab_id = if stale {
                99
            } else {
                state.active_tab_id.unwrap()
            };
            let generation = if stale { 1 } else { state.render_generation };
            state.raster_jobs.insert(
                RasterJob::Paginated {
                    tab_id,
                    generation,
                    key: key.clone(),
                },
                state.raster_budget.try_reserve(byte_len).unwrap(),
            );

            let task = update(
                &mut state,
                Message::PageRendered {
                    tab_id,
                    generation,
                    key,
                    result: Err("render failed".to_owned()),
                },
            );

            if stale {
                assert!(task.units() > 0);
                assert!(!state.raster_jobs.is_empty());
            } else {
                let failed = RasterFailure::Paginated {
                    tab_id,
                    key: PageCacheKey {
                        page,
                        scale_bits: scale.to_bits(),
                        highlights: Vec::new(),
                    },
                };
                assert!(state.raster_failures.contains(&failed));
                assert!(
                    state.raster_jobs.keys().all(|job| job.failure() != failed),
                    "a terminal failure must not immediately retry"
                );
                assert!(matches!(
                    state.error,
                    Some(AppError::Render(ref error)) if error == "render failed"
                ));
            }
        }
    }

    #[test]
    fn unadmittable_raster_outputs_fail_once_with_an_actionable_error() {
        for continuous in [false, true] {
            let pdf = PdfDoc::from_bytes(
                include_bytes!("../../shosai-core/tests/fixtures/sample.pdf").to_vec(),
            )
            .unwrap();
            let mut state = state_with_document(OpenDocument::Pdf(Arc::new(pdf)));
            state.raster_budget = CacheBudget::new(0);
            if continuous {
                state.reading_mode = ReadingMode::Continuous;
                state.continuous_pages = vec![None; state.total_pages];
                state.continuous_visible.insert(0);
                assert_eq!(reconcile_continuous_rasters(&mut state).units(), 0);
            } else {
                assert_eq!(refresh_content(&mut state).units(), 0);
            }

            assert!(matches!(
                state.error,
                Some(AppError::Render(ref error)) if error.contains("exceeding the 0 byte limit")
            ));
            assert!(state.raster_jobs.is_empty());
            let failures = state.raster_failures.clone();
            assert_eq!(pump_raster_queue(&mut state).units(), 0);
            assert_eq!(state.raster_failures, failures);
            assert!(state.error.is_some());
        }
    }

    #[test]
    fn epub_image_decode_holds_transient_memory_admission() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(1)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        assert_eq!(load_epub_images_task(&mut state).units(), 1);
        let job = state.epub_image_jobs.iter().next().unwrap().clone();
        let transient_budget = state.transient_decode_budget.clone();

        let task = update(
            &mut state,
            Message::EpubImageSizeLoaded {
                tab_id: job.tab_id,
                generation: job.generation,
                path: job.path,
                byte_len: Some(4),
            },
        );

        assert_eq!(task.units(), 1);
        assert!(transient_budget.used() > 0);
        drop(task);
        assert_eq!(transient_budget.used(), 0);
    }

    #[test]
    fn epub_image_workers_are_bounded_globally_and_require_exact_completions() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(1)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        assert_eq!(load_epub_images_task(&mut state).units(), 1);
        let job = state.epub_image_jobs.iter().next().unwrap().clone();
        state.epub_image_decode_active = false;

        assert_eq!(load_epub_images_task(&mut state).units(), 0);
        assert_eq!(state.epub_image_jobs.len(), EPUB_IMAGE_WORKERS);
        assert_eq!(
            update(
                &mut state,
                Message::EpubImageSizeLoaded {
                    tab_id: job.tab_id,
                    generation: job.generation,
                    path: "unknown.png".to_owned(),
                    byte_len: Some(4),
                },
            )
            .units(),
            0
        );
        assert_eq!(state.epub_image_jobs.len(), EPUB_IMAGE_WORKERS);
    }

    #[test]
    fn epub_image_scrubbing_keeps_one_batch_and_prioritizes_the_latest_chapter() {
        let epub = EpubDoc::from_bytes(epub_with_image_chapters(5)).unwrap();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let _ = load_epub_images_task(&mut state);
        let obsolete = state
            .epub_images_pending
            .iter()
            .cloned()
            .collect::<Vec<_>>();
        let obsolete_job = obsolete[0].clone();

        state.current_page = 4;
        assert_eq!(load_epub_images_task(&mut state).units(), 0);
        assert!(state.epub_image_decode_active);
        assert_eq!(state.epub_images_desired.len(), 2);

        let budget = state.epub_image_budget.clone();
        let next = update(
            &mut state,
            Message::EpubImagesDecoded {
                tab_id: 1,
                generation: 0,
                path: obsolete_job,
                images: obsolete
                    .into_iter()
                    .map(|path| {
                        (
                            path,
                            Some(DecodedEpubImage::Raster {
                                width: 1,
                                height: 1,
                                pixels: vec![1, 2, 3, 255],
                                permit: budget.try_reserve(4).unwrap(),
                            }),
                        )
                    })
                    .collect(),
            },
        );

        assert_eq!(next.units(), 1);
        assert!(state.epub_image_handles.is_empty());
        assert!(state.epub_image_decode_active);
        assert_eq!(state.epub_images_pending.len(), 1);
        assert!(
            state
                .epub_images_pending
                .iter()
                .all(|path| { path.ends_with("image-3.png") || path.ends_with("image-4.png") })
        );
    }

    #[test]
    fn reader_tabs_share_paginated_layout_storage() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let _ = refresh_content(&mut state);
        complete_epub_pagination(&mut state);
        state.file_path = Some(PathBuf::from("book.epub"));

        let tab = capture_reader_tab(&state).expect("reader tab should be captured");

        assert!(std::ptr::eq(
            state.epub_pages.as_ptr(),
            tab.epub_pages.as_ptr()
        ));
    }

    #[test]
    fn continuous_epub_resolution_updates_character_offset_within_a_chapter() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.reading_mode = ReadingMode::Continuous;
        let activation = state.continuous_activation;

        let _ = update(
            &mut state,
            Message::ContinuousItemResolved {
                tab_id: 1,
                activation,
                page: 0,
                epub_offset: Some(37),
            },
        );

        assert_eq!(state.current_page, 0);
        assert_eq!(state.epub_offset, 37);
    }

    #[test]
    fn epub_location_survives_relayout_and_mode_changes() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.window_size = Size::new(360.0, 320.0);
        state.font_size = 32.0;
        let _ = refresh_content(&mut state);
        complete_epub_pagination(&mut state);
        let target_page = state
            .epub_pages
            .iter()
            .position(|page| page.nodes.first().is_some_and(|node| node.text_offset > 0))
            .expect("fixture should produce a continuation page");
        state.epub_page = target_page;
        sync_epub_location(&mut state);
        let location = (state.current_page, state.epub_offset);

        let _ = update(&mut state, Message::FontSizeDown);
        complete_epub_pagination(&mut state);
        assert_eq!((state.current_page, state.epub_offset), location);
        assert_eq!(
            state.epub_pages[state.epub_page].chapter, location.0,
            "relayout should select a page in the anchored chapter"
        );

        let _ = update(&mut state, Message::ToggleReadingMode);
        let _ = update(&mut state, Message::ToggleReadingMode);
        complete_epub_pagination(&mut state);
        assert_eq!((state.current_page, state.epub_offset), location);
        assert_eq!(state.epub_pages[state.epub_page].chapter, location.0);
    }

    #[test]
    fn epub_location_boundary_selects_the_continuation_page() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let paragraph = |text: &str| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text: text.to_string(),
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
                    preserve_whitespace: false,
                    link: None,
                }],
                Default::default(),
            )
        };
        state.epub_pages = Arc::new(vec![
            EpubPage {
                chapter: 0,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("first"),
                    text_offset: 0,
                    block_before: 0.0,
                    block_after: 0.0,
                }],
            },
            EpubPage {
                chapter: 0,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("second"),
                    text_offset: 5,
                    block_before: 0.0,
                    block_after: 0.0,
                }],
            },
        ]);

        assert_eq!(epub_page_for_location(&state, 0, 5), 1);
    }

    #[test]
    fn epub_fragment_locations_drive_paginated_and_continuous_navigation() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let paragraph = |text: &str| {
            ContentNode::Paragraph(
                vec![shosai_core::epub::render::TextSpan {
                    text: text.to_string(),
                    math: None,
                    font_family: None,
                    bold: false,
                    italic: false,
                    monospace: false,
                    font_size_multiplier: 1.0,
                    preserve_whitespace: false,
                    link: None,
                }],
                Default::default(),
            )
        };
        state.epub_pages = Arc::new(vec![
            EpubPage {
                chapter: 0,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("first"),
                    text_offset: 0,
                    block_before: 0.0,
                    block_after: 0.0,
                }],
            },
            EpubPage {
                chapter: 0,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("second"),
                    text_offset: 5,
                    block_before: 0.0,
                    block_after: 0.0,
                }],
            },
            EpubPage {
                chapter: 1,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("third"),
                    text_offset: 0,
                    block_before: 0.0,
                    block_after: 0.0,
                }],
            },
        ]);

        let task = navigate_to_epub_location(&mut state, 0, 5);
        assert_eq!(task.units(), 0);
        assert_eq!(state.epub_page, 1);
        assert_eq!((state.current_page, state.epub_offset), (0, 5));

        state.reading_mode = ReadingMode::Continuous;
        let task = navigate_to_epub_location(&mut state, 1, 12);
        assert!(task.units() > 0);
        assert_eq!((state.current_page, state.epub_offset), (1, 12));
        assert_eq!(state.page_input, "2");
    }

    #[test]
    fn epub_contents_panel_uses_resolved_toc_locations() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");

        let locations = epub_toc_locations(&epub);

        assert_eq!(
            locations,
            vec![
                (0, "Chapter 1: Introduction".to_string(), 0, 0),
                (0, "Chapter 2: Getting Started".to_string(), 1, 0),
            ]
        );
    }

    #[test]
    fn switching_from_continuous_epub_preserves_the_current_chapter() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let _ = refresh_content(&mut state);
        complete_epub_pagination(&mut state);
        assert!(state.epub_pages.iter().any(|page| page.chapter == 1));

        let _ = update(&mut state, Message::ToggleReadingMode);
        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        state.current_page = 1;
        state.epub_page = 0;

        let _ = update(&mut state, Message::ToggleReadingMode);
        complete_epub_pagination(&mut state);

        assert_eq!(state.reading_mode, ReadingMode::Paginated);
        assert_eq!(state.current_page, 1);
        assert_eq!(state.epub_pages[state.epub_page].chapter, 1);
    }

    #[tokio::test]
    async fn warm_paginated_epub_turn_reuses_layout_resources_and_queues_persistence() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("book.epub"));
        state.reading_state_saves = Some(start_reading_state_writer(store.clone()));
        state.window_size.width = 900.0;
        state.epub_pages = Arc::new(vec![
            EpubPage {
                chapter: 0,
                title: None,
                nodes: Vec::new(),
            },
            EpubPage {
                chapter: 1,
                title: None,
                nodes: Vec::new(),
            },
            EpubPage {
                chapter: 2,
                title: None,
                nodes: Vec::new(),
            },
        ]);
        state.epub_layout_key = Some(epub_layout_key(&state));
        state.bookmarks.push(Bookmark {
            id: 1,
            file_path: "book.epub".to_string(),
            book_id: None,
            page: 2,
            location_offset: Some(0),
            title: None,
            note: None,
            color: "yellow".to_string(),
            created_at: "2026-08-17".to_string(),
        });

        assert_eq!(epub_visible_pages(&state), vec![0, 1]);
        assert!(can_turn_epub_page(&state, true));
        let pages = Arc::clone(&state.epub_pages);
        let layout_key = state.epub_layout_key;
        let render_generation = state.render_generation;
        let presentation = match &state.document {
            Some(OpenDocument::Epub(document)) => document.presentation() as *const _,
            _ => panic!("expected EPUB document"),
        };

        let task = turn_epub_page(&mut state, true);

        assert!(task.units() > 0);
        assert!(Arc::ptr_eq(&state.epub_pages, &pages));
        assert_eq!(state.epub_layout_key, layout_key);
        assert_eq!(state.render_generation, render_generation);
        let current_presentation = match &state.document {
            Some(OpenDocument::Epub(document)) => document.presentation() as *const _,
            _ => panic!("expected EPUB document"),
        };
        assert_eq!(current_presentation, presentation);
        assert_eq!(state.epub_page, 2);
        assert_eq!(state.current_page, 2);
        assert_eq!(epub_visible_pages(&state), vec![2]);
        assert!(state.current_page_bookmarked);
        let (flushed, wait) = oneshot::channel();
        state
            .reading_state_saves
            .as_ref()
            .unwrap()
            .send(ReadingStateWriterMessage::Flush(flushed))
            .unwrap();
        wait.await.unwrap().unwrap();
        let save = store.get_async(Path::new("book.epub")).await.unwrap();
        assert_eq!(save.page, 2);
        assert_eq!(save.location_offset, Some(0));
    }

    #[tokio::test]
    async fn repeated_epub_chapter_turns_retain_per_book_resources() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.file_path = Some(PathBuf::from("book.epub"));
        state.reading_state_saves = Some(start_reading_state_writer(store.clone()));
        state.window_size.width = 500.0;
        state.epub_pages = Arc::new(vec![
            EpubPage {
                chapter: 0,
                title: None,
                nodes: Vec::new(),
            },
            EpubPage {
                chapter: 1,
                title: None,
                nodes: Vec::new(),
            },
        ]);
        state.epub_layout_key = Some(epub_layout_key(&state));

        let pages = Arc::clone(&state.epub_pages);
        let layout_key = state.epub_layout_key;
        let render_generation = state.render_generation;
        let search_document_generation = state.search_document_generation;
        let search_query_generation = state.search_query_generation;
        let (presentation, fonts, native_text_id) = match &state.document {
            Some(OpenDocument::Epub(document)) => (
                document.presentation() as *const _,
                document.fonts() as *const _,
                document.fonts().native_text_id(),
            ),
            _ => panic!("expected EPUB document"),
        };

        for turn in 0..64 {
            let forward = turn % 2 == 0;
            let _ = turn_epub_page(&mut state, forward);
            assert_eq!(state.current_page, usize::from(forward));
        }

        let (flushed, wait) = oneshot::channel();
        state
            .reading_state_saves
            .as_ref()
            .unwrap()
            .send(ReadingStateWriterMessage::Flush(flushed))
            .unwrap();
        wait.await.unwrap().unwrap();
        assert_eq!(
            store.get_async(Path::new("book.epub")).await.unwrap().page,
            state.current_page
        );
        assert!(Arc::ptr_eq(&state.epub_pages, &pages));
        assert_eq!(state.epub_layout_key, layout_key);
        assert_eq!(state.render_generation, render_generation);
        assert_eq!(state.search_document_generation, search_document_generation);
        assert_eq!(state.search_query_generation, search_query_generation);
        let (current_presentation, current_fonts, current_native_text_id) = match &state.document {
            Some(OpenDocument::Epub(document)) => (
                document.presentation() as *const _,
                document.fonts() as *const _,
                document.fonts().native_text_id(),
            ),
            _ => panic!("expected EPUB document"),
        };
        assert_eq!(current_presentation, presentation);
        assert_eq!(current_fonts, fonts);
        assert_eq!(current_native_text_id, native_text_id);
    }

    #[test]
    fn repeated_chapter_view_replacement_keeps_rasters_bounded_and_releases_them() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/epub-conformance/conformance.epub")
                .to_vec(),
        )
        .expect("conformance fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.window_size = Size::new(500.0, 700.0);
        complete_epub_pagination(&mut state);
        let document = match &state.document {
            Some(OpenDocument::Epub(document)) => Arc::clone(document),
            _ => panic!("expected EPUB document"),
        };
        let native_text_id = document.fonts().native_text_id();
        let chapters = [0, 3];
        assert!(
            chapters
                .iter()
                .all(|chapter| { state.epub_pages.iter().any(|page| page.chapter == *chapter) })
        );
        let mut renderer = iced::Renderer::Secondary(iced_tiny_skia::Renderer::new(
            iced::Font::DEFAULT,
            iced::Pixels(16.0),
        ));
        let mut cache = iced_runtime::user_interface::Cache::new();
        let theme = iced::Theme::Light;
        let style = iced::advanced::renderer::Style::default();

        for turn in 0..32 {
            let chapter = chapters[turn % chapters.len()];
            assert_eq!(navigate_to_epub_location(&mut state, chapter, 0).units(), 0);
            let element = epub_chapter_view(&state);
            let mut interface = iced_runtime::UserInterface::build(
                element,
                state.window_size,
                cache,
                &mut renderer,
            );
            interface.draw(
                &mut renderer,
                &theme,
                &style,
                iced::mouse::Cursor::Unavailable,
            );
            cache = interface.into_cache();
            assert!(
                crate::epub::native_text::retained_book_raster_pixels(native_text_id)
                    <= crate::epub::native_text::book_raster_pixel_budget()
            );
        }

        drop(cache);
        assert_eq!(
            crate::epub::native_text::retained_book_raster_pixels(native_text_id),
            0,
            "replaced chapter trees must release their raster permits"
        );
    }

    #[tokio::test]
    async fn reading_state_writer_coalesces_queued_positions() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("book.epub");
        std::fs::copy(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../shosai-core/tests/fixtures/sample.epub"),
            &path,
        )
        .unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let library = Library::new(store.pool().clone(), store.managed_books_dir());
        let book = library.import_file(&path).await.unwrap();
        let saves = start_reading_state_writer(store.clone());

        for page in 1..=3 {
            saves
                .send(ReadingStateWriterMessage::Save(ReadingStateSave {
                    book_id: None,
                    path: path.clone(),
                    reading: FileReadingState {
                        page,
                        location_offset: Some(page * 10),
                        zoom: 1.0,
                    },
                }))
                .unwrap();
        }
        for progress in [0.25, 0.5, 0.75] {
            saves
                .send(ReadingStateWriterMessage::Progress {
                    book_id: book.id,
                    progress,
                })
                .unwrap();
        }

        let (flushed, wait_for_flush) = oneshot::channel();
        saves
            .send(ReadingStateWriterMessage::Flush(flushed))
            .unwrap();
        wait_for_flush.await.unwrap().unwrap();

        let saved = store
            .get_async(&path)
            .await
            .expect("flush should persist the latest queued position");
        assert_eq!(saved.page, 3);
        assert_eq!(saved.location_offset, Some(30));
        assert_eq!(library.get(book.id).await.unwrap().unwrap().progress, 0.75);
    }

    #[tokio::test]
    async fn reading_state_writer_flushes_the_latest_language_preference() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let saves = start_reading_state_writer(store.clone());

        saves
            .send(ReadingStateWriterMessage::Preference(
                LANGUAGE_PREFERENCE_KEY.to_owned(),
                LanguagePreference::Japanese.stored().to_owned(),
            ))
            .unwrap();
        saves
            .send(ReadingStateWriterMessage::Preference(
                LANGUAGE_PREFERENCE_KEY.to_owned(),
                LanguagePreference::English.stored().to_owned(),
            ))
            .unwrap();
        let (flushed, wait_for_flush) = oneshot::channel();
        saves
            .send(ReadingStateWriterMessage::Flush(flushed))
            .unwrap();
        wait_for_flush.await.unwrap().unwrap();

        assert_eq!(
            store.get_pref_async(LANGUAGE_PREFERENCE_KEY).await,
            Some(LanguagePreference::English.stored().to_string())
        );
    }

    #[test]
    fn persistence_overload_is_reported_as_data_loss() {
        assert_eq!(
            state_writer_send_error(StateWriterSendError::Full),
            AppError::Storage(
                "state persistence queue is full; latest change was not saved".to_owned()
            )
        );
    }

    #[test]
    fn paginated_epub_caps_wide_pages_at_a_readable_line_length() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.window_size.width = 3440.0;

        let wide_page = epub_page_size(&state);
        let estimated_characters =
            wide_page.width / (state.font_size * crate::epub::AVERAGE_CHARACTER_WIDTH);

        assert!((estimated_characters - crate::epub::MAX_CHARACTERS_PER_LINE as f32).abs() < 0.01);

        state.window_size.width = 500.0;
        let narrow_page = epub_page_size(&state);
        assert!(narrow_page.width < wide_page.width);
    }

    #[test]
    fn reader_text_and_links_meet_contrast_targets_in_every_theme() {
        fn linear(channel: f32) -> f32 {
            if channel <= 0.04045 {
                channel / 12.92
            } else {
                ((channel + 0.055) / 1.055).powf(2.4)
            }
        }
        fn luminance(color: iced::Color) -> f32 {
            0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
        }
        fn contrast(left: iced::Color, right: iced::Color) -> f32 {
            let (lighter, darker) = if luminance(left) >= luminance(right) {
                (luminance(left), luminance(right))
            } else {
                (luminance(right), luminance(left))
            };
            (lighter + 0.05) / (darker + 0.05)
        }
        fn composite(foreground: iced::Color, background: iced::Color) -> iced::Color {
            iced::Color {
                r: foreground.r * foreground.a + background.r * (1.0 - foreground.a),
                g: foreground.g * foreground.a + background.g * (1.0 - foreground.a),
                b: foreground.b * foreground.a + background.b * (1.0 - foreground.a),
                a: 1.0,
            }
        }

        for theme in [ReaderTheme::Light, ReaderTheme::Dark, ReaderTheme::Sepia] {
            let palette = theme.palette();
            for surface in [palette.background, palette.table_header_background] {
                assert!(contrast(palette.text, surface) >= 4.5);
                assert!(contrast(palette.link, surface) >= 4.5);
                for highlight in [palette.search_highlight, palette.current_search_highlight] {
                    let highlighted_surface = composite(highlight, surface);
                    assert!(
                        contrast(palette.text, highlighted_surface) >= 4.5,
                        "{theme:?} highlighted text must remain readable"
                    );
                    assert!(
                        contrast(palette.link, highlighted_surface) >= 4.5,
                        "{theme:?} highlighted links must remain readable"
                    );
                }
            }
            assert!(
                contrast(palette.table_header_border, palette.background) >= 3.0,
                "{theme:?} table headers need a perceivable non-text cue"
            );
        }
    }

    #[test]
    fn raster_page_refresh_schedules_background_work() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));

        let task = refresh_content(&mut state);

        assert!(task.units() > 0);
        assert!(state.rendered_page.is_none());
        assert_eq!(state.render_generation, 1);
    }

    #[test]
    fn raster_page_refresh_reuses_a_cached_page() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        cbz.page_size(0).unwrap();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        let key = PageCacheKey {
            page: 0,
            scale_bits: 1.0_f32.to_bits(),
            highlights: Vec::new(),
        };
        cache_rendered_page(
            &mut state,
            key,
            RenderedPage {
                width: 42,
                height: 42,
                pixels: bytes::Bytes::from(vec![0; 42 * 42 * 4]),
            },
        );

        let task = refresh_content(&mut state);

        assert_eq!(task.units(), 0);
        assert_eq!(
            state.rendered_page.as_ref().map(|page| page.width),
            Some(42)
        );
    }

    #[test]
    fn page_cache_evicts_the_least_recently_used_page() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));

        for page in 0..=PAGE_CACHE_CAPACITY {
            cache_rendered_page(
                &mut state,
                PageCacheKey {
                    page,
                    scale_bits: 1.0_f32.to_bits(),
                    highlights: Vec::new(),
                },
                RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: bytes::Bytes::from(vec![0; 4]),
                },
            );
        }

        assert_eq!(state.page_cache.len(), PAGE_CACHE_CAPACITY);
        assert!(state.page_cache.iter().all(|(key, _)| key.page != 0));
    }

    #[test]
    fn page_cache_evicts_by_decoded_pixel_bytes() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.page_cache = BoundedCache::new(8);
        state.raster_budget = CacheBudget::new(6);

        for page in 0..2 {
            let permit = reserve_raster_bytes(&mut state, 4).unwrap();
            let rendered = attach_raster_permit(
                RenderedPage {
                    width: 1,
                    height: 1,
                    pixels: bytes::Bytes::from(vec![0; 4]),
                },
                permit,
            )
            .unwrap();
            cache_rendered_page(
                &mut state,
                PageCacheKey {
                    page,
                    scale_bits: 1.0_f32.to_bits(),
                    highlights: Vec::new(),
                },
                rendered,
            );
        }

        assert_eq!(state.raster_budget.used(), 4);
        assert_eq!(state.page_cache.len(), 1);
        assert_eq!(state.page_cache.iter().next().unwrap().0.page, 1);
    }

    #[test]
    fn paginated_admission_evicts_inactive_continuous_only_rasters() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.file_path = Some(PathBuf::from("inactive.cbz"));
        state.display_title = Some("Inactive".to_owned());
        state.raster_budget = CacheBudget::new(4);
        let permit = state.raster_budget.try_reserve(4).unwrap();
        state.continuous_pages = vec![attach_raster_permit(
            RenderedPage {
                width: 1,
                height: 1,
                pixels: bytes::Bytes::from(vec![0; 4]),
            },
            permit,
        )];
        state.tabs.push(capture_reader_tab(&state).unwrap());
        state.continuous_pages.clear();
        state.reading_mode = ReadingMode::Paginated;

        let paginated = reserve_raster_bytes(&mut state, 4);

        assert!(paginated.is_some());
        assert!(state.tabs[0].continuous_pages[0].is_none());
    }

    #[test]
    fn changing_query_immediately_clears_previous_results() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.search_query = "old".to_string();
        state.search_results = vec![SearchMatch {
            page: 0,
            offset: 4,
            length: 3,
            context: "old result".to_string(),
        }];

        let _ = update(&mut state, Message::SearchQueryChanged("new".to_string()));

        assert_eq!(state.search_query, "new");
        assert!(state.search_results.is_empty());
        assert_eq!(state.search_current, 0);
    }

    #[test]
    fn document_search_runs_only_after_the_latest_debounce() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let debounce = update(
            &mut state,
            Message::SearchQueryChanged("sample".to_string()),
        );
        let query_generation = state.search_query_generation;
        let document_generation = state.search_document_generation;

        assert!(debounce.units() > 0);
        assert_eq!(
            update(
                &mut state,
                Message::SearchQueryDebounced {
                    tab_id: 1,
                    document_generation,
                    query_generation: query_generation - 1,
                },
            )
            .units(),
            0
        );

        let search = update(
            &mut state,
            Message::SearchQueryDebounced {
                tab_id: 1,
                document_generation,
                query_generation,
            },
        );
        assert!(search.units() > 0);
    }

    #[test]
    fn rendered_node_lengths_match_search_text_offsets() {
        let nodes = vec![ContentNode::BlockQuote {
            children: vec![
                ContentNode::Heading {
                    level: 2,
                    spans: vec![shosai_core::epub::render::TextSpan {
                        text: "A heading".to_string(),
                        math: None,
                        font_family: None,
                        bold: true,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
                        preserve_whitespace: false,
                        link: None,
                    }],
                    style: Default::default(),
                },
                ContentNode::OrderedList {
                    items: vec![vec![shosai_core::epub::render::TextSpan {
                        text: "list item".to_string(),
                        math: None,
                        font_family: None,
                        bold: true,
                        italic: false,
                        monospace: false,
                        font_size_multiplier: 1.0,
                        preserve_whitespace: false,
                        link: None,
                    }]],
                    start: 1,
                },
            ],
            style: Default::default(),
        }];
        let extracted = shosai_core::search::extract_text_from_nodes(&nodes);
        let rendered_length: usize = nodes
            .iter()
            .map(|node| content_node_text_len(node) + 1)
            .sum();

        assert_eq!(rendered_length, extracted.chars().count());
    }

    #[test]
    fn language_selection_is_ignored_until_storage_finishes_initializing() {
        let (mut state, _) = boot();

        let _ = update(
            &mut state,
            Message::SelectLanguage(LanguagePreference::Japanese),
        );

        assert_eq!(state.i18n.preference(), LanguagePreference::System);
    }

    #[test]
    fn render_errors_are_kept_as_raw_details() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        let generation = state.render_generation;
        let key = PageCacheKey {
            page: 0,
            scale_bits: 1.0_f32.to_bits(),
            highlights: Vec::new(),
        };
        admit_test_raster(
            &mut state,
            RasterJob::Paginated {
                tab_id: 1,
                generation,
                key: key.clone(),
            },
            4,
        );

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation,
                key,
                result: Err("renderer detail".to_string()),
            },
        );

        assert!(matches!(
            &state.error,
            Some(AppError::Render(detail)) if detail == "renderer detail"
        ));
        let error = state.error.as_ref().unwrap();
        assert_eq!(
            error
                .localized(&I18n::new(LanguagePreference::English))
                .replace(['\u{2068}', '\u{2069}'], ""),
            "Failed to render page: renderer detail"
        );
        assert_eq!(
            error
                .localized(&I18n::new(LanguagePreference::Japanese))
                .replace(['\u{2068}', '\u{2069}'], ""),
            "ページを表示できませんでした：renderer detail"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn generated_bookmark_titles_are_not_persisted() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(
            CbzDoc::from_bytes(
                include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
            )
            .unwrap(),
        )));
        state.file_path = Some(directory.path().join("book.cbz"));
        state.bookmark_store = Some(BookmarkStore::new(store.pool().clone()));
        state.i18n.set_preference(LanguagePreference::Japanese);

        use iced::futures::StreamExt;

        let task = update(&mut state, Message::ToggleBookmark);
        assert!(state.bookmarks.is_empty());
        let mut messages = iced_runtime::task::into_stream(task).expect("bookmark task");
        let iced_runtime::Action::Output(message) =
            messages.next().await.expect("bookmark completion")
        else {
            panic!("bookmark task should produce a message");
        };
        let _ = update(&mut state, message);

        assert_eq!(state.bookmarks.len(), 1);
        assert!(state.bookmarks[0].title.is_none());
    }
}
