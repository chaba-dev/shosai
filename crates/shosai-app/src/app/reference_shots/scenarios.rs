//! The capture table: which `1B-*` states exist, how each is reached, and which
//! acceptance-matrix rows it is reference evidence for.
//!
//! Every state is produced by dispatching the production `Message` values (see
//! [`super::harness`]); nothing here renders or edits the view. Where the
//! application has no in-process entry point for a state, the capture says so
//! in `notes` instead of inventing the state.

use std::path::{Path, PathBuf};

use shosai_core::library::{BookFormat, ManagedStorageSummary};

use super::super::{AddBookBehavior, LIBRARY_PAGE_SIZE, Message, ReadingMode};
use super::fixtures::{IMPORT_EMPTY_FOLDER, IMPORT_FOLDER, IMPORT_LONG_FILES};
use super::harness::Harness;
use super::seed::seed_path;
use crate::i18n::LanguagePreference;
use crate::pdf::ZoomMode;
use crate::theme::ReaderTheme;

/// Client sizes from the reference specification §2.2.
pub(crate) const W1280: (f32, f32) = (1280.0, 800.0);
pub(crate) const W900: (f32, f32) = (900.0, 700.0);
pub(crate) const C390: (f32, f32) = (390.0, 844.0);

/// Locale of a capture, from the reference specification §2.1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Locale {
    /// English interface.
    En,
    /// Japanese interface.
    Ja,
    /// Latin + Japanese metadata in one surface.
    Mix,
}

impl Locale {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::En => "EN",
            Self::Ja => "JA",
            Self::Mix => "MIX",
        }
    }
}

/// Which disposable state a capture starts from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Base {
    /// Full seeded library (46 books), read-only captures.
    Seeded,
    /// A second identical seed for the import-dialog captures, so the
    /// read-only library captures cannot be disturbed by them.
    Import,
    /// A third seed for the removal-in-flight capture (removal deletes a row
    /// from its disposable store).
    ImportRemoval,
    /// A fourth seed for the completed-import capture (the import adds rows to
    /// its disposable store).
    ImportCompleted,
    /// Seeded schema with no books (`LB-18`).
    Empty,
    /// No store at all: the real storage-failure state (`LB-20`).
    NoStore,
}

/// The surface a capture must have reached before it is rendered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Surface {
    /// The library grid (import dialogs are overlays on top of it).
    Library,
    /// The settings screen.
    Settings,
}

impl Surface {
    pub(crate) fn screen(self) -> super::super::Screen {
        match self {
            Self::Library => super::super::Screen::Library,
            Self::Settings => super::super::Screen::Settings,
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Library => "library",
            Self::Settings => "settings",
        }
    }
}

/// Captures that are allowed to be pixel-identical to each other.
///
/// Every entry is a pair of capture ids with the reason they legitimately share
/// pixels. The runner fails when two captures are byte-identical without being
/// listed here, because that means a capture silently shows another capture's
/// state.
pub(crate) const PIXEL_ALIASES: [(&str, &str, &str); 1] = [(
    "settings-disabled-importing-w900-en",
    "settings-disabled-removing-w900-en",
    "The settings screen disables exactly the same managed-library actions while an import and \
     while a removal run, and it renders no progress indicator, so both states legitimately \
     render the same image; `assert_reached` still checks each state separately",
)];

/// Title of the fixture that only exists in the import sources: the visible
/// post-condition of the completed-import capture.
const IMPORTED_TITLE: &str = "Tandem Draft";

/// Whether the import dialog is open with discovery finished: the shared
/// precondition of every review-dialog capture.
fn review_dialog_open(state: &super::super::State) -> bool {
    state.add_books_open && !state.add_books_discovering
}

/// Whether the import dialog shows real review rows.
fn review_rows_present(state: &super::super::State) -> bool {
    review_dialog_open(state) && !state.add_books_review_rows.is_empty()
}

/// Assert that a capture reached the surface, language and state its rows claim.
///
/// The runner calls this before rendering: a capture that silently shows the
/// wrong surface, the wrong interface language or a state that never reached the
/// flags the evidence describes is not evidence for its rows, so it must fail
/// instead of being written.
pub(crate) fn assert_reached(scenario: &Scenario, state: &super::super::State) {
    assert_eq!(
        state.screen,
        scenario.surface().screen(),
        "{}: expected the {} surface",
        scenario.id,
        scenario.surface().label()
    );
    match scenario.locale {
        // Without a store there is no persisted preference to read: the
        // application boots with `LanguagePreference::System` and only resolves
        // it once initialization succeeds, so that is the honest expectation.
        _ if scenario.base == Base::NoStore => assert_eq!(
            state.i18n.preference(),
            LanguagePreference::System,
            "{}: no store, so the interface language stays unresolved",
            scenario.id
        ),
        Locale::Ja => assert_eq!(
            state.i18n.preference(),
            LanguagePreference::Japanese,
            "{}: expected the Japanese interface",
            scenario.id
        ),
        Locale::En | Locale::Mix => assert_eq!(
            state.i18n.preference(),
            LanguagePreference::English,
            "{}: expected the English interface",
            scenario.id
        ),
    }

    // The flags the capture's rows describe. Anything listed here is claimed by
    // the scenario table, and the capture fails rather than recording an image
    // of a state that never got there.
    let reached = match scenario.kind {
        Kind::LibraryDefault | Kind::LibraryJapanese | Kind::SharpnessLibrary => {
            !state.library_loading && !state.library_books.is_empty()
        }
        Kind::LibraryLoadingSkeleton => state.library_loading,
        Kind::LibraryLoadingMore => state.library_loading && state.library_offset > 0,
        Kind::LibraryPaged => !state.library_loading && state.library_offset > 0,
        Kind::LibraryLoadError => state.library_error.is_some(),
        Kind::LibraryStorageError => state.storage_error.is_some(),
        Kind::LibraryRemovePending => state.removing_book.is_some(),
        Kind::LibraryRemoveModal => state.pending_remove_book.is_some(),
        Kind::LibraryBookMenu => state.book_menu.is_some(),
        Kind::LibrarySearchJapanese | Kind::LibrarySearchLongJapanese => {
            !state.library_search.is_empty() && !state.library_books.is_empty()
        }
        Kind::LibrarySearchNoMatches => {
            !state.library_search.is_empty() && state.library_books.is_empty()
        }
        Kind::LibrarySearchNoCover => {
            !state.library_search.is_empty()
                && !state.library_books.is_empty()
                && state.library_books.iter().all(|book| book.cover.is_none())
        }
        Kind::LibraryFilterPdf => state.library_filter.is_some(),
        Kind::LibrarySearchWithFilter => {
            state.library_filter.is_some() && !state.library_search.is_empty()
        }
        Kind::LibraryEmpty => state.library_books.is_empty() && state.library.is_some(),
        Kind::ImportEntry => state.add_books_open,
        Kind::ImportDiscoveryEnumerating | Kind::ImportDiscoveryChecking => {
            state.add_books_open && state.add_books_discovering
        }
        Kind::ImportReview | Kind::ImportFilesSelection | Kind::SharpnessImport => {
            review_rows_present(state) && !state.staged_imports.is_empty()
        }
        Kind::ImportNoSupported => review_dialog_open(state) && state.staged_imports.is_empty(),
        Kind::ImportReviewNoMatch => {
            review_dialog_open(state)
                && !state.add_books_review_search.is_empty()
                && state.add_books_review_rows.is_empty()
        }
        Kind::ImportReviewDeselectAll => {
            review_rows_present(state) && state.staged_imports.iter().all(|staged| !staged.selected)
        }
        Kind::ImportStorageCopy => review_rows_present(state) && state.add_books_copy == Some(true),
        Kind::ImportStorageCurrent => {
            review_rows_present(state) && state.add_books_copy == Some(false)
        }
        Kind::ImportInProgress => state.adding_books,
        // The import resets `book_import_completed` when it finishes, so the
        // post-condition of a completed import is its visible effect: a book
        // that only exists in the import sources is now in the library.
        Kind::ImportCompleted => {
            !state.adding_books
                && state
                    .library_books
                    .iter()
                    .any(|book| book.title == IMPORTED_TITLE)
        }
        Kind::SettingsDefault | Kind::SettingsJapanese => state.library.is_some(),
        Kind::SettingsChanged => {
            state.add_book_behavior == AddBookBehavior::Copy
                && state.reader_defaults.reading_mode == ReadingMode::Continuous
                && state.reader_defaults.theme == ReaderTheme::Dark
                && state.reader_defaults.pdf_zoom == ZoomMode::FitWidth
        }
        Kind::SettingsMoveDialog => state.pending_library_move.is_some() && !state.moving_library,
        Kind::SettingsMoveInProgress => state.moving_library,
        Kind::SettingsError => state.settings_error.is_some(),
        Kind::SettingsDisabledImporting => state.adding_books,
        Kind::SettingsDisabledRemoving => state.removing_book.is_some(),
        Kind::SettingsUnavailable => state.library.is_none() && state.storage_error.is_some(),
    };
    assert!(
        reached,
        "{}: the state never reached the flags its rows describe",
        scenario.id
    );
}

/// The capture states. Each variant is reached by production messages only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    /// The seeded library exactly as it loads.
    LibraryDefault,
    /// Same, with the interface switched to Japanese.
    LibraryJapanese,
    /// A search that matches seeded Japanese titles.
    LibrarySearchJapanese,
    /// A search that returns several long Japanese titles and authors, so the
    /// fixed title/author heights are exercised (`LB-13`).
    LibrarySearchLongJapanese,
    /// A search with no matches (distinct from an empty library).
    LibrarySearchNoMatches,
    /// A search that isolates the reused conformance book, which has no cover.
    LibrarySearchNoCover,
    /// The PDF filter selected.
    LibraryFilterPdf,
    /// A search combined with the PDF filter.
    LibrarySearchWithFilter,
    /// First-page load in flight: the skeleton state.
    LibraryLoadingSkeleton,
    /// Additional page in flight: the loading-more state.
    LibraryLoadingMore,
    /// Second page loaded: paging controls in their loaded state.
    LibraryPaged,
    /// No books at all.
    LibraryEmpty,
    /// A book card menu open.
    LibraryBookMenu,
    /// The remove-book confirmation dialog.
    LibraryRemoveModal,
    /// Removal in flight: the card's removing state.
    LibraryRemovePending,
    /// A real library page failure delivered through `Message::LibraryLoaded`.
    LibraryLoadError,
    /// Storage initialization failed: the real `Message::Initialized(Err(..))`.
    LibraryStorageError,
    /// Import dialog entry state.
    ImportEntry,
    /// Discovery running, still enumerating.
    ImportDiscoveryEnumerating,
    /// Discovery finished hashing/checking but the result has not landed.
    ImportDiscoveryChecking,
    /// Discovery result: grouped review list with duplicates and failures.
    ImportReview,
    /// Review list with a filter that matches nothing.
    ImportReviewNoMatch,
    /// Review list with every row deselected through the select-all-new
    /// checkbox (selecting everything again is pixel-identical to the default
    /// review list, so the toggle is captured in its off position).
    ImportReviewDeselectAll,
    /// File selection (long Japanese paths) review list.
    ImportFilesSelection,
    /// Folder with nothing importable.
    ImportNoSupported,
    /// Storage choice: copy into the library.
    ImportStorageCopy,
    /// Storage choice: keep the current location.
    ImportStorageCurrent,
    /// Import in flight.
    ImportInProgress,
    /// Import finished; the library reflects the added books.
    ImportCompleted,
    /// Settings, defaults.
    SettingsDefault,
    /// Settings, Japanese interface.
    SettingsJapanese,
    /// Settings with every control changed from its default.
    SettingsChanged,
    /// The move-library dialog.
    SettingsMoveDialog,
    /// The move-library dialog while the move runs.
    SettingsMoveInProgress,
    /// Settings error banner from a real `ManagedLibraryMovePlanned(Err(..))`.
    SettingsError,
    /// Settings while an import runs (library actions disabled).
    SettingsDisabledImporting,
    /// Settings while a removal runs (library actions disabled).
    SettingsDisabledRemoving,
    /// Settings with no library at all (unavailable path).
    SettingsUnavailable,
    /// The library at DPR 2 (sharpness subset).
    SharpnessLibrary,
    /// The import dialog at DPR 2 (sharpness subset).
    SharpnessImport,
}

/// One capture.
#[derive(Debug, Clone)]
pub(crate) struct Scenario {
    pub(crate) id: &'static str,
    pub(crate) family: &'static str,
    pub(crate) rows: &'static [&'static str],
    pub(crate) locale: Locale,
    pub(crate) client: (f32, f32),
    pub(crate) dpr: f32,
    pub(crate) base: Base,
    pub(crate) kind: Kind,
    /// Seeded fixtures the state is built from.
    pub(crate) fixture: &'static str,
    pub(crate) notes: &'static [&'static str],
}

impl Scenario {
    /// How the state is reached, recorded in the manifest.
    pub(crate) fn derivation(&self) -> String {
        match self.kind {
            Kind::LibraryDefault => {
                "seeded library loaded through `Message::Initialized` + the real library page \
                 and cover tasks"
                    .to_owned()
            }
            Kind::LibraryJapanese => {
                "as the loaded library, then `Message::SelectLanguage(Japanese)`".to_owned()
            }
            Kind::LibrarySearchJapanese => {
                "`Message::LibrarySearchChanged(\"図書館\")` settled through its debounce"
                    .to_owned()
            }
            Kind::LibrarySearchLongJapanese => {
                "`Message::LibrarySearchChanged(\"の\")` settled through its debounce: a grid of \
                 long Japanese titles and authors"
                    .to_owned()
            }
            Kind::LibrarySearchNoMatches => {
                "`Message::LibrarySearchChanged(\"no such title\")` settled through its debounce"
                    .to_owned()
            }
            Kind::LibrarySearchNoCover => {
                "`Message::LibrarySearchChanged(\"Conformance\")` settled through its debounce"
                    .to_owned()
            }
            Kind::LibraryFilterPdf => {
                "`Message::LibraryFilterChanged(Some(Pdf))` settled".to_owned()
            }
            Kind::LibrarySearchWithFilter => {
                "`Message::LibraryFilterChanged(Some(Pdf))` then `Message::LibrarySearchChanged(\
                 \"annual\")`, both settled"
                    .to_owned()
            }
            Kind::LibraryLoadingSkeleton => {
                "`Message::RefreshLibrary` dispatched without settling its page task: the \
                 first-page load state the window shows while the page loads, with the skeleton \
                 placeholders"
                    .to_owned()
            }
            Kind::LibraryLoadingMore => {
                "`Message::LoadMoreLibrary` dispatched without settling its page task"
                    .to_owned()
            }
            Kind::LibraryPaged => "`Message::LoadMoreLibrary` settled".to_owned(),
            Kind::LibraryEmpty => {
                "an empty disposable store loaded through `Message::Initialized`".to_owned()
            }
            Kind::LibraryBookMenu => "`Message::ToggleBookMenu(first book id)`".to_owned(),
            Kind::LibraryRemoveModal => "`Message::RequestRemoveBook(first book id)`".to_owned(),
            Kind::LibraryRemovePending => {
                "`Message::RequestRemoveBook` then `Message::RemoveBook` without settling its \
                 removal task"
                    .to_owned()
            }
            Kind::LibraryLoadError => {
                "a real `Library::page` failure (oversized query) delivered through \
                 `Message::LibraryLoaded { result: Err(..) }`, exactly like a failing production \
                 load"
                    .to_owned()
            }
            Kind::LibraryStorageError => {
                "the real failure from opening a store where the data path is a file, delivered \
                 through `Message::Initialized(Err(..))`; the disposable path is replaced by a \
                 placeholder so the image stays deterministic"
                    .to_owned()
            }
            Kind::ImportEntry => "`Message::OpenAddBooks`".to_owned(),
            Kind::ImportDiscoveryEnumerating => {
                "`Message::OpenAddBooks` then `Message::AddBookFolderSelected` with the discovery \
                 task not polled: the initial enumerating phase"
                    .to_owned()
            }
            Kind::ImportDiscoveryChecking => {
                "`Message::OpenAddBooks` then `Message::AddBookFolderSelected` with the real \
                 discovery task polled to completion and its final `BooksDiscovered` message not \
                 delivered: the checking phase with real counts"
                    .to_owned()
            }
            Kind::ImportReview => {
                "`Message::OpenAddBooks` then a real `AddBookFolderSelected` discovery of the \
                 import folder, settled"
                    .to_owned()
            }
            Kind::ImportReviewNoMatch => {
                "the settled review list, then `Message::AddBooksReviewSearchChanged(\
                 \"no such book\")`"
                    .to_owned()
            }
            Kind::ImportReviewDeselectAll => {
                "the settled review list with the select-all-new checkbox pressed off, so every row \
                 is deselected"
                    .to_owned()
            }
            Kind::ImportFilesSelection => {
                "`Message::OpenAddBooks` then a real `AddBookFilesSelected` discovery of the long \
                 Japanese file paths, settled"
                    .to_owned()
            }
            Kind::ImportNoSupported => {
                "`Message::OpenAddBooks` then a real `AddBookFolderSelected` discovery of a folder \
                 with no supported books, settled"
                    .to_owned()
            }
            Kind::ImportStorageCopy => {
                "the settled review list, then `Message::SelectAddBooksStorage(true)`"
                    .to_owned()
            }
            Kind::ImportStorageCurrent => {
                "the settled review list, then `Message::SelectAddBooksStorage(false)`"
                    .to_owned()
            }
            Kind::ImportInProgress => {
                "the settled review list with a storage choice, then `Message::AddSelectedBooks` \
                 without settling its import task"
                    .to_owned()
            }
            Kind::ImportCompleted => {
                "the settled review list with a storage choice, then `Message::AddSelectedBooks` \
                 settled: the real post-import library"
                    .to_owned()
            }
            Kind::SettingsDefault => "`Message::ShowSettings`".to_owned(),
            Kind::SettingsJapanese => {
                "`Message::SelectLanguage(Japanese)` then `Message::ShowSettings`".to_owned()
            }
            Kind::SettingsChanged => {
                "`Message::ShowSettings` then the real settings messages for add behavior, reading \
                 mode, theme, EPUB font size, line spacing and PDF zoom"
                    .to_owned()
            }
            Kind::SettingsMoveDialog => {
                "`Message::ShowSettings` then `Message::ManagedLibraryMovePlanned { result: \
                 Ok(summary) }` with the summary produced by \
                 `Library::managed_storage_summary`, standing in for the native folder picker"
                    .to_owned()
            }
            Kind::SettingsMoveInProgress => {
                "as the move dialog, then `Message::ConfirmManagedLibraryMove` without settling \
                 its move task"
                    .to_owned()
            }
            Kind::SettingsError => {
                "`Message::ShowSettings` then `Message::ManagedLibraryMovePlanned { result: \
                 Err(..) }`"
                    .to_owned()
            }
            Kind::SettingsDisabledImporting => {
                "an import started for real (discovery + `Message::AddSelectedBooks` in flight), \
                 then `Message::ShowSettings`"
                    .to_owned()
            }
            Kind::SettingsDisabledRemoving => {
                "a removal started for real (`Message::RequestRemoveBook` + `Message::RemoveBook` \
                 in flight), then `Message::ShowSettings`"
                    .to_owned()
            }
            Kind::SettingsUnavailable => {
                "the storage-failure state, then `Message::ShowSettings`".to_owned()
            }
            Kind::SharpnessLibrary => "as the loaded library, rendered at DPR 2".to_owned(),
            Kind::SharpnessImport => "as the import review list, rendered at DPR 2".to_owned(),
        }
    }

    /// The surface this capture must have reached before it is rendered.
    pub(crate) fn surface(&self) -> Surface {
        match self.kind {
            Kind::SettingsDefault
            | Kind::SettingsJapanese
            | Kind::SettingsChanged
            | Kind::SettingsMoveDialog
            | Kind::SettingsMoveInProgress
            | Kind::SettingsError
            | Kind::SettingsDisabledImporting
            | Kind::SettingsDisabledRemoving
            | Kind::SettingsUnavailable => Surface::Settings,
            // Every other capture is the library; the import dialog is an
            // overlay on top of it, not a screen of its own.
            _ => Surface::Library,
        }
    }

    /// Settings that differ from the harness defaults when the capture is taken.
    pub(crate) fn settings(&self) -> Vec<String> {
        let mut settings = Vec::new();
        if self.locale == Locale::Ja {
            settings.push("language=ja (persisted by `Message::SelectLanguage`)".to_owned());
        }
        match self.kind {
            Kind::SettingsChanged => settings.extend(
                [
                    "library.add_behavior=copy (persisted)",
                    "reader.default_mode=continuous (persisted)",
                    "reader.default_theme=dark (persisted)",
                    "reader.default_epub_font_size=20 (persisted)",
                    "reader.default_epub_line_spacing=2.0 (persisted)",
                    "reader.default_pdf_zoom=fit-width (persisted)",
                ]
                .map(str::to_owned),
            ),
            Kind::ImportStorageCopy | Kind::ImportInProgress | Kind::ImportCompleted => {
                settings.push("import storage choice: copy into the library".to_owned());
            }
            Kind::ImportStorageCurrent => {
                settings.push("import storage choice: keep current location".to_owned());
            }
            _ => {}
        }
        settings
    }
}

fn wide(
    id: &'static str,
    family: &'static str,
    rows: &'static [&'static str],
    kind: Kind,
) -> Scenario {
    Scenario {
        id,
        family,
        rows,
        locale: Locale::En,
        client: W1280,
        dpr: 1.0,
        base: Base::Seeded,
        kind,
        fixture: "G1 seeded library (46 books)",
        notes: &[],
    }
}

/// The capture table.
pub(crate) fn scenarios() -> Vec<Scenario> {
    vec![
        // -- 1B-LIB-WIDE -------------------------------------------------------
        wide(
            "lib-wide-w1280-en",
            "1B-LIB-WIDE",
            &[
                "LB-01", "LB-04", "LB-06", "LB-07", "LB-11", "LB-12", "LB-16",
            ],
            Kind::LibraryDefault,
        ),
        Scenario {
            id: "lib-wide-w900-en",
            family: "1B-LIB-WIDE",
            rows: &["LB-01", "LB-07", "LB-11"],
            locale: Locale::En,
            client: W900,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryDefault,
            fixture: "G1 seeded library (46 books)",
            notes: &[
                "Iced default window (`main.rs`); wide under both breakpoints, so it is a wide \
                 reference and not a compact one",
            ],
        },
        Scenario {
            id: "lib-wide-w1280-ja",
            family: "1B-LIB-WIDE",
            rows: &["LB-03", "LB-04", "LB-05", "LB-07", "LB-11", "LB-13"],
            locale: Locale::Ja,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryJapanese,
            fixture: "G1 seeded library (46 books) + G3 Japanese/mixed metadata",
            notes: &[],
        },
        Scenario {
            id: "lib-wide-w1280-dpr2",
            family: "1B-LIB-WIDE",
            rows: &["LB-15"],
            locale: Locale::Mix,
            client: W1280,
            dpr: 2.0,
            base: Base::Seeded,
            kind: Kind::SharpnessLibrary,
            fixture: "G1 seeded library (46 books)",
            notes: &[
                "DPR 2 sharpness subset (specification `D2`); composition is identical to \
                 `lib-wide-w1280-en`, only the raster density differs",
                "cover bitmaps come from the seeded cover blobs; the lazy-load path itself \
                 (`sensor().on_show`) needs a real window and is not exercised here",
            ],
        },
        // -- 1B-LIB-COMPACT ----------------------------------------------------
        Scenario {
            id: "lib-compact-c390-en",
            family: "1B-LIB-COMPACT",
            rows: &["LB-02", "LB-05", "LB-12", "LB-18"],
            locale: Locale::En,
            client: C390,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryDefault,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-compact-c390-ja",
            family: "1B-LIB-COMPACT",
            rows: &["LB-02", "LB-03", "LB-05", "LB-13"],
            locale: Locale::Ja,
            client: C390,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryJapanese,
            fixture: "G1 seeded library (46 books) + G3 Japanese/mixed metadata",
            notes: &[
                "Iced renders no `T200` text scaling, so the 200% text row stays with the \
                 accepting package",
            ],
        },
        Scenario {
            id: "lib-breakpoint-759-en",
            family: "1B-LIB-COMPACT",
            rows: &["LB-03"],
            locale: Locale::En,
            client: (759.0, 700.0),
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryDefault,
            fixture: "G1 seeded library (46 books)",
            notes: &["`B760±` probe: compact filter row"],
        },
        Scenario {
            id: "lib-breakpoint-760-en",
            family: "1B-LIB-COMPACT",
            rows: &["LB-03"],
            locale: Locale::En,
            client: (760.0, 700.0),
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryDefault,
            fixture: "G1 seeded library (46 books)",
            notes: &["`B760±` probe: wide sidebar at the breakpoint"],
        },
        Scenario {
            id: "lib-breakpoint-761-en",
            family: "1B-LIB-COMPACT",
            rows: &["LB-03"],
            locale: Locale::En,
            client: (761.0, 700.0),
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryDefault,
            fixture: "G1 seeded library (46 books)",
            notes: &["`B760±` probe: wide sidebar"],
        },
        Scenario {
            id: "lib-compact-c390-dpr2",
            family: "1B-LIB-COMPACT",
            rows: &["LB-15"],
            locale: Locale::En,
            client: C390,
            dpr: 2.0,
            base: Base::Seeded,
            kind: Kind::SharpnessLibrary,
            fixture: "G1 seeded library (46 books)",
            notes: &["DPR 2 sharpness subset (specification `D2`)"],
        },
        // -- 1B-LIB-STATE ------------------------------------------------------
        Scenario {
            id: "lib-state-search-ja-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-08"],
            locale: Locale::Mix,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchJapanese,
            fixture: "G1 seeded library (46 books) + G3 Japanese/mixed metadata",
            notes: &[],
        },
        Scenario {
            id: "lib-state-search-no-matches-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-08", "LB-19"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchNoMatches,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-state-filter-pdf-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-06", "LB-08"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryFilterPdf,
            fixture: "G1 seeded library (46 books)",
            notes: &[
                "The CBZ filter entry is a retained Flutter extension and has no Iced filter; \
                 Iced offers All/EPUB/PDF only",
            ],
        },
        Scenario {
            id: "lib-state-search-with-filter-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-08"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchWithFilter,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-state-loading-skeleton-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-17"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryLoadingSkeleton,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-state-loading-more-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-22"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryLoadingMore,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-state-paged-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-22"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryPaged,
            fixture: "G1 seeded library (46 books)",
            notes: &["46 books: the first page holds 40, the second page holds 6"],
        },
        Scenario {
            id: "lib-state-empty-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-18"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Empty,
            kind: Kind::LibraryEmpty,
            fixture: "empty disposable store",
            notes: &[],
        },
        Scenario {
            id: "lib-state-empty-c390",
            family: "1B-LIB-STATE",
            rows: &["LB-18"],
            locale: Locale::En,
            client: C390,
            dpr: 1.0,
            base: Base::Empty,
            kind: Kind::LibraryEmpty,
            fixture: "empty disposable store",
            notes: &[],
        },
        Scenario {
            id: "lib-state-load-error-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-20"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryLoadError,
            fixture: "G1 seeded library (46 books)",
            notes: &[
                "The failure text is a real `Library` error; the library stays usable and shows \
                 the alert bar above the grid, which is Iced's load-error composition",
            ],
        },
        Scenario {
            id: "lib-state-storage-error-w900",
            family: "1B-LIB-STATE",
            rows: &["LB-20"],
            locale: Locale::En,
            client: W900,
            dpr: 1.0,
            base: Base::NoStore,
            kind: Kind::LibraryStorageError,
            fixture: "no store (real open failure)",
            notes: &[
                "Iced shows the storage failure inside the empty-library composition (there is no \
                 library to keep usable); there is no separate storage-error alert bar",
            ],
        },
        Scenario {
            id: "lib-state-book-menu-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-14"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryBookMenu,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-state-remove-modal-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-14"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibraryRemoveModal,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-state-remove-pending-w1280",
            family: "1B-LIB-STATE",
            rows: &["LB-14"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::ImportRemoval,
            kind: Kind::LibraryRemovePending,
            fixture: "G1 seeded library (46 books)",
            notes: &[
                "Runs against its own disposable seed so the removal cannot affect other captures",
            ],
        },
        // -- 1B-LIB-META -------------------------------------------------------
        Scenario {
            id: "lib-meta-no-cover-w1280",
            family: "1B-LIB-META",
            rows: &["LB-12"],
            locale: Locale::En,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchNoCover,
            fixture: "G1 seeded library (46 books)",
            notes: &[
                "`Conformance` matches the reused redistribution-safe conformance book, which has \
                 no cover image, so the placeholder keeps the 210 px cover box",
            ],
        },
        Scenario {
            id: "lib-meta-no-cover-c390",
            family: "1B-LIB-META",
            rows: &["LB-12"],
            locale: Locale::En,
            client: C390,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchNoCover,
            fixture: "G1 seeded library (46 books)",
            notes: &[],
        },
        Scenario {
            id: "lib-meta-long-ja-w1280",
            family: "1B-LIB-META",
            rows: &["LB-13"],
            locale: Locale::Mix,
            client: W1280,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchLongJapanese,
            fixture: "G3 Japanese/mixed metadata",
            notes: &[
                "The search returns only long Japanese titles and authors while the UI language \
                 stays English, so this is the mixed-metadata surface",
            ],
        },
        Scenario {
            id: "lib-meta-long-ja-c390",
            family: "1B-LIB-META",
            rows: &["LB-13"],
            locale: Locale::Mix,
            client: C390,
            dpr: 1.0,
            base: Base::Seeded,
            kind: Kind::LibrarySearchLongJapanese,
            fixture: "G3 Japanese/mixed metadata",
            notes: &[],
        },
        // -- 1B-IMPORT ---------------------------------------------------------
        import(
            "import-entry-w900-en",
            &["IM-01", "IM-10"],
            Locale::En,
            W900,
            1.0,
            Kind::ImportEntry,
            &[],
        ),
        import(
            "import-entry-w900-ja",
            &["IM-01", "IM-10"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportEntry,
            &[],
        ),
        import(
            "import-entry-c390-en",
            &["IM-10"],
            Locale::En,
            C390,
            1.0,
            Kind::ImportEntry,
            &["Compact client: the modal keeps its 680 px maximum width inside a 390 px window"],
        ),
        import(
            "import-discovery-enumerating-w900",
            &["IM-03", "IM-10"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportDiscoveryEnumerating,
            &[],
        ),
        import(
            "import-discovery-checking-w900",
            &["IM-03"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportDiscoveryChecking,
            &[
                "The reading phase (`hashed_files < total_files`) is a race between the hashing \
                 worker and the polling tick; it is not deterministically capturable in-process \
                 and stays open for 6A's own renders",
            ],
        ),
        import(
            "import-review-w900-en",
            &["IM-04", "IM-05", "IM-06", "IM-07", "IM-10"],
            Locale::En,
            W900,
            1.0,
            Kind::ImportReview,
            &[],
        ),
        import(
            "import-review-w900-ja",
            &["IM-04", "IM-05", "IM-06", "IM-07", "IM-12"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportReview,
            &[
                "The pre-choice storage state (no copy/keep decision yet) renders exactly like this \
                 review list, so IM-07's two choices are evidenced by the copy/current captures \
                 instead of a duplicate ask-state image",
            ],
        ),
        import(
            "import-review-no-match-w900-ja",
            &["IM-04"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportReviewNoMatch,
            &[],
        ),
        import(
            "import-review-deselect-all-w900-en",
            &["IM-04", "IM-05"],
            Locale::En,
            W900,
            1.0,
            Kind::ImportReviewDeselectAll,
            &[
                "Discovery selects every non-duplicate row, so pressing select-all-new on is \
                 pixel-identical to import-review-w900-en; this capture shows the toggle in its off \
                 position: all rows cleared, the duplicate row still unchecked, and the add action \
                 disabled while nothing is selected",
            ],
        ),
        import(
            "import-files-selection-w900-ja",
            &["IM-04", "IM-12"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportFilesSelection,
            &[
                "Long Japanese file paths; the native file picker itself cannot run in-process (IM-02)",
            ],
        ),
        import(
            "import-no-supported-w900-ja",
            &["IM-04"],
            Locale::Ja,
            W900,
            1.0,
            Kind::ImportNoSupported,
            &[],
        ),
        import(
            "import-storage-copy-w900-en",
            &["IM-07"],
            Locale::En,
            W900,
            1.0,
            Kind::ImportStorageCopy,
            &[],
        ),
        import(
            "import-storage-current-w900-en",
            &["IM-07"],
            Locale::En,
            W900,
            1.0,
            Kind::ImportStorageCurrent,
            &[],
        ),
        import(
            "import-progress-w900-en",
            &["IM-08"],
            Locale::En,
            W900,
            1.0,
            Kind::ImportInProgress,
            &[
                "The import task is started and deliberately left unsettled, so the header action \
                 shows the real cancel/progress label with 0 of N; mid-import counts are not \
                 captured because the parallel copy tasks complete in a scheduling-dependent order",
            ],
        ),
        Scenario {
            id: "import-completed-w900-en",
            family: "1B-IMPORT",
            rows: &["IM-08"],
            locale: Locale::En,
            client: W900,
            dpr: 1.0,
            base: Base::ImportCompleted,
            kind: Kind::ImportCompleted,
            fixture: "G1 seeded library (46 books) + import sources",
            notes: &[
                "Runs against its own disposable seed, because the import adds rows to the store",
                "The imported books are copied into the disposable managed directory; the \
                 committed library is untouched",
            ],
        },
        Scenario {
            id: "import-review-dpr2-w900",
            family: "1B-IMPORT",
            rows: &["IM-10"],
            locale: Locale::En,
            client: W900,
            dpr: 2.0,
            base: Base::Import,
            kind: Kind::SharpnessImport,
            fixture: "G1 seeded library (46 books) + import folder",
            notes: &["DPR 2 sharpness subset (specification `D2`)"],
        },
        // -- 1B-SETTINGS -------------------------------------------------------
        settings(
            "settings-wide-w900-en",
            &["ST-01", "ST-02", "ST-04", "ST-05", "ST-09"],
            Locale::En,
            W900,
            1.0,
            Kind::SettingsDefault,
            &[],
        ),
        settings(
            "settings-wide-w900-ja",
            &["ST-01", "ST-02", "ST-04", "ST-05", "ST-09"],
            Locale::Ja,
            W900,
            1.0,
            Kind::SettingsJapanese,
            &[],
        ),
        settings(
            "settings-compact-c390-en",
            &["ST-09", "ST-01"],
            Locale::En,
            C390,
            1.0,
            Kind::SettingsDefault,
            &["Compact settings stack the controls vertically"],
        ),
        settings(
            "settings-compact-c390-ja",
            &["ST-09", "ST-01"],
            Locale::Ja,
            C390,
            1.0,
            Kind::SettingsJapanese,
            &[],
        ),
        settings(
            "settings-changed-w900-en",
            &["ST-04", "ST-05"],
            Locale::En,
            W900,
            1.0,
            Kind::SettingsChanged,
            &[],
        ),
        settings(
            "settings-move-dialog-w900-ja",
            &["ST-03", "ST-07"],
            Locale::Ja,
            W900,
            1.0,
            Kind::SettingsMoveDialog,
            &[
                "The book count and size come from the real `Library::managed_storage_summary`; \
                 the destination path stands in for the native folder picker's result",
            ],
        ),
        settings(
            "settings-move-progress-w900-en",
            &["ST-03", "ST-07"],
            Locale::En,
            W900,
            1.0,
            Kind::SettingsMoveInProgress,
            &[],
        ),
        settings(
            "settings-error-w900-en",
            &["ST-06"],
            Locale::En,
            W900,
            1.0,
            Kind::SettingsError,
            &[
                "ST-06 acceptance stays with 6B's renders; this is the Iced reference for the \
                 error banner",
            ],
        ),
        settings(
            "settings-disabled-importing-w900-en",
            &["ST-07"],
            Locale::En,
            W900,
            1.0,
            Kind::SettingsDisabledImporting,
            &[],
        ),
        settings(
            "settings-disabled-removing-w900-en",
            &["ST-07"],
            Locale::En,
            W900,
            1.0,
            Kind::SettingsDisabledRemoving,
            &[],
        ),
        Scenario {
            id: "settings-unavailable-w900-en",
            family: "1B-SETTINGS",
            rows: &["ST-07"],
            locale: Locale::En,
            client: W900,
            dpr: 1.0,
            base: Base::NoStore,
            kind: Kind::SettingsUnavailable,
            fixture: "no store (real open failure)",
            notes: &["Shows the unavailable managed location and the disabled library actions"],
        },
        settings(
            "settings-compact-c390-dpr2-ja",
            &["ST-09"],
            Locale::Ja,
            C390,
            2.0,
            Kind::SettingsJapanese,
            &["DPR 2 sharpness subset (specification `D2`)"],
        ),
    ]
}

fn import(
    id: &'static str,
    rows: &'static [&'static str],
    locale: Locale,
    client: (f32, f32),
    dpr: f32,
    kind: Kind,
    notes: &'static [&'static str],
) -> Scenario {
    Scenario {
        id,
        family: "1B-IMPORT",
        rows,
        locale,
        client,
        dpr,
        base: Base::Import,
        kind,
        fixture: "G1 seeded library (46 books) + import sources (duplicates, failures, long JA paths)",
        notes,
    }
}

fn settings(
    id: &'static str,
    rows: &'static [&'static str],
    locale: Locale,
    client: (f32, f32),
    dpr: f32,
    kind: Kind,
    notes: &'static [&'static str],
) -> Scenario {
    Scenario {
        id,
        family: "1B-SETTINGS",
        rows,
        locale,
        client,
        dpr,
        base: Base::Seeded,
        kind,
        fixture: "G1 seeded library (46 books)",
        notes,
    }
}

/// The matrix rows this capture set satisfies, split by *how*: rows a capture
/// renders, rows the provenance manifest itself satisfies, and rows that are
/// deliberately left open (with the owning package and reason).
pub(crate) fn matrix_rows() -> (
    Vec<&'static str>,
    Vec<&'static str>,
    Vec<(&'static str, &'static str)>,
) {
    let captured = vec![
        "LB-01", "LB-02", "LB-03", "LB-04", "LB-05", "LB-06", "LB-07", "LB-08", "LB-11", "LB-12",
        "LB-13", "LB-14", "LB-15", "LB-16", "LB-17", "LB-18", "LB-19", "LB-20", "LB-22", "IM-01",
        "IM-03", "IM-04", "IM-05", "IM-06", "IM-07", "IM-08", "IM-10", "IM-12", "ST-01", "ST-02",
        "ST-03", "ST-04", "ST-05", "ST-06", "ST-07", "ST-09",
    ];
    // XA-10 (provenance/evidence-code row) is satisfied by `manifest.json`,
    // `captures.sha256`, `fixtures.sha256` and the README rather than by an
    // image, so it is listed separately instead of being faked as a capture.
    let manifest = vec!["XA-10"];
    let pending = vec![
        (
            "LB-09",
            "3A — Flutter keyboard behavior with no Iced counterpart",
        ),
        ("LB-10", "3A — 200% text scaling is Flutter-only (`T200`)"),
        (
            "LB-21",
            "3C — cleanup/deletion debt policy is retained Flutter/plan-owned",
        ),
        (
            "LB-23",
            "2C — library palette states are mapped and rendered by 2C (`2C-PALETTE`)",
        ),
        (
            "IM-02",
            "6A — native pickers and the Android provider path cannot run in-process",
        ),
        (
            "IM-09",
            "6A — completion summaries are Flutter behavior per the notice policy",
        ),
        ("IM-11", "2A — dialog accessibility is Flutter-owned (`WT`)"),
        (
            "ST-08",
            "6B — restart persistence and per-book precedence are behavioral (`WT`)",
        ),
        (
            "ST-10",
            "6B/6A — capability-parity review record, not a capture",
        ),
        (
            "RD-*",
            "1C — reader captures use this harness in package 1C",
        ),
    ];
    (captured, manifest, pending)
}

/// Apply a scenario to a harness, reaching the state through production
/// messages only.
pub(crate) async fn apply(scenario: &Scenario, harness: &mut Harness, fixtures_root: &Path) {
    // The interface language comes first: it is a property of the capture, not
    // of its state, and it must not be able to swallow the state dispatch (a
    // Japanese settings capture that only switched language would silently
    // render the library).
    if scenario.locale == Locale::Ja {
        harness
            .dispatch(Message::SelectLanguage(LanguagePreference::Japanese))
            .await;
    }
    match scenario.kind {
        Kind::LibraryDefault => {}
        Kind::LibraryJapanese => {}
        Kind::SettingsJapanese => {
            harness.dispatch(Message::ShowSettings).await;
        }

        Kind::SharpnessLibrary => {}

        Kind::LibrarySearchJapanese => {
            harness
                .dispatch(Message::LibrarySearchChanged("図書館".to_owned()))
                .await;
        }
        Kind::LibrarySearchLongJapanese => {
            harness
                .dispatch(Message::LibrarySearchChanged("の".to_owned()))
                .await;
        }
        Kind::LibrarySearchNoMatches => {
            harness
                .dispatch(Message::LibrarySearchChanged("no such title".to_owned()))
                .await;
        }
        Kind::LibrarySearchNoCover => {
            harness
                .dispatch(Message::LibrarySearchChanged("Conformance".to_owned()))
                .await;
        }
        Kind::LibraryFilterPdf => {
            harness
                .dispatch(Message::LibraryFilterChanged(Some(BookFormat::Pdf)))
                .await;
        }
        Kind::LibrarySearchWithFilter => {
            harness
                .dispatch(Message::LibraryFilterChanged(Some(BookFormat::Pdf)))
                .await;
            harness
                .dispatch(Message::LibrarySearchChanged("annual".to_owned()))
                .await;
        }
        Kind::LibraryLoadingSkeleton => {
            let _in_flight = harness.start(Message::RefreshLibrary);
        }
        Kind::LibraryLoadingMore => {
            let _in_flight = harness.start(Message::LoadMoreLibrary);
        }
        Kind::LibraryPaged => {
            harness.dispatch(Message::LoadMoreLibrary).await;
        }
        Kind::LibraryEmpty => {}
        Kind::LibraryBookMenu => {
            let id = first_book_id(harness);
            harness.dispatch(Message::ToggleBookMenu(id)).await;
        }
        Kind::LibraryRemoveModal => {
            let id = first_book_id(harness);
            harness.dispatch(Message::RequestRemoveBook(id)).await;
        }
        Kind::LibraryRemovePending => {
            let id = first_book_id(harness);
            harness.dispatch(Message::RequestRemoveBook(id)).await;
            let _in_flight = harness.start(Message::RemoveBook(id));
        }
        Kind::LibraryLoadError => {
            let library = harness
                .state
                .library
                .clone()
                .expect("seeded capture state has a library");
            let oversized = "x".repeat(shosai_core::library::MAX_LIBRARY_QUERY_BYTES + 1);
            let error = library
                .page(Some(&oversized), None, LIBRARY_PAGE_SIZE, 0)
                .await
                .err()
                .map(|error| format!("{error:#}"))
                .unwrap_or_else(|| "library page failed".to_owned());
            let generation = harness.state.library_generation;
            let offset = harness.state.library_offset;
            harness
                .dispatch(Message::LibraryLoaded {
                    generation,
                    offset,
                    result: Err(error),
                })
                .await;
        }
        Kind::LibraryStorageError => {
            let error = super::seed::storage_failure_message().await;
            harness.dispatch(Message::Initialized(Err(error))).await;
        }
        Kind::ImportEntry => {
            harness.dispatch(Message::OpenAddBooks).await;
        }
        Kind::ImportDiscoveryEnumerating => {
            harness.dispatch(Message::OpenAddBooks).await;
            let generation = harness.state.add_books_generation;
            let _in_flight = harness.start(Message::AddBookFolderSelected {
                generation,
                path: Some(fixtures_root.join(IMPORT_FOLDER)),
            });
        }
        Kind::ImportDiscoveryChecking => {
            harness.dispatch(Message::OpenAddBooks).await;
            let generation = harness.state.add_books_generation;
            let task = harness.start(Message::AddBookFolderSelected {
                generation,
                path: Some(fixtures_root.join(IMPORT_FOLDER)),
            });
            harness.run_without_delivery(task).await;
        }
        Kind::ImportReview
        | Kind::ImportReviewNoMatch
        | Kind::ImportReviewDeselectAll
        | Kind::ImportStorageCopy
        | Kind::ImportStorageCurrent
        | Kind::ImportInProgress
        | Kind::ImportCompleted
        | Kind::SharpnessImport => {
            open_review(harness, fixtures_root).await;
            match scenario.kind {
                Kind::ImportReviewNoMatch => {
                    harness
                        .dispatch(Message::AddBooksReviewSearchChanged(
                            "no such book".to_owned(),
                        ))
                        .await;
                }
                Kind::ImportReviewDeselectAll => {
                    harness.dispatch(Message::SelectAllStagedBooks(false)).await;
                }
                Kind::ImportStorageCopy => {
                    harness.dispatch(Message::SelectAddBooksStorage(true)).await;
                }
                Kind::ImportStorageCurrent => {
                    harness
                        .dispatch(Message::SelectAddBooksStorage(false))
                        .await;
                }
                Kind::ImportInProgress => {
                    harness.dispatch(Message::SelectAddBooksStorage(true)).await;
                    let _in_flight = harness.start(Message::AddSelectedBooks);
                }
                Kind::ImportCompleted => {
                    harness.dispatch(Message::SelectAddBooksStorage(true)).await;
                    harness.dispatch(Message::AddSelectedBooks).await;
                }
                _ => {}
            }
        }
        Kind::ImportFilesSelection => {
            harness.dispatch(Message::OpenAddBooks).await;
            let generation = harness.state.add_books_generation;
            let paths = IMPORT_LONG_FILES
                .iter()
                .map(|file| seed_path(fixtures_root, file))
                .collect();
            harness
                .dispatch(Message::AddBookFilesSelected { generation, paths })
                .await;
        }
        Kind::ImportNoSupported => {
            harness.dispatch(Message::OpenAddBooks).await;
            let generation = harness.state.add_books_generation;
            harness
                .dispatch(Message::AddBookFolderSelected {
                    generation,
                    path: Some(fixtures_root.join(IMPORT_EMPTY_FOLDER)),
                })
                .await;
        }
        Kind::SettingsDefault => {
            harness.dispatch(Message::ShowSettings).await;
        }
        Kind::SettingsChanged => {
            harness.dispatch(Message::ShowSettings).await;
            harness
                .dispatch(Message::SelectAddBookBehavior(AddBookBehavior::Copy))
                .await;
            harness
                .dispatch(Message::SelectDefaultReadingMode(ReadingMode::Continuous))
                .await;
            harness
                .dispatch(Message::SelectDefaultReaderTheme(ReaderTheme::Dark))
                .await;
            harness.dispatch(Message::DefaultEpubFontSizeUp).await;
            harness.dispatch(Message::DefaultEpubFontSizeUp).await;
            harness
                .dispatch(Message::SelectDefaultEpubLineSpacing(2.0))
                .await;
            harness
                .dispatch(Message::SelectDefaultPdfFitWidth(true))
                .await;
        }
        Kind::SettingsMoveDialog | Kind::SettingsMoveInProgress => {
            harness.dispatch(Message::ShowSettings).await;
            let summary = managed_storage_summary(harness).await;
            let generation = harness.state.managed_library_move_generation;
            harness
                .dispatch(Message::ManagedLibraryMovePlanned {
                    generation,
                    destination: move_destination(),
                    result: Ok(summary),
                })
                .await;
            if scenario.kind == Kind::SettingsMoveInProgress {
                let _in_flight = harness.start(Message::ConfirmManagedLibraryMove);
            }
        }
        Kind::SettingsError => {
            harness.dispatch(Message::ShowSettings).await;
            let generation = harness.state.managed_library_move_generation;
            harness
                .dispatch(Message::ManagedLibraryMovePlanned {
                    generation,
                    destination: move_destination(),
                    result: Err("failed to move the managed library: permission denied \
                         (capture reference text)"
                        .to_owned()),
                })
                .await;
        }
        Kind::SettingsDisabledImporting => {
            open_review(harness, fixtures_root).await;
            harness.dispatch(Message::SelectAddBooksStorage(true)).await;
            let _in_flight = harness.start(Message::AddSelectedBooks);
            harness.dispatch(Message::ShowSettings).await;
        }
        Kind::SettingsDisabledRemoving => {
            let id = first_book_id(harness);
            harness.dispatch(Message::RequestRemoveBook(id)).await;
            let _in_flight = harness.start(Message::RemoveBook(id));
            harness.dispatch(Message::ShowSettings).await;
        }
        Kind::SettingsUnavailable => {
            let error = super::seed::storage_failure_message().await;
            harness.dispatch(Message::Initialized(Err(error))).await;
            harness.dispatch(Message::ShowSettings).await;
        }
    }
}

/// The first book in the loaded grid, used by the card-action captures.
fn first_book_id(harness: &Harness) -> i64 {
    harness
        .state
        .library_books
        .first()
        .map(|book| book.id)
        .expect("seeded capture state has books")
}

async fn managed_storage_summary(harness: &Harness) -> ManagedStorageSummary {
    harness
        .state
        .library
        .clone()
        .expect("seeded capture state has a library")
        .managed_storage_summary()
        .await
        .unwrap_or_else(|error| panic!("managed storage summary failed: {error:#}"))
}

/// The destination the move dialog shows. The folder picker cannot run
/// in-process, so the capture uses a fixed, documented path.
fn move_destination() -> PathBuf {
    PathBuf::from("/tmp/shosai-reference-shots-1b-moved")
}

/// Reach the settled import review list for the fixture import folder.
async fn open_review(harness: &mut Harness, fixtures_root: &Path) {
    harness.dispatch(Message::OpenAddBooks).await;
    let generation = harness.state.add_books_generation;
    harness
        .dispatch(Message::AddBookFolderSelected {
            generation,
            path: Some(fixtures_root.join(IMPORT_FOLDER)),
        })
        .await;
}

/// The state identifier recorded in the manifest.
pub(crate) fn state_id(scenario: &Scenario) -> &'static str {
    match scenario.kind {
        Kind::LibraryDefault
        | Kind::LibraryJapanese
        | Kind::LibrarySearchJapanese
        | Kind::LibrarySearchLongJapanese
        | Kind::LibrarySearchNoMatches
        | Kind::LibrarySearchNoCover
        | Kind::LibraryFilterPdf
        | Kind::LibrarySearchWithFilter
        | Kind::LibraryLoadingSkeleton
        | Kind::LibraryLoadingMore
        | Kind::LibraryPaged
        | Kind::LibraryEmpty
        | Kind::LibraryBookMenu
        | Kind::LibraryRemoveModal
        | Kind::LibraryRemovePending
        | Kind::LibraryLoadError
        | Kind::LibraryStorageError
        | Kind::SharpnessLibrary => "library",
        Kind::ImportEntry
        | Kind::ImportDiscoveryEnumerating
        | Kind::ImportDiscoveryChecking
        | Kind::ImportReview
        | Kind::ImportReviewNoMatch
        | Kind::ImportReviewDeselectAll
        | Kind::ImportFilesSelection
        | Kind::ImportNoSupported
        | Kind::ImportStorageCopy
        | Kind::ImportStorageCurrent
        | Kind::ImportInProgress
        | Kind::ImportCompleted
        | Kind::SharpnessImport => "library+import-dialog",
        Kind::SettingsDefault
        | Kind::SettingsJapanese
        | Kind::SettingsChanged
        | Kind::SettingsMoveDialog
        | Kind::SettingsMoveInProgress
        | Kind::SettingsError
        | Kind::SettingsDisabledImporting
        | Kind::SettingsDisabledRemoving
        | Kind::SettingsUnavailable => "settings",
    }
}
