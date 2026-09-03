use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use iced::{keyboard, window};
use shosai_core::bookmarks::Bookmark;
use shosai_core::document::RenderedPage;
use shosai_core::library::{
    Book, BookPage, ImportDiscovery, ImportFailure, ImportReport, PreparedManagedImport,
};
use shosai_core::search::SearchMatch;

use super::{
    ContinuousRequest, DecodedEpubImage, EpubLayoutKey, EpubPage, InitializedState, PageCacheKey,
    RasterImageHandle,
};

#[derive(Debug, Clone)]
pub enum Message {
    Initialized(Result<InitializedState, String>),
    FingerprintBackfillFinished(Result<(), String>),

    // File
    OpenFile,
    FileSelected(Option<PathBuf>),
    DocumentOpened {
        generation: u64,
        path: PathBuf,
        book_id: Option<i64>,
        result: Result<super::OpenDocument, super::AppError>,
    },
    ShowDocumentOpenNotice(u64),

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
    LibraryLoaded {
        generation: u64,
        offset: usize,
        next_offset: usize,
        page: BookPage,
    },
    LibraryCoversLoaded {
        generation: u64,
        offset: usize,
        cover_handles: HashMap<i64, RasterImageHandle>,
    },
    OpenAddBooks,
    CancelAddBooks,
    ChooseBookFiles,
    ChooseBookFolder,
    AddBookFilesSelected {
        generation: u64,
        paths: Vec<PathBuf>,
    },
    AddBookFolderSelected {
        generation: u64,
        path: Option<PathBuf>,
    },
    BooksDiscovered {
        generation: u64,
        discovery: ImportDiscovery,
    },
    AddBooksReviewSearchChanged(String),
    AddBooksReviewScrolled {
        generation: u64,
        revision: u64,
        offset: f32,
        viewport_height: f32,
    },
    ToggleStagedBook(usize, bool),
    SelectAllStagedBooks(bool),
    SelectAddBooksStorage(bool),
    ClearAddBooksSelection,
    ChangeAddBooksStorage,
    AddSelectedBooks,
    ManagedBookPrepared {
        index: usize,
        result: Result<(PathBuf, Arc<PreparedManagedImport>), ImportFailure>,
    },
    BookAddedToBatch(ImportReport),
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
    LibrarySearchDebounced(u64),
    LibraryFilterChanged(Option<shosai_core::library::BookFormat>),
    LibraryActivityTick,
    SelectLanguage(crate::i18n::LanguagePreference),

    // Settings
    SelectAddBookBehavior(super::AddBookBehavior),
    SelectDefaultReadingMode(super::ReadingMode),
    SelectDefaultReaderTheme(crate::theme::ReaderTheme),
    DefaultEpubFontSizeUp,
    DefaultEpubFontSizeDown,
    SelectDefaultEpubLineSpacing(f32),
    SelectDefaultPdfFitWidth(bool),
    OpenManagedLibraryFolder,
    ChooseManagedLibraryParent,
    ManagedLibraryParentSelected(Option<PathBuf>),
    ManagedLibraryMovePlanned {
        destination: PathBuf,
        result: Result<shosai_core::library::ManagedStorageSummary, String>,
    },
    CancelManagedLibraryMove,
    ConfirmManagedLibraryMove,
    ManagedLibraryMoved {
        destination: PathBuf,
        result: Result<Vec<shosai_core::library::ManagedPathChange>, String>,
    },

    // Bookmarks
    ToggleBookmark,
    BookmarkToggled {
        tab_id: u64,
        file_path: PathBuf,
        book_id: Option<i64>,
        page: usize,
        location_offset: Option<usize>,
        result: Result<Option<Bookmark>, String>,
    },
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
    BookmarkMutationFinished {
        tab_id: u64,
        file_path: PathBuf,
        book_id: Option<i64>,
        result: Result<(), String>,
    },
    ExportBookmarks,

    // In-document search
    ToggleSearchBar,
    SearchQueryChanged(String),
    SearchQueryDebounced {
        tab_id: u64,
        document_generation: u64,
        query_generation: u64,
    },
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
        complete: bool,
        pages: Arc<Vec<EpubPage>>,
    },
    EpubImagesDecoded {
        tab_id: u64,
        generation: u64,
        images: Vec<(String, Option<DecodedEpubImage>)>,
    },
    CbzDimensionsLoaded {
        tab_id: u64,
        generation: u64,
        page: usize,
        result: Result<(), String>,
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
    ReadingStateFlushed {
        id: window::Id,
        result: Result<(), String>,
    },
    PerfFramePresented,
}
