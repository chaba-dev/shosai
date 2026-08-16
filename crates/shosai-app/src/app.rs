use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;

use iced::advanced::widget::{Id as WidgetId, operation};
use iced::keyboard;
use iced::widget::{
    button, center, column, container, grid, image, responsive, rich_text, row, scrollable, sensor,
    span, text, text_input,
};
use iced::{Element, Font, Length, Point, Size, Subscription, Task, window};

use shosai_core::bookmarks::{Bookmark, BookmarkStore};
use shosai_core::cbz::CbzDoc;
use shosai_core::document::{Document, RenderedPage};
use shosai_core::epub::EpubDoc;
use shosai_core::epub::render::{ContentNode, parse_chapter_xhtml};
use shosai_core::library::{Book, BookPage, Library};
use shosai_core::pdf::PdfDoc;
use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
use shosai_core::search::SearchMatch;

use crate::epub::{
    BLOCKQUOTE_SPACING as EPUB_BLOCKQUOTE_SPACING, PAGE_NUMBER_SIZE as EPUB_PAGE_NUMBER_SIZE,
    Page as EpubPage, PageNode as EpubPageNode, content_node_text_len, paginate_epub_chapter,
    spans_text_len,
};
use crate::pdf::ZoomMode;
use crate::{theme as app_theme, widgets};

mod dispatch;
mod message;

pub use dispatch::update;
pub use message::Message;

// ---------------------------------------------------------------------------
// Open document wrapper
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum OpenDocument {
    Pdf(Arc<PdfDoc>),
    Epub(Arc<EpubDoc>),
    Cbz(Arc<CbzDoc>),
}

#[derive(Clone)]
struct RasterImageHandle(image::Handle);

impl std::fmt::Debug for RasterImageHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_tuple("RasterImageHandle")
            .field(&self.0.id())
            .finish()
    }
}

#[derive(Clone)]
struct EpubImageHandle(image::Handle);

impl std::fmt::Debug for EpubImageHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_tuple("EpubImageHandle")
            .field(&self.0.id())
            .finish()
    }
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
enum Screen {
    Library,
    Reader,
}

#[derive(Debug)]
enum PendingOpen {
    FileSelected(PathBuf),
    LibraryBook(PathBuf),
}

impl PendingOpen {
    fn into_message(self) -> Message {
        match self {
            Self::FileSelected(path) => Message::FileSelected(Some(path)),
            Self::LibraryBook(path) => Message::OpenBook(path.to_string_lossy().into_owned()),
        }
    }
}

const LIBRARY_PAGE_SIZE: u32 = 40;
const LIBRARY_LOAD_AHEAD_PX: u32 = 600;
const LIBRARY_REFRESH_MIN_DURATION: std::time::Duration = std::time::Duration::from_millis(300);
const LIBRARY_ACTIVITY_TICK: std::time::Duration = std::time::Duration::from_millis(16);
const LIBRARY_ACTIVITY_STEP: f32 = 16.0 / 300.0;
const PAGE_CACHE_CAPACITY: usize = 8;
const CONTINUOUS_PAGE_CACHE_CAPACITY: usize = 8;
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

struct ContinuousItemOperation {
    item_ids: Vec<WidgetId>,
    scroll_id: WidgetId,
    item_bounds: Vec<Option<iced::Rectangle>>,
    content_top: Option<f32>,
    content_height: Option<f32>,
    viewport_height: Option<f32>,
    current_tail_extent: f32,
    requested_offset: Option<f32>,
    target: Option<usize>,
}

impl ContinuousItemOperation {
    fn resolve(tab_id: u64, activation: u64, total: usize, offset: f32) -> Self {
        Self {
            item_ids: (0..total)
                .map(|index| continuous_item_id(tab_id, activation, index))
                .collect(),
            scroll_id: continuous_scroll_id(tab_id, activation),
            item_bounds: vec![None; total],
            content_top: None,
            content_height: None,
            viewport_height: None,
            current_tail_extent: 0.0,
            requested_offset: Some(offset),
            target: None,
        }
    }

    fn locate(
        tab_id: u64,
        activation: u64,
        total: usize,
        target: usize,
        current_tail_extent: f32,
    ) -> Self {
        Self {
            item_ids: (0..total)
                .map(|index| continuous_item_id(tab_id, activation, index))
                .collect(),
            scroll_id: continuous_scroll_id(tab_id, activation),
            item_bounds: vec![None; total],
            content_top: None,
            content_height: None,
            viewport_height: None,
            current_tail_extent,
            requested_offset: None,
            target: Some(target),
        }
    }
}

impl operation::Operation<(usize, f32, f32)> for ContinuousItemOperation {
    fn traverse(
        &mut self,
        operate: &mut dyn FnMut(&mut dyn operation::Operation<(usize, f32, f32)>),
    ) {
        operate(self);
    }

    fn container(&mut self, id: Option<&WidgetId>, bounds: iced::Rectangle) {
        if let Some(index) = id.and_then(|id| self.item_ids.iter().position(|item| item == id)) {
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

    fn finish(&self) -> operation::Outcome<(usize, f32, f32)> {
        let Some(content_top) = self.content_top else {
            return operation::Outcome::None;
        };
        if let Some(target) = self.target
            && let Some(bounds) = self.item_bounds.get(target).copied().flatten()
        {
            let offset = (bounds.y - content_top).max(0.0);
            let tail_extent = self
                .content_height
                .zip(self.viewport_height)
                .map(|(content_height, viewport_height)| {
                    (offset + viewport_height - (content_height - self.current_tail_extent))
                        .max(0.0)
                })
                .unwrap_or(0.0);
            return operation::Outcome::Some((target, offset, tail_extent));
        }
        let Some(offset) = self.requested_offset else {
            return operation::Outcome::None;
        };
        let viewport_y = content_top + offset;
        let resolved = self
            .item_bounds
            .iter()
            .enumerate()
            .filter_map(|(index, bounds)| bounds.map(|bounds| (index, bounds)))
            .take_while(|(_, bounds)| bounds.y <= viewport_y + 1.0)
            .map(|(index, _)| index)
            .last()
            .unwrap_or(0);
        operation::Outcome::Some((resolved, offset, 0.0))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum ReadingMode {
    #[default]
    Paginated,
    Continuous,
}

#[derive(Debug, Clone)]
struct ReaderTab {
    id: u64,
    file_path: PathBuf,
    document: OpenDocument,
    current_page: usize,
    total_pages: usize,
    zoom: ZoomMode,
    rendered_page: Option<RenderedPage>,
    rendered_page_index: Option<usize>,
    rendered_page_handle: Option<RasterImageHandle>,
    rendered_facing_page: Option<(usize, RenderedPage)>,
    rendered_facing_page_handle: Option<RasterImageHandle>,
    page_cache: VecDeque<(PageCacheKey, RenderedPage)>,
    chapter_content: Vec<ContentNode>,
    epub_image_handles: HashMap<String, EpubImageHandle>,
    epub_pages: Vec<EpubPage>,
    epub_page: usize,
    epub_offset: usize,
    continuous_pages: Vec<Option<RenderedPage>>,
    continuous_pending: BTreeMap<usize, ContinuousRequest>,
    continuous_visible: BTreeSet<usize>,
    continuous_chapters: Vec<Vec<ContentNode>>,
    continuous_tail_extent: f32,
    render_generation: u64,
    page_input: String,
    error: Option<String>,
    font_size: f32,
    line_spacing: f32,
    theme: ReaderTheme,
    reading_mode: ReadingMode,
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
    search_text: Option<Arc<Vec<String>>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContinuousRequest {
    id: u64,
    generation: u64,
}

#[derive(Debug, Clone)]
pub struct InitializedState {
    store: ReadingStateStore,
    window_geometry: Option<(Size, Point)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PageCacheKey {
    page: usize,
    scale_bits: u32,
    highlights: Vec<(usize, usize, bool)>,
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub struct State {
    screen: Screen,

    // -- Reader state --
    file_path: Option<PathBuf>,
    document: Option<OpenDocument>,
    current_page: usize,
    total_pages: usize,
    zoom: ZoomMode,
    rendered_page: Option<RenderedPage>,
    rendered_page_index: Option<usize>,
    rendered_page_handle: Option<RasterImageHandle>,
    rendered_facing_page: Option<(usize, RenderedPage)>,
    rendered_facing_page_handle: Option<RasterImageHandle>,
    page_cache: VecDeque<(PageCacheKey, RenderedPage)>,
    render_generation: u64,
    chapter_content: Vec<ContentNode>,
    epub_image_handles: HashMap<String, EpubImageHandle>,
    epub_pages: Vec<EpubPage>,
    epub_page: usize,
    epub_offset: usize,
    continuous_pages: Vec<Option<RenderedPage>>,
    continuous_pending: BTreeMap<usize, ContinuousRequest>,
    continuous_visible: BTreeSet<usize>,
    continuous_chapters: Vec<Vec<ContentNode>>,
    continuous_tail_extent: f32,
    continuous_activation: u64,
    next_continuous_request_id: u64,
    page_input: String,
    error: Option<String>,
    font_size: f32,
    line_spacing: f32,
    theme: ReaderTheme,
    reading_mode: ReadingMode,
    tabs: Vec<ReaderTab>,
    active_tab: Option<usize>,
    active_tab_id: Option<u64>,
    next_tab_id: u64,
    open_error: Option<String>,
    show_reader_settings: bool,
    show_reader_more: bool,

    // -- Shared --
    reading_state: Option<ReadingStateStore>,
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
    search_text: Option<Arc<Vec<String>>>,
    search_loading: bool,
    search_document_generation: u64,
    search_query_generation: u64,

    // -- Library state --
    library_books: Vec<Book>,
    library_search: String,
    library_filter: Option<shosai_core::library::BookFormat>,
    library_has_more: bool,
    library_loading: bool,
    library_activity_progress: f32,
    library_generation: u64,
    library_book_ids: Arc<Vec<i64>>,
    library_offset: usize,
    storage_initializing: bool,
    storage_error: Option<String>,
    pending_open: Option<PendingOpen>,
    window_id: Option<window::Id>,
    window_size: Size,
    window_position: Option<Point>,
    saved_window_geometry: Option<(Size, Point)>,
    window_geometry_generation: u64,
    window_geometry_dirty: bool,
    window_geometry_saving: bool,
    close_after_geometry_save: Option<window::Id>,
}

/// Color theme for the EPUB reader.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum ReaderTheme {
    #[default]
    Light,
    Dark,
    Sepia,
}

impl ReaderTheme {
    fn background(&self) -> iced::Color {
        match self {
            ReaderTheme::Light => iced::Color::WHITE,
            ReaderTheme::Dark => iced::Color::from_rgb(0.12, 0.12, 0.14),
            ReaderTheme::Sepia => iced::Color::from_rgb(0.96, 0.92, 0.84),
        }
    }

    fn text_color(&self) -> iced::Color {
        match self {
            ReaderTheme::Light => iced::Color::from_rgb(0.1, 0.1, 0.1),
            ReaderTheme::Dark => iced::Color::from_rgb(0.85, 0.85, 0.85),
            ReaderTheme::Sepia => iced::Color::from_rgb(0.3, 0.2, 0.1),
        }
    }

    fn label(&self) -> &'static str {
        match self {
            ReaderTheme::Light => "Light",
            ReaderTheme::Dark => "Dark",
            ReaderTheme::Sepia => "Sepia",
        }
    }

    fn next(&self) -> Self {
        match self {
            ReaderTheme::Light => ReaderTheme::Dark,
            ReaderTheme::Dark => ReaderTheme::Sepia,
            ReaderTheme::Sepia => ReaderTheme::Light,
        }
    }
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

pub fn boot() -> (State, Task<Message>) {
    let state = State {
        screen: Screen::Library,

        file_path: None,
        document: None,
        current_page: 0,
        total_pages: 0,
        zoom: ZoomMode::default(),
        rendered_page: None,
        rendered_page_index: None,
        rendered_page_handle: None,
        rendered_facing_page: None,
        rendered_facing_page_handle: None,
        page_cache: VecDeque::new(),
        render_generation: 0,
        chapter_content: Vec::new(),
        epub_image_handles: HashMap::new(),
        epub_pages: Vec::new(),
        epub_page: 0,
        epub_offset: 0,
        continuous_pages: Vec::new(),
        continuous_pending: BTreeMap::new(),
        continuous_visible: BTreeSet::new(),
        continuous_chapters: Vec::new(),
        continuous_tail_extent: 0.0,
        continuous_activation: 0,
        next_continuous_request_id: 1,
        page_input: String::new(),
        error: None,
        font_size: 16.0,
        line_spacing: 1.6,
        theme: ReaderTheme::default(),
        reading_mode: ReadingMode::default(),
        tabs: Vec::new(),
        active_tab: None,
        active_tab_id: None,
        next_tab_id: 1,
        open_error: None,
        show_reader_settings: false,
        show_reader_more: false,

        bookmark_store: None,

        reading_state: None,
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
        search_text: None,
        search_loading: false,
        search_document_generation: 0,
        search_query_generation: 0,

        library_books: Vec::new(),
        library_search: String::new(),
        library_filter: None,
        library_has_more: false,
        library_loading: true,
        library_activity_progress: 0.0,
        library_generation: 0,
        library_book_ids: Arc::new(Vec::new()),
        library_offset: 0,
        storage_initializing: true,
        storage_error: None,
        pending_open: None,
        window_id: None,
        window_size: Size::new(900.0, 700.0),
        window_position: None,
        saved_window_geometry: None,
        window_geometry_generation: 0,
        window_geometry_dirty: false,
        window_geometry_saving: false,
        close_after_geometry_save: None,
    };
    let initialize = Task::perform(
        async {
            let started = std::time::Instant::now();
            let store = ReadingStateStore::open_async()
                .await
                .map_err(|error| error.to_string())?;
            let geometry = match (
                store.get_pref_int_async(WINDOW_WIDTH_KEY).await,
                store.get_pref_int_async(WINDOW_HEIGHT_KEY).await,
                store.get_pref_int_async(WINDOW_X_KEY).await,
                store.get_pref_int_async(WINDOW_Y_KEY).await,
            ) {
                (Some(width), Some(height), Some(x), Some(y)) if width >= 480 && height >= 360 => {
                    Some((
                        Size::new(width as f32, height as f32),
                        Point::new(x as f32, y as f32),
                    ))
                }
                _ => None,
            };
            eprintln!(
                "startup: database and preferences initialized in {} ms",
                started.elapsed().as_millis()
            );
            Ok(InitializedState {
                store,
                window_geometry: geometry,
            })
        },
        Message::Initialized,
    );
    (state, initialize)
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
    let next_offset = (offset + LIBRARY_PAGE_SIZE as usize).min(state.library_book_ids.len());
    let ids = Arc::clone(&state.library_book_ids);
    state.library_loading = true;

    Task::perform(
        async move {
            let books = library
                .books_by_ids(&ids[offset..next_offset])
                .await
                .unwrap_or_default();
            BookPage {
                books,
                has_more: next_offset < ids.len(),
            }
        },
        move |page| Message::LibraryLoaded {
            generation,
            offset,
            next_offset,
            page,
        },
    )
}

fn reset_library(state: &mut State) -> Task<Message> {
    state.library_generation = state.library_generation.wrapping_add(1);
    state.library_book_ids = Arc::new(Vec::new());
    state.library_offset = 0;
    state.library_has_more = false;
    let Some(library) = state.library.clone() else {
        state.library_loading = false;
        return Task::none();
    };
    let generation = state.library_generation;
    let search = state.library_search.clone();
    let filter = state.library_filter;
    state.library_loading = true;
    state.library_activity_progress = 0.0;

    Task::perform(
        async move {
            let started = std::time::Instant::now();
            let ids = library
                .matching_ids(Some(&search), filter)
                .await
                .unwrap_or_default();
            if let Some(remaining) = LIBRARY_REFRESH_MIN_DURATION.checked_sub(started.elapsed()) {
                tokio::time::sleep(remaining).await;
            }
            ids
        },
        move |ids| Message::LibraryIndexLoaded { generation, ids },
    )
}

fn library_load_sensor_key(state: &State) -> Option<(u64, usize)> {
    state
        .library_has_more
        .then_some((state.library_generation, state.library_offset))
}

fn library_activity_active(state: &State) -> bool {
    state.screen == Screen::Library && state.library_loading && state.library_offset == 0
}

fn capture_reader_tab(state: &State) -> Option<ReaderTab> {
    Some(ReaderTab {
        id: state.active_tab_id?,
        file_path: state.file_path.clone()?,
        document: state.document.clone()?,
        current_page: state.current_page,
        total_pages: state.total_pages,
        zoom: state.zoom,
        rendered_page: state.rendered_page.clone(),
        rendered_page_index: state.rendered_page_index,
        rendered_page_handle: state.rendered_page_handle.clone(),
        rendered_facing_page: state.rendered_facing_page.clone(),
        rendered_facing_page_handle: state.rendered_facing_page_handle.clone(),
        page_cache: state.page_cache.clone(),
        chapter_content: state.chapter_content.clone(),
        epub_image_handles: state.epub_image_handles.clone(),
        epub_pages: state.epub_pages.clone(),
        epub_page: state.epub_page,
        epub_offset: state.epub_offset,
        continuous_pages: state.continuous_pages.clone(),
        continuous_pending: state.continuous_pending.clone(),
        continuous_visible: BTreeSet::new(),
        continuous_chapters: state.continuous_chapters.clone(),
        continuous_tail_extent: state.continuous_tail_extent,
        render_generation: state.render_generation,
        page_input: state.page_input.clone(),
        error: state.error.clone(),
        font_size: state.font_size,
        line_spacing: state.line_spacing,
        theme: state.theme,
        reading_mode: state.reading_mode,
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
        search_text: state.search_text.clone(),
    })
}

fn restore_reader_tab(state: &mut State, tab: ReaderTab) {
    state.active_tab_id = Some(tab.id);
    state.file_path = Some(tab.file_path);
    state.document = Some(tab.document);
    state.current_page = tab.current_page;
    state.total_pages = tab.total_pages;
    state.zoom = tab.zoom;
    state.rendered_page = tab.rendered_page;
    state.rendered_page_index = tab.rendered_page_index;
    state.rendered_page_handle = tab.rendered_page_handle;
    state.rendered_facing_page = tab.rendered_facing_page;
    state.rendered_facing_page_handle = tab.rendered_facing_page_handle;
    state.page_cache = tab.page_cache;
    state.chapter_content = tab.chapter_content;
    state.epub_image_handles = tab.epub_image_handles;
    state.epub_pages = tab.epub_pages;
    state.epub_page = tab.epub_page;
    state.epub_offset = tab.epub_offset;
    state.continuous_pages = tab.continuous_pages;
    state.continuous_pending = tab.continuous_pending;
    state.continuous_visible = tab.continuous_visible;
    state.continuous_chapters = tab.continuous_chapters;
    state.continuous_tail_extent = tab.continuous_tail_extent;
    state.page_input = tab.page_input;
    state.error = tab.error;
    state.font_size = tab.font_size;
    state.line_spacing = tab.line_spacing;
    state.theme = tab.theme;
    state.reading_mode = tab.reading_mode;
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
    state.search_text = tab.search_text;
    state.search_loading = false;
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
    state.active_tab = Some(index);
    state.screen = Screen::Reader;
    let search_task = if state.show_search_bar && !state.search_query.is_empty() {
        perform_search(state)
    } else {
        Task::none()
    };
    let content_task = if state.reading_mode == ReadingMode::Continuous {
        scroll_to_current_page(state)
    } else if state.rendered_page.is_some() || matches!(state.document, Some(OpenDocument::Epub(_)))
    {
        Task::none()
    } else {
        refresh_content(state)
    };
    let bookmarks_task = if state.show_bookmarks_panel {
        refresh_bookmarks(state)
    } else {
        Task::none()
    };
    Task::batch([content_task, search_task, bookmarks_task])
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
        state.file_path = None;
        state.document = None;
        state.rendered_page = None;
        state.rendered_page_index = None;
        state.rendered_page_handle = None;
        state.rendered_facing_page = None;
        state.rendered_facing_page_handle = None;
        state.epub_image_handles.clear();
        state.epub_pages.clear();
        state.epub_page = 0;
        state.epub_offset = 0;
        state.continuous_pages.clear();
        state.continuous_chapters.clear();
        state.screen = Screen::Library;
        state.render_generation = state.render_generation.wrapping_add(1);
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

fn open_document(state: &mut State, path: PathBuf) -> Task<Message> {
    if let Some(index) = state.tabs.iter().position(|tab| tab.file_path == path) {
        return select_tab(state, index);
    }
    let document = match load_document(&path) {
        Ok(document) => document,
        Err(error) => {
            state.open_error = Some(error);
            return Task::none();
        }
    };
    save_active_tab(state);
    let tab_id = state.next_tab_id;
    state.next_tab_id = state.next_tab_id.wrapping_add(1);
    state.active_tab_id = Some(tab_id);
    state.continuous_activation = state.continuous_activation.wrapping_add(1);
    state.open_error = None;
    install_document(state, path, document);
    let task = refresh_content(state);
    if let Some(tab) = capture_reader_tab(state) {
        state.tabs.push(tab);
        state.active_tab = Some(state.tabs.len() - 1);
        state.screen = Screen::Reader;
    }
    task
}

fn load_document(path: &PathBuf) -> Result<OpenDocument, String> {
    let ext = path
        .extension()
        .map(|extension| extension.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "pdf" => PdfDoc::open(path)
            .map(|document| OpenDocument::Pdf(Arc::new(document)))
            .map_err(|error| format!("Failed to open PDF: {error}")),
        "epub" => EpubDoc::open(path)
            .map(|document| OpenDocument::Epub(Arc::new(document)))
            .map_err(|error| format!("Failed to open EPUB: {error}")),
        "cbz" => CbzDoc::open(path)
            .map(|document| OpenDocument::Cbz(Arc::new(document)))
            .map_err(|error| format!("Failed to open CBZ: {error}")),
        _ => Err(format!("Unsupported file format: .{ext}")),
    }
}

fn install_document(state: &mut State, path: PathBuf, document: OpenDocument) {
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
    state.chapter_content = Vec::new();
    state.epub_image_handles.clear();
    state.epub_pages.clear();
    state.epub_page = 0;
    state.epub_offset = 0;
    state.continuous_pages.clear();
    state.continuous_pending.clear();
    state.continuous_visible.clear();
    state.continuous_chapters.clear();
    state.continuous_tail_extent = 0.0;
    state.show_reader_settings = false;
    state.show_reader_more = false;
    state.show_search_bar = false;
    state.search_query.clear();
    state.search_results.clear();
    state.search_current = 0;
    state.search_text = None;
    state.search_loading = false;

    state.total_pages = match &document {
        OpenDocument::Pdf(document) => document.page_count(),
        OpenDocument::Epub(document) => document.chapter_count(),
        OpenDocument::Cbz(document) => document.page_count(),
    };
    state.document = Some(document);

    let saved = state
        .reading_state
        .as_ref()
        .and_then(|store| store.get(&path));
    if let Some(saved) = saved {
        state.current_page = saved.page.min(state.total_pages.saturating_sub(1));
        state.epub_offset = saved.location_offset.unwrap_or(0);
    } else {
        state.current_page = 0;
        state.epub_offset = 0;
    }
    state.zoom = ZoomMode::FitPage;

    state.page_input = format!("{}", state.current_page + 1);
    state.file_path = Some(path);
    update_bookmark_status(state);
    if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
        state.bookmarks = store.list_for_file(path).unwrap_or_default();
    }
}

fn handle_key_event(state: &State, event: keyboard::Event) -> Task<Message> {
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

/// Handle a link click from the EPUB reader.
fn handle_link_click(state: &mut State, href: &str) -> Task<Message> {
    // External links: open in system browser.
    if href.starts_with("http://") || href.starts_with("https://") || href.starts_with("mailto:") {
        if let Err(e) = open::that(href) {
            eprintln!("warning: failed to open URL: {e}");
        }
        return Task::none();
    }

    // Internal EPUB links: navigate to the target chapter.
    if let Some(OpenDocument::Epub(doc)) = &state.document {
        // Split href into path and optional fragment (#anchor).
        let (target_path, _fragment) = match href.split_once('#') {
            Some((path, frag)) => (path, Some(frag)),
            None => (href, None),
        };

        // If the path is empty, it's a same-chapter fragment link — nothing to navigate.
        if target_path.is_empty() {
            return Task::none();
        }

        // Find the chapter whose path ends with the target.
        // Links may be relative to the current chapter's directory, so we
        // resolve against the current chapter's base path.
        let current_base = doc
            .chapter(state.current_page)
            .map(|ch| {
                ch.path
                    .rsplit_once('/')
                    .map(|(dir, _)| dir.to_string())
                    .unwrap_or_default()
            })
            .unwrap_or_default();

        let resolved = if !current_base.is_empty() && !target_path.starts_with('/') {
            format!("{current_base}/{target_path}")
        } else {
            target_path.to_string()
        };

        // Find the chapter index by matching the resolved path.
        if let Some(chapter_idx) = doc.content.chapters.iter().position(|ch| {
            ch.path == resolved || ch.path.ends_with(target_path) || ch.path.ends_with(&resolved)
        }) {
            if uses_paginated_epub_layout(state) {
                state.epub_page = epub_page_for_location(state, chapter_idx, 0);
                sync_epub_location(state);
                save_reading_state(state);
                return Task::none();
            }
            state.current_page = chapter_idx;
            state.epub_page = 0;
            state.epub_offset = 0;
            state.page_input = format!("{}", state.current_page + 1);
            save_reading_state(state);
            return refresh_content(state);
        }
    }

    Task::none()
}

/// Refresh the visible content for the current page/chapter.
fn refresh_content(state: &mut State) -> Task<Message> {
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
                state.error = None;
                return Task::batch([
                    reconcile_continuous_rasters(state),
                    scroll_to_current_page(state),
                ]);
            }
            Some(OpenDocument::Epub(doc)) => {
                state.rendered_page = None;
                state.rendered_page_index = None;
                state.rendered_page_handle = None;
                state.rendered_facing_page = None;
                state.rendered_facing_page_handle = None;
                state.continuous_chapters = doc
                    .content
                    .chapters
                    .iter()
                    .map(|chapter| {
                        let base_path = chapter
                            .path
                            .rsplit_once('/')
                            .map(|(directory, _)| directory)
                            .unwrap_or("");
                        parse_chapter_xhtml(&chapter.content, base_path, &doc.content.styles)
                    })
                    .collect();
                cache_epub_image_handles(
                    &mut state.epub_image_handles,
                    state.continuous_chapters.iter().flatten(),
                    &doc.content.resources,
                );
                state.error = None;
                return scroll_to_current_page(state);
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
                state.error = None;
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
            let scale = paginated_raster_scale(state, &pages);
            state.chapter_content.clear();
            state.error = None;
            let mut tasks = Vec::new();
            for page in pages {
                let highlights = search_highlights_for_page(state, page);
                let key = PageCacheKey {
                    page,
                    scale_bits: scale.to_bits(),
                    highlights: highlights.clone(),
                };
                if !is_page_cached(state, &key) {
                    let doc = Arc::clone(&doc);
                    tasks.push(render_page_task(tab_id, generation, key, move || {
                        doc.render_page_with_highlights(page, scale, &highlights)
                    }));
                }
            }
            let spread_changed = show_cached_paginated_spread(state);
            if tasks.is_empty() && spread_changed {
                tasks.push(prefetch_next_paginated_spread(state));
            }
            return Task::batch(tasks);
        }
        Some(OpenDocument::Epub(doc)) => {
            let anchor = (state.current_page, state.epub_offset);
            let page_size = epub_page_size(state);
            state.rendered_page = None;
            state.rendered_page_index = None;
            state.rendered_page_handle = None;
            state.rendered_facing_page = None;
            state.rendered_facing_page_handle = None;
            let parsed_chapters = doc
                .content
                .chapters
                .iter()
                .map(|chapter| {
                    let base_path = chapter
                        .path
                        .rsplit_once('/')
                        .map(|(dir, _)| dir)
                        .unwrap_or("");
                    parse_chapter_xhtml(&chapter.content, base_path, &doc.content.styles)
                })
                .collect::<Vec<_>>();
            cache_epub_image_handles(
                &mut state.epub_image_handles,
                parsed_chapters.iter().flatten(),
                &doc.content.resources,
            );
            state.epub_pages = parsed_chapters
                .iter()
                .enumerate()
                .flat_map(|(chapter_index, nodes)| {
                    let chapter = &doc.content.chapters[chapter_index];
                    let title = chapter
                        .title
                        .as_deref()
                        .filter(|title| !content_starts_with_heading(nodes, title));
                    paginate_epub_chapter(
                        nodes,
                        title,
                        state.font_size,
                        state.line_spacing,
                        page_size,
                    )
                    .into_iter()
                    .enumerate()
                    .map(move |(page_index, nodes)| EpubPage {
                        chapter: chapter_index,
                        title: (page_index == 0)
                            .then(|| title.map(str::to_string))
                            .flatten(),
                        nodes,
                    })
                })
                .collect();
            if state.epub_pages.is_empty() {
                state.chapter_content.clear();
                state.epub_page = 0;
                state.error = Some("EPUB contains no readable content".to_string());
            } else {
                let requested_page = epub_page_for_location(state, anchor.0, anchor.1);
                state.epub_page = requested_page.min(state.epub_pages.len() - 1);
                state.current_page = state.epub_pages[state.epub_page].chapter;
                state.chapter_content = parsed_chapters[state.current_page].clone();
                state.page_input = (state.epub_page + 1).to_string();
                state.error = None;
            }
        }
        Some(OpenDocument::Cbz(doc)) => {
            let doc = Arc::clone(doc);
            let pages = paginated_raster_pages(state);
            let scale = paginated_raster_scale(state, &pages);
            state.chapter_content.clear();
            state.error = None;
            let mut tasks = Vec::new();
            for page in pages {
                let key = PageCacheKey {
                    page,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                };
                if !is_page_cached(state, &key) {
                    let doc = Arc::clone(&doc);
                    tasks.push(render_page_task(tab_id, generation, key, move || {
                        doc.render_page(page, scale)
                    }));
                }
            }
            let spread_changed = show_cached_paginated_spread(state);
            if tasks.is_empty() && spread_changed {
                tasks.push(prefetch_next_paginated_spread(state));
            }
            return Task::batch(tasks);
        }
        None => {}
    }

    Task::none()
}

fn cache_epub_image_handles<'a>(
    handles: &mut HashMap<String, EpubImageHandle>,
    nodes: impl IntoIterator<Item = &'a ContentNode>,
    resources: &HashMap<String, Vec<u8>>,
) {
    for node in nodes {
        match node {
            ContentNode::Image { src, .. } => {
                if handles.contains_key(src) {
                    continue;
                }
                let Some(data) = resources.get(src) else {
                    continue;
                };
                let Ok(image) = ::image::load_from_memory(data) else {
                    continue;
                };
                let rgba = image.to_rgba8();
                let (width, height) = rgba.dimensions();
                handles.insert(
                    src.clone(),
                    EpubImageHandle(image::Handle::from_rgba(width, height, rgba.into_raw())),
                );
            }
            ContentNode::BlockQuote { children, .. } => {
                cache_epub_image_handles(handles, children, resources);
            }
            _ => {}
        }
    }
}

fn epub_uses_spread(state: &State) -> bool {
    state.reading_mode == ReadingMode::Paginated
        && matches!(state.document, Some(OpenDocument::Epub(_)))
        && available_reader_size(state).width >= MIN_TWO_PAGE_WIDTH
}

fn epub_page_size(state: &State) -> Size {
    crate::epub::page_size(
        available_reader_size(state),
        epub_uses_spread(state),
        PAGE_GUTTER,
        state.font_size,
        state.line_spacing,
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
    render: impl FnOnce() -> anyhow::Result<RenderedPage> + Send + 'static,
) -> Task<Message> {
    Task::perform(
        async move {
            tokio::task::spawn_blocking(render)
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

fn continuous_scroll_id(tab_id: u64, activation: u64) -> iced::widget::Id {
    iced::widget::Id::from(format!("continuous-reader-{tab_id}-{activation}"))
}

fn scroll_to_current_page(state: &State) -> Task<Message> {
    if state.reading_mode != ReadingMode::Continuous {
        return Task::none();
    }
    let Some(tab_id) = state.active_tab_id else {
        return Task::none();
    };
    let activation = state.continuous_activation;
    iced::advanced::widget::operate(ContinuousItemOperation::locate(
        tab_id,
        activation,
        state.total_pages,
        state.current_page,
        state.continuous_tail_extent,
    ))
    .map(
        move |(_, offset, tail_extent)| Message::ContinuousNavigationMeasured {
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
    let mut desired = state.continuous_visible.iter().copied().collect::<Vec<_>>();
    if state.current_page < state.total_pages && !desired.contains(&state.current_page) {
        desired.push(state.current_page);
    }
    desired.sort_by_key(|page| (page.abs_diff(state.current_page), *page));
    desired.truncate(CONTINUOUS_PAGE_CACHE_CAPACITY);
    let desired = desired.into_iter().collect::<BTreeSet<_>>();

    for (page, rendered) in state.continuous_pages.iter_mut().enumerate() {
        if !desired.contains(&page) {
            *rendered = None;
        }
    }

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
    let missing_desired = desired
        .iter()
        .filter(|page| {
            state.continuous_pages[**page].is_none() && !state.continuous_pending.contains_key(page)
        })
        .count();
    let mut inactive_ready_budget =
        CONTINUOUS_PAGE_CACHE_CAPACITY.saturating_sub(active_ready + pending + missing_desired);
    for tab in state
        .tabs
        .iter_mut()
        .filter(|tab| Some(tab.id) != state.active_tab_id)
    {
        for rendered in &mut tab.continuous_pages {
            if rendered.is_some() {
                if inactive_ready_budget == 0 {
                    *rendered = None;
                } else {
                    inactive_ready_budget -= 1;
                }
            }
        }
    }
    let inactive_ready = state
        .tabs
        .iter()
        .filter(|tab| Some(tab.id) != state.active_tab_id)
        .flat_map(|tab| &tab.continuous_pages)
        .filter(|page| page.is_some())
        .count();
    let mut occupied = active_ready + inactive_ready + pending;
    let mut tasks = Vec::new();
    for page in desired {
        if occupied >= CONTINUOUS_PAGE_CACHE_CAPACITY {
            break;
        }
        if state.continuous_pages[page].is_none() && !state.continuous_pending.contains_key(&page) {
            let request = ContinuousRequest {
                id: state.next_continuous_request_id,
                generation: state.render_generation,
            };
            state.next_continuous_request_id = state.next_continuous_request_id.wrapping_add(1);
            state.continuous_pending.insert(page, request);
            occupied += 1;
            tasks.push(Task::done(Message::RenderContinuousPage { tab_id, page }));
        }
    }
    Task::batch(tasks)
}

fn invalidate_continuous_rasters(state: &mut State) {
    state.continuous_pages.fill(None);
    state.render_generation = state.render_generation.wrapping_add(1);
}

fn invalidate_continuous_layout(state: &mut State) {
    state.continuous_tail_extent = 0.0;
    state.continuous_activation = state.continuous_activation.wrapping_add(1);
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

fn turn_epub_page(state: &mut State, forward: bool) -> Task<Message> {
    let step = if epub_uses_spread(state) { 2 } else { 1 };
    let page = if forward {
        let next = epub_spread_start(state, state.epub_page).saturating_add(step);
        if next >= state.epub_pages.len() {
            return Task::none();
        }
        next
    } else if state.epub_page > 0 {
        epub_spread_start(state, state.epub_page).saturating_sub(step)
    } else {
        return Task::none();
    };
    state.epub_page = page;
    sync_epub_location(state);
    save_reading_state(state);
    Task::none()
}

fn can_turn_epub_page(state: &State, forward: bool) -> bool {
    if forward {
        let step = if epub_uses_spread(state) { 2 } else { 1 };
        epub_spread_start(state, state.epub_page).saturating_add(step) < state.epub_pages.len()
    } else {
        state.epub_page > 0
    }
}

fn sync_epub_location(state: &mut State) {
    if let Some(page) = state.epub_pages.get(state.epub_page) {
        state.current_page = page.chapter;
        state.epub_offset = page.nodes.first().map_or(0, |node| node.text_offset);
        state.page_input = (state.epub_page + 1).to_string();
        update_bookmark_status(state);
    }
}

fn uses_page_spreads(state: &State) -> bool {
    uses_paginated_raster_layout(state)
        && available_reader_size(state).width >= MIN_TWO_PAGE_WIDTH
        && state.total_pages > 1
}

fn available_reader_size(state: &State) -> Size {
    let compact = uses_compact_reader_layout(state.window_size.width);
    let bookmarks_width = if state.show_bookmarks_panel {
        BOOKMARKS_PANEL_WIDTH
    } else {
        0.0
    };
    let search_height = if state.show_search_bar {
        reader_search_height(compact)
    } else {
        0.0
    };
    let settings_height = if state.show_reader_settings {
        62.0
    } else {
        0.0
    };
    let more_height = if state.show_reader_more {
        reader_more_height(compact)
    } else {
        0.0
    };
    Size::new(
        (state.window_size.width - bookmarks_width - READER_HORIZONTAL_PADDING).max(1.0),
        (state.window_size.height
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
        Some(OpenDocument::Cbz(document)) => document.page_size(page).ok(),
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
    render: impl FnOnce() -> anyhow::Result<RenderedPage> + Send + 'static,
) -> Task<Message> {
    Task::perform(
        async move {
            tokio::task::spawn_blocking(render)
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

fn prefetch_next_paginated_spread(state: &State) -> Task<Message> {
    let Some(next_page) = next_page_location(state) else {
        return Task::none();
    };
    let pages = paginated_raster_pages_at(state, next_page);
    let scale = paginated_raster_scale(state, &pages);
    let tab_id = state.active_tab_id.unwrap_or(0);
    let generation = state.render_generation;
    let mut tasks = Vec::new();

    for page in pages {
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
        match &state.document {
            Some(OpenDocument::Pdf(document)) => {
                let document = Arc::clone(document);
                tasks.push(render_page_task(tab_id, generation, key, move || {
                    document.render_page_with_highlights(page, scale, &highlights)
                }));
            }
            Some(OpenDocument::Cbz(document)) => {
                let document = Arc::clone(document);
                tasks.push(render_page_task(tab_id, generation, key, move || {
                    document.render_page(page, scale)
                }));
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
    if let Some(position) = state
        .page_cache
        .iter()
        .position(|(cached_key, _)| cached_key == &key)
    {
        state.page_cache.remove(position);
    }
    state.page_cache.push_back((key, page));
    while state.page_cache.len() > PAGE_CACHE_CAPACITY {
        state.page_cache.pop_front();
    }
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
    let scale = paginated_raster_scale(state, &pages);
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
        let result_path = path.clone();
        Task::perform(
            async move { store.list_for_file_async(&path).await.unwrap_or_default() },
            move |bookmarks| Message::BookmarksLoaded {
                tab_id,
                file_path: result_path.clone(),
                bookmarks,
            },
        )
    } else {
        Task::none()
    }
}

fn update_bookmark_status(state: &mut State) {
    if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
        state.current_page_bookmarked =
            store.is_bookmarked_at(path, state.current_page, current_epub_offset(state));
    } else {
        state.current_page_bookmarked = false;
    }
}

fn save_reading_state(state: &State) {
    if let (Some(path), Some(store)) = (&state.file_path, &state.reading_state) {
        let reading = FileReadingState {
            page: state.current_page,
            location_offset: current_epub_offset(state),
            zoom: state.zoom.scale(),
        };
        if let Err(e) = store.set(path, &reading) {
            eprintln!("warning: failed to save reading state: {e}");
        }
    }

    // Also update library progress so the library sort/order stays current.
    // Use a background task to avoid blocking the UI thread on DB writes.
    if let (Some(lib), Some(path)) = (state.library.clone(), state.file_path.clone())
        && state.total_pages > 0
    {
        let progress = (state.current_page + 1) as f64 / state.total_pages as f64;
        let progress = progress.clamp(0.0, 1.0);
        tokio::task::spawn(async move {
            let _ = lib.update_progress_by_path(&path, progress).await;
        });
    }
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
    let Some(path) = state.file_path.clone() else {
        return Task::none();
    };

    if let Some(text) = state.search_text.clone() {
        return Task::perform(
            async move {
                tokio::task::spawn_blocking(move || {
                    shosai_core::search::search_pages(&text, &query)
                })
                .await
                .unwrap_or_default()
            },
            move |results| Message::SearchPerformed {
                tab_id,
                document_generation,
                query_generation,
                results,
            },
        );
    }

    if state.search_loading {
        return Task::none();
    }
    state.search_loading = true;

    Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                let pages = match path
                    .extension()
                    .and_then(|extension| extension.to_str())
                    .map(str::to_ascii_lowercase)
                    .as_deref()
                {
                    Some("pdf") => PdfDoc::open(&path)
                        .and_then(|document| document.page_texts())
                        .unwrap_or_default(),
                    Some("epub") => EpubDoc::open(&path)
                        .map(|document| shosai_core::search::extract_epub_text(&document))
                        .unwrap_or_default(),
                    _ => Vec::new(),
                };
                Arc::new(pages)
            })
            .await
            .unwrap_or_else(|_| Arc::new(Vec::new()))
        },
        move |text| Message::SearchTextExtracted {
            tab_id,
            document_generation,
            text,
        },
    )
}

fn navigate_to_current_search_result(
    state: &mut State,
    previous_highlights: &[SearchHighlight],
) -> Task<Message> {
    let target = if let Some(result) = state.search_results.get(state.search_current) {
        let target_page = result.page;
        if matches!(state.document, Some(OpenDocument::Epub(_))) {
            state.epub_offset = result.offset;
        }
        if target_page != state.current_page && target_page < state.total_pages {
            state.current_page = target_page;
            state.epub_page = 0;
            state.page_input = format!("{}", state.current_page + 1);
            save_reading_state(state);
        }
        Some((target_page, result.offset))
    } else {
        None
    };
    if uses_paginated_epub_layout(state) {
        if let Some((chapter, offset)) = target {
            state.epub_page = epub_page_for_location(state, chapter, offset);
            sync_epub_location(state);
            state.epub_offset = offset;
            save_reading_state(state);
        }
        return Task::none();
    }
    if matches!(state.document, Some(OpenDocument::Pdf(_)))
        && (state.reading_mode == ReadingMode::Continuous
            || previous_highlights != current_page_search_highlights(state))
    {
        if state.reading_mode == ReadingMode::Continuous {
            invalidate_continuous_rasters(state);
        }
        refresh_content(state)
    } else {
        content_navigation_task(state)
    }
}

fn epub_page_for_location(state: &State, chapter: usize, offset: usize) -> usize {
    state
        .epub_pages
        .iter()
        .enumerate()
        .filter(|(_, page)| {
            page.chapter == chapter
                && page
                    .nodes
                    .first()
                    .is_none_or(|node| node.text_offset <= offset)
        })
        .map(|(index, _)| index)
        .next_back()
        .or_else(|| {
            state
                .epub_pages
                .iter()
                .position(|page| page.chapter == chapter)
        })
        .unwrap_or(0)
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
    let main_content = reader_surface(state, compact);
    let body: Element<'_, Message> = if state.show_bookmarks_panel {
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

    if state.show_reader_settings {
        layout = layout.push(reader_settings(state, compact));
    }

    if state.show_reader_more {
        layout = layout.push(reader_more_panel(state, compact));
    }

    if state.show_search_bar {
        layout = layout.push(search_bar(state, compact));
    }

    if let Some(error) = &state.open_error {
        layout = layout.push(
            container(
                text(error)
                    .size(13)
                    .color(iced::Color::from_rgb8(0xA5, 0x43, 0x43)),
            )
            .padding([7, 14])
            .width(Length::Fill)
            .style(app_theme::reader_alert),
        );
    }

    layout = layout.push(body).push(status_bar(state));

    layout.width(Length::Fill).height(Length::Fill).into()
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
    button(text(label).size(if compact { 28 } else { 36 }))
        .on_press_maybe(message)
        .padding([12, if compact { 8 } else { 16 }])
        .height(Length::Fill)
        .style(app_theme::reader_edge_button)
}

fn tabs_view(state: &State) -> Element<'_, Message> {
    let mut tabs = row![].spacing(3).padding([5, 10]);
    for (index, tab) in state.tabs.iter().enumerate() {
        let name = tab
            .file_path
            .file_name()
            .map(|name| name.to_string_lossy())
            .unwrap_or_default();
        let selected = state.active_tab == Some(index);
        tabs = tabs.push(
            container(
                row![
                    button(text(truncate_reader_label(&name, 34)).size(12))
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
            format!("Page {first} · {percentage}%")
        } else {
            format!("Pages {first}–{last} · {percentage}%")
        }
    } else if state.document.is_some() {
        format!(
            "Page {} · {percentage}%",
            state.current_page.saturating_add(1)
        )
    } else {
        "No book open".to_string()
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
    let title = state
        .document
        .as_ref()
        .and_then(|document| match document {
            OpenDocument::Pdf(document) => document.metadata().title,
            OpenDocument::Epub(document) => document.metadata().title,
            OpenDocument::Cbz(document) => document.metadata().title,
        })
        .filter(|title| !title.trim().is_empty())
        .or_else(|| {
            state
                .file_path
                .as_ref()
                .and_then(|path| path.file_stem())
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "Reader".to_string());
    let title = truncate_reader_label(&title, if compact { 24 } else { 58 });
    let actions = row![
        reader_control_button(
            "Contents",
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
            widgets::secondary_button("‹ Library", Some(Message::ShowLibrary),),
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
    let is_pdf_or_cbz = matches!(
        state.document,
        Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
    );
    let is_epub = matches!(state.document, Some(OpenDocument::Epub(_)));
    let mut reading = row![].spacing(5).align_y(iced::Alignment::Center);
    let mode_label = match state.reading_mode {
        ReadingMode::Paginated => "Paginated",
        ReadingMode::Continuous => "Continuous",
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
                text(state.zoom.label())
                    .size(12)
                    .width(70)
                    .color(app_theme::TEXT_MUTED),
            )
            .push(reader_control_button("+", Some(Message::ZoomIn), false))
            .push(reader_control_button(
                if compact { "Width" } else { "Fit width" },
                Some(Message::SetZoomFitWidth),
                state.zoom == ZoomMode::FitWidth,
            ))
            .push(reader_control_button(
                if compact { "Page" } else { "Fit page" },
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
                state.theme.label(),
                Some(Message::CycleTheme),
                false,
            ));
    }

    container(
        scrollable(
            row![
                text(if compact {
                    "Reading"
                } else {
                    "Reading appearance"
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

fn reader_more_panel(state: &State, compact: bool) -> Element<'_, Message> {
    let total = if uses_paginated_epub_layout(state) {
        state.epub_pages.len()
    } else {
        state.total_pages
    };
    let location = row![
        text_input("Page", &state.page_input)
            .on_input(Message::PageInputChanged)
            .on_submit(Message::GoToPage)
            .padding([7, 8])
            .width(64),
        text(format!("of {total}"))
            .size(12)
            .color(app_theme::TEXT_MUTED),
    ]
    .spacing(6)
    .align_y(iced::Alignment::Center);

    let mut actions = row![
        reader_control_button(
            if state.current_page_bookmarked {
                "★ Saved"
            } else {
                "☆ Bookmark"
            },
            state.document.as_ref().map(|_| Message::ToggleBookmark),
            state.current_page_bookmarked,
        ),
        reader_control_button("Open book", Some(Message::OpenFile), false),
    ]
    .spacing(5)
    .align_y(iced::Alignment::Center);
    if state.document.is_some() && !matches!(state.document, Some(OpenDocument::Cbz(_))) {
        actions = actions.push(reader_control_button(
            "Search",
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
            text("Contents").size(18),
            text("Chapters and saved places")
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
        panel = panel.push(text("Chapters").size(12).color(app_theme::TEXT_MUTED));
        for (index, chapter) in document.content.chapters.iter().enumerate() {
            let title = chapter
                .title
                .clone()
                .filter(|title| !title.trim().is_empty())
                .unwrap_or_else(|| format!("Chapter {}", index + 1));
            panel = panel.push(
                button(text(truncate_reader_label(&title, 38)).size(12))
                    .on_press(Message::GoToBookmark(index, None))
                    .padding([6, 8])
                    .width(Length::Fill)
                    .style(app_theme::bookmark_link),
            );
        }
    }

    panel = panel.push(
        text(format!("Bookmarks · {}", state.bookmarks.len()))
            .size(12)
            .color(app_theme::TEXT_MUTED),
    );

    if state.bookmarks.is_empty() {
        panel = panel.push(
            container(
                column![
                    text("No bookmarks yet").size(15),
                    text("Save a page to keep it close at hand.")
                        .size(12)
                        .color(app_theme::TEXT_MUTED),
                ]
                .spacing(5),
            )
            .padding([18, 4]),
        );
    } else {
        for bm in &state.bookmarks {
            let title = bm
                .title
                .clone()
                .unwrap_or_else(|| format!("Pg {}", bm.page + 1));

            let is_editing = state.editing_note_id == Some(bm.id);

            let mut entry_col = column![].spacing(4);

            // Header row: title + page + delete button
            let header = row![
                button(text(title).size(12))
                    .on_press(Message::GoToBookmark(bm.page, bm.location_offset))
                    .padding([4, 6])
                    .style(app_theme::bookmark_link),
                iced::widget::Space::new().width(Length::Fill),
                text(format!("p.{}", bm.page + 1))
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
                let input = text_input("Add a note...", &state.editing_note_text)
                    .on_input(Message::EditNoteChanged)
                    .on_submit(Message::SaveNote)
                    .size(12)
                    .padding(8)
                    .width(Length::Fill);
                entry_col = entry_col.push(input);
                entry_col = entry_col.push(
                    row![
                        reader_control_button("Save", Some(Message::SaveNote), true),
                        reader_control_button("Cancel", Some(Message::CancelEditNote), false),
                    ]
                    .spacing(5),
                );
            } else {
                if let Some(note) = &bm.note {
                    entry_col =
                        entry_col.push(text(note.clone()).size(11).color(app_theme::TEXT_MUTED));
                }
                let edit_label = if bm.note.is_some() {
                    "Edit note"
                } else {
                    "Add note"
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
            "Export as Markdown",
            Some(Message::ExportBookmarks),
        ));
    }

    container(scrollable(panel).height(Length::Fill))
        .width(width)
        .height(Length::Fill)
        .style(app_theme::bookmarks_panel)
        .into()
}

fn search_bar(state: &State, compact: bool) -> Element<'_, Message> {
    let input = text_input("Search in document...", &state.search_query)
        .id(search_input_id())
        .on_input(Message::SearchQueryChanged)
        .on_submit(Message::SearchNext)
        .padding([8, 10])
        .width(Length::Fill);

    let result_info = if state.search_results.is_empty() {
        if state.search_query.is_empty() {
            String::new()
        } else {
            "No results".to_string()
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
        return center(text(error).size(16))
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
        None => welcome_view(),
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
                    image(handle)
                        .width(Length::Fixed(rendered.width as f32))
                        .height(Length::Fixed(rendered.height as f32))
                        .into()
                } else {
                    let page_height = match &state.document {
                        Some(OpenDocument::Pdf(doc)) => doc.page_size(index).ok(),
                        Some(OpenDocument::Cbz(doc)) => doc.page_size(index).ok(),
                        _ => None,
                    }
                    .map(|(_, height)| height * state.zoom.scale())
                    .unwrap_or(600.0);
                    center(text("Rendering...")).height(page_height).into()
                };
                let page = container(
                    column![text(format!("Page {}", index + 1)).size(12), content]
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
            let mut chapters = column![].spacing(32).padding(20).width(Length::Fill);
            for (chapter_index, nodes) in state.continuous_chapters.iter().enumerate() {
                let mut chapter = column![].spacing(state.font_size * state.line_spacing);
                if let Some(title) = doc
                    .chapter(chapter_index)
                    .and_then(|chapter| chapter.title.as_ref())
                    .filter(|title| !content_starts_with_heading(nodes, title))
                {
                    chapter = chapter.push(
                        text(title.clone())
                            .size(state.font_size * 1.5)
                            .color(state.theme.text_color()),
                    );
                }
                let highlights = search_highlight_models_for_page(state, chapter_index);
                let mut text_offset = 0;
                for node in nodes {
                    chapter = chapter.push(render_content_node(
                        node,
                        state.font_size,
                        state.theme.text_color(),
                        &state.epub_image_handles,
                        false,
                        text_offset,
                        &highlights,
                    ));
                    text_offset += content_node_text_len(node) + 1;
                }
                chapters = chapters.push(
                    sensor(
                        container(chapter.width(Length::Fill))
                            .id(continuous_item_id(tab_id, activation, chapter_index))
                            .width(Length::Fill),
                    )
                    .key(chapter_index)
                    .on_show(move |_| Message::ContinuousItemVisibility {
                        tab_id,
                        activation,
                        page: chapter_index,
                        visible: true,
                    })
                    .on_hide(Message::ContinuousItemVisibility {
                        tab_id,
                        activation,
                        page: chapter_index,
                        visible: false,
                    }),
                );
            }
            chapters =
                chapters.push(iced::widget::Space::new().height(state.continuous_tail_extent));
            let content = container(chapters)
                .max_width(800)
                .width(Length::Fill)
                .center_x(Length::Fill);
            let background = state.theme.background();
            container(
                scrollable(content)
                    .id(continuous_scroll_id(tab_id, activation))
                    .on_scroll(move |viewport| Message::ContinuousScrolled {
                        tab_id,
                        activation,
                        offset: viewport.absolute_offset().y,
                    })
                    .width(Length::Fill)
                    .height(Length::Fill),
            )
            .style(move |_| container::Style {
                background: Some(iced::Background::Color(background)),
                ..Default::default()
            })
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
        }
        None => welcome_view(),
    }
}

fn pdf_page_view(state: &State) -> Element<'_, Message> {
    let pages = displayed_paginated_raster_pages(state);
    if pages.is_empty() {
        return center(text("Rendering...").size(16))
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
    let mut spread = row![].spacing(PAGE_GUTTER).padding(20);
    for page in pages {
        let rendered = rendered_for(page);
        let rendered_width = rendered.map_or(0.0, |(rendered, _)| rendered.width as f32);
        let content: Element<'_, Message> = if let Some((rendered, handle)) = rendered {
            match state.zoom {
                ZoomMode::Manual(_) | ZoomMode::FitWidth => image(&handle.0)
                    .width(Length::Fixed(rendered.width as f32))
                    .height(Length::Fixed(rendered.height as f32))
                    .into(),
                ZoomMode::FitPage => image(&handle.0)
                    .width(Length::Fill)
                    .height(Length::Fill)
                    .content_fit(iced::ContentFit::Contain)
                    .into(),
            }
        } else {
            center(text(format!("Rendering page {}...", page + 1))).into()
        };
        let page_container = match state.zoom {
            ZoomMode::FitPage => container(content)
                .width(Length::FillPortion(1))
                .height(Length::Fill)
                .center_x(Length::Fill)
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

fn epub_chapter_view(state: &State) -> Element<'_, Message> {
    let font_size = state.font_size;
    let text_color = state.theme.text_color();
    let line_gap = state.font_size * state.line_spacing;
    let bg = state.theme.background();
    let mut spread = row![].spacing(PAGE_GUTTER).height(Length::Fill);
    let visible_pages = epub_visible_pages(state);
    let text_width = epub_page_size(state).width;

    for (visible_index, page_index) in visible_pages.iter().enumerate() {
        let epub_page = &state.epub_pages[*page_index];
        let highlights = search_highlight_models_for_page(state, epub_page.chapter);
        let image_only = matches!(
            epub_page.nodes.as_slice(),
            [EpubPageNode {
                node: ContentNode::Image { .. },
                ..
            }]
        );
        let mut page = column![].spacing(line_gap).width(Length::Fill);
        if let Some(title) = &epub_page.title {
            page = page.push(text(title.clone()).size(font_size * 1.5).color(text_color));
        }
        for page_node in &epub_page.nodes {
            page = page.push(render_content_node(
                &page_node.node,
                font_size,
                text_color,
                &state.epub_image_handles,
                true,
                page_node.text_offset,
                &highlights,
            ));
        }
        if !image_only {
            page = page.push(iced::widget::Space::new().height(Length::Fill));
        }
        page = page.push(
            text(format!("{}", page_index + 1))
                .size(EPUB_PAGE_NUMBER_SIZE)
                .color(iced::Color {
                    a: 0.55,
                    ..text_color
                }),
        );
        let mut page_content = container(page).width(Length::Fill).height(Length::Fill);
        if !image_only {
            page_content = page_content.max_width(text_width);
        }
        let content_alignment = if epub_uses_spread(state) {
            if visible_index == 0 {
                iced::Alignment::End
            } else {
                iced::Alignment::Start
            }
        } else {
            iced::Alignment::Center
        };
        spread = spread.push(
            container(page_content)
                .padding(20)
                .width(Length::FillPortion(1))
                .height(Length::Fill)
                .align_x(content_alignment)
                .style(move |_| container::Style {
                    background: Some(iced::Background::Color(bg)),
                    ..Default::default()
                }),
        );
    }
    if epub_uses_spread(state) && visible_pages.len() == 1 {
        spread = spread.push(container(iced::widget::Space::new()).width(Length::FillPortion(1)));
    }

    container(spread)
        .padding(20)
        .style(move |_theme| container::Style {
            background: Some(iced::Background::Color(bg)),
            ..Default::default()
        })
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn content_starts_with_heading(nodes: &[ContentNode], title: &str) -> bool {
    nodes.first().is_some_and(
        |node| matches!(node, ContentNode::Heading { text, .. } if text.trim() == title.trim()),
    )
}

fn render_content_node<'a>(
    node: &ContentNode,
    font_size: f32,
    text_color: iced::Color,
    image_handles: &HashMap<String, EpubImageHandle>,
    fill_images: bool,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    match node {
        ContentNode::Heading {
            level,
            text: t,
            style,
        } => {
            let base_size = match level {
                1 => font_size * 2.0,
                2 => font_size * 1.6,
                3 => font_size * 1.3,
                4 => font_size * 1.1,
                _ => font_size,
            };
            let size = style
                .font_size_multiplier
                .map(|m| base_size * m)
                .unwrap_or(base_size);
            let align = node_style_to_alignment(style);
            let heading = render_highlighted_text(t, text_offset, size, text_color, highlights);
            container(heading).width(Length::Fill).align_x(align).into()
        }

        ContentNode::Paragraph(spans, style) => {
            let size = style
                .font_size_multiplier
                .map(|m| font_size * m)
                .unwrap_or(font_size);
            let align = node_style_to_alignment(style);
            let rendered = render_spans(spans, size, text_color, text_offset, highlights);
            let mut c = container(rendered).width(Length::Fill).align_x(align);
            if let Some(margin) = style.margin_left_em {
                c = c.padding(iced::Padding {
                    left: margin * font_size,
                    ..iced::Padding::ZERO
                });
            }
            c.into()
        }

        ContentNode::BlockQuote { children, style } => {
            let mut col = column![].spacing(EPUB_BLOCKQUOTE_SPACING);
            let mut child_offset = text_offset;
            for child in children {
                col = col.push(render_content_node(
                    child,
                    font_size,
                    text_color,
                    image_handles,
                    fill_images,
                    child_offset,
                    highlights,
                ));
                child_offset += content_node_text_len(child) + 1;
            }
            let margin = style.margin_left_em.unwrap_or(1.0) * font_size;
            container(col)
                .width(Length::Fill)
                .padding(iced::Padding {
                    left: margin,
                    ..iced::Padding::ZERO
                })
                .into()
        }

        ContentNode::UnorderedList(items) => {
            let mut col = column![].spacing(4);
            let mut item_offset = text_offset;
            for item_spans in items {
                col = col.push(render_spans_with_prefix(
                    "  \u{2022} ",
                    item_spans,
                    font_size,
                    text_color,
                    item_offset,
                    highlights,
                ));
                item_offset += spans_text_len(item_spans) + 1;
            }
            col.into()
        }

        ContentNode::OrderedList { items, start } => {
            let mut col = column![].spacing(4);
            let mut item_offset = text_offset;
            for (i, item_spans) in items.iter().enumerate() {
                let num_text = format!("  {}. ", start + i);
                col = col.push(render_spans_with_prefix(
                    &num_text,
                    item_spans,
                    font_size,
                    text_color,
                    item_offset,
                    highlights,
                ));
                item_offset += spans_text_len(item_spans) + 1;
            }
            col.into()
        }

        ContentNode::CodeBlock { code, language } => render_code_block(
            code,
            language.as_deref(),
            font_size,
            text_color,
            text_offset,
            highlights,
        ),

        ContentNode::InlineCode(code_text) => {
            // Render as monospace span inline
            let mono_font = Font {
                family: iced::font::Family::Monospace,
                ..Font::DEFAULT
            };
            render_highlighted_text_with_font(
                code_text,
                text_offset,
                font_size * 0.9,
                text_color,
                mono_font,
                highlights,
            )
        }

        ContentNode::Image { src, alt } => render_epub_image(
            src,
            alt,
            font_size,
            text_color,
            image_handles,
            fill_images,
            text_offset,
            highlights,
        ),

        ContentNode::HorizontalRule => text("───────────────────")
            .size(font_size)
            .color(text_color)
            .into(),
    }
}

/// Render a cached EPUB image, falling back to alt text.
#[allow(clippy::too_many_arguments)]
fn render_epub_image<'a>(
    src: &str,
    alt: &str,
    font_size: f32,
    text_color: iced::Color,
    image_handles: &HashMap<String, EpubImageHandle>,
    fill: bool,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    if let Some(handle) = image_handles.get(src) {
        let mut rendered = image(&handle.0)
            .content_fit(iced::ContentFit::ScaleDown)
            .width(Length::Fill);
        if fill {
            rendered = rendered.height(Length::Fill);
        }
        let mut image_container = container(rendered)
            .width(Length::Fill)
            .center_x(Length::Fill);
        if fill {
            image_container = image_container.height(Length::Fill);
        }
        return image_container.into();
    }

    // Fallback: show alt text placeholder.
    let mut spans: Vec<iced::widget::text::Span<'_, String>> = vec![
        span("[Image: ".to_string())
            .size(font_size)
            .color(text_color),
    ];
    spans.extend(
        highlighted_fragments(alt, text_offset, highlights)
            .into_iter()
            .map(|(fragment, highlight)| {
                apply_search_highlight(span(fragment).size(font_size).color(text_color), highlight)
            }),
    );
    spans.push(span("]".to_string()).size(font_size).color(text_color));
    rich_text(spans).into()
}

/// Render a code block with optional syntax highlighting.
fn render_code_block<'a>(
    code: &str,
    language: Option<&str>,
    font_size: f32,
    text_color: iced::Color,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    use shosai_core::highlight;

    let mono_font = Font {
        family: iced::font::Family::Monospace,
        ..Font::DEFAULT
    };
    let code_size = font_size * 0.85;

    // Try syntax highlighting.
    let theme_name = highlight::syntect_theme_for_reader(
        text_color.r > 0.5, // dark theme = light text
    );

    if let Some(highlighted_lines) = highlight::highlight_code(code, language, theme_name) {
        let bg_color = highlight::theme_background(theme_name)
            .map(|(r, g, b)| iced::Color::from_rgb8(r, g, b))
            .unwrap_or(iced::Color::from_rgb(0.15, 0.15, 0.18));

        let mut lines_col = column![].spacing(0);
        let mut code_offset = text_offset;

        for line_spans in &highlighted_lines {
            let rich_spans: Vec<iced::widget::text::Span<'_, Message>> =
                highlighted_code_line(line_spans, &mut code_offset, highlights)
                    .into_iter()
                    .map(|fragment| {
                        let (r, g, b) = fragment.color;
                        let mut font = mono_font;
                        if fragment.bold {
                            font.weight = iced::font::Weight::Bold;
                        }
                        if fragment.italic {
                            font.style = iced::font::Style::Italic;
                        }
                        apply_search_highlight(
                            span(fragment.text)
                                .size(code_size)
                                .font(font)
                                .color(iced::Color::from_rgb8(r, g, b)),
                            fragment.search_highlight,
                        )
                    })
                    .collect();

            lines_col = lines_col.push(rich_text(rich_spans));
        }

        return container(lines_col)
            .padding(12)
            .width(Length::Fill)
            .style(move |_theme| container::Style {
                background: Some(iced::Background::Color(bg_color)),
                border: iced::Border {
                    radius: 4.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            })
            .into();
    }

    // Fallback: plain monospace text.
    container(render_highlighted_text_with_font(
        code,
        text_offset,
        code_size,
        text_color,
        mono_font,
        highlights,
    ))
    .padding(12)
    .width(Length::Fill)
    .style(move |_theme| container::Style {
        background: Some(iced::Background::Color(iced::Color::from_rgb(
            0.15, 0.15, 0.18,
        ))),
        border: iced::Border {
            radius: 4.0.into(),
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}

#[derive(Debug, PartialEq)]
struct HighlightedCodeFragment {
    text: String,
    color: (u8, u8, u8),
    bold: bool,
    italic: bool,
    search_highlight: Option<bool>,
}

fn highlighted_code_line(
    line: &[shosai_core::highlight::HighlightSpan],
    code_offset: &mut usize,
    highlights: &[SearchHighlight],
) -> Vec<HighlightedCodeFragment> {
    let mut fragments = Vec::new();
    for syntax_span in line {
        fragments.extend(
            highlighted_fragments(&syntax_span.text, *code_offset, highlights)
                .into_iter()
                .map(|(text, search_highlight)| HighlightedCodeFragment {
                    text,
                    color: syntax_span.color,
                    bold: syntax_span.bold,
                    italic: syntax_span.italic,
                    search_highlight,
                }),
        );
        *code_offset += syntax_span.text.chars().count();
    }
    fragments
}

fn node_style_to_alignment(
    style: &shosai_core::epub::render::NodeStyle,
) -> iced::alignment::Horizontal {
    match style.text_align {
        Some(shosai_core::epub::style::TextAlignment::Center) => {
            iced::alignment::Horizontal::Center
        }
        Some(shosai_core::epub::style::TextAlignment::Right) => iced::alignment::Horizontal::Right,
        _ => iced::alignment::Horizontal::Left,
    }
}

const LINK_COLOR: iced::Color = iced::Color {
    r: 0.2,
    g: 0.5,
    b: 0.9,
    a: 1.0,
};

const SEARCH_HIGHLIGHT_COLOR: iced::Color = iced::Color {
    r: 1.0,
    g: 0.88,
    b: 0.28,
    a: 0.7,
};

const CURRENT_SEARCH_HIGHLIGHT_COLOR: iced::Color = iced::Color {
    r: 1.0,
    g: 0.55,
    b: 0.18,
    a: 0.82,
};

fn render_spans<'a>(
    spans: &[shosai_core::epub::render::TextSpan],
    font_size: f32,
    text_color: iced::Color,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    render_spans_with_prefix("", spans, font_size, text_color, text_offset, highlights)
}

fn render_spans_with_prefix<'a>(
    prefix: &str,
    spans: &[shosai_core::epub::render::TextSpan],
    font_size: f32,
    text_color: iced::Color,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    let mut rich_spans: Vec<iced::widget::text::Span<'a, String>> = Vec::new();
    if !prefix.is_empty() {
        rich_spans.push(span(prefix.to_string()).size(font_size).color(text_color));
    }

    let mut span_offset = text_offset;
    for text_span in spans {
        for (fragment, highlight) in highlighted_fragments(&text_span.text, span_offset, highlights)
        {
            rich_spans.push(styled_epub_span(
                text_span, fragment, font_size, text_color, highlight,
            ));
        }
        span_offset += text_span.text.chars().count();
    }

    rich_text(rich_spans)
        .on_link_click(Message::LinkClicked)
        .into()
}

fn styled_epub_span<'a>(
    text_span: &shosai_core::epub::render::TextSpan,
    fragment: String,
    font_size: f32,
    text_color: iced::Color,
    highlight: Option<bool>,
) -> iced::widget::text::Span<'a, String> {
    let is_link = text_span.link.is_some();
    let family = if text_span.monospace {
        iced::font::Family::Monospace
    } else {
        iced::font::Family::default()
    };
    let font = Font {
        family,
        weight: if text_span.bold {
            iced::font::Weight::Bold
        } else {
            iced::font::Weight::Normal
        },
        style: if text_span.italic {
            iced::font::Style::Italic
        } else {
            iced::font::Style::Normal
        },
        ..Font::DEFAULT
    };
    let color = if is_link { LINK_COLOR } else { text_color };
    let mut rendered = span(fragment).size(font_size).font(font).color(color);
    if is_link {
        rendered = rendered.underline(true);
    }
    if let Some(href) = &text_span.link {
        rendered = rendered.link(href.clone());
    }
    apply_search_highlight(rendered, highlight)
}

fn render_highlighted_text<'a>(
    value: &str,
    text_offset: usize,
    font_size: f32,
    text_color: iced::Color,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    render_highlighted_text_with_font(
        value,
        text_offset,
        font_size,
        text_color,
        Font::DEFAULT,
        highlights,
    )
}

fn render_highlighted_text_with_font<'a>(
    value: &str,
    text_offset: usize,
    font_size: f32,
    text_color: iced::Color,
    font: Font,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    let spans = highlighted_fragments(value, text_offset, highlights)
        .into_iter()
        .map(|(fragment, highlight)| {
            apply_search_highlight(
                span(fragment).size(font_size).font(font).color(text_color),
                highlight,
            )
        })
        .collect::<Vec<iced::widget::text::Span<'a, String>>>();
    rich_text(spans).into()
}

fn apply_search_highlight<'a, Link>(
    text_span: iced::widget::text::Span<'a, Link>,
    highlight: Option<bool>,
) -> iced::widget::text::Span<'a, Link> {
    match highlight {
        Some(true) => text_span.background(CURRENT_SEARCH_HIGHLIGHT_COLOR),
        Some(false) => text_span.background(SEARCH_HIGHLIGHT_COLOR),
        None => text_span,
    }
}

fn highlighted_fragments(
    value: &str,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Vec<(String, Option<bool>)> {
    let characters = value.chars().collect::<Vec<_>>();
    let text_end = text_offset + characters.len();
    let mut boundaries = vec![text_offset, text_end];

    for highlight in highlights {
        if highlight.start < text_end && highlight.end > text_offset {
            boundaries.push(highlight.start.max(text_offset));
            boundaries.push(highlight.end.min(text_end));
        }
    }
    boundaries.sort_unstable();
    boundaries.dedup();

    boundaries
        .windows(2)
        .filter(|range| range[0] < range[1])
        .map(|range| {
            let start = range[0];
            let end = range[1];
            let highlight = highlights
                .iter()
                .find(|highlight| highlight.start <= start && highlight.end >= end)
                .map(|highlight| highlight.current);
            (
                characters[start - text_offset..end - text_offset]
                    .iter()
                    .collect(),
                highlight,
            )
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

    if compact {
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
    }
}

fn library_header(state: &State, compact: bool) -> Element<'_, Message> {
    let search_input = text_input("Search by title or author...", &state.library_search)
        .id(library_search_input_id())
        .on_input(Message::LibrarySearchChanged)
        .padding([10, 12])
        .width(Length::Fill);
    let search = container(search_input).width(Length::Fill).max_width(380);
    let import_message = state.library.is_some().then_some(Message::ImportFile);
    let folder_message = state.library.is_some().then_some(Message::ImportDirectory);
    let actions = row![
        widgets::secondary_button("Scan folder", folder_message),
        widgets::primary_button("＋ Add book", import_message),
    ]
    .spacing(8)
    .align_y(iced::Alignment::Center);

    let content: Element<'_, Message> = if compact {
        column![
            row![
                column![
                    text("Library").size(26),
                    text("Your private reading room")
                        .size(12)
                        .color(app_theme::TEXT_MUTED),
                ]
                .spacing(2),
                iced::widget::Space::new().width(Length::Fill),
                actions,
            ]
            .align_y(iced::Alignment::Center),
            search,
        ]
        .spacing(12)
        .into()
    } else {
        row![
            column![
                text("Library").size(26),
                text("Your private reading room")
                    .size(12)
                    .color(app_theme::TEXT_MUTED),
            ]
            .spacing(2),
            iced::widget::Space::new().width(Length::Fill),
            search,
            actions,
        ]
        .spacing(16)
        .align_y(iced::Alignment::Center)
        .into()
    };

    let activity_active = library_activity_active(state);
    let header = column![
        container(content).padding([16, 20]).width(Length::Fill),
        widgets::activity_bar(activity_active, state.library_activity_progress),
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

fn library_sidebar(state: &State) -> Element<'_, Message> {
    let content = column![
        text("COLLECTION").size(11).color(app_theme::TEXT_MUTED),
        widgets::navigation_button(
            "All books",
            state.library_filter.is_none(),
            Message::LibraryFilterChanged(None),
        ),
        widgets::navigation_button(
            "EPUB",
            state.library_filter == Some(shosai_core::library::BookFormat::Epub),
            Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Epub)),
        ),
        widgets::navigation_button(
            "PDF",
            state.library_filter == Some(shosai_core::library::BookFormat::Pdf),
            Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Pdf)),
        ),
    ]
    .spacing(6)
    .padding([22, 14]);

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
                "All",
                state.library_filter.is_none(),
                Message::LibraryFilterChanged(None),
            ),
            widgets::navigation_button(
                "EPUB",
                state.library_filter == Some(shosai_core::library::BookFormat::Epub),
                Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Epub)),
            ),
            widgets::navigation_button(
                "PDF",
                state.library_filter == Some(shosai_core::library::BookFormat::Pdf),
                Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Pdf)),
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
            "Loading library..."
        } else if let Some(error) = &state.storage_error {
            error
        } else if state.library_search.is_empty() && state.library_filter.is_none() {
            "No books in library. Import files to get started."
        } else {
            "No books match your search or filter."
        };

        let heading = if state.library_loading {
            "Loading your library"
        } else if constrained {
            "No matching books"
        } else {
            "A quiet place for every book"
        };
        let mut empty = column![
            text(heading).size(24),
            text(empty_msg).size(14).color(app_theme::TEXT_MUTED),
        ]
        .spacing(14)
        .align_x(iced::Center);
        if !state.library_loading && !constrained && state.storage_error.is_none() {
            empty = empty.push(
                row![
                    widgets::primary_button(
                        "＋ Add your first book",
                        state.library.is_some().then_some(Message::ImportFile),
                    ),
                    widgets::secondary_button(
                        "Scan a folder",
                        state.library.is_some().then_some(Message::ImportDirectory),
                    ),
                ]
                .spacing(8),
            );
        }

        return center(empty)
            .width(Length::Fill)
            .height(Length::Fill)
            .into();
    }

    let cards = state
        .library_books
        .iter()
        .map(render_book_card)
        .collect::<Vec<_>>();
    let book_grid = grid(cards).fluid(220).height(Length::Shrink).spacing(18);
    let mut sections = column![].spacing(16).width(Length::Fill);

    if let Some(book) = continue_reading_book(state) {
        sections = sections
            .push(text("Continue reading").size(18))
            .push(render_continue_card(book))
            .push(iced::widget::Space::new().height(4));
    }

    let section_title = if state.library_search.is_empty() {
        "All books"
    } else {
        "Search results"
    };
    sections = sections.push(text(section_title).size(18)).push(book_grid);

    if state.library_loading && state.library_offset > 0 {
        sections = sections
            .push(center(text("Loading more…").color(app_theme::TEXT_MUTED)).width(Length::Fill));
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
        "All books"
    } else {
        "Search results"
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

fn render_book_card(book: &Book) -> Element<'_, Message> {
    let file_path = book.file_path.clone();
    let cover = render_book_cover(book, Length::Fill, 210.0);
    let title_text = text(book.title.clone())
        .size(13)
        .wrapping(iced::widget::text::Wrapping::WordOrGlyph);
    let author = text(book.author.as_deref().unwrap_or("Unknown author"))
        .size(11)
        .color(app_theme::TEXT_MUTED);
    let format_label = text(book.format.as_str().to_uppercase())
        .size(10)
        .color(app_theme::TEXT_MUTED);
    let percentage = (book.progress.clamp(0.0, 1.0) * 100.0).round() as u32;
    let progress_label = text(if percentage == 0 {
        "Not started".to_string()
    } else {
        format!("{percentage}%")
    })
    .size(10)
    .color(app_theme::TEXT_MUTED);

    let card = column![
        container(cover).style(app_theme::book_cover),
        container(title_text).height(32),
        container(author).height(28),
        iced::widget::Space::new().height(Length::Fill),
        row![
            format_label,
            iced::widget::Space::new().width(Length::Fill),
            progress_label,
        ],
        widgets::reading_progress(book.progress),
    ]
    .spacing(4)
    .height(Length::Fill)
    .width(Length::Fill);

    widgets::book_button(card, Message::OpenBook(file_path))
        .height(330)
        .into()
}

fn render_continue_card(book: &Book) -> Element<'_, Message> {
    let file_path = book.file_path.clone();
    let percentage = (book.progress.clamp(0.0, 1.0) * 100.0).round() as u32;
    let details = column![
        text(book.title.clone()).size(16),
        text(book.author.as_deref().unwrap_or("Unknown author"))
            .size(12)
            .color(app_theme::TEXT_MUTED),
        iced::widget::Space::new().height(Length::Fill),
        text(format!("{percentage}% complete"))
            .size(11)
            .color(app_theme::TEXT_MUTED),
        widgets::reading_progress(book.progress),
    ]
    .spacing(6)
    .height(100)
    .width(Length::Fill);
    let content = row![
        render_book_cover(book, Length::Fixed(72.0), 100.0),
        details,
        text("Continue  ›").size(13).color(app_theme::ACCENT),
    ]
    .spacing(14)
    .align_y(iced::Alignment::Center);

    container(widgets::book_button(content, Message::OpenBook(file_path)))
        .width(Length::Fill)
        .max_width(620)
        .style(app_theme::surface)
        .into()
}

fn render_book_cover(book: &Book, width: Length, height: f32) -> Element<'_, Message> {
    if let Some(ref cover_data) = book.cover
        && let Ok(img) = ::image::load_from_memory(cover_data)
    {
        let rgba = img.to_rgba8();
        let (w, h) = rgba.dimensions();
        let handle = image::Handle::from_rgba(w, h, rgba.into_raw());
        return image(handle)
            .width(width)
            .height(Length::Fixed(height))
            .content_fit(iced::ContentFit::Contain)
            .into();
    }
    cover_placeholder(width, height, &book.title)
}

fn cover_placeholder(width: Length, height: f32, title: &str) -> Element<'_, Message> {
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

fn welcome_view<'a>() -> Element<'a, Message> {
    center(
        column![
            text("Shosai (書斎)").size(32),
            text("Open a PDF, EPUB, or CBZ file to start reading").size(16),
            button("Open File").on_press(Message::OpenFile),
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

pub fn title(state: &State) -> String {
    if let Some(path) = &state.file_path {
        let filename = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        format!("{filename} - Shosai")
    } else {
        "Shosai".to_string()
    }
}

// ---------------------------------------------------------------------------
// Subscription
// ---------------------------------------------------------------------------

pub fn subscription(state: &State) -> Subscription<Message> {
    Subscription::batch([
        keyboard::listen().map(Message::KeyPressed),
        window::events().map(|(id, event)| Message::WindowEvent(id, event)),
        if library_activity_active(state) {
            iced::time::every(LIBRARY_ACTIVITY_TICK).map(|_| Message::LibraryActivityTick)
        } else {
            Subscription::none()
        },
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use iced::advanced::widget::Operation;

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
        let mut operation = ContinuousItemOperation::resolve(1, 0, 3, 500.0);
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
            operation::Outcome::Some((0, _, _))
        ));

        let mut navigation = ContinuousItemOperation::locate(1, 0, 3, 1, 0.0);
        navigation.content_top = operation.content_top;
        navigation.item_bounds = operation.item_bounds;
        navigation.content_height = Some(1000.0);
        navigation.viewport_height = Some(700.0);
        assert!(matches!(
            navigation.finish(),
            operation::Outcome::Some((1, offset, tail_extent))
                if offset == 800.0 && tail_extent == 500.0
        ));
    }

    fn state_with_document(document: OpenDocument) -> State {
        let (mut state, _) = boot();
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
    fn fit_page_scale_keeps_the_complete_spread_in_the_reader() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
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
    fn zoom_step_starts_from_the_actual_fitted_scale() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let total_pages = cbz.page_count();
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
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;

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
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.total_pages = total_pages;
        state.zoom = ZoomMode::FitPage;
        let scale = paginated_raster_scale(&state, &[0, 1]);
        for page in [0, 1] {
            cache_rendered_page(
                &mut state,
                PageCacheKey {
                    page,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
                RenderedPage {
                    width: 10,
                    height: 20,
                    pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
                },
            );
        }

        assert!(show_cached_paginated_spread(&mut state));
        assert_eq!(prefetch_next_paginated_spread(&state).units(), 1);
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
            cache_rendered_page(
                &mut state,
                PageCacheKey {
                    page,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
                RenderedPage {
                    width: 10,
                    height: 20,
                    pixels: bytes::Bytes::from(vec![0; 10 * 20 * 4]),
                },
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
        let scale = paginated_raster_scale(&state, &[0, 1]);
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
                key: PageCacheKey {
                    page: 0,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
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
                key: PageCacheKey {
                    page: 1,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
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

        assert_eq!(task.units(), 1);
        assert_eq!(displayed_paginated_raster_pages(&state), vec![0, 1]);

        let scale = paginated_raster_scale(&state, &[2]);
        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation,
                key: PageCacheKey {
                    page: 2,
                    scale_bits: scale.to_bits(),
                    highlights: Vec::new(),
                },
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
        install_document(&mut state, path, OpenDocument::Cbz(Arc::new(cbz)));

        assert_eq!(state.current_page, 1);
        assert_eq!(state.zoom, ZoomMode::FitPage);
    }

    fn test_book(id: i64) -> Book {
        Book {
            id,
            title: format!("Book {id}"),
            author: None,
            format: shosai_core::library::BookFormat::Epub,
            file_path: format!("/book-{id}.epub"),
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
    fn continuous_epub_mode_builds_every_chapter() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let chapter_count = epub.chapter_count();
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.total_pages = chapter_count;

        let _ = update(&mut state, Message::ToggleReadingMode);

        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        assert_eq!(state.continuous_chapters.len(), chapter_count);
        assert!(
            state
                .continuous_chapters
                .iter()
                .all(|chapter| !chapter.is_empty())
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

        assert_eq!(task.units(), CONTINUOUS_PAGE_CACHE_CAPACITY);
        assert_eq!(
            state.continuous_pending.len()
                + state
                    .continuous_pages
                    .iter()
                    .filter(|page| page.is_some())
                    .count(),
            CONTINUOUS_PAGE_CACHE_CAPACITY
        );
        assert_eq!(reconcile_continuous_rasters(&mut state).units(), 0);
    }

    #[test]
    fn stale_continuous_completion_releases_its_pending_slot() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        state.continuous_visible.insert(0);
        let request = ContinuousRequest {
            id: 1,
            generation: 1,
        };
        state.continuous_pending.insert(0, request);
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
    fn old_continuous_completion_cannot_remove_a_newer_request() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));
        state.reading_mode = ReadingMode::Continuous;
        state.continuous_pages = vec![None];
        let old_request = ContinuousRequest {
            id: 1,
            generation: 1,
        };
        let new_request = ContinuousRequest {
            id: 2,
            generation: 1,
        };
        state.continuous_pending.insert(0, new_request);

        let _ = update(
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

        assert_eq!(state.continuous_pending.get(&0), Some(&new_request));
        assert!(state.continuous_pages[0].is_none());
    }

    #[test]
    fn continuous_completion_is_saved_while_its_tab_is_inactive() {
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
        };
        state.continuous_pending.insert(0, request);
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
        assert_eq!(
            state.tabs[0].continuous_pages[0]
                .as_ref()
                .map(|page| page.width),
            Some(7)
        );
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
                bookmarks: vec![Bookmark {
                    id: 1,
                    file_path: "first.epub".to_string(),
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

    #[tokio::test]
    async fn library_refresh_keeps_visible_books_until_the_replacement_is_ready() {
        let directory = tempfile::tempdir().unwrap();
        let store = ReadingStateStore::open_at_async(&directory.path().join("state.db"))
            .await
            .unwrap();
        let (mut state, _) = boot();
        state.library = Some(Library::new(store.pool().clone()));
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
        state.library = Some(Library::new(store.pool().clone()));
        state.library_books.push(test_book(1));
        state.library_loading = false;
        let generation = state.library_generation;

        let task = update(
            &mut state,
            Message::LibraryFilterChanged(Some(shosai_core::library::BookFormat::Pdf)),
        );

        assert!(task.units() > 0);
        assert!(state.library_loading);
        assert_eq!(state.library_generation, generation.wrapping_add(1));
        assert_eq!(state.library_books.len(), 1);
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
    fn empty_library_index_clears_books_from_the_previous_filter() {
        let (mut state, _) = boot();
        state.library_generation = 2;
        state.library_books.push(test_book(1));
        state.library_loading = true;

        let _ = update(
            &mut state,
            Message::LibraryIndexLoaded {
                generation: 2,
                ids: Vec::new(),
            },
        );

        assert!(state.library_books.is_empty());
        assert!(!state.library_loading);
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
        state.library_book_ids = Arc::new(vec![1, 2]);
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
    fn opening_a_book_while_storage_initializes_is_queued() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.storage_initializing = true;

        let task = update(&mut state, Message::OpenBook("queued.epub".to_string()));

        assert_eq!(task.units(), 0);
        assert!(matches!(
            state.pending_open,
            Some(PendingOpen::LibraryBook(ref path)) if path == &PathBuf::from("queued.epub")
        ));
        assert!(state.file_path.is_none());
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
            Some(PendingOpen::FileSelected(ref path)) if path == &PathBuf::from("selected.epub")
        ));
    }

    #[test]
    fn failed_storage_keeps_import_actions_disabled() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.storage_error = Some("storage failed".to_string());

        let task = update(&mut state, Message::ImportFile);

        assert_eq!(task.units(), 0);
        assert!(state.library.is_none());
        assert_eq!(state.storage_error.as_deref(), Some("storage failed"));
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
            Message::SearchTextExtracted {
                tab_id: 1,
                document_generation: 1,
                text: Arc::new(vec!["stale text".to_string()]),
            },
        );
        let _ = update(
            &mut state,
            Message::SearchPerformed {
                tab_id: 1,
                document_generation: 2,
                query_generation: 1,
                results: vec![SearchMatch {
                    page: 0,
                    offset: 0,
                    length: 5,
                    context: "stale".to_string(),
                }],
            },
        );

        assert!(state.search_loading);
        assert!(state.search_text.is_none());
        assert!(state.search_results.is_empty());
    }

    #[test]
    fn stale_page_renders_do_not_replace_the_latest_request() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));

        let first_task = refresh_content(&mut state);
        let first_generation = state.render_generation;
        state.zoom = ZoomMode::Manual(1.25);
        let second_task = refresh_content(&mut state);
        let second_generation = state.render_generation;

        assert!(first_task.units() > 0);
        assert!(second_task.units() > 0);
        assert!(second_generation > first_generation);

        let stale_page = RenderedPage {
            width: 10,
            height: 10,
            pixels: bytes::Bytes::from(vec![0; 400]),
        };
        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation: first_generation,
                key: PageCacheKey {
                    page: 0,
                    scale_bits: 1.0_f32.to_bits(),
                    highlights: Vec::new(),
                },
                result: Ok(stale_page),
            },
        );

        assert!(state.rendered_page.is_none());

        let latest_page = RenderedPage {
            width: 20,
            height: 20,
            pixels: bytes::Bytes::from(vec![0; 1600]),
        };
        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation: second_generation,
                key: PageCacheKey {
                    page: 0,
                    scale_bits: 1.25_f32.to_bits(),
                    highlights: Vec::new(),
                },
                result: Ok(latest_page),
            },
        );

        assert_eq!(
            state.rendered_page.as_ref().map(|page| page.width),
            Some(20)
        );
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
    fn failed_open_preserves_the_active_document_and_render_state() {
        let cbz = CbzDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.cbz").to_vec(),
        )
        .expect("fixture should be a valid CBZ");
        let mut state = state_with_document(OpenDocument::Cbz(Arc::new(cbz)));

        let render_task = refresh_content(&mut state);
        let old_generation = state.render_generation;
        let old_document = state.document.clone();
        let open_task = open_document(&mut state, PathBuf::from("unsupported.txt"));

        assert!(render_task.units() > 0);
        assert_eq!(open_task.units(), 0);
        assert_eq!(state.render_generation, old_generation);
        assert!(matches!(
            (&state.document, old_document),
            (Some(OpenDocument::Cbz(_)), Some(OpenDocument::Cbz(_)))
        ));
        assert!(
            state
                .open_error
                .as_deref()
                .is_some_and(|error| error.contains("Unsupported"))
        );

        let _ = update(
            &mut state,
            Message::PageRendered {
                tab_id: 1,
                generation: old_generation,
                key: PageCacheKey {
                    page: 0,
                    scale_bits: 1.0_f32.to_bits(),
                    highlights: Vec::new(),
                },
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
    fn epub_refresh_remains_synchronous() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));

        let task = refresh_content(&mut state);

        assert_eq!(task.units(), 0);
        assert!(!state.chapter_content.is_empty());
        assert!(!state.epub_pages.is_empty());
        assert!(state.error.is_none());
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
                    bold: false,
                    italic: false,
                    monospace: false,
                    preserve_whitespace: false,
                    link: None,
                }],
                Default::default(),
            )
        };
        state.epub_pages = vec![
            EpubPage {
                chapter: 0,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("first"),
                    text_offset: 0,
                }],
            },
            EpubPage {
                chapter: 0,
                title: None,
                nodes: vec![EpubPageNode {
                    node: paragraph("second"),
                    text_offset: 5,
                }],
            },
        ];

        assert_eq!(epub_page_for_location(&state, 0, 5), 1);
    }

    #[test]
    fn switching_from_continuous_epub_preserves_the_current_chapter() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        let _ = refresh_content(&mut state);
        assert!(state.epub_pages.iter().any(|page| page.chapter == 1));

        let _ = update(&mut state, Message::ToggleReadingMode);
        assert_eq!(state.reading_mode, ReadingMode::Continuous);
        state.current_page = 1;
        state.epub_page = 0;

        let _ = update(&mut state, Message::ToggleReadingMode);

        assert_eq!(state.reading_mode, ReadingMode::Paginated);
        assert_eq!(state.current_page, 1);
        assert_eq!(state.epub_pages[state.epub_page].chapter, 1);
    }

    #[test]
    fn paginated_epub_navigation_moves_between_horizontal_spreads() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(Arc::new(epub)));
        state.window_size.width = 900.0;
        state.epub_pages = vec![
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
        ];

        assert_eq!(epub_visible_pages(&state), vec![0, 1]);
        assert!(can_turn_epub_page(&state, true));

        let task = turn_epub_page(&mut state, true);

        assert_eq!(task.units(), 0);
        assert_eq!(state.epub_page, 2);
        assert_eq!(state.current_page, 2);
        assert_eq!(epub_visible_pages(&state), vec![2]);
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
    fn rebuilding_the_view_reuses_epub_image_handles() {
        let mut image_bytes = Vec::new();
        ::image::DynamicImage::ImageRgba8(::image::RgbaImage::from_pixel(
            2,
            3,
            ::image::Rgba([1, 2, 3, 255]),
        ))
        .write_to(
            &mut std::io::Cursor::new(&mut image_bytes),
            ::image::ImageFormat::Png,
        )
        .unwrap();
        let resources = HashMap::from([("image.png".to_string(), image_bytes)]);
        let nodes = vec![ContentNode::Image {
            src: "image.png".to_string(),
            alt: String::new(),
        }];
        let mut handles = HashMap::new();

        cache_epub_image_handles(&mut handles, &nodes, &resources);
        let first_id = handles.get("image.png").unwrap().0.id();
        drop(render_content_node(
            &nodes[0],
            16.0,
            iced::Color::BLACK,
            &handles,
            false,
            0,
            &[],
        ));
        cache_epub_image_handles(&mut handles, &nodes, &resources);
        drop(render_content_node(
            &nodes[0],
            16.0,
            iced::Color::BLACK,
            &handles,
            false,
            0,
            &[],
        ));

        assert_eq!(handles.get("image.png").unwrap().0.id(), first_id);
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
    fn search_highlights_split_unicode_text_at_character_offsets() {
        let highlights = [SearchHighlight {
            start: 11,
            end: 13,
            current: true,
        }];

        assert_eq!(
            highlighted_fragments("aé日z", 10, &highlights),
            vec![
                ("a".to_string(), None),
                ("é日".to_string(), Some(true)),
                ("z".to_string(), None),
            ]
        );
    }

    #[test]
    fn code_search_highlights_preserve_syntax_colors() {
        let code = "fn main() {\n    let target = true;\n}";
        let syntax_lines =
            shosai_core::highlight::highlight_code(code, Some("rust"), "base16-ocean.dark")
                .unwrap();
        let target_offset = code.find("target").unwrap();
        let highlights = [SearchHighlight {
            start: target_offset,
            end: target_offset + "target".len(),
            current: true,
        }];
        let mut code_offset = 0;
        let fragments = syntax_lines
            .iter()
            .flat_map(|line| highlighted_code_line(line, &mut code_offset, &highlights))
            .collect::<Vec<_>>();

        assert!(fragments.iter().any(|fragment| {
            fragment.text == "target" && fragment.search_highlight == Some(true)
        }));
        let mut colors = fragments
            .iter()
            .map(|fragment| fragment.color)
            .collect::<Vec<_>>();
        colors.sort_unstable();
        colors.dedup();
        assert!(
            colors.len() > 1,
            "syntax foreground colors must be retained"
        );
    }

    #[test]
    fn rendered_node_lengths_match_search_text_offsets() {
        let nodes = vec![ContentNode::BlockQuote {
            children: vec![
                ContentNode::Heading {
                    level: 2,
                    text: "A heading".to_string(),
                    style: Default::default(),
                },
                ContentNode::OrderedList {
                    items: vec![vec![shosai_core::epub::render::TextSpan {
                        text: "list item".to_string(),
                        bold: true,
                        italic: false,
                        monospace: false,
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
}
