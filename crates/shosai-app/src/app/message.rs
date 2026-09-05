use std::path::PathBuf;
use std::sync::Arc;

use iced::{keyboard, window};
use shosai_core::bookmarks::Bookmark;
use shosai_core::document::RenderedPage;
use shosai_core::library::{
    Book, BookPage, ImportCompletion, ImportDiscovery, ImportFailure, PreparedManagedImport,
};
use shosai_core::search::{SearchError, SearchMatch};

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
        result: Result<(super::OpenDocument, String), super::AppError>,
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
        result: Result<BookPage, String>,
    },
    LibraryCoversLoaded {
        generation: u64,
        offset: usize,
        cover_handles: Vec<(i64, RasterImageHandle, usize)>,
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
    CancelBookImport,
    ManagedBookPrepared {
        generation: u64,
        index: usize,
        result: Result<(PathBuf, Arc<PreparedManagedImport>), ImportFailure>,
    },
    BookAddedToBatch {
        generation: u64,
        completion: ImportCompletion,
    },
    OpenLibraryBook(i64, String),
    LocateBook(i64),
    RelinkBookSelected {
        generation: u64,
        book_id: i64,
        path: Option<PathBuf>,
    },
    BookRelinked {
        generation: u64,
        result: Result<Book, String>,
    },
    ToggleBookMenu(i64),
    CloseBookMenu,
    RequestRemoveBook(i64),
    CancelRemoveBook,
    RemoveBook(i64),
    BookRemoved {
        id: i64,
        result: Result<Option<PathBuf>, String>,
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
    ManagedLibraryParentSelected {
        generation: u64,
        parent: Option<PathBuf>,
    },
    ManagedLibraryMovePlanned {
        generation: u64,
        destination: PathBuf,
        result: Result<shosai_core::library::ManagedStorageSummary, String>,
    },
    CancelManagedLibraryMove,
    ConfirmManagedLibraryMove,
    ManagedLibraryMoved {
        generation: u64,
        destination: PathBuf,
        result: Result<Vec<shosai_core::library::ManagedPathChange>, String>,
    },

    // Bookmarks
    ToggleBookmark,
    BookmarkToggled {
        tab_id: u64,
        generation: u64,
        file_path: PathBuf,
        book_id: Option<i64>,
        page: usize,
        location_offset: Option<usize>,
        result: Result<Option<Bookmark>, String>,
    },
    ToggleBookmarksPanel,
    BookmarksLoaded {
        tab_id: u64,
        load_generation: u64,
        file_path: PathBuf,
        book_id: Option<i64>,
        result: Result<Vec<Bookmark>, String>,
    },
    GoToBookmark(usize, Option<usize>), // page/chapter and EPUB character offset
    StartEditNote(i64, String),
    EditNoteChanged(String),
    SaveNote,
    CancelEditNote,
    DeleteBookmark(i64),
    BookmarkMutationFinished {
        tab_id: u64,
        generation: u64,
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
    SearchPerformed {
        tab_id: u64,
        document_generation: u64,
        query_generation: u64,
        result: Result<Vec<SearchMatch>, SearchError>,
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
        path: String,
        images: Vec<(String, Option<DecodedEpubImage>)>,
    },
    EpubImageSizeLoaded {
        tab_id: u64,
        generation: u64,
        path: String,
        byte_len: Option<usize>,
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
    // Keyboard
    KeyPressed(keyboard::Event),
    WindowEvent(window::Id, window::Event),
    WindowScaleFactorLoaded {
        generation: u64,
        scale_factor: f32,
    },
    PersistWindowGeometry(u64),
    WindowGeometryPersisted(Result<(), String>),
    ReadingStateFlushed {
        id: window::Id,
        result: Result<(), String>,
    },
    PerfFramePresented,
}
