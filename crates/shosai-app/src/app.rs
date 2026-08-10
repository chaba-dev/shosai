use std::path::PathBuf;
use std::sync::Arc;

use iced::keyboard;
use iced::widget::{
    button, center, column, container, image, rich_text, row, scrollable, span, text, text_input,
};
use iced::{Element, Font, Length, Subscription, Task};

use shosai_core::bookmarks::{Bookmark, BookmarkStore};
use shosai_core::cbz::CbzDoc;
use shosai_core::document::{Document, RenderedPage};
use shosai_core::epub::EpubDoc;
use shosai_core::epub::render::{ContentNode, parse_chapter_xhtml};
use shosai_core::library::{Book, Library};
use shosai_core::pdf::PdfDoc;
use shosai_core::reading_state::{FileReadingState, ReadingStateStore};
use shosai_core::search::SearchMatch;

// ---------------------------------------------------------------------------
// Open document wrapper
// ---------------------------------------------------------------------------

#[derive(Debug)]
enum OpenDocument {
    Pdf(PdfDoc),
    Epub(EpubDoc),
    Cbz(CbzDoc),
}

// ---------------------------------------------------------------------------
// Zoom (PDF only)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ZoomMode {
    Manual(f32),
    FitWidth,
    FitPage,
}

impl ZoomMode {
    fn scale(&self) -> f32 {
        match self {
            ZoomMode::Manual(s) => *s,
            ZoomMode::FitWidth => 1.0,
            ZoomMode::FitPage => 1.0,
        }
    }

    fn label(&self) -> String {
        match self {
            ZoomMode::Manual(s) => format!("{}%", (s * 100.0) as u32),
            ZoomMode::FitWidth => "Fit Width".to_string(),
            ZoomMode::FitPage => "Fit Page".to_string(),
        }
    }
}

impl Default for ZoomMode {
    fn default() -> Self {
        ZoomMode::Manual(1.0)
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

const LIBRARY_CARDS_PER_ROW_MIN: usize = 2;
const LIBRARY_CARDS_PER_ROW_MAX: usize = 8;
const LIBRARY_CARDS_PER_ROW_DEFAULT: usize = 5;
const LIBRARY_CARDS_PER_ROW_KEY: &str = "library.cards_per_row";

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
    chapter_content: Vec<ContentNode>,
    page_input: String,
    error: Option<String>,
    font_size: f32,
    line_spacing: f32,
    theme: ReaderTheme,

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
    library_cards_per_row: usize,
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
// Messages
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum Message {
    // File
    OpenFile,
    FileSelected(Option<PathBuf>),

    // Navigation
    NextPage,
    PrevPage,
    PageInputChanged(String),
    GoToPage,

    // Zoom (PDF)
    ZoomIn,
    ZoomOut,
    SetZoomFitWidth,
    SetZoomFitPage,

    // EPUB reading controls
    FontSizeUp,
    FontSizeDown,
    CycleTheme,

    // Links
    LinkClicked(String),

    // Library
    ShowLibrary,
    RefreshLibrary,
    LibraryLoaded(Vec<Book>),
    ImportFile,
    ImportDirectory,
    OpenBook(String), // file_path
    #[allow(dead_code)]
    RemoveBook(i64),
    LibrarySearchChanged(String),
    LibraryFilterChanged(Option<shosai_core::library::BookFormat>),
    LibraryCardsPerRowIncrement,
    LibraryCardsPerRowDecrement,

    // Bookmarks
    ToggleBookmark,
    ToggleBookmarksPanel,
    BookmarksLoaded(Vec<Bookmark>),
    GoToBookmark(usize), // page index
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
        document_generation: u64,
        text: Arc<Vec<String>>,
    },
    SearchPerformed {
        document_generation: u64,
        query_generation: u64,
        results: Vec<SearchMatch>,
    },
    SearchNext,
    SearchPrev,
    CloseSearch,

    // Keyboard
    KeyPressed(keyboard::Event),
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

pub fn boot() -> (State, Task<Message>) {
    let reading_state = match ReadingStateStore::open() {
        Ok(store) => Some(store),
        Err(e) => {
            eprintln!("warning: failed to open reading state database: {e}");
            None
        }
    };

    let library = reading_state
        .as_ref()
        .map(|store| Library::new(store.pool().clone()));

    // Load the last chosen layout density so the library feels consistent across launches.
    let library_cards_per_row = reading_state
        .as_ref()
        .and_then(|store| store.get_pref_int(LIBRARY_CARDS_PER_ROW_KEY))
        .and_then(|value| usize::try_from(value).ok())
        .filter(|value| {
            (*value >= LIBRARY_CARDS_PER_ROW_MIN) && (*value <= LIBRARY_CARDS_PER_ROW_MAX)
        })
        .unwrap_or(LIBRARY_CARDS_PER_ROW_DEFAULT);

    let state = State {
        screen: Screen::Library,

        file_path: None,
        document: None,
        current_page: 0,
        total_pages: 0,
        zoom: ZoomMode::default(),
        rendered_page: None,
        chapter_content: Vec::new(),
        page_input: String::new(),
        error: None,
        font_size: 16.0,
        line_spacing: 1.6,
        theme: ReaderTheme::default(),

        bookmark_store: reading_state
            .as_ref()
            .map(|s| BookmarkStore::new(s.pool().clone())),

        reading_state,
        library,

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
        library_cards_per_row,
    };
    (state, Task::done(Message::RefreshLibrary))
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

pub fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::OpenFile => {
            return Task::perform(
                async {
                    let file = rfd::AsyncFileDialog::new()
                        .add_filter("Ebooks", &["pdf", "epub", "cbz"])
                        .add_filter("PDF", &["pdf"])
                        .add_filter("EPUB", &["epub"])
                        .add_filter("CBZ", &["cbz"])
                        .set_title("Open File")
                        .pick_file()
                        .await;

                    file.map(|f| f.path().to_path_buf())
                },
                Message::FileSelected,
            );
        }

        Message::FileSelected(Some(path)) => {
            open_file(state, path);
        }

        Message::FileSelected(None) => {}

        Message::NextPage => {
            if state.document.is_some() && state.current_page + 1 < state.total_pages {
                state.current_page += 1;
                state.page_input = format!("{}", state.current_page + 1);
                refresh_content(state);
                save_reading_state(state);
            }
        }

        Message::PrevPage => {
            if state.document.is_some() && state.current_page > 0 {
                state.current_page -= 1;
                state.page_input = format!("{}", state.current_page + 1);
                refresh_content(state);
                save_reading_state(state);
            }
        }

        Message::PageInputChanged(value) => {
            state.page_input = value;
        }

        Message::GoToPage => {
            if let Ok(page_num) = state.page_input.parse::<usize>()
                && page_num >= 1
                && page_num <= state.total_pages
            {
                state.current_page = page_num - 1;
                refresh_content(state);
                save_reading_state(state);
            }
            state.page_input = format!("{}", state.current_page + 1);
        }

        Message::ZoomIn => {
            if matches!(
                state.document,
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
            ) {
                let new_scale = (state.zoom.scale() + 0.25).min(5.0);
                state.zoom = ZoomMode::Manual(new_scale);
                refresh_content(state);
                save_reading_state(state);
            }
        }

        Message::ZoomOut => {
            if matches!(
                state.document,
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
            ) {
                let new_scale = (state.zoom.scale() - 0.25).max(0.25);
                state.zoom = ZoomMode::Manual(new_scale);
                refresh_content(state);
                save_reading_state(state);
            }
        }

        Message::SetZoomFitWidth => {
            state.zoom = ZoomMode::FitWidth;
            refresh_content(state);
            save_reading_state(state);
        }

        Message::SetZoomFitPage => {
            state.zoom = ZoomMode::FitPage;
            refresh_content(state);
            save_reading_state(state);
        }

        Message::FontSizeUp => {
            state.font_size = (state.font_size + 2.0).min(48.0);
        }

        Message::FontSizeDown => {
            state.font_size = (state.font_size - 2.0).max(8.0);
        }

        Message::CycleTheme => {
            state.theme = state.theme.next();
        }

        Message::LinkClicked(href) => {
            handle_link_click(state, &href);
        }

        // Library
        Message::ShowLibrary => {
            state.screen = Screen::Library;
            return Task::done(Message::RefreshLibrary);
        }

        Message::RefreshLibrary => {
            if let Some(lib) = state.library.clone() {
                let search = state.library_search.clone();
                let filter = state.library_filter;
                return Task::perform(
                    async move {
                        if !search.is_empty() {
                            lib.search(&search).await.unwrap_or_default()
                        } else if let Some(fmt) = filter {
                            lib.filter_by_format(fmt).await.unwrap_or_default()
                        } else {
                            lib.list_all().await.unwrap_or_default()
                        }
                    },
                    Message::LibraryLoaded,
                );
            }
        }

        Message::LibraryLoaded(books) => {
            state.library_books = books;
        }

        Message::ImportFile => {
            return Task::perform(
                async {
                    let file = rfd::AsyncFileDialog::new()
                        .add_filter("Ebooks", &["pdf", "epub", "cbz"])
                        .set_title("Import to Library")
                        .pick_file()
                        .await;
                    file.map(|f| f.path().to_path_buf())
                },
                |path| {
                    if let Some(p) = path {
                        Message::OpenBook(p.to_string_lossy().to_string())
                    } else {
                        Message::RefreshLibrary // no-op refresh
                    }
                },
            );
        }

        Message::ImportDirectory => {
            if let Some(lib) = state.library.clone() {
                return Task::perform(
                    async move {
                        let dir = rfd::AsyncFileDialog::new()
                            .set_title("Import Directory")
                            .pick_folder()
                            .await;
                        if let Some(d) = dir {
                            let _ = lib.import_directory(d.path()).await;
                        }
                        // Return the updated list.
                        lib.list_all().await.unwrap_or_default()
                    },
                    Message::LibraryLoaded,
                );
            }
        }

        Message::OpenBook(file_path) => {
            let path = PathBuf::from(&file_path);
            // Import to library if not already there.
            if let Some(lib) = state.library.clone() {
                let p = path.clone();
                // Fire-and-forget import.
                tokio::task::spawn(async move {
                    let _ = lib.import_file(&p).await;
                });
            }
            open_file(state, path);
            state.screen = Screen::Reader;
        }

        Message::RemoveBook(id) => {
            if let Some(lib) = state.library.clone() {
                return Task::perform(
                    async move {
                        let _ = lib.remove(id).await;
                        lib.list_all().await.unwrap_or_default()
                    },
                    Message::LibraryLoaded,
                );
            }
        }

        Message::LibrarySearchChanged(query) => {
            state.library_search = query;
            return Task::done(Message::RefreshLibrary);
        }

        Message::LibraryFilterChanged(filter) => {
            state.library_filter = filter;
            return Task::done(Message::RefreshLibrary);
        }

        Message::LibraryCardsPerRowIncrement => {
            // Clamp within bounds to keep the grid readable on small windows.
            if state.library_cards_per_row < LIBRARY_CARDS_PER_ROW_MAX {
                state.library_cards_per_row += 1;
                save_library_cards_per_row(state);
            }
        }

        Message::LibraryCardsPerRowDecrement => {
            // Clamp within bounds to keep the grid readable on small windows.
            if state.library_cards_per_row > LIBRARY_CARDS_PER_ROW_MIN {
                state.library_cards_per_row -= 1;
                save_library_cards_per_row(state);
            }
        }

        // Bookmarks
        Message::ToggleBookmark => {
            if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
                let page_title = format!("Page {}", state.current_page + 1);
                match store.toggle(path, state.current_page, Some(&page_title)) {
                    Ok(Some(_)) => state.current_page_bookmarked = true,
                    Ok(None) => state.current_page_bookmarked = false,
                    Err(e) => eprintln!("warning: failed to toggle bookmark: {e}"),
                }
                return refresh_bookmarks(state);
            }
        }

        Message::ToggleBookmarksPanel => {
            state.show_bookmarks_panel = !state.show_bookmarks_panel;
            if state.show_bookmarks_panel {
                return refresh_bookmarks(state);
            }
        }

        Message::BookmarksLoaded(bookmarks) => {
            state.bookmarks = bookmarks;
            // Update current page bookmark status.
            if let Some(path) = &state.file_path
                && let Some(store) = &state.bookmark_store
            {
                state.current_page_bookmarked = store.is_bookmarked(path, state.current_page);
            }
        }

        Message::GoToBookmark(page) => {
            state.current_page = page;
            state.page_input = format!("{}", page + 1);
            refresh_content(state);
            save_reading_state(state);
            update_bookmark_status(state);
        }

        Message::StartEditNote(id, existing) => {
            state.editing_note_id = Some(id);
            state.editing_note_text = existing;
        }

        Message::EditNoteChanged(text) => {
            state.editing_note_text = text;
        }

        Message::SaveNote => {
            if let (Some(id), Some(store)) = (state.editing_note_id, &state.bookmark_store) {
                let note = if state.editing_note_text.is_empty() {
                    None
                } else {
                    Some(state.editing_note_text.as_str())
                };
                let rt = tokio::runtime::Handle::current();
                if let Err(e) = rt.block_on(store.update_note_async(id, note)) {
                    eprintln!("warning: failed to save note: {e}");
                }
            }
            state.editing_note_id = None;
            state.editing_note_text = String::new();
            return refresh_bookmarks(state);
        }

        Message::CancelEditNote => {
            state.editing_note_id = None;
            state.editing_note_text = String::new();
        }

        Message::DeleteBookmark(id) => {
            if let Some(store) = &state.bookmark_store {
                let rt = tokio::runtime::Handle::current();
                if let Err(e) = rt.block_on(store.remove_async(id)) {
                    eprintln!("warning: failed to delete bookmark: {e}");
                }
            }
            return refresh_bookmarks(state);
        }

        Message::ExportBookmarks => {
            if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
                match store.export_markdown(path) {
                    Ok(md) => {
                        // Save to file next to the document.
                        let export_path = path.with_extension("bookmarks.md");
                        if let Err(e) = std::fs::write(&export_path, &md) {
                            eprintln!("warning: failed to export bookmarks: {e}");
                        } else {
                            eprintln!("Bookmarks exported to {}", export_path.display());
                        }
                    }
                    Err(e) => eprintln!("warning: failed to export bookmarks: {e}"),
                }
            }
        }

        // In-document search
        Message::ToggleSearchBar => {
            if state.screen == Screen::Reader
                && matches!(
                    state.document,
                    Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Epub(_))
                )
            {
                state.show_search_bar = !state.show_search_bar;
                if !state.show_search_bar {
                    let previous_highlights = current_page_search_highlights(state);
                    // Clear results when closing.
                    state.search_query.clear();
                    state.search_results.clear();
                    state.search_current = 0;
                    state.search_query_generation = state.search_query_generation.wrapping_add(1);
                    refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
                } else {
                    return iced::widget::operation::focus(search_input_id());
                }
            }
        }

        Message::SearchQueryChanged(query) => {
            let previous_highlights = current_page_search_highlights(state);
            state.search_query = query;
            state.search_query_generation = state.search_query_generation.wrapping_add(1);
            state.search_results.clear();
            state.search_current = 0;
            refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
            if !state.search_query.is_empty() {
                return perform_search(state);
            }
        }

        Message::SearchTextExtracted {
            document_generation,
            text,
        } => {
            if document_generation == state.search_document_generation {
                state.search_loading = false;
                state.search_text = Some(text);
                if !state.search_query.is_empty() {
                    return perform_search(state);
                }
            }
        }

        Message::SearchPerformed {
            document_generation,
            query_generation,
            results,
        } => {
            if document_generation == state.search_document_generation
                && query_generation == state.search_query_generation
            {
                let previous_highlights = current_page_search_highlights(state);
                state.search_results = results;
                state.search_current = 0;
                // Navigate to first result if any.
                if !navigate_to_current_search_result(state) {
                    refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
                }
            }
        }

        Message::SearchNext => {
            if !state.search_results.is_empty() {
                let previous_highlights = current_page_search_highlights(state);
                state.search_current = (state.search_current + 1) % state.search_results.len();
                if !navigate_to_current_search_result(state) {
                    refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
                }
            }
        }

        Message::SearchPrev => {
            if !state.search_results.is_empty() {
                let previous_highlights = current_page_search_highlights(state);
                state.search_current = if state.search_current == 0 {
                    state.search_results.len() - 1
                } else {
                    state.search_current - 1
                };
                if !navigate_to_current_search_result(state) {
                    refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
                }
            }
        }

        Message::CloseSearch => {
            let previous_highlights = current_page_search_highlights(state);
            state.show_search_bar = false;
            state.search_query.clear();
            state.search_results.clear();
            state.search_current = 0;
            state.search_query_generation = state.search_query_generation.wrapping_add(1);
            refresh_pdf_search_highlights_if_changed(state, &previous_highlights);
        }

        Message::KeyPressed(event) => {
            return handle_key_event(state, event);
        }
    }

    Task::none()
}

fn open_file(state: &mut State, path: PathBuf) {
    state.search_document_generation = state.search_document_generation.wrapping_add(1);
    state.search_query_generation = state.search_query_generation.wrapping_add(1);
    state.error = None;
    state.rendered_page = None;
    state.chapter_content = Vec::new();
    state.show_search_bar = false;
    state.search_query.clear();
    state.search_results.clear();
    state.search_current = 0;
    state.search_text = None;
    state.search_loading = false;

    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    let result: Result<(), String> = match ext.as_str() {
        "pdf" => match PdfDoc::open(&path) {
            Ok(doc) => {
                state.total_pages = doc.page_count();
                state.document = Some(OpenDocument::Pdf(doc));
                Ok(())
            }
            Err(e) => Err(format!("Failed to open PDF: {e}")),
        },
        "epub" => match EpubDoc::open(&path) {
            Ok(doc) => {
                state.total_pages = doc.chapter_count();
                state.document = Some(OpenDocument::Epub(doc));
                Ok(())
            }
            Err(e) => Err(format!("Failed to open EPUB: {e}")),
        },
        "cbz" => match CbzDoc::open(&path) {
            Ok(doc) => {
                state.total_pages = doc.page_count();
                state.document = Some(OpenDocument::Cbz(doc));
                Ok(())
            }
            Err(e) => Err(format!("Failed to open CBZ: {e}")),
        },
        _ => Err(format!("Unsupported file format: .{ext}")),
    };

    match result {
        Ok(()) => {
            // Restore reading position.
            let saved = state
                .reading_state
                .as_ref()
                .and_then(|store| store.get(&path));
            if let Some(saved) = saved {
                state.current_page = saved.page.min(state.total_pages.saturating_sub(1));
                if matches!(
                    state.document,
                    Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
                ) {
                    state.zoom = ZoomMode::Manual(saved.zoom);
                }
            } else {
                state.current_page = 0;
                state.zoom = ZoomMode::Manual(1.0);
            }

            state.page_input = format!("{}", state.current_page + 1);
            state.file_path = Some(path);
            refresh_content(state);
            update_bookmark_status(state);
            // Load bookmarks for this file.
            if let (Some(p), Some(store)) = (&state.file_path, &state.bookmark_store) {
                state.bookmarks = store.list_for_file(p).unwrap_or_default();
            }
        }
        Err(msg) => {
            state.error = Some(msg);
        }
    }
}

fn handle_key_event(state: &State, event: keyboard::Event) -> Task<Message> {
    if let keyboard::Event::KeyPressed { key, modifiers, .. } = event {
        match key.as_ref() {
            keyboard::Key::Named(keyboard::key::Named::ArrowRight)
            | keyboard::Key::Named(keyboard::key::Named::PageDown) => {
                return Task::done(Message::NextPage);
            }
            keyboard::Key::Named(keyboard::key::Named::ArrowLeft)
            | keyboard::Key::Named(keyboard::key::Named::PageUp) => {
                return Task::done(Message::PrevPage);
            }

            keyboard::Key::Character(c) if c == "=" || c == "+" => {
                return Task::done(Message::ZoomIn);
            }
            keyboard::Key::Character("-") => {
                return Task::done(Message::ZoomOut);
            }

            keyboard::Key::Character(c) if c == "o" && modifiers.command() => {
                return Task::done(Message::OpenFile);
            }

            // Ctrl+B: toggle bookmark on current page
            keyboard::Key::Character(c) if c == "b" && modifiers.command() => {
                if state.screen == Screen::Reader {
                    return Task::done(Message::ToggleBookmark);
                }
            }

            // B: toggle bookmarks panel
            keyboard::Key::Character(c) if c == "b" && !modifiers.command() => {
                if state.screen == Screen::Reader {
                    return Task::done(Message::ToggleBookmarksPanel);
                }
            }

            // Ctrl+F: toggle search bar
            keyboard::Key::Character(c) if c == "f" && modifiers.command() => {
                if state.screen == Screen::Reader {
                    return Task::done(Message::ToggleSearchBar);
                }
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
fn handle_link_click(state: &mut State, href: &str) {
    // External links: open in system browser.
    if href.starts_with("http://") || href.starts_with("https://") || href.starts_with("mailto:") {
        if let Err(e) = open::that(href) {
            eprintln!("warning: failed to open URL: {e}");
        }
        return;
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
            return;
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
            state.current_page = chapter_idx;
            state.page_input = format!("{}", state.current_page + 1);
            refresh_content(state);
            save_reading_state(state);
        }
    }
}

/// Refresh the visible content for the current page/chapter.
fn refresh_content(state: &mut State) {
    let pdf_highlights = current_page_search_highlights(state)
        .into_iter()
        .map(|highlight| {
            (
                highlight.start,
                highlight.end - highlight.start,
                highlight.current,
            )
        })
        .collect::<Vec<_>>();

    match &state.document {
        Some(OpenDocument::Pdf(doc)) => {
            let scale = state.zoom.scale();
            match doc.render_page_with_highlights(state.current_page, scale, &pdf_highlights) {
                Ok(page) => {
                    state.rendered_page = Some(page);
                    state.chapter_content = Vec::new();
                    state.error = None;
                }
                Err(e) => {
                    state.error = Some(format!("Failed to render page: {e}"));
                    state.rendered_page = None;
                }
            }
        }
        Some(OpenDocument::Epub(doc)) => {
            state.rendered_page = None;
            if let Some(chapter) = doc.chapter(state.current_page) {
                let base_path = chapter
                    .path
                    .rsplit_once('/')
                    .map(|(dir, _)| dir)
                    .unwrap_or("");
                state.chapter_content =
                    parse_chapter_xhtml(&chapter.content, base_path, &doc.content.styles);
                state.error = None;
            } else {
                state.chapter_content = Vec::new();
                state.error = Some(format!("Chapter {} not found", state.current_page));
            }
        }
        Some(OpenDocument::Cbz(doc)) => {
            let scale = state.zoom.scale();
            match doc.render_page(state.current_page, scale) {
                Ok(page) => {
                    state.rendered_page = Some(page);
                    state.chapter_content = Vec::new();
                    state.error = None;
                }
                Err(e) => {
                    state.error = Some(format!("Failed to render page: {e}"));
                    state.rendered_page = None;
                }
            }
        }
        None => {}
    }

    update_bookmark_status(state);
}

fn refresh_bookmarks(state: &State) -> Task<Message> {
    if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
        let store = store.clone();
        let path = path.clone();
        Task::perform(
            async move { store.list_for_file_async(&path).await.unwrap_or_default() },
            Message::BookmarksLoaded,
        )
    } else {
        Task::none()
    }
}

fn update_bookmark_status(state: &mut State) {
    if let (Some(path), Some(store)) = (&state.file_path, &state.bookmark_store) {
        state.current_page_bookmarked = store.is_bookmarked(path, state.current_page);
    } else {
        state.current_page_bookmarked = false;
    }
}

fn save_reading_state(state: &State) {
    if let (Some(path), Some(store)) = (&state.file_path, &state.reading_state) {
        let reading = FileReadingState {
            page: state.current_page,
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

fn save_library_cards_per_row(state: &State) {
    // Persist the layout choice alongside reading state for quick reloads.
    if let Some(store) = &state.reading_state
        && let Err(e) = store.set_pref_int(
            LIBRARY_CARDS_PER_ROW_KEY,
            state.library_cards_per_row as i64,
        )
    {
        eprintln!("warning: failed to save library layout: {e}");
    }
}

fn perform_search(state: &mut State) -> Task<Message> {
    let query = state.search_query.clone();
    let document_generation = state.search_document_generation;
    let query_generation = state.search_query_generation;
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
            document_generation,
            text,
        },
    )
}

fn navigate_to_current_search_result(state: &mut State) -> bool {
    if let Some(result) = state.search_results.get(state.search_current) {
        let target_page = result.page;
        if target_page != state.current_page && target_page < state.total_pages {
            state.current_page = target_page;
            state.page_input = format!("{}", state.current_page + 1);
            refresh_content(state);
            save_reading_state(state);
            return true;
        }
    }
    false
}

fn refresh_pdf_search_highlights_if_changed(
    state: &mut State,
    previous_highlights: &[SearchHighlight],
) {
    if matches!(state.document, Some(OpenDocument::Pdf(_)))
        && previous_highlights != current_page_search_highlights(state)
    {
        refresh_content(state);
    }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

pub fn view(state: &State) -> Element<'_, Message> {
    match state.screen {
        Screen::Library => library_view(state),
        Screen::Reader => {
            let main_content = content_view(state);

            let body: Element<'_, Message> = if state.show_bookmarks_panel {
                row![
                    container(main_content)
                        .width(Length::Fill)
                        .height(Length::Fill),
                    bookmarks_panel(state),
                ]
                .width(Length::Fill)
                .height(Length::Fill)
                .into()
            } else {
                main_content
            };

            let mut layout = column![toolbar(state)].spacing(0);

            if state.show_search_bar {
                layout = layout.push(search_bar(state));
            }

            layout = layout.push(body);

            layout.width(Length::Fill).height(Length::Fill).into()
        }
    }
}

fn toolbar(state: &State) -> Element<'_, Message> {
    let open_btn = button("Open").on_press(Message::OpenFile);

    let has_doc = state.document.is_some();
    let is_pdf_or_cbz = matches!(
        state.document,
        Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_))
    );
    let is_epub = matches!(state.document, Some(OpenDocument::Epub(_)));
    let can_prev = has_doc && state.current_page > 0;
    let can_next = has_doc && state.current_page + 1 < state.total_pages;

    let mut prev_btn = button("<");
    if can_prev {
        prev_btn = prev_btn.on_press(Message::PrevPage);
    }

    let mut next_btn = button(">");
    if can_next {
        next_btn = next_btn.on_press(Message::NextPage);
    }

    let nav_label = if is_epub { "Ch" } else { "Pg" };

    let page_input = text_input(nav_label, &state.page_input)
        .on_input(Message::PageInputChanged)
        .on_submit(Message::GoToPage)
        .width(60);

    let page_label = text(if has_doc {
        format!("/ {}", state.total_pages)
    } else {
        String::new()
    });

    let library_btn = button("Library").on_press(Message::ShowLibrary);

    let mut toolbar_items: Vec<Element<'_, Message>> = vec![
        library_btn.into(),
        open_btn.into(),
        prev_btn.into(),
        page_input.into(),
        page_label.into(),
        next_btn.into(),
    ];

    // PDF: zoom controls
    if is_pdf_or_cbz || !has_doc {
        let zoom_out_btn = if is_pdf_or_cbz {
            button("-").on_press(Message::ZoomOut)
        } else {
            button("-")
        };
        let zoom_label = text(state.zoom.label()).width(70);
        let zoom_in_btn = if is_pdf_or_cbz {
            button("+").on_press(Message::ZoomIn)
        } else {
            button("+")
        };
        let mut fit_w = button("W");
        let mut fit_p = button("P");
        if is_pdf_or_cbz {
            fit_w = fit_w.on_press(Message::SetZoomFitWidth);
            fit_p = fit_p.on_press(Message::SetZoomFitPage);
        }

        toolbar_items.push(zoom_out_btn.into());
        toolbar_items.push(zoom_label.into());
        toolbar_items.push(zoom_in_btn.into());
        toolbar_items.push(fit_w.into());
        toolbar_items.push(fit_p.into());
    }

    // EPUB: font size + theme controls
    if is_epub {
        let size_label = text(format!("{}px", state.font_size as u32)).width(50);
        toolbar_items.push(button("A-").on_press(Message::FontSizeDown).into());
        toolbar_items.push(size_label.into());
        toolbar_items.push(button("A+").on_press(Message::FontSizeUp).into());
        toolbar_items.push(
            button(state.theme.label())
                .on_press(Message::CycleTheme)
                .into(),
        );
    }

    // Bookmark controls (for all formats when a doc is open)
    if has_doc {
        let bookmark_label = if state.current_page_bookmarked {
            "\u{2605}" // filled star
        } else {
            "\u{2606}" // empty star
        };
        toolbar_items.push(
            button(bookmark_label)
                .on_press(Message::ToggleBookmark)
                .into(),
        );
        let panel_label = if state.show_bookmarks_panel {
            "Hide BM"
        } else {
            "Show BM"
        };
        toolbar_items.push(
            button(panel_label)
                .on_press(Message::ToggleBookmarksPanel)
                .into(),
        );
        // Search button (PDF and EPUB only, not CBZ)
        if !matches!(state.document, Some(OpenDocument::Cbz(_))) {
            let search_label = if state.show_search_bar {
                "Hide Search"
            } else {
                "Search"
            };
            toolbar_items.push(
                button(search_label)
                    .on_press(Message::ToggleSearchBar)
                    .into(),
            );
        }
    }

    let toolbar_row = row(toolbar_items)
        .spacing(8)
        .align_y(iced::Alignment::Center);

    container(toolbar_row).padding(8).width(Length::Fill).into()
}

fn bookmarks_panel(state: &State) -> Element<'_, Message> {
    let mut panel = column![text("Bookmarks").size(16)]
        .spacing(8)
        .padding(8)
        .width(Length::Fixed(280.0));

    if state.bookmarks.is_empty() {
        panel = panel.push(text("No bookmarks yet").size(12));
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
                    .on_press(Message::GoToBookmark(bm.page))
                    .padding(2),
                text(format!("p.{}", bm.page + 1)).size(10),
                button(text("\u{2715}").size(10))
                    .on_press(Message::DeleteBookmark(bm.id))
                    .padding(2),
            ]
            .spacing(4)
            .align_y(iced::Alignment::Center);

            entry_col = entry_col.push(header);

            if is_editing {
                // Note editing mode
                let input = text_input("Add a note...", &state.editing_note_text)
                    .on_input(Message::EditNoteChanged)
                    .on_submit(Message::SaveNote)
                    .size(12)
                    .width(Length::Fill);
                let cancel_btn = button(text("Cancel").size(10))
                    .on_press(Message::CancelEditNote)
                    .padding(2);
                let save_btn = button(text("Save").size(10))
                    .on_press(Message::SaveNote)
                    .padding(2);
                entry_col = entry_col.push(input);
                entry_col = entry_col.push(row![save_btn, cancel_btn].spacing(4));
            } else {
                // Display note or "Add note" button
                if let Some(note) = &bm.note {
                    entry_col = entry_col.push(text(note.clone()).size(11));
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
                        .padding(2),
                );
            }

            panel = panel.push(container(entry_col).padding(4).width(Length::Fill));
        }
    }

    // Export button at the bottom
    if !state.bookmarks.is_empty() {
        panel = panel.push(
            button(text("Export as Markdown").size(11))
                .on_press(Message::ExportBookmarks)
                .padding(4),
        );
    }

    container(scrollable(panel).height(Length::Fill))
        .width(Length::Fixed(280.0))
        .height(Length::Fill)
        .style(|_theme| container::Style {
            background: Some(iced::Background::Color(iced::Color::from_rgb(
                0.95, 0.95, 0.95,
            ))),
            ..Default::default()
        })
        .into()
}

fn search_bar(state: &State) -> Element<'_, Message> {
    let input = text_input("Search in document...", &state.search_query)
        .id(search_input_id())
        .on_input(Message::SearchQueryChanged)
        .on_submit(Message::SearchNext)
        .width(300);

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

    let mut prev_btn = button("<");
    if has_results {
        prev_btn = prev_btn.on_press(Message::SearchPrev);
    }

    let mut next_btn = button(">");
    if has_results {
        next_btn = next_btn.on_press(Message::SearchNext);
    }

    let close_btn = button("\u{2715}").on_press(Message::CloseSearch);

    let bar = row![
        input,
        text(result_info).size(14),
        prev_btn,
        next_btn,
        close_btn,
    ]
    .spacing(8)
    .align_y(iced::Alignment::Center);

    container(bar)
        .padding(8)
        .width(Length::Fill)
        .style(|_theme| container::Style {
            background: Some(iced::Background::Color(iced::Color::from_rgb(
                0.93, 0.93, 0.93,
            ))),
            ..Default::default()
        })
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

    match &state.document {
        Some(OpenDocument::Pdf(_) | OpenDocument::Cbz(_)) => pdf_page_view(state),
        Some(OpenDocument::Epub(_)) => epub_chapter_view(state),
        None => welcome_view(),
    }
}

fn pdf_page_view(state: &State) -> Element<'_, Message> {
    if let Some(rendered) = &state.rendered_page {
        let handle =
            image::Handle::from_rgba(rendered.width, rendered.height, rendered.pixels.clone());

        let img = image(handle)
            .width(Length::Fixed(rendered.width as f32))
            .height(Length::Fixed(rendered.height as f32));

        let page_container = container(img).width(Length::Fill).center_x(Length::Fill);

        scrollable(page_container)
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    } else {
        center(text("Rendering...").size(16))
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SearchHighlight {
    start: usize,
    end: usize,
    current: bool,
}

fn current_page_search_highlights(state: &State) -> Vec<SearchHighlight> {
    state
        .search_results
        .iter()
        .enumerate()
        .filter(|(_, result)| result.page == state.current_page)
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

    let mut content_col = column![].spacing(line_gap).padding(20).width(Length::Fill);

    // Chapter title from the TOC if available.
    if let Some(OpenDocument::Epub(doc)) = &state.document
        && let Some(chapter) = doc.chapter(state.current_page)
        && let Some(title) = &chapter.title
    {
        content_col = content_col.push(text(title.clone()).size(font_size * 1.5).color(text_color));
    }

    let resources = match &state.document {
        Some(OpenDocument::Epub(doc)) => &doc.content.resources,
        _ => &std::collections::HashMap::new(),
    };

    let highlights = current_page_search_highlights(state);
    let mut text_offset = 0;

    for node in &state.chapter_content {
        content_col = content_col.push(render_content_node(
            node,
            font_size,
            text_color,
            resources,
            text_offset,
            &highlights,
        ));
        text_offset += content_node_text_len(node) + 1;
    }

    let padded = container(content_col)
        .max_width(800)
        .width(Length::Fill)
        .center_x(Length::Fill);

    let bg = state.theme.background();

    container(scrollable(padded).width(Length::Fill).height(Length::Fill))
        .style(move |_theme| container::Style {
            background: Some(iced::Background::Color(bg)),
            ..Default::default()
        })
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn render_content_node<'a>(
    node: &ContentNode,
    font_size: f32,
    text_color: iced::Color,
    resources: &std::collections::HashMap<String, Vec<u8>>,
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

        ContentNode::BlockQuote(children) => {
            let quote_color = iced::Color {
                a: 0.7,
                ..text_color
            };
            let bar_color = iced::Color {
                a: 0.3,
                ..text_color
            };
            let mut col = column![].spacing(8);
            let mut child_offset = text_offset;
            for child in children {
                col = col.push(render_content_node(
                    child,
                    font_size,
                    quote_color,
                    resources,
                    child_offset,
                    highlights,
                ));
                child_offset += content_node_text_len(child) + 1;
            }
            row![
                container(column![])
                    .width(Length::Fixed(3.0))
                    .height(Length::Fill)
                    .style(move |_theme| container::Style {
                        background: Some(iced::Background::Color(bar_color)),
                        ..Default::default()
                    }),
                container(col).padding([4, 12]),
            ]
            .spacing(0)
            .width(Length::Fill)
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

        ContentNode::OrderedList(items) => {
            let mut col = column![].spacing(4);
            let mut item_offset = text_offset;
            for (i, item_spans) in items.iter().enumerate() {
                let num_text = format!("  {}. ", i + 1);
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
            resources,
            text_offset,
            highlights,
        ),

        ContentNode::HorizontalRule => text("───────────────────")
            .size(font_size)
            .color(text_color)
            .into(),
    }
}

/// Render an EPUB image from the resource map, falling back to alt text.
fn render_epub_image<'a>(
    src: &str,
    alt: &str,
    font_size: f32,
    text_color: iced::Color,
    resources: &std::collections::HashMap<String, Vec<u8>>,
    text_offset: usize,
    highlights: &[SearchHighlight],
) -> Element<'a, Message> {
    if let Some(data) = resources.get(src) {
        // Try to decode the image and display as RGBA via iced::widget::image.
        if let Ok(img) = ::image::load_from_memory(data) {
            let rgba = img.to_rgba8();
            let (w, h) = rgba.dimensions();
            let handle = image::Handle::from_rgba(w, h, rgba.into_raw());

            return container(
                image(handle)
                    .content_fit(iced::ContentFit::ScaleDown)
                    .width(Length::Fill),
            )
            .width(Length::Fill)
            .center_x(Length::Fill)
            .into();
        }
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

fn spans_text_len(spans: &[shosai_core::epub::render::TextSpan]) -> usize {
    spans.iter().map(|span| span.text.chars().count()).sum()
}

fn content_node_text_len(node: &ContentNode) -> usize {
    match node {
        ContentNode::Heading { text, .. } => text.chars().count(),
        ContentNode::Paragraph(spans, _) => spans_text_len(spans),
        ContentNode::BlockQuote(children) => children
            .iter()
            .map(|child| content_node_text_len(child) + 1)
            .sum(),
        ContentNode::UnorderedList(items) | ContentNode::OrderedList(items) => {
            items.iter().map(|spans| spans_text_len(spans) + 1).sum()
        }
        ContentNode::CodeBlock { code, .. } | ContentNode::InlineCode(code) => code.chars().count(),
        ContentNode::Image { alt, .. } => alt.chars().count(),
        ContentNode::HorizontalRule => 0,
    }
}

fn library_view(state: &State) -> Element<'_, Message> {
    let search_input = text_input("Search by title or author...", &state.library_search)
        .on_input(Message::LibrarySearchChanged)
        .width(300);

    let all_btn = button("All").on_press(Message::LibraryFilterChanged(None));
    let pdf_btn = button("PDF").on_press(Message::LibraryFilterChanged(Some(
        shosai_core::library::BookFormat::Pdf,
    )));
    let epub_btn = button("EPUB").on_press(Message::LibraryFilterChanged(Some(
        shosai_core::library::BookFormat::Epub,
    )));
    let cbz_btn = button("CBZ").on_press(Message::LibraryFilterChanged(Some(
        shosai_core::library::BookFormat::Cbz,
    )));
    let import_btn = button("Import File").on_press(Message::ImportFile);
    let import_dir_btn = button("Import Folder").on_press(Message::ImportDirectory);

    // Layout density controls: keeps the grid customizable without resizing cards.
    let mut per_row_down = button("-");
    if state.library_cards_per_row > LIBRARY_CARDS_PER_ROW_MIN {
        per_row_down = per_row_down.on_press(Message::LibraryCardsPerRowDecrement);
    }
    let mut per_row_up = button("+");
    if state.library_cards_per_row < LIBRARY_CARDS_PER_ROW_MAX {
        per_row_up = per_row_up.on_press(Message::LibraryCardsPerRowIncrement);
    }
    let per_row_label = text(format!("Per row: {}", state.library_cards_per_row)).size(14);

    let toolbar = row![
        text("Library").size(24),
        search_input,
        all_btn,
        pdf_btn,
        epub_btn,
        cbz_btn,
        per_row_down,
        per_row_label,
        per_row_up,
        import_btn,
        import_dir_btn,
    ]
    .spacing(8)
    .align_y(iced::Alignment::Center);

    let header = container(toolbar).padding(12).width(Length::Fill);

    if state.library_books.is_empty() {
        let empty_msg = if state.library_search.is_empty() && state.library_filter.is_none() {
            "No books in library. Import files to get started."
        } else {
            "No books match your search or filter."
        };

        return column![
            header,
            center(
                column![
                    text("Shosai (書斎)").size(32),
                    text(empty_msg).size(16),
                    button("Import File").on_press(Message::ImportFile),
                    button("Import Folder").on_press(Message::ImportDirectory),
                ]
                .spacing(16)
                .align_x(iced::Center),
            )
            .width(Length::Fill)
            .height(Length::Fill),
        ]
        .into();
    }

    // Grid of book covers (wrap flow).
    let cover_width = 150.0_f32;
    let cover_height = 200.0_f32;

    // Build grid as rows of cards.
    let cards_per_row = state.library_cards_per_row;
    let mut grid = column![].spacing(12);
    let mut current_row: Vec<Element<'_, Message>> = Vec::new();

    for book in &state.library_books {
        current_row.push(render_book_card(book, cover_width, cover_height));
        if current_row.len() >= cards_per_row {
            grid = grid.push(row(std::mem::take(&mut current_row)).spacing(12));
        }
    }
    if !current_row.is_empty() {
        grid = grid.push(row(current_row).spacing(12));
    }

    let content = scrollable(container(grid).padding(12).width(Length::Fill))
        .width(Length::Fill)
        .height(Length::Fill);

    column![header, content].into()
}

fn render_book_card<'a>(book: &Book, width: f32, height: f32) -> Element<'a, Message> {
    let file_path = book.file_path.clone();

    // Cover image or placeholder.
    let cover: Element<'_, Message> = if let Some(ref cover_data) = book.cover {
        if let Ok(img) = ::image::load_from_memory(cover_data) {
            let rgba = img.to_rgba8();
            let (w, h) = rgba.dimensions();
            let handle = image::Handle::from_rgba(w, h, rgba.into_raw());
            image(handle)
                .width(Length::Fixed(width))
                .height(Length::Fixed(height))
                .content_fit(iced::ContentFit::Cover)
                .into()
        } else {
            cover_placeholder(width, height, &book.title)
        }
    } else {
        cover_placeholder(width, height, &book.title)
    };

    let title_text = text(book.title.clone())
        .size(12)
        .wrapping(iced::widget::text::Wrapping::WordOrGlyph);

    let format_label = text(book.format.as_str().to_uppercase()).size(10);

    let card = column![cover, title_text, format_label]
        .spacing(4)
        .width(Length::Fixed(width));

    button(card)
        .on_press(Message::OpenBook(file_path))
        .padding(4)
        .width(Length::Fixed(width + 8.0))
        .into()
}

fn cover_placeholder<'a>(width: f32, height: f32, title: &str) -> Element<'a, Message> {
    let label = text(title.chars().take(20).collect::<String>())
        .size(14)
        .color(iced::Color::WHITE);

    container(center(label))
        .width(Length::Fixed(width))
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

pub fn subscription(_state: &State) -> Subscription<Message> {
    keyboard::listen().map(Message::KeyPressed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_with_document(document: OpenDocument) -> State {
        State {
            screen: Screen::Reader,
            file_path: None,
            document: Some(document),
            current_page: 0,
            total_pages: 1,
            zoom: ZoomMode::default(),
            rendered_page: None,
            chapter_content: Vec::new(),
            page_input: "1".to_string(),
            error: None,
            font_size: 16.0,
            line_spacing: 1.6,
            theme: ReaderTheme::default(),
            reading_state: None,
            library: None,
            bookmark_store: None,
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
            library_cards_per_row: LIBRARY_CARDS_PER_ROW_DEFAULT,
        }
    }

    #[test]
    fn opening_search_requests_focus_for_the_query_input() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(epub));

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
        let mut state = state_with_document(OpenDocument::Cbz(cbz));

        let _ = update(&mut state, Message::ToggleSearchBar);

        assert!(!state.show_search_bar);
    }

    #[test]
    fn stale_search_completions_do_not_replace_current_state() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(epub));
        state.file_path = Some(PathBuf::from("book.epub"));
        state.search_document_generation = 2;
        state.search_query_generation = 3;
        state.search_query = "same query again".to_string();
        state.search_loading = true;

        let _ = update(
            &mut state,
            Message::SearchTextExtracted {
                document_generation: 1,
                text: Arc::new(vec!["stale text".to_string()]),
            },
        );
        let _ = update(
            &mut state,
            Message::SearchPerformed {
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
    fn changing_query_immediately_clears_previous_results() {
        let epub = EpubDoc::from_bytes(
            include_bytes!("../../shosai-core/tests/fixtures/sample.epub").to_vec(),
        )
        .expect("fixture should be a valid EPUB");
        let mut state = state_with_document(OpenDocument::Epub(epub));
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
        let nodes = vec![ContentNode::BlockQuote(vec![
            ContentNode::Heading {
                level: 2,
                text: "A heading".to_string(),
                style: Default::default(),
            },
            ContentNode::OrderedList(vec![vec![shosai_core::epub::render::TextSpan {
                text: "list item".to_string(),
                bold: true,
                italic: false,
                monospace: false,
                link: None,
            }]]),
        ])];
        let extracted = shosai_core::search::extract_text_from_nodes(&nodes);
        let rendered_length: usize = nodes
            .iter()
            .map(|node| content_node_text_len(node) + 1)
            .sum();

        assert_eq!(rendered_length, extracted.chars().count());
    }
}
