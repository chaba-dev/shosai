use std::path::PathBuf;
use std::sync::Arc;

use iced::{keyboard, window};
use shosai_core::bookmarks::Bookmark;
use shosai_core::document::RenderedPage;
use shosai_core::library::{Book, BookPage};
use shosai_core::search::SearchMatch;

use super::{ContinuousRequest, EpubLayoutKey, EpubPage, InitializedState, PageCacheKey};

#[derive(Debug, Clone)]
pub enum Message {
    Initialized(Result<InitializedState, String>),

    // File
    OpenFile,
    FileSelected(Option<PathBuf>),

    // Navigation
    NextPage,
    PrevPage,
    PageInputChanged(String),
    GoToPage,
    FirstPage,
    LastPage,
    ToggleReadingMode,
    ContinuousScrolled {
        tab_id: u64,
        activation: u64,
        offset: f32,
    },
    ContinuousItemResolved {
        tab_id: u64,
        activation: u64,
        page: usize,
        epub_offset: Option<usize>,
    },
    ContinuousItemVisibility {
        tab_id: u64,
        activation: u64,
        page: usize,
        visible: bool,
    },
    ContinuousNavigationMeasured {
        tab_id: u64,
        activation: u64,
        offset: f32,
        tail_extent: f32,
    },

    // Document tabs
    SelectTab(usize),
    CloseTab(usize),
    NextTab,

    // Zoom (PDF)
    ZoomIn,
    ZoomOut,
    SetZoomFitWidth,
    SetZoomFitPage,

    // EPUB reading controls
    FontSizeUp,
    FontSizeDown,
    CycleTheme,
    ToggleReaderSettings,
    ToggleReaderMore,

    // Links
    LinkClicked(String),

    // Library
    ShowLibrary,
    ShowSettings,
    RefreshLibrary,
    LoadMoreLibrary,
    LibraryIndexLoaded {
        generation: u64,
        ids: Vec<i64>,
    },
    LibraryLoaded {
        generation: u64,
        offset: usize,
        next_offset: usize,
        page: BookPage,
    },
    OpenAddBooks,
    CancelAddBooks,
    ChooseBookFiles,
    ChooseBookFolder,
    AddBookFilesSelected(Vec<PathBuf>),
    AddBookFolderSelected(Option<PathBuf>),
    ClearAddBooksSelection,
    AddSelectedBooks {
        copy: bool,
    },
    BooksAdded(Result<(), String>),
    OpenLibraryBook(i64, String),
    LocateBook(i64),
    RelinkBookSelected(i64, Option<PathBuf>),
    BookRelinked(Result<Book, String>),
    ToggleBookMenu(i64),
    CloseBookMenu,
    RequestRemoveBook(i64),
    CancelRemoveBook,
    RemoveBook(i64),
    BookRemoved {
        id: i64,
        result: Result<(), String>,
    },
    LibrarySearchChanged(String),
    LibraryFilterChanged(Option<shosai_core::library::BookFormat>),
    LibraryActivityTick,
    SelectLanguage(crate::i18n::LanguagePreference),

    // Bookmarks
    ToggleBookmark,
    ToggleBookmarksPanel,
    BookmarksLoaded {
        tab_id: u64,
        file_path: PathBuf,
        book_id: Option<i64>,
        bookmarks: Vec<Bookmark>,
    },
    GoToBookmark(usize, Option<usize>), // page/chapter and EPUB character offset
    StartEditNote(i64, String),
    EditNoteChanged(String),
    SaveNote,
    CancelEditNote,
    DeleteBookmark(i64),
    ExportBookmarks,

    // In-document search
    ToggleSearchBar,
    SearchQueryChanged(String),
    SearchTextExtracted {
        tab_id: u64,
        document_generation: u64,
        text: Arc<Vec<String>>,
    },
    SearchPerformed {
        tab_id: u64,
        document_generation: u64,
        query_generation: u64,
        results: Vec<SearchMatch>,
    },
    SearchNext,
    SearchPrev,
    CloseSearch,

    // Background page rendering
    EpubPaginated {
        tab_id: u64,
        generation: u64,
        layout_key: EpubLayoutKey,
        pages: Arc<Vec<EpubPage>>,
    },
    PageRendered {
        tab_id: u64,
        generation: u64,
        key: PageCacheKey,
        result: Result<RenderedPage, String>,
    },
    ContinuousPageRendered {
        tab_id: u64,
        request: ContinuousRequest,
        page: usize,
        result: Result<RenderedPage, String>,
    },
    RenderContinuousPage {
        tab_id: u64,
        page: usize,
    },

    // Keyboard
    KeyPressed(keyboard::Event),
    WindowEvent(window::Id, window::Event),
    WindowScaleFactorLoaded {
        generation: u64,
        scale_factor: f32,
    },
    PersistWindowGeometry(u64),
    WindowGeometryPersisted,
    ReadingStateFlushed(window::Id),
    PerfFramePresented,
}
