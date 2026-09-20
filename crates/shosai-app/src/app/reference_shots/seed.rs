//! Disposable deterministic library seeds.
//!
//! The capture harness never touches a real user library: every store lives in
//! a `tempfile::TempDir`, so the database and the managed book copies are
//! deleted when the capture run ends.
//!
//! The seed imports the generated fixture tree with the real
//! `Library::import_file` path, so titles, authors, formats, sizes, content
//! hashes and cover blobs are all produced by production code. Only two things
//! are then normalized, because they depend on the wall clock and would make
//! ordering and the continue-reading row non-deterministic:
//!
//! - `date_added` is set to the fixed value each `SeedBook` records (the
//!   visible library order is `last_read DESC NULLS LAST, date_added DESC,
//!   id DESC`);
//! - `last_read` is set for exactly one book, the continue-reading entry.
//!
//! Everything else (progress, titles, covers) is read back through
//! `Library::get`, so the recorded inventory is what the application would see.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use shosai_core::library::{Book, Library};
use shosai_core::reading_state::ReadingStateStore;

use super::fixtures::{self, SeedBook};

/// The preferences every capture set persists before the state is built.
///
/// They are explicit so a capture never depends on the host locale or on state
/// left behind by an earlier run. `library.add_behavior = ask` is the
/// application default; the settings captures reach the other persisted values
/// by dispatching the real settings messages. Every capture starts by writing
/// this baseline back, because the captures share one disposable store per base
/// and the application persists preference changes.
pub(crate) const CAPTURE_PREFS: [(&str, &str); 7] = [
    (super::super::LANGUAGE_PREFERENCE_KEY, "en-US"),
    (super::super::ADD_BOOK_BEHAVIOR_KEY, "ask"),
    (super::super::DEFAULT_READING_MODE_KEY, "paginated"),
    (super::super::DEFAULT_READER_THEME_KEY, "light"),
    (super::super::DEFAULT_EPUB_FONT_SIZE_KEY, "16"),
    (super::super::DEFAULT_EPUB_LINE_SPACING_KEY, "1.6"),
    (super::super::DEFAULT_PDF_ZOOM_KEY, "fit-page"),
];

/// One seeded book as the application sees it after normalization.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct SeededBook {
    /// Fixture path relative to the fixture root, or `repo:<path>`.
    pub(crate) fixture: String,
    pub(crate) id: i64,
    pub(crate) title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) author: Option<String>,
    pub(crate) format: String,
    pub(crate) file_size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) content_hash: Option<String>,
    /// 0.0–1.0, rendered as a percentage on the card.
    pub(crate) progress: f64,
    pub(crate) date_added: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) last_read: Option<String>,
    /// Whether the seeded row carries a cover blob.
    pub(crate) has_cover: bool,
}

/// A seeded disposable library plus the store that owns it.
pub(crate) struct SeededLibrary {
    pub(crate) store: ReadingStateStore,
    pub(crate) library: Library,
    /// Books in `date_added` order, which is also the visible order except for
    /// the single continue-reading entry.
    pub(crate) books: Vec<SeededBook>,
}

impl SeededLibrary {
    /// The book the continue-reading row must show: the only seeded book with
    /// a `last_read` value and progress below 1.0.
    pub(crate) fn continue_reading(&self) -> Option<&SeededBook> {
        self.books
            .iter()
            .find(|book| book.last_read.is_some() && book.progress < 1.0)
    }
}

/// Resolve one seed entry to a path on disk.
pub(crate) fn seed_path(fixtures_root: &Path, file: &str) -> PathBuf {
    match file.strip_prefix("repo:") {
        Some(relative) => fixtures::repository_fixture_path(relative),
        None => fixtures_root.join(file),
    }
}

/// Build the initialized-state payload for a disposable store.
///
/// This is the *harness copy* of the parsing `boot`'s initialize task performs
/// after opening the application's store: the capture tool checks out no
/// production code for it, so the state a capture starts from is built here from
/// the same preference keys, the same `from_stored` constructors and the same
/// `stored_f32` clamp helper the application uses (`super::super::stored_f32`),
/// against a store the application never opens. Keep it aligned with `boot` when
/// that parsing changes; `capture_startup_parsing_matches_the_application_defaults`
/// and `capture_startup_parsing_reads_persisted_preferences` in
/// [`super::tests`] pin the baseline and non-default values.
pub(crate) async fn capture_initialized_state(
    store: ReadingStateStore,
) -> Result<super::super::InitializedState, String> {
    use super::super::{
        ADD_BOOK_BEHAVIOR_KEY, AddBookBehavior, DEFAULT_EPUB_FONT_SIZE_KEY,
        DEFAULT_EPUB_LINE_SPACING_KEY, DEFAULT_PDF_ZOOM_KEY, DEFAULT_READER_THEME_KEY,
        DEFAULT_READING_MODE_KEY, LANGUAGE_PREFERENCE_KEY, ReaderDefaults, WINDOW_HEIGHT_KEY,
        WINDOW_WIDTH_KEY, WINDOW_X_KEY, WINDOW_Y_KEY, stored_f32,
    };
    use crate::i18n::LanguagePreference;
    use crate::pdf::ZoomMode;
    use crate::theme::ReaderTheme;
    use shosai_core::path_from_key;
    use shosai_core::reader::ReadingMode;

    let preferences = store
        .get_prefs_async()
        .await
        .map_err(|error| error.to_string())?;
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
        (Some(width), Some(height), Some(x), Some(y)) if width >= 480 && height >= 360 => Some((
            iced::Size::new(width as f32, height as f32),
            iced::Point::new(x as f32, y as f32),
        )),
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
    let add_book_behavior =
        AddBookBehavior::from_stored(preferences.get(ADD_BOOK_BEHAVIOR_KEY).map(String::as_str));
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
    Ok(super::super::InitializedState {
        store,
        window_geometry: geometry,
        language_preference,
        managed_books_dir,
        add_book_behavior,
        reader_defaults,
    })
}

/// Write the capture preference baseline back into a base store.
///
/// Called before every capture state is built: the application persists
/// preference changes (`Message::SelectLanguage`, the settings controls), so
/// without this reset one capture's interface language would leak into the next
/// one and the set would depend on its own order.
pub(crate) async fn reset_capture_preferences(store: &ReadingStateStore) -> Result<()> {
    let prefs: Vec<(&str, String)> = CAPTURE_PREFS
        .iter()
        .map(|(key, value)| (*key, (*value).to_owned()))
        .collect();
    store
        .set_prefs_async(&prefs)
        .await
        .context("reset capture preferences")
}

/// Seed the full reference library into `data_dir` from an already written
/// fixture tree.
pub(crate) async fn seed_library(data_dir: &Path, fixtures_root: &Path) -> Result<SeededLibrary> {
    let store = open_store(data_dir).await?;
    let library = Library::new(store.pool().clone(), store.managed_books_dir());

    let mut books = Vec::new();
    for seed in fixtures::library_seed() {
        books.push(import_seed_book(&store, &library, fixtures_root, seed).await?);
    }

    reset_capture_preferences(&store).await?;

    Ok(SeededLibrary {
        store,
        library,
        books,
    })
}

/// Seed an empty library: the same schema and preferences, no books.
pub(crate) async fn seed_empty_library(data_dir: &Path) -> Result<SeededLibrary> {
    let store = open_store(data_dir).await?;
    let library = Library::new(store.pool().clone(), store.managed_books_dir());
    reset_capture_preferences(&store).await?;
    Ok(SeededLibrary {
        store,
        library,
        books: Vec::new(),
    })
}

/// The real failure text from opening a store where the data path is a file.
///
/// The disposable root is replaced by a placeholder so the captured text is
/// deterministic across runs and machines; everything else is the message the
/// application shows when storage initialization fails.
pub(crate) async fn storage_failure_message(root: &Path) -> String {
    let blocked = root.join("blocked");
    let _ = std::fs::remove_file(&blocked);
    let _ = std::fs::remove_dir_all(&blocked);
    if std::fs::write(&blocked, b"not a directory").is_err() {
        return "the disposable capture store could not be opened".to_owned();
    }
    let db_path = blocked.join("state.db");
    let error = ReadingStateStore::open_at_async_deferred_backfill(&db_path)
        .await
        .err()
        .map(|error| format!("{error:#}"))
        .unwrap_or_else(|| "the disposable capture store could not be opened".to_owned());
    error
        .replace(&db_path.display().to_string(), "<capture-data>/state.db")
        .replace(&blocked.display().to_string(), "<capture-data>")
        .replace(&root.display().to_string(), "<capture-data>")
}

pub(crate) async fn open_store(data_dir: &Path) -> Result<ReadingStateStore> {
    std::fs::create_dir_all(data_dir).with_context(|| format!("create {}", data_dir.display()))?;
    ReadingStateStore::open_at_async_deferred_backfill(&data_dir.join("state.db"))
        .await
        .context("open disposable capture store")
}

async fn import_seed_book(
    store: &ReadingStateStore,
    library: &Library,
    fixtures_root: &Path,
    seed: SeedBook,
) -> Result<SeededBook> {
    let path = seed_path(fixtures_root, seed.file);
    let imported = library
        .import_file(&path)
        .await
        .with_context(|| format!("import {}", seed.file))?;
    // Normalize the clock-dependent columns so captures are reproducible.
    sqlx::query("UPDATE books SET date_added = ?, last_read = ?, progress = ? WHERE id = ?")
        .bind(seed.date_added)
        .bind(seed.last_read)
        .bind(seed.progress)
        .bind(imported.id)
        .execute(store.pool())
        .await
        .context("normalize seeded book")?;
    let book: Book = library
        .get(imported.id)
        .await
        .context("read seeded book")?
        .with_context(|| format!("seeded book {} disappeared", seed.file))?;
    Ok(SeededBook {
        fixture: seed.file.to_owned(),
        id: book.id,
        title: book.title,
        author: book.author,
        format: book.format.as_str().to_owned(),
        file_size: book.file_size.unwrap_or_default(),
        content_hash: book.content_hash,
        progress: book.progress,
        date_added: book.date_added,
        last_read: book.last_read,
        has_cover: book.cover.is_some(),
    })
}
