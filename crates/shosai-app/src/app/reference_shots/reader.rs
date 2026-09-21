//! Package 1C: the Iced reader reference captures.
//!
//! Reader chrome, panels, spreads and the six format/mode combinations are
//! reached through the production `Message` values on a document opened from the
//! seeded disposable library, rendered offscreen by the shared
//! [`super::runner`] and written to their own evidence directory with their own
//! manifest.
//!
//! 1C changes no 1B capture *state*, table row or manifest field. The one 1B
//! change that 1C work carries is shared and not reader-specific: the renderer
//! now encodes the application's colour order instead of the compositor's, which
//! re-encoded every committed 1B PNG (same states, same sizes, same manifest
//! fields; see `docs/reference-captures.md`, "Colour order and the 1B
//! rebaseline").
//!
//! **What an Iced reader capture can and cannot evidence.** These images are the
//! Iced reference for `1C-*` rows; they are not acceptance evidence for the
//! Flutter reader, which renders and inspects its own states (specification
//! §4.0). Two reader rows have no Iced counterpart at all and are deliberately
//! left pending here:
//!
//! - the decision-12 readability fallback (`FM-11`, `FM-12`): Iced applies a
//!   width-only 720 px rule and never falls back to one column for readability,
//!   so a large-font capture is a comparison image only;
//! - selection and highlighting (`RD-12`, `FM-16`, `FM-17`): Iced has no
//!   production interactive selection, so the authority is RFD 6 and the
//!   retained Flutter implementation, recorded by [`non_iced_authority`] and in
//!   `docs/reference-captures.md` rather than fabricated as an image.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use shosai_core::application::OpenDocument;

use super::super::{Message, ReadingMode};
use super::harness::Harness;
use super::scenarios::{Base, Locale, ReaderFacts, Scenario, Surface, W1280};
use crate::theme::ReaderTheme;

/// The reader families package 1C is assigned by the reference specification.
pub(crate) const PACKAGE_1C_FAMILIES: [&str; 9] = [
    "1C-RD-CHROME",
    "1C-RD-PANEL",
    "1C-SPREAD",
    "1C-EPUB-PAG",
    "1C-EPUB-CONT",
    "1C-PDF-PAG",
    "1C-PDF-CONT",
    "1C-CBZ-PAG",
    "1C-CBZ-CONT",
];

/// The `W900` window the Iced default client size is, at reader height 700.
const W900_READER: (f32, f32) = (900.0, 700.0);
/// `C390` at the reader height used by the compact reader captures.
const C390_READER: (f32, f32) = (390.0, 844.0);
/// `B860±` reader compact-breakpoint probes (height 700, DPR 1, panels closed).
const B860_PROBES: [(f32, f32); 3] = [(859.0, 700.0), (860.0, 700.0), (861.0, 700.0)];
/// `B720±` spread-threshold probes with all panels closed: available width
/// `client − 112` is 719 / 720 / 721.
const B720_CLOSED: [(f32, f32); 3] = [(831.0, 700.0), (832.0, 700.0), (833.0, 700.0)];
/// `B720±` spread-threshold probes with the bookmarks panel open: available
/// width `client − 112 − 300` is 719 / 720 / 721.
const B720_BOOKMARKS: [(f32, f32); 3] = [(1131.0, 700.0), (1132.0, 700.0), (1133.0, 700.0)];

/// The pointer position the hover capture injects, inside the *next-page* edge
/// control of the `W1280` client.
///
/// The control is a full-height button at the reader's right edge with 16 px
/// horizontal padding, so its strip covers the last ~50 logical pixels and the
/// vertical centre is inside it. The capture points at the next-page control
/// rather than the previous-page one because it shows the first page: a
/// previous-page control there is disabled (`app::reader_edge_button` passes
/// `on_press_maybe(None)`), and `iced_widget::button` paints
/// `Status::Disabled` — never `Status::Hovered` — for a button with no action,
/// so a pointer over it would produce no hover state at all. The frame
/// therefore shows the disabled control, the enabled control and the hovered
/// control in one state, which is what `RD-06` asks for.
const HOVER_EDGE_POSITION: (f32, f32) = (W1280.0 - 24.0, 420.0);

/// The same pointer position for the compact (`C390`) client.
///
/// The compact control keeps the full-height strip and its 8 px padding, so the
/// last ~45 logical pixels hold the 28 px glyph and the same vertical centre is
/// inside it.
const HOVER_EDGE_POSITION_COMPACT: (f32, f32) = (C390_READER.0 - 24.0, 420.0);

/// Deterministic reader fixtures, all reused from the shared generator.
///
/// 1C adds no fixture of its own: the shared reference tree already carries
/// multi-chapter EPUBs in English and Japanese, a four-page and a two-page
/// artwork-only PDF and a twelve-page CBZ, all byte-stable and all documented in
/// [`super::fixtures`]. Reusing them keeps the committed fixture tree
/// byte-identical between the two packages, so 1C changes no fixture byte.
pub(crate) const EPUB_EVEN: &str = "library/featured/slow-rivers.epub";
pub(crate) const EPUB_ODD: &str = "library/featured/quiet-cartographer.epub";
pub(crate) const EPUB_JA: &str = "library/featured/mizu-no-kioku.epub";
pub(crate) const EPUB_JA_TWO: &str = "library/featured/kaze-no-mukougawa.epub";
pub(crate) const PDF_FOUR: &str = "library/featured/small-atlas.pdf";
pub(crate) const PDF_TWO: &str = "library/featured/field-notes.pdf";
pub(crate) const CBZ_TWELVE: &str = "library/featured/comet-courier.cbz";
pub(crate) const CBZ_THREE: &str = "library/featured/comet-courier-02.cbz";

/// The generated capture-only fixture package 1C adds (lists, a quote, a link
/// and a coloured run).
pub(crate) const EPUB_MARKS: &str = "library/featured/reader-marks.epub";
/// Reused conformance fixtures that render under the pinned font environment.
pub(crate) const EPUB_LINKS: &str =
    "repo:crates/shosai-core/tests/fixtures/epub-conformance/links.epub";
pub(crate) const EPUB_BIDI: &str =
    "repo:crates/shosai-core/tests/fixtures/epub-conformance/bidi.epub";
pub(crate) const EPUB_FONTS: &str =
    "repo:crates/shosai-core/tests/fixtures/epub-conformance/fonts.epub";
pub(crate) const EPUB_FONTS_ISOLATION: &str =
    "repo:crates/shosai-core/tests/fixtures/epub-conformance/fonts-isolation.epub";
pub(crate) const EPUB_TABLE: &str =
    "repo:crates/shosai-core/tests/fixtures/epub-conformance/table.epub";
pub(crate) const EPUB_MATHML: &str =
    "repo:crates/shosai-core/tests/fixtures/epub-conformance/mathml.epub";

/// The fixture string the rich-content captures record.
const READER_SEED_LABEL: &str = "1C reader seed (the shared 46-book library + six reused \
                                    conformance fixtures + the generated reader-marks fixture)";

/// A panel state a capture opens after it reaches its document location.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Panel {
    /// Every panel closed.
    None,
    /// The Contents / saved-places panel, with no saved place yet.
    Contents,
    /// The Contents / saved-places panel with one saved place on the page.
    ContentsWithBookmark,
    /// The same, with the note editor open on the saved place.
    ContentsNoteEditor,
    /// The typography controls (`Aa`).
    Typography,
    /// The `⋯` panel (page input, bookmark, open book, search).
    More,
    /// The in-document search bar, reached through the `⋯` panel.
    Search(&'static str),
}

impl Panel {
    /// How the panel state is recorded in the manifest and the README.
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Contents => "contents",
            Self::ContentsWithBookmark => "contents+saved-place",
            Self::ContentsNoteEditor => "contents+note-editor",
            Self::Typography => "typography",
            Self::More => "more",
            Self::Search(_) => "more+search",
        }
    }

    /// The panel flags the state must carry once the capture is reached:
    /// `(bookmarks, settings, more, search)`, in the order the reader layout
    /// stacks the panels.
    pub(crate) fn flags(self) -> (bool, bool, bool, bool) {
        match self {
            Self::None => (false, false, false, false),
            Self::Contents | Self::ContentsWithBookmark | Self::ContentsNoteEditor => {
                (true, false, false, false)
            }
            Self::Typography => (false, true, false, false),
            Self::More => (false, false, true, false),
            Self::Search(_) => (false, false, true, true),
        }
    }

    /// The panel names recorded in [`ReaderFacts::panels`].
    pub(crate) fn names(self) -> Vec<String> {
        match self {
            Self::None => Vec::new(),
            Self::Contents | Self::ContentsWithBookmark | Self::ContentsNoteEditor => {
                vec!["contents".to_owned()]
            }
            Self::Typography => vec!["typography".to_owned()],
            Self::More => vec!["more".to_owned()],
            Self::Search(_) => vec!["more".to_owned(), "search".to_owned()],
        }
    }
}

/// The panel flags a reader state opens, as the reader layout stacks them:
/// `(bookmarks, settings, more, search)`.
pub(crate) fn panels_of_kind(kind: ReaderKind) -> (bool, bool, bool, bool) {
    match kind {
        ReaderKind::EpubPage { panel, .. }
        | ReaderKind::EpubContinuous { panel, .. }
        | ReaderKind::RasterPage { panel, .. }
        | ReaderKind::RasterContinuous { panel, .. } => panel.flags(),
        _ => (false, false, false, false),
    }
}

/// The value [`ReaderFacts::zoom`] records when no raster document is open.
pub(crate) const ZOOM_NOT_APPLICABLE: &str = "n/a";

/// A raster page's zoom mode.
///
/// `FM-02` and `FM-13` name fit-page, fit-width and manual. The captures record
/// fit-page and fit-width; manual is reached by `Message::ZoomIn`/`ZoomOut` from
/// the current fit scale, and the package records it as a gap rather than
/// deriving a scale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RasterZoom {
    /// Fit the page inside the reader (the application default).
    FitPage,
    /// Fit the page width, so the height may overflow.
    FitWidth,
    /// One `Message::ZoomIn` from the fit-page baseline.
    Manual,
}

impl RasterZoom {
    /// The mode name, without the manual scale.
    pub(crate) fn mode(self) -> &'static str {
        match self {
            Self::FitPage => "fit-page",
            Self::FitWidth => "fit-width",
            Self::Manual => "manual",
        }
    }

    /// The value recorded in [`ReaderFacts::zoom`].
    ///
    /// The manual mode's scale is derived by production arithmetic from the
    /// sizes of the pages the spread shows, so it is computed here from the same
    /// page-size table and a test re-derives it from the fixture bytes.
    pub(crate) fn recorded(
        self,
        fixture: &str,
        available: (f32, f32),
        visible_pages: usize,
    ) -> String {
        match self {
            Self::Manual => format!(
                "manual({})",
                manual_zoom_scale(fixture, available, visible_pages)
            ),
            other => other.mode().to_owned(),
        }
    }
}

/// The scale one `Message::ZoomIn` reaches from the fit-page baseline.
///
/// Production computes `paginated_raster_scale(state, pages) + 0.25`, clamped
/// to `[0.25, 5.0]` (`app::zoom_step_scale`), and the fit-page scale is
/// `pdf::fit_scale` over the sizes of every page the spread shows at the
/// reader's available size (`app::paginated_raster_scale`). `raster_page_size_at`
/// supplies one page's size and `visible_pages` says how many the spread shows,
/// so the declaration is arithmetic rather than an observation, and
/// `reader_manual_zoom_scales_are_rederived_from_fixture_bytes` re-derives both
/// from the fixture bytes.
pub(crate) fn manual_zoom_scale(fixture: &str, available: (f32, f32), visible_pages: usize) -> f32 {
    let page = raster_page_size_at(fixture);
    let sizes = vec![page; visible_pages.max(1)];
    let fit = crate::pdf::fit_scale(
        &sizes,
        iced::Size::new(available.0, available.1),
        super::super::PAGE_GUTTER,
        true,
    );
    (fit + 0.25).clamp(0.25, 5.0)
}

/// The page size the shared fixture generator writes for a raster fixture.
pub(crate) fn raster_page_size_at(fixture: &str) -> (f32, f32) {
    match fixture {
        PDF_FOUR | PDF_TWO => (612.0, 792.0),
        CBZ_TWELVE | CBZ_THREE => (200.0, 300.0),
        other => panic!("no declared page size for {other}"),
    }
}

/// A reader capture state.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum ReaderKind {
    /// Paginated EPUB at a 0-based page.
    EpubPage {
        fixture: &'static str,
        page: usize,
        panel: Panel,
    },
    /// Continuous EPUB: the chapter column from its top.
    EpubContinuous { fixture: &'static str, panel: Panel },
    /// Paginated PDF or CBZ at a 0-based page.
    RasterPage {
        fixture: &'static str,
        page: usize,
        panel: Panel,
        zoom: RasterZoom,
    },
    /// Continuous PDF or CBZ: the page column from its top.
    RasterContinuous { fixture: &'static str, panel: Panel },
    /// Paginated EPUB at a book font size far above the default.
    ///
    /// Comparison only: Iced has no readability fallback, so this image shows
    /// what the width-only rule does and cannot evidence `FM-11`.
    EpubLargeFont {
        fixture: &'static str,
        font_size: f32,
    },
    /// Several documents open; the selected tab is shown.
    Tabs {
        fixtures: [&'static str; 3],
        selected: usize,
    },
    /// The document-opening state (cover, title, "opening" label).
    Opening { fixture: &'static str },
    /// A book whose file has disappeared: the locate/remove alert.
    MissingFile { fixture: &'static str },
    /// A book whose file cannot be opened: the open-error alert.
    OpenError { fixture: &'static str },
    /// Paginated EPUB under a reader palette.
    Theme {
        fixture: &'static str,
        theme: ReaderTheme,
    },
    /// A paginated EPUB with the pointer delivered at a client position, so the
    /// control under it shows its hover state (`RD-06`).
    Hover {
        fixture: &'static str,
        page: usize,
        position: (f32, f32),
    },
}

/// The client position a capture injects as the pointer, if it injects one.
pub(crate) fn hover_position(kind: ReaderKind) -> Option<(f32, f32)> {
    match kind {
        ReaderKind::Hover { position, .. } => Some(position),
        _ => None,
    }
}

impl ReaderKind {
    /// How the state is reached, recorded in the manifest.
    pub(crate) fn derivation(&self) -> String {
        let open = |fixture: &str| format!("`Message::OpenLibraryBook` on `{fixture}`");
        match self {
            Self::EpubPage {
                fixture,
                page,
                panel,
            } => format!(
                "{} then the paginated EPUB location {} ({})",
                open(fixture),
                location_text(*page),
                panel_text(*panel)
            ),
            Self::EpubContinuous { fixture, panel } => format!(
                "{} then `Message::ToggleReadingMode` (continuous) ({})",
                open(fixture),
                panel_text(*panel)
            ),
            Self::RasterPage {
                fixture,
                page,
                panel,
                zoom,
            } => format!(
                "{} then the paginated raster location {}{} ({})",
                open(fixture),
                location_text(*page),
                match zoom {
                    RasterZoom::FitPage => String::new(),
                    RasterZoom::FitWidth => " then `Message::SetZoomFitWidth`".to_owned(),
                    RasterZoom::Manual => {
                        " then `Message::ZoomIn` from the fit-page baseline".to_owned()
                    }
                },
                panel_text(*panel)
            ),
            Self::RasterContinuous { fixture, panel } => format!(
                "{} then `Message::ToggleReadingMode` (continuous) ({})",
                open(fixture),
                panel_text(*panel)
            ),
            Self::EpubLargeFont { fixture, font_size } => format!(
                "{} then `Message::FontSizeUp` until the book font is {font_size} px; comparison \
                 only (Iced has no readability fallback)",
                open(fixture)
            ),
            Self::Tabs { fixtures, selected } => format!(
                "{} for {} in order, then `Message::SelectTab({selected})`",
                open(fixtures[0]),
                fixtures.join("`, `")
            ),
            Self::Opening { fixture } => format!(
                "`Message::OpenLibraryBook` on `{fixture}` with the open task left in flight and \
                 `Message::ShowDocumentOpenNotice(generation)` delivered, which is the production \
                 timer's own message for the in-flight generation"
            ),
            Self::MissingFile { fixture } => format!(
                "`Message::OpenLibraryBook` on `{fixture}` after its disposable copy is removed: \
                 the real missing-file state, restored immediately afterwards so the committed \
                 fixture tree stays complete"
            ),
            Self::OpenError { fixture } => format!(
                "`Message::OpenLibraryBook` on `{fixture}` is started and left in flight; its \
                 disposable copy is then overwritten with bytes that are not a document, the \
                 production preparation path reports the real failure for those bytes, and that \
                 failure is delivered through the production `Message::DocumentOpened {{ result: \
                 Err(..) }}` for the in-flight generation. The original bytes are written back \
                 immediately afterwards, so the committed fixture tree stays complete"
            ),
            Self::Theme { fixture, theme } => format!(
                "{} then `Message::CycleTheme` until the reader palette is `{}`",
                open(fixture),
                theme.stored()
            ),
            Self::Hover {
                fixture,
                page,
                position,
            } => format!(
                "{} then the paginated EPUB location {}; the frame is drawn with the pointer \
                 delivered at ({}, {}), which is inside the enabled next-page edge control, so that \
                 control paints the hover state a window would show while the previous-page control \
                 stays disabled on the first page",
                open(fixture),
                location_text(*page),
                position.0,
                position.1
            ),
        }
    }

    /// The reader state this capture declares before it is rendered.
    ///
    /// These are independent expectations, not observations: the runner
    /// compares them with the state it actually reached and fails instead of
    /// writing an image whose manifest would describe a state it never showed.
    pub(crate) fn facts(&self, client: (f32, f32)) -> ReaderFacts {
        match self {
            Self::EpubPage {
                fixture,
                page,
                panel,
            } => epub_facts(fixture, *page, *panel, client, 16.0),
            Self::EpubContinuous { fixture, panel } => {
                let mut facts = epub_facts(fixture, 0, *panel, client, 16.0);
                facts.mode = "continuous".to_owned();
                facts.spread = false;
                facts.visible_pages.clear();
                facts
            }
            Self::RasterPage {
                fixture,
                page,
                panel,
                zoom,
            } => raster_facts(fixture, *page, *panel, client, *zoom),
            Self::RasterContinuous { fixture, panel } => {
                let mut facts = raster_facts(fixture, 0, *panel, client, RasterZoom::FitPage);
                facts.mode = "continuous".to_owned();
                facts.spread = false;
                facts.visible_pages.clear();
                facts
            }
            Self::EpubLargeFont { fixture, font_size } => {
                epub_facts(fixture, 0, Panel::None, client, *font_size)
            }
            Self::Tabs { fixtures, selected } => {
                let mut facts = epub_facts(fixtures[*selected], 0, Panel::None, client, 16.0);
                facts.tabs = fixtures.len();
                facts
            }
            // These captures have no open document: the alert or the opening
            // composition is what the reader shows, so the document fields stay
            // empty and only the reader geometry and the book-text defaults are
            // claimed.
            Self::Opening { .. } | Self::MissingFile { .. } | Self::OpenError { .. } => {
                blank_facts(client)
            }
            Self::Theme { fixture, theme } => {
                let mut facts = epub_facts(fixture, 0, Panel::None, client, 16.0);
                facts.theme = theme.stored().to_owned();
                facts
            }
            Self::Hover { fixture, page, .. } => {
                epub_facts(fixture, *page, Panel::None, client, 16.0)
            }
        }
    }
}

fn location_text(page: usize) -> String {
    format!("page {}", page + 1)
}

fn panel_text(panel: Panel) -> String {
    match panel {
        Panel::None => "no panel open".to_owned(),
        Panel::Search(query) => format!("`Message::ToggleSearchBar` and the query `{query}`"),
        other => format!("`{}` open", other.code()),
    }
}

/// The file name of a fixture reference, used as the document identity.
pub(crate) fn file_name(fixture: &str) -> String {
    fixture.rsplit('/').next().unwrap_or(fixture).to_owned()
}

/// The format code of a fixture, from its extension.
pub(crate) fn format_of(fixture: &str) -> &'static str {
    if fixture.ends_with(".epub") {
        "epub"
    } else if fixture.ends_with(".pdf") {
        "pdf"
    } else if fixture.ends_with(".cbz") {
        "cbz"
    } else {
        "unknown"
    }
}

// ---------------------------------------------------------------------------
// The capture table
// ---------------------------------------------------------------------------

/// One reader capture.
#[allow(clippy::too_many_arguments)]
fn reader(
    id: &'static str,
    family: &'static str,
    rows: &'static [&'static str],
    locale: Locale,
    client: (f32, f32),
    dpr: f32,
    kind: ReaderKind,
    notes: &'static [&'static str],
) -> Scenario {
    Scenario {
        id,
        family,
        rows,
        locale,
        client,
        dpr,
        base: Base::Seeded,
        kind: super::scenarios::Kind::Reader(kind),
        fixture: "G1 seeded library (46 books) + reader fixtures",
        reader: Some(kind.facts(client)),
        notes,
    }
}

/// One reader capture on the rich-content base seed.
#[allow(clippy::too_many_arguments)]
fn reader_rich(
    id: &'static str,
    family: &'static str,
    rows: &'static [&'static str],
    locale: Locale,
    client: (f32, f32),
    dpr: f32,
    kind: ReaderKind,
    notes: &'static [&'static str],
) -> Scenario {
    Scenario {
        id,
        family,
        rows,
        locale,
        client,
        dpr,
        base: Base::Reader,
        kind: super::scenarios::Kind::Reader(kind),
        fixture: READER_SEED_LABEL,
        reader: Some(kind.facts(client)),
        notes,
    }
}

/// The capture table.
pub(crate) fn scenarios() -> Vec<Scenario> {
    let mut scenarios = vec![
        // -- 1C-RD-CHROME -----------------------------------------------------
        reader(
            "rd-chrome-w1280-en",
            "1C-RD-CHROME",
            &["RD-01", "RD-05", "RD-06"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &[
                "Wide chrome: the back action, the centred 17 px title, Contents/`Aa`/`⋯`, the 36 px \
                 edge glyphs, the 280 px progress bar and the 11 px page-range status, all with every \
                 panel closed",
            ],
        ),
        reader(
            "rd-chrome-w1280-ja",
            "1C-RD-CHROME",
            &["RD-01", "RD-03", "RD-05"],
            Locale::Ja,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_JA,
                page: 0,
                panel: Panel::None,
            },
            &[
                "Japanese interface and a Japanese book: the tab label, the header title, the \
                 status-bar page wording and the progress label",
            ],
        ),
        reader(
            "rd-chrome-tabs-w1280-ja",
            "1C-RD-CHROME",
            &["RD-03"],
            Locale::Ja,
            W1280,
            1.0,
            ReaderKind::Tabs {
                fixtures: [EPUB_EVEN, EPUB_ODD, EPUB_JA],
                selected: 0,
            },
            &[
                "Three documents open: the selected tab keeps the surface + border treatment, the \
                 other two stay reachable, and every tab carries its close control",
                "`RD-04` (decision-11 overflow, automatic active-tab reveal, keyboard close) has no \
                 Iced implementation and is not claimed by this capture",
            ],
        ),
        reader(
            "rd-chrome-c390-ja",
            "1C-RD-CHROME",
            &["RD-02", "RD-06"],
            Locale::Ja,
            C390_READER,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_JA,
                page: 0,
                panel: Panel::None,
            },
            &[
                "Compact chrome below the 860 px breakpoint: the 15 px title truncated at 24 \
                 characters, the 28 px edge glyphs and the compact spacing",
                "`T200` UI text scaling has no Iced counterpart and stays with the accepting \
                 package",
            ],
        ),
        reader(
            "rd-chrome-b860-859-en",
            "1C-RD-CHROME",
            &["RD-02"],
            Locale::En,
            B860_PROBES[0],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &["`B860±` probe: compact chrome at 859 (available reader width 747, still a spread)"],
        ),
        reader(
            "rd-chrome-b860-860-en",
            "1C-RD-CHROME",
            &["RD-01"],
            Locale::En,
            B860_PROBES[1],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &[
                "`B860±` probe: the breakpoint itself, where compact chrome ends and the wide \
                 header starts (available reader width 748, still a spread)",
            ],
        ),
        reader(
            "rd-chrome-b860-861-en",
            "1C-RD-CHROME",
            &["RD-01"],
            Locale::En,
            B860_PROBES[2],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &["`B860±` probe: wide chrome at 861 (available reader width 749, still a spread)"],
        ),
        reader(
            "rd-chrome-opening-w900-en",
            "1C-RD-CHROME",
            &["RD-16"],
            Locale::En,
            W900_READER,
            1.0,
            ReaderKind::Opening { fixture: EPUB_EVEN },
            &[
                "The document-opening composition: the 140×200 cover (a real decoded cover handle), \
                 the 16 px title and the 13 px label, capped at 320 logical pixels",
                "The open task is deliberately left unsettled and the production timer's own \
                 `ShowDocumentOpenNotice` message for the in-flight generation is delivered: this is \
                 the state a window shows while a document opens, not a synthesized one",
            ],
        ),
        reader(
            "rd-chrome-missing-file-w900-en",
            "1C-RD-CHROME",
            &["RD-17"],
            Locale::En,
            W900_READER,
            1.0,
            ReaderKind::MissingFile { fixture: EPUB_EVEN },
            &[
                "A real missing-file state: the disposable copy of the seeded book is removed before \
                 `Message::OpenLibraryBook` is dispatched, so the alert, the locate action and the \
                 remove action are production output",
                "The fixture is written back immediately afterwards, so the committed fixture tree \
                 and its checksums stay complete",
            ],
        ),
        reader(
            "rd-chrome-open-error-w900-en",
            "1C-RD-CHROME",
            &["RD-17"],
            Locale::En,
            W900_READER,
            1.0,
            ReaderKind::OpenError { fixture: EPUB_EVEN },
            &[
                "A real open failure: the disposable copy is overwritten with bytes that are not a \
                 document, the production preparation path reports the failure for those bytes, and \
                 it is delivered through the production `Message::DocumentOpened { result: Err(..) }` \
                 for the in-flight generation, so the alert text is the production document-open \
                 error rather than a substituted message",
                "The fixture is written back immediately afterwards, so the committed fixture tree \
                 and its checksums stay complete",
            ],
        ),
        reader(
            "rd-chrome-hover-edge-w1280-en",
            "1C-RD-CHROME",
            &["RD-06"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::Hover {
                fixture: EPUB_EVEN,
                page: 0,
                position: HOVER_EDGE_POSITION,
            },
            &[
                "`RD-06`'s hover state next to its disabled state: the frame is drawn with the \
                 pointer delivered at the enabled next-page edge control, which paints the hover \
                 background a window would paint (`theme::reader_edge_button`'s hovered style), \
                 while the previous-page control on the first page stays disabled and paints none",
                "The pointer position is recorded in the manifest; a regression test requires the \
                 committed image to differ from the same state without a pointer, and to differ \
                 only inside the edge-control strip",
            ],
        ),
        reader(
            "rd-chrome-hover-edge-c390-ja",
            "1C-RD-CHROME",
            &["RD-06"],
            Locale::Ja,
            C390_READER,
            1.0,
            ReaderKind::Hover {
                fixture: EPUB_JA,
                page: 0,
                position: HOVER_EDGE_POSITION_COMPACT,
            },
            &[
                "`RD-06` at the compact configuration: the same enabled next-page control hovered \
                 at the 28 px compact glyph and 8 px padding, with the disabled previous-page \
                 control beside it",
                "The pointer position is recorded in the manifest; the same regression test that \
                 covers the wide hover capture requires this image to differ from its pointer-free \
                 render only inside the edge-control strip",
            ],
        ),
        reader(
            "rd-chrome-theme-dark-w1280-en",
            "1C-RD-CHROME",
            &["RD-01"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::Theme {
                fixture: EPUB_EVEN,
                theme: ReaderTheme::Dark,
            },
            &[
                "The reader surface under the dark palette (`theme.rs`); `XA-11`'s mapped Flutter \
                 render stays with 2C/5G, this is the Iced reference",
            ],
        ),
        reader(
            "rd-chrome-theme-sepia-w1280-en",
            "1C-RD-CHROME",
            &["RD-01"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::Theme {
                fixture: EPUB_EVEN,
                theme: ReaderTheme::Sepia,
            },
            &[
                "The reader surface under the sepia palette (`theme.rs`); `XA-11`'s mapped Flutter \
                 render stays with 2C/5G, this is the Iced reference",
            ],
        ),
        // -- 1C-RD-PANEL ------------------------------------------------------
        reader(
            "rd-panel-contents-w1280-ja",
            "1C-RD-PANEL",
            &["RD-07"],
            Locale::Ja,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_JA,
                page: 0,
                panel: Panel::Contents,
            },
            &[
                "The Contents panel: the 18 px heading, the 11 px subheading and the chapter list, \
                 which is Iced's table of contents (there are no saved places yet in this capture)",
            ],
        ),
        reader(
            "rd-panel-saved-places-empty-w1280-en",
            "1C-RD-PANEL",
            &["RD-08"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Contents,
            },
            &[
                "The saved-places empty state: the disposable store carries no bookmark for this \
                 capture, and the run clears reader state between captures so the order of the \
                 captures cannot change that",
            ],
        ),
        reader(
            "rd-panel-saved-place-w1280-en",
            "1C-RD-PANEL",
            &["RD-08"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 1,
                panel: Panel::ContentsWithBookmark,
            },
            &[
                "One saved place, created by `Message::ToggleBookmark` on the page this capture is \
                 on: the entry shows its page label and its edit/delete actions",
            ],
        ),
        reader(
            "rd-panel-note-editor-w1280-en",
            "1C-RD-PANEL",
            &["RD-08"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 1,
                panel: Panel::ContentsNoteEditor,
            },
            &[
                "The saved place with its note editor open (`Message::StartEditNote` on the real \
                 bookmark id plus `Message::EditNoteChanged`), which is how a note is written",
            ],
        ),
        reader(
            "rd-panel-typography-epub-w1280-en",
            "1C-RD-PANEL",
            &["RD-09"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Typography,
            },
            &[
                "The EPUB typography controls: `A−`/`A+` around the 16 px book-font label and the \
                 palette cycle button",
            ],
        ),
        reader(
            "rd-panel-typography-pdf-w1280-en",
            "1C-RD-PANEL",
            &["RD-09"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: PDF_FOUR,
                page: 0,
                panel: Panel::Typography,
                zoom: RasterZoom::FitPage,
            },
            &[
                "The PDF/CBZ controls: zoom `−`/`+`, the percentage label and the fit-width/fit-page \
                 pair, which replace the EPUB font controls for a non-reflowable document",
            ],
        ),
        reader(
            "rd-panel-more-w1280-en",
            "1C-RD-PANEL",
            &["RD-10"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::More,
            },
            &[
                "The `⋯` panel in its wide composition: the page input with `of N`, the bookmark \
                 toggle, the open-book action and the search toggle on one row",
            ],
        ),
        reader(
            "rd-panel-more-c390-en",
            "1C-RD-PANEL",
            &["RD-10"],
            Locale::En,
            C390_READER,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::More,
            },
            &["The `⋯` panel in its compact composition: the page row stacks above the actions"],
        ),
        reader(
            "rd-panel-search-w1280-en",
            "1C-RD-PANEL",
            &["RD-11"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Search("the"),
            },
            &[
                "The search bar with real results: the query went through the production debounce and \
                 the production search worker, so `n / total`, the previous/next actions and the close \
                 control all read from the settled result",
            ],
        ),
        reader(
            "rd-panel-search-c390-en",
            "1C-RD-PANEL",
            &["RD-11"],
            Locale::En,
            C390_READER,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Search("the"),
            },
            &["The compact search bar, below the compact `⋯` panel that opened it"],
        ),
        // -- 1C-EPUB-PAG ------------------------------------------------------
        reader(
            "rd-epub-pag-w1280-en",
            "1C-EPUB-PAG",
            &["FM-01"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 1,
                panel: Panel::None,
            },
            &[
                "Paginated EPUB: styled headings and body text composed by the production view, the \
                 page-number footer and the spread pairing",
                "The composited page is written as full RGBA; `FM-18` acceptance (document colours \
                 survive compositing) is plan 5G's, so the row is recorded as pending for 1C",
            ],
        ),
        reader(
            "rd-epub-pag-w1280-ja",
            "1C-EPUB-PAG",
            &["FM-01"],
            Locale::Ja,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_JA,
                page: 1,
                panel: Panel::None,
            },
            &["Japanese pagination and Japanese interface text in the same capture"],
        ),
        reader(
            "rd-epub-pag-dpr2-w1280-en",
            "1C-EPUB-PAG",
            &["FM-01"],
            Locale::En,
            W1280,
            2.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &[
                "DPR 2 sharpness subset (specification `D2`): the composition is the DPR 1 capture, \
                 only the raster density differs",
                "`FM-19`/`XA-09` acceptance stays with 6C",
            ],
        ),
        // -- 1C-EPUB-CONT -----------------------------------------------------
        reader(
            "rd-epub-cont-w1280-ja",
            "1C-EPUB-CONT",
            &["FM-04"],
            Locale::Ja,
            W1280,
            1.0,
            ReaderKind::EpubContinuous {
                fixture: EPUB_JA,
                panel: Panel::None,
            },
            &[
                "Continuous EPUB: the chapter column with 32 px chapter spacing and 20 px content \
                 padding, no page boxes, no per-page titles and no footers",
            ],
        ),
        reader(
            "rd-epub-cont-w1280-en",
            "1C-EPUB-CONT",
            &["FM-04"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubContinuous {
                fixture: EPUB_EVEN,
                panel: Panel::None,
            },
            &[
                "Continuous EPUB in English: four chapters in one column, each with its own heading \
                 and body text",
                "The offscreen renderer has no scroll interaction, so the column is captured from its \
                 top; `FM-14`'s tile seams are a Flutter/renderer deliverable (`5H-RENDER`) and are \
                 not claimed here",
            ],
        ),
        // -- 1C-PDF-PAG -------------------------------------------------------
        reader(
            "rd-pdf-pag-w1280-en",
            "1C-PDF-PAG",
            &["FM-02"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: PDF_FOUR,
                page: 1,
                panel: Panel::None,
                zoom: RasterZoom::FitPage,
            },
            &[
                "Paginated PDF: the raster pages produced by the native PDFium backend at the \
                 fit-page scale, with the page label in the status bar",
                "The generated PDF draws shapes only, so the raster does not depend on host fonts; \
                 the native PDFium identity is recorded in the manifest as run metadata",
            ],
        ),
        reader(
            "rd-pdf-fit-width-w1280-en",
            "1C-PDF-PAG",
            &["FM-02", "FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: PDF_FOUR,
                page: 1,
                panel: Panel::None,
                zoom: RasterZoom::FitWidth,
            },
            &[
                "The second fit mode of `FM-02`, and the fit-width spread `FM-13` names: \
                 `Message::SetZoomFitWidth` on the same page as `rd-pdf-pag-w1280-en`, so the \
                 spread fills the reader width instead of fitting inside it",
                "Manual zoom (the third mode both rows name) is reached by \
                 `Message::ZoomIn`/`ZoomOut` from the current fit scale and is recorded as a gap \
                 in the package limitations",
            ],
        ),
        reader(
            "rd-pdf-manual-zoom-w1280-en",
            "1C-PDF-PAG",
            &["FM-02", "FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: PDF_FOUR,
                page: 1,
                panel: Panel::None,
                zoom: RasterZoom::Manual,
            },
            &[
                "The third fit mode `FM-02` and `FM-13` name: one `Message::ZoomIn` from the \
                 fit-page baseline, recorded as the production arithmetic's own scale",
                "The declared scale is re-derived by a regression test from the fixture's page \
                 size, so a change in the arithmetic fails the test instead of drifting the \
                 manifest",
            ],
        ),
        // -- 1C-PDF-CONT ------------------------------------------------------
        reader(
            "rd-pdf-cont-w1280-en",
            "1C-PDF-CONT",
            &["FM-05"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterContinuous {
                fixture: PDF_FOUR,
                panel: Panel::None,
            },
            &[
                "Continuous PDF: the page column with 20 px spacing and 20 px padding and its page \
                 labels",
            ],
        ),
        // -- 1C-CBZ-PAG -------------------------------------------------------
        reader(
            "rd-cbz-pag-w1280-en",
            "1C-CBZ-PAG",
            &["FM-03", "FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: CBZ_TWELVE,
                page: 2,
                panel: Panel::None,
                zoom: RasterZoom::FitPage,
            },
            &[
                "Paginated CBZ: the raster pages at the document's natural page size, decoded by the \
                 in-process `image` path rather than PDFium",
                "The CBZ page pair is also the fit-page CBZ spread `FM-13` names: the two pages sit \
                 side by side in their own slots",
            ],
        ),
        reader(
            "rd-cbz-fit-width-w1280-en",
            "1C-CBZ-PAG",
            &["FM-03", "FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: CBZ_TWELVE,
                page: 2,
                panel: Panel::None,
                zoom: RasterZoom::FitWidth,
            },
            &[
                "The CBZ fit-width spread: `Message::SetZoomFitWidth` scales the natural page to \
                 the reader width, so the page is wider than the fit-page capture of the same page \
                 and overflows the viewport height",
                "`FM-13`'s fit modes: this is the CBZ fit-width half of the row, next to the PDF \
                 fit-width and fit-page captures",
            ],
        ),
        reader(
            "rd-cbz-manual-zoom-w1280-en",
            "1C-CBZ-PAG",
            &["FM-03", "FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: CBZ_TWELVE,
                page: 2,
                panel: Panel::None,
                zoom: RasterZoom::Manual,
            },
            &[
                "The CBZ manual-zoom half of `FM-13`: one `Message::ZoomIn` from the fit-page \
                 baseline, so the recorded scale is the production arithmetic's own value rather \
                 than a chosen number",
                "The declared scale is re-derived by a regression test from the fixture's page \
                 size, so a change in the arithmetic fails the test instead of drifting the \
                 manifest",
            ],
        ),
        // -- 1C-CBZ-CONT ------------------------------------------------------
        reader(
            "rd-cbz-cont-w1280-en",
            "1C-CBZ-CONT",
            &["FM-06"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterContinuous {
                fixture: CBZ_TWELVE,
                panel: Panel::None,
            },
            &["Continuous CBZ: the same column behavior as the PDF continuous mode"],
        ),
        // -- 1C-SPREAD --------------------------------------------------------
        reader(
            "rd-spread-first-w1280-en",
            "1C-SPREAD",
            &["FM-07", "FM-10"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_ODD,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The first spread: two distinct consecutive pages side by side, with no reserved \
                 slot before them",
            ],
        ),
        reader(
            "rd-spread-last-w1280-en",
            "1C-SPREAD",
            &["FM-10"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 2,
                panel: Panel::None,
            },
            &[
                "The last spread of an even page count: the final pair, neither page orphaned and \
                 neither repeated",
            ],
        ),
        reader(
            "rd-spread-odd-final-w1280-en",
            "1C-SPREAD",
            &["FM-08", "FM-10"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_ODD,
                page: 2,
                panel: Panel::None,
            },
            &[
                "An odd page count: the final spread shows exactly one page in its half-width slot, \
                 no blank page is inserted and the last page is not repeated",
            ],
        ),
        reader(
            "rd-spread-w1280-ja",
            "1C-SPREAD",
            &["FM-07"],
            Locale::Ja,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_JA_TWO,
                page: 0,
                panel: Panel::None,
            },
            &["The Japanese spread: two consecutive Japanese pages with the Japanese interface"],
        ),
        reader(
            "rd-spread-narrow-c390-en",
            "1C-SPREAD",
            &["FM-08"],
            Locale::En,
            C390_READER,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &[
                "Narrow single-page mode: one page fills the row with no reserved second slot \
                 (available reader width 278)",
            ],
        ),
        reader(
            "rd-spread-b720-831-en",
            "1C-SPREAD",
            &["FM-09"],
            Locale::En,
            B720_CLOSED[0],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &[
                "`B720±` probe, panels closed: available reader width 719, below the spread \
                 threshold, so one page fills the row",
                "The client width is also below the 860 px reader breakpoint, so this probe \
                 exercises compact chrome with a single page",
            ],
        ),
        reader(
            "rd-spread-b720-832-en",
            "1C-SPREAD",
            &["FM-09"],
            Locale::En,
            B720_CLOSED[1],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &[
                "`B720±` probe, panels closed: available reader width 720, the threshold itself, \
                 where the spread starts",
            ],
        ),
        reader(
            "rd-spread-b720-833-en",
            "1C-SPREAD",
            &["FM-09"],
            Locale::En,
            B720_CLOSED[2],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::None,
            },
            &["`B720±` probe, panels closed: available reader width 721, still a spread"],
        ),
        reader(
            "rd-spread-b720-1131-en",
            "1C-SPREAD",
            &["FM-09"],
            Locale::En,
            B720_BOOKMARKS[0],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Contents,
            },
            &[
                "`B720±` probe with the bookmarks panel open: available reader width 719 after the \
                 300 px panel, so the same single-page side of the threshold is reached at a wider \
                 client",
            ],
        ),
        reader(
            "rd-spread-b720-1132-en",
            "1C-SPREAD",
            &["FM-09"],
            Locale::En,
            B720_BOOKMARKS[1],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Contents,
            },
            &[
                "`B720±` probe with the bookmarks panel open: available reader width 720, the \
                 threshold itself",
            ],
        ),
        reader(
            "rd-spread-b720-1133-en",
            "1C-SPREAD",
            &["FM-09"],
            Locale::En,
            B720_BOOKMARKS[2],
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_EVEN,
                page: 0,
                panel: Panel::Contents,
            },
            &["`B720±` probe with the bookmarks panel open: available reader width 721, a spread"],
        ),
        reader(
            "rd-spread-pdf-w1280-en",
            "1C-SPREAD",
            &["FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: PDF_FOUR,
                page: 0,
                panel: Panel::None,
                zoom: RasterZoom::FitPage,
            },
            &[
                "The PDF spread: two consecutive raster pages, the first pair of a four-page book, \
                 each drawn in its own slot",
            ],
        ),
        reader(
            "rd-spread-pdf-last-w1280-en",
            "1C-SPREAD",
            &["FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: PDF_TWO,
                page: 1,
                panel: Panel::None,
                zoom: RasterZoom::FitPage,
            },
            &[
                "The final raster spread of an even total: two pages, so the pair is complete and \
                 the last page is shown next to the one before it rather than alone",
            ],
        ),
        reader(
            "rd-spread-cbz-w1280-en",
            "1C-SPREAD",
            &["FM-13"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::RasterPage {
                fixture: CBZ_THREE,
                page: 2,
                panel: Panel::None,
                zoom: RasterZoom::FitPage,
            },
            &[
                "The CBZ spread with an odd total: three pages, so the final spread shows the last \
                 page alone, without a blank page or a repeated page",
            ],
        ),
        reader(
            "rd-spread-large-font-bf32-w1280-en",
            "1C-SPREAD",
            &["FM-07"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubLargeFont {
                fixture: EPUB_EVEN,
                font_size: 32.0,
            },
            &[
                "Comparison only for decision 12: Iced keeps the width-only 720 px spread rule at a \
                 32 px book font and never falls back to one column for readability, so this image \
                 cannot evidence `FM-11` or `FM-12`; acceptance is owned by 5A/5B/5H and `FM-11` \
                 stays pending in this package's matrix",
                "The row it renders is `FM-07`: the wide paginated EPUB spread, here at a 32 px book \
                 font",
            ],
        ),
        // -- 1C-EPUB-PAG: rich composition over the reused conformance set --
        reader_rich(
            "rd-epub-marks-w1280-en",
            "1C-EPUB-PAG",
            &["FM-01", "FM-18"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_MARKS,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The generated capture-only fixture: a list, a quote, a styled link and a document \
                 image in one page, which is the composition `FM-01` names",
                "`FM-18`: the specification names `F4` (`conformance.epub`) and `F7` \
                 (`mathml.epub`) for this row, but `F4` cannot render under the pinned capture font \
                 environment and `F7` carries no document colour, so the colour evidence comes from \
                 this generated fixture: its image is filled with one exact colour the chrome never \
                 uses, and a regression test requires that colour in the rendered page, so a tinted \
                 or monochrome composite fails instead of passing unnoticed",
                "The fixture deliberately carries no italic on the interface family: the repository's \
                 sampler book does, and the pinned capture font environment cannot shape it (see the \
                 rich-fixture limitation)",
            ],
        ),
        reader_rich(
            "rd-epub-links-w1280-en",
            "1C-EPUB-PAG",
            &["FM-01"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_LINKS,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The reused conformance link fixture: its anchors and the cross-chapter target \
                 page compose inside the page budget, so a reviewer sees what the reader does \
                 with the fixture's link shapes",
                "The fixture's chapter puts its anchors directly under `<main>`, and the parser's \
                 inline collector does not carry a block-level anchor's own `href` into its spans, \
                 so those anchors render as plain text. The gap is recorded in the known \
                 limitations; `FM-01`'s styled-link evidence is `rd-epub-marks-w1280-en`, whose \
                 link sits inside a paragraph and renders with the palette's link colour and \
                 underline",
            ],
        ),
        reader_rich(
            "rd-epub-bidi-w1280-mix",
            "1C-EPUB-PAG",
            &["FM-01", "FM-21"],
            Locale::Mix,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_BIDI,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The reused conformance `F5` bidi fixture at the specification's `MIX` \
                 configuration: the interface stays English while the document mixes scripts, the \
                 right-to-left paragraphs keep their direction (the Hebrew and Arabic runs occupy \
                 their logical slots) and the Latin and Japanese runs compose in the page",
                "Two parts of the row are not visible here. The Hebrew and Arabic runs themselves \
                 are blank, because the pinned capture font set has no face for those scripts; and \
                 the fixture's authored RTL *list* direction is not preserved, because the Iced \
                 list composition is left-to-right. Both are recorded as the partial-coverage \
                 reason on `FM-21` and in the known limitations rather than being read as a \
                 rendering result",
            ],
        ),
        reader_rich(
            "rd-epub-fonts-w1280-en",
            "1C-EPUB-PAG",
            &["FM-22"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_FONTS,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The reused conformance font fixture: four embedded container formats, a bold and \
                 an italic face of an embedded family, and the missing/corrupt fallbacks \
                 (`FM-22`)",
                "Embedded faces are document fonts: they stay isolated from the interface fonts the \
                 pinned environment registers, which is what the image shows",
            ],
        ),
        reader_rich(
            "rd-epub-fonts-isolation-w1280-en",
            "1C-EPUB-PAG",
            &["FM-22"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_FONTS_ISOLATION,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The reused conformance isolation fixture: its embedded face is used only for the \
                 run the document asks for it on, while the heading and every other run keep the \
                 interface font (`FM-22`)",
            ],
        ),
        reader_rich(
            "rd-epub-table-w1280-en",
            "1C-EPUB-PAG",
            &["FM-23"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_TABLE,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The reused conformance table fixture: table cells and a table image compose inside \
                 the page budget (`FM-23`)",
            ],
        ),
        reader_rich(
            "rd-epub-mathml-w1280-en",
            "1C-EPUB-PAG",
            &["FM-23"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubPage {
                fixture: EPUB_MATHML,
                page: 0,
                panel: Panel::None,
            },
            &[
                "The reused conformance math fixture: inline and display math compose inside the \
                 page budget (`FM-23`)",
            ],
        ),
        reader(
            "rd-spread-large-font-bf48-w1280-en",
            "1C-SPREAD",
            &["FM-07"],
            Locale::En,
            W1280,
            1.0,
            ReaderKind::EpubLargeFont {
                fixture: EPUB_EVEN,
                font_size: 48.0,
            },
            &[
                "Comparison only, as the 32 px capture: the book font stays at its chosen size and \
                 Iced still forms a spread, which is exactly the behavior decision 12 replaces for \
                 the Flutter reader",
                "The row it renders is `FM-07`: the wide paginated EPUB spread, here at a 48 px book \
                 font",
            ],
        ),
    ];
    scenarios.sort_by_key(|scenario| scenario.id);
    scenarios
}

// ---------------------------------------------------------------------------
// Reaching a state
// ---------------------------------------------------------------------------

/// The seeded book whose file is `fixture`, as the application sees it.
///
/// The seeded store keeps the fixture path as its file key, so a book is found
/// by the path the seed imported; the repository fixture (`repo:`) resolves to
/// the checkout path instead of the disposable root.
pub(crate) fn locate_book(
    state: &super::super::State,
    fixtures_root: &Path,
    fixture: &str,
) -> Result<(i64, String)> {
    // The seed imports through `Library::import_file`, which stores the
    // canonical path key, so the lookup compares canonical paths: the repository
    // fixture is reached through a `..` component that canonicalization removes.
    let wanted = canonical(super::seed::seed_path(fixtures_root, fixture));
    let book = state
        .library_books
        .iter()
        .find(|book| canonical(shosai_core::path_from_key(&book.file_path)) == wanted)
        .with_context(|| format!("no seeded book for {fixture}"))?;
    Ok((book.id, book.file_path.clone()))
}

/// A path with symlinks and `..` resolved, falling back to the path itself when
/// it cannot be resolved.
fn canonical(path: PathBuf) -> PathBuf {
    std::fs::canonicalize(&path).unwrap_or(path)
}

/// Open a seeded book through the production message.
async fn open_book(harness: &mut Harness, fixtures_root: &Path, fixture: &str) -> Result<()> {
    let (id, key) = locate_book(&harness.state, fixtures_root, fixture)?;
    harness.dispatch(Message::OpenLibraryBook(id, key)).await;
    Ok(())
}

/// Move a paginated EPUB to a 0-based page through the production messages.
async fn goto_epub_page(harness: &mut Harness, page: usize) -> Result<()> {
    let pages = harness.state.epub_pages.len();
    anyhow::ensure!(
        page < pages,
        "the EPUB paginated to {pages} page(s), so page {} does not exist",
        page + 1
    );
    harness
        .dispatch(Message::PageInputChanged((page + 1).to_string()))
        .await;
    harness.dispatch(Message::GoToPage).await;
    Ok(())
}

/// Move a paginated raster document to a 0-based page.
async fn goto_raster_page(harness: &mut Harness, page: usize) -> Result<()> {
    let pages = harness.state.total_pages;
    anyhow::ensure!(
        page < pages,
        "the document has {pages} page(s), so page {} does not exist",
        page + 1
    );
    harness
        .dispatch(Message::PageInputChanged((page + 1).to_string()))
        .await;
    harness.dispatch(Message::GoToPage).await;
    Ok(())
}

/// Open the panels a capture declares, in the order a reader would reach them.
async fn apply_panel(harness: &mut Harness, panel: Panel) -> Result<()> {
    match panel {
        Panel::None => {}
        Panel::Contents => {
            harness.dispatch(Message::ToggleBookmarksPanel).await;
        }
        Panel::ContentsWithBookmark | Panel::ContentsNoteEditor => {
            harness.dispatch(Message::ToggleBookmark).await;
            harness.dispatch(Message::ToggleBookmarksPanel).await;
        }
        Panel::Typography => {
            harness.dispatch(Message::ToggleReaderSettings).await;
        }
        Panel::More => {
            harness.dispatch(Message::ToggleReaderMore).await;
        }
        Panel::Search(query) => {
            harness.dispatch(Message::ToggleReaderMore).await;
            harness.dispatch(Message::ToggleSearchBar).await;
            harness
                .dispatch(Message::SearchQueryChanged(query.to_owned()))
                .await;
        }
    }
    if panel == Panel::ContentsNoteEditor {
        let id = harness
            .state
            .bookmarks
            .first()
            .map(|bookmark| bookmark.id)
            .context("the note-editor capture needs the saved place it just created")?;
        harness
            .dispatch(Message::StartEditNote(id, String::new()))
            .await;
        harness
            .dispatch(Message::EditNoteChanged(
                "check the survey notes".to_owned(),
            ))
            .await;
    }
    Ok(())
}

/// Reach a reader state through production messages only.
pub(crate) async fn apply(
    scenario: &Scenario,
    harness: &mut Harness,
    data_root: &Path,
) -> Result<()> {
    let super::scenarios::Kind::Reader(kind) = scenario.kind else {
        anyhow::bail!("{}: not a reader capture", scenario.id);
    };
    let fixtures_root = data_root.join("fixtures");
    match kind {
        ReaderKind::EpubPage {
            fixture,
            page,
            panel,
        } => {
            open_book(harness, &fixtures_root, fixture).await?;
            goto_epub_page(harness, page).await?;
            apply_panel(harness, panel).await?;
        }
        ReaderKind::Hover { fixture, page, .. } => {
            open_book(harness, &fixtures_root, fixture).await?;
            goto_epub_page(harness, page).await?;
        }
        ReaderKind::EpubContinuous { fixture, panel } => {
            open_book(harness, &fixtures_root, fixture).await?;
            harness.dispatch(Message::ToggleReadingMode).await;
            apply_panel(harness, panel).await?;
        }
        ReaderKind::RasterPage {
            fixture,
            page,
            panel,
            zoom,
        } => {
            open_book(harness, &fixtures_root, fixture).await?;
            goto_raster_page(harness, page).await?;
            match zoom {
                RasterZoom::FitPage => {
                    harness.dispatch(Message::SetZoomFitPage).await;
                }
                RasterZoom::FitWidth => {
                    harness.dispatch(Message::SetZoomFitWidth).await;
                }
                RasterZoom::Manual => {
                    harness.dispatch(Message::ZoomIn).await;
                }
            }
            apply_panel(harness, panel).await?;
        }
        ReaderKind::RasterContinuous { fixture, panel } => {
            open_book(harness, &fixtures_root, fixture).await?;
            harness.dispatch(Message::ToggleReadingMode).await;
            apply_panel(harness, panel).await?;
        }
        ReaderKind::EpubLargeFont { fixture, font_size } => {
            open_book(harness, &fixtures_root, fixture).await?;
            while harness.state.font_size < font_size {
                harness.dispatch(Message::FontSizeUp).await;
            }
            anyhow::ensure!(
                harness.state.font_size == font_size,
                "the book font stopped at {} px instead of {font_size}",
                harness.state.font_size
            );
        }
        ReaderKind::Tabs { fixtures, selected } => {
            for fixture in fixtures {
                open_book(harness, &fixtures_root, fixture).await?;
            }
            harness.dispatch(Message::SelectTab(selected)).await;
        }
        ReaderKind::Opening { fixture } => {
            let (id, key) = locate_book(&harness.state, &fixtures_root, fixture)?;
            // The open task stays in flight: this is the state a window shows
            // while the document loads. The notice message is the production
            // timer's own output for the generation that is still opening.
            let _in_flight = harness.start(Message::OpenLibraryBook(id, key));
            let generation = harness.state.document_open_generation;
            harness
                .dispatch(Message::ShowDocumentOpenNotice(generation))
                .await;
        }
        ReaderKind::MissingFile { fixture } => {
            let path = super::seed::seed_path(&fixtures_root, fixture);
            let original = std::fs::read(&path)
                .with_context(|| format!("read the disposable copy of {fixture}"))?;
            std::fs::remove_file(&path).context("remove the disposable copy")?;
            let opened = open_book(harness, &fixtures_root, fixture).await;
            // Restore before the result is judged: the committed fixture tree
            // must stay complete even when the capture fails.
            let restored = std::fs::write(&path, &original)
                .with_context(|| format!("restore the disposable copy of {fixture}"));
            opened?;
            restored?;
        }
        ReaderKind::OpenError { fixture } => {
            // The production preparation path reports the failure for these
            // bytes, but a *preparation* failure leaves the reader on the
            // library screen, so the reader's own failure composition is reached
            // the way the accepted 1B failure captures are: the real error is
            // obtained from the production operation and delivered through the
            // production message that carries it.
            let (id, key) = locate_book(&harness.state, &fixtures_root, fixture)?;
            let path = super::seed::seed_path(&fixtures_root, fixture);
            let original = std::fs::read(&path)
                .with_context(|| format!("read the disposable copy of {fixture}"))?;
            let _in_flight = harness.start(Message::OpenLibraryBook(id, key));
            let generation = harness.state.document_open_generation;
            std::fs::write(&path, b"not a document").context("overwrite the disposable copy")?;
            let prepared = shosai_core::application::OpenDocumentPlan::prepare_cancellable(
                &shosai_core::application::DeviceFileLocator::from_path(&path),
                &shosai_core::bridge::Cancellation::new(),
            );
            // Restore before the result is judged: the committed fixture tree
            // must stay complete even when the capture fails.
            std::fs::write(&path, &original)
                .with_context(|| format!("restore the disposable copy of {fixture}"))?;
            let error = match prepared {
                Err(error) => error,
                Ok(_) => anyhow::bail!(
                    "the corrupt bytes opened successfully, so the open-error capture would show \
                     a substituted message instead of the production error"
                ),
            };
            harness
                .dispatch(Message::DocumentOpened {
                    generation,
                    path,
                    book_id: Some(id),
                    result: Err(super::super::app_document_open_error(error)),
                })
                .await;
        }
        ReaderKind::Theme { fixture, theme } => {
            open_book(harness, &fixtures_root, fixture).await?;
            while harness.state.theme != theme {
                harness.dispatch(Message::CycleTheme).await;
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Observing a state
// ---------------------------------------------------------------------------

/// Read the reader facts out of a reached state.
pub(crate) fn observe(state: &super::super::State) -> ReaderFacts {
    let format = match &state.document {
        Some(OpenDocument::Epub(_)) => "epub",
        Some(OpenDocument::Pdf(_)) => "pdf",
        Some(OpenDocument::Cbz(_)) => "cbz",
        None => "",
    };
    let document = state
        .file_path
        .as_ref()
        .and_then(|path| path.file_name())
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_owned();
    let paginated_epub = super::super::uses_paginated_epub_layout(state);
    let paginated_raster = super::super::uses_paginated_raster_layout(state);
    let (page_count, location, visible, spread) = if paginated_epub {
        (
            state.epub_pages.len(),
            state.epub_page,
            super::super::epub_visible_pages(state)
                .into_iter()
                .map(|page| page + 1)
                .collect::<Vec<_>>(),
            super::super::epub_uses_spread(state),
        )
    } else if paginated_raster {
        (
            state.total_pages,
            state.current_page,
            super::super::paginated_raster_pages(state)
                .into_iter()
                .map(|page| page + 1)
                .collect::<Vec<_>>(),
            super::super::uses_page_spreads(state),
        )
    } else if state.document.is_some() {
        (
            if format == "epub" {
                state.epub_pages.len()
            } else {
                state.total_pages
            },
            state.current_page,
            Vec::new(),
            false,
        )
    } else {
        (0, 0, Vec::new(), false)
    };
    let available = super::super::available_reader_size(state);
    ReaderFacts {
        document,
        format: format.to_owned(),
        mode: match state.reading_mode {
            ReadingMode::Paginated => "paginated".to_owned(),
            ReadingMode::Continuous => "continuous".to_owned(),
        },
        zoom: match (&state.document, state.zoom) {
            (
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_)),
                crate::pdf::ZoomMode::FitPage,
            ) => RasterZoom::FitPage.mode().to_owned(),
            (
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_)),
                crate::pdf::ZoomMode::FitWidth,
            ) => RasterZoom::FitWidth.mode().to_owned(),
            (
                Some(OpenDocument::Pdf(_)) | Some(OpenDocument::Cbz(_)),
                crate::pdf::ZoomMode::Manual(scale),
            ) => format!("manual({scale})"),
            // An EPUB reflows, and a state with no document has no page to
            // scale: the zoom the state carries is not a reader fact there.
            _ => ZOOM_NOT_APPLICABLE.to_owned(),
        },
        theme: state.theme.stored().to_owned(),
        page_count,
        location: if state.document.is_some() {
            location + 1
        } else {
            0
        },
        visible_pages: visible,
        spread,
        available_width: available.width,
        available_height: available.height,
        font_size: state.font_size,
        line_spacing: state.line_spacing,
        panels: panels_of(state),
        bookmarks: state.bookmarks.len(),
        search_matches: if state.show_search_bar {
            Some(state.search_results.len())
        } else {
            None
        },
        tabs: state.tabs.len(),
    }
}

/// The panels that are open in a state, in the order the layout stacks them.
fn panels_of(state: &super::super::State) -> Vec<String> {
    let mut panels = Vec::new();
    if state.show_bookmarks_panel {
        panels.push("contents".to_owned());
    }
    if state.show_reader_settings {
        panels.push("typography".to_owned());
    }
    if state.show_reader_more {
        panels.push("more".to_owned());
    }
    if state.show_search_bar {
        panels.push("search".to_owned());
    }
    panels
}

/// Assert that a capture reached the surface, language and reader state its
/// declared facts describe.
///
/// A capture whose state silently differs from its declaration is not evidence
/// for its rows, so the run fails instead of writing the image.
pub(crate) fn assert_reached(scenario: &Scenario, state: &super::super::State) {
    assert_eq!(
        scenario.surface(),
        Surface::Reader,
        "{}: a reader capture must be on the reader surface",
        scenario.id
    );
    assert_eq!(
        state.screen,
        super::super::Screen::Reader,
        "{}: expected the reader screen",
        scenario.id
    );
    let declared = scenario
        .reader
        .as_ref()
        .unwrap_or_else(|| panic!("{}: a reader capture needs declared facts", scenario.id));
    let observed = observe(state);
    assert_eq!(
        &observed, declared,
        "{}: the reached reader state does not match the declared facts",
        scenario.id
    );
    let super::scenarios::Kind::Reader(kind) = scenario.kind else {
        return;
    };
    match kind {
        ReaderKind::Opening { .. } => assert!(
            state.document_opening && state.document_open_notice_visible,
            "{}: the opening state is not in flight",
            scenario.id
        ),
        ReaderKind::MissingFile { .. } => assert!(
            state.open_error.is_some() && state.missing_book_id.is_some(),
            "{}: the missing-file alert did not reach the state that offers locate/remove",
            scenario.id
        ),
        ReaderKind::OpenError { .. } => assert!(
            state.open_error.is_some() && state.missing_book_id.is_none(),
            "{}: the open-error alert did not reach the state without a locate action",
            scenario.id
        ),
        ReaderKind::Tabs { fixtures, selected } => {
            assert_eq!(
                state.tabs.len(),
                fixtures.len(),
                "{}: expected {} open documents",
                scenario.id,
                fixtures.len()
            );
            assert_eq!(
                state.active_tab,
                Some(selected),
                "{}: the selected tab is not the declared one",
                scenario.id
            );
        }
        _ => assert!(
            state.document.is_some(),
            "{}: no document is open",
            scenario.id
        ),
    }
}

/// Captures that are allowed to be pixel-identical to each other.
pub(crate) const PIXEL_ALIASES: [(&str, &str, &str); 0] = [];

/// Captured rows whose reference coverage is deliberately partial.
///
/// A `captured` row means an Iced capture renders that state; it is not a claim
/// that every part of the row has an image. These entries name what no image
/// covers, so an accepting package reads the gap instead of inferring complete
/// coverage from the row id. The same gaps are listed in
/// [`limitations`], and the owner is asked to accept them with the package.
pub(crate) const CAPTURED_PARTIAL: [(&str, &str); 1] = [(
    "FM-21",
    "partial: the reused `bidi.epub` fixture's right-to-left paragraphs are referenced and its \
     Latin and Japanese runs compose in the page; its Hebrew and Arabic runs are blank because \
     the pinned capture font set (Inter, NotoSansJP, the math font) has no face for those scripts \
     and the pinned fontconfig names an empty directory, and the fixture's authored RTL list \
     direction is not preserved either, because the Iced list composition is left-to-right \
     (`app/epub_view.rs`). The row's Hebrew/Arabic shaping and its RTL list direction are \
     therefore not evidenced by this capture",
)];

/// The matrix rows this capture set satisfies, split by *how*.
pub(crate) fn matrix_rows() -> (
    Vec<&'static str>,
    Vec<&'static str>,
    Vec<(&'static str, &'static str)>,
) {
    let captured = vec![
        "RD-01", "RD-02", "RD-03", "RD-05", "RD-06", "RD-07", "RD-08", "RD-09", "RD-10", "RD-11",
        "RD-16", "RD-17", "FM-01", "FM-02", "FM-03", "FM-04", "FM-05", "FM-06", "FM-07", "FM-08",
        "FM-09", "FM-10", "FM-13", "FM-18", "FM-21", "FM-22", "FM-23",
    ];
    // `XA-10` is the provenance row: `manifest.json` with `captures.sha256`,
    // `fixtures.sha256` and the README satisfies it, not an image.
    let manifest = vec!["XA-10"];
    let pending = vec![
        (
            "RD-04",
            "4B — decision-11 tab overflow (active-tab reveal, keyboard close, readable width floor) \
             has no Iced implementation",
        ),
        (
            "RD-12",
            "4D — selection and annotation actions are RFD 6 / retained Flutter authority, recorded \
             in the 1C non-Iced authority record instead of an Iced capture",
        ),
        (
            "RD-13",
            "4B — panel exclusivity is behavioral (`WT`): an Iced capture of the same state would \
             only duplicate the open-panel captures",
        ),
        (
            "RD-14",
            "4B — keyboard reachability and focus visibility are Flutter-owned (`WT`)",
        ),
        (
            "RD-15",
            "4D — large-text and palette inspection of the Flutter components is local evidence",
        ),
        (
            "FM-11",
            "5H — decision-12 readability fallback has no Iced implementation; the large-font \
             captures are comparison images only",
        ),
        (
            "FM-12",
            "5H — the fallback boundary and durable-location preservation are `WT` + `5H-RENDER`",
        ),
        (
            "FM-14",
            "5H — tiled continuous seams are a Flutter/renderer deliverable; Iced continuous is a \
             single chapter column with no tiled render",
        ),
        (
            "FM-15",
            "5H — mode-switch position preservation is behavioral (`WT`)",
        ),
        (
            "FM-16",
            "5I — EPUB cross-fragment selection is RFD 6 authority, not an Iced capture",
        ),
        ("FM-17", "5I — PDF page-local selection is RFD 6 authority"),
        (
            "FM-19",
            "6C — DPR 2 sharpness acceptance is `6C-A11Y`; the 1C DPR 2 capture is the Iced \
             reference",
        ),
        (
            "FM-20",
            "5J — resource-rejection distinguishability is behavioral (`WT`)",
        ),
    ];
    (captured, manifest, pending)
}

/// What this package deliberately does not capture, with the owner.
pub(crate) fn limitations(broken_symlinks_available: bool) -> Vec<String> {
    let mut limitations = vec![
        "Iced has no production interactive selection or highlighting: `RD-12`, `FM-16` and \
         `FM-17` are recorded as RFD 6 / retained-Flutter authority in the 1C non-Iced authority \
         record and `docs/reference-captures.md`, never fabricated as an Iced capture."
            .to_owned(),
        "Iced applies a width-only 720 px spread rule and has no decision-12 readability fallback: \
         the `BF32`/`BF48` captures are comparison images only and `FM-11`/`FM-12` stay with \
         5A/5B/5H."
            .to_owned(),
        "The offscreen renderer has no scroll interaction and the application exposes no message \
         that scrolls the reader: continuous captures show the chapter/page column from its top and \
         the paginated captures are reached by the production page-navigation messages. Tiled \
         continuous seams (`FM-14`) are a Flutter/renderer deliverable."
            .to_owned(),
        "Iced has no text scaling (`T200`) and no decision-11 tab overflow: `RD-04`, `RD-14` and \
         `RD-15` have no Iced counterpart and stay with 4B/4D."
            .to_owned(),
        "The document-opening capture delivers the production timer's own \
         `ShowDocumentOpenNotice(generation)` message for the in-flight generation, because the \
         offscreen run cannot wait on a real window's 200 ms timer without also completing the open \
         it is capturing; the state it shows is the production opening composition."
            .to_owned(),
        "The missing-file and open-error captures need a real failure, so they remove (respectively \
         overwrite) the disposable copy of one seeded fixture and write the original bytes back \
         immediately afterwards; the committed fixture tree and its checksums stay complete, and \
         the disposable root is the run's own."
            .to_owned(),
        "Two of the repository's conformance fixtures cannot render under the pinned capture font \
         environment: `conformance.epub` and `css-cascade.epub` both style `font-style: italic` on \
         the default family, which has no italic face in the pinned set, and the text stack panics \
         (`no default font found`) instead of falling back to the family's upright face. The other \
         twelve conformance fixtures render and are the ones the rich captures use; the trigger is \
         a production behavior (only the application fonts are registered), and the fallback gap \
         itself belongs with the renderer owner rather than being papered over here."
            .to_owned(),
        "The generated PDF fixtures draw shapes only (no page text), because PDFium resolves fonts \
         for unembedded text by scanning the host font directories and does not follow \
         `FONTCONFIG_FILE`; the native PDFium that rasterized the pages is recorded in \
         `environment.pdfium` as run metadata, so a different build can render different pixels."
            .to_owned(),
        "Rendering is in-process software rasterization, not a compositor screenshot: window \
         decorations, native menus, toasts and animations are outside the capture, and the \
         disposable data root path is visible in application text that names a real path."
            .to_owned(),
        "Every reader capture uses a viewport the composition fits in, because the renderer has no \
         scroll interaction: the reader chrome is captured at `W1280`/`W900`/`C390` and at the \
         documented `B860±`/`B720±` probe widths. The layout rules, the theme and the composition \
         are unchanged; only the window is the size the probe names. The zoom captures are the \
         deliberate exceptions: `rd-pdf-fit-width-w1280-en`, `rd-cbz-fit-width-w1280-en`, \
         `rd-pdf-manual-zoom-w1280-en` and `rd-cbz-manual-zoom-w1280-en` all scale the page past \
         the viewport height, so those captures show the overflow and the vertical scrollbar \
         instead of a page that fits."
            .to_owned(),
        "The rich captures open from package 1C's own base seed (the shared library plus the \
         reused conformance fixtures and the generated marks fixture) so the shared seed's order, \
         and therefore package 1B's evidence, is untouched. The marks fixture is generated for \
         these captures and carries no italic on the interface family, which is why it can render \
         where `conformance.epub` cannot."
            .to_owned(),
        "An anchor that is itself a block-level child of a block container loses its own `href`: \
         the parser's inline collector applies a link only to the spans *inside* an `a` element, \
         not to the anchor's own block. `links.epub`'s chapter puts its anchors directly under \
         `main`, which is why `rd-epub-links-w1280-en` shows their text without the link colour \
         or underline; the same anchor inside a paragraph (`rd-epub-marks-w1280-en`) or inside a \
         table cell (`rd-epub-table-w1280-en`) keeps its link."
            .to_owned(),
        "The pinned capture font set (Inter, NotoSansJP and the math font, with a fontconfig that \
         names an empty directory) covers Latin, Japanese and the math glyphs only. `FM-21`'s \
         Hebrew and Arabic runs in `bidi.epub`, and the emoji in its mixed line, therefore render \
         blank in `rd-epub-bidi-w1280-mix`: the capture shows the fixture's right-to-left \
         paragraphs and its Latin/Japanese runs, not its Hebrew or Arabic shaping. The fixture's \
         authored RTL list direction is not preserved either, because the Iced list composition \
         is left-to-right (`app/epub_view.rs`), which is why `FM-21` is recorded as a partially \
         covered row. Evidencing the missing halves needs a Hebrew/Arabic face in the capture \
         font set and an RTL-aware list composition, which are renderer/capture-contract changes \
         and owner decisions rather than something this package may do on its own."
            .to_owned(),
        "The shared EPUB style model carries no colour field, so document text is painted with the \
         reader palette and no capture can show a CSS text colour: `FM-18`'s Iced reference is the \
         document *image* path (`rd-epub-marks-w1280-en`), where the document's own pixels survive \
         composition. A document text colour is renderer work that belongs with 5G, not something \
         a capture here can evidence."
            .to_owned(),
        "Document images compose only where the parser keeps an image node: a block-level `img` and \
         an image inside a table cell render, while an `img` inside a paragraph is dropped by the \
         inline collector (the paragraph keeps its text only) and a missing resource never reaches \
         the page. `nested-image.epub`'s paragraph-inline image and its missing-image fallback are \
         therefore not composed; the gap is recorded here rather than hidden by a fabricated \
         state."
            .to_owned(),
    ];
    if !broken_symlinks_available {
        limitations.push(
            "The dangling-symlink discovery-failure fixture could not be created on this platform, \
             so the shared fixture tree is incomplete."
                .to_owned(),
        );
    }
    limitations
}

// ---------------------------------------------------------------------------
// Declared facts
// ---------------------------------------------------------------------------

/// The facts of a reader state with no document open.
fn blank_facts(client: (f32, f32)) -> ReaderFacts {
    let available = available_for(client, Panel::None);
    ReaderFacts {
        document: String::new(),
        format: String::new(),
        mode: "paginated".to_owned(),
        zoom: ZOOM_NOT_APPLICABLE.to_owned(),
        theme: ReaderTheme::Light.stored().to_owned(),
        page_count: 0,
        location: 0,
        visible_pages: Vec::new(),
        spread: false,
        available_width: available.0,
        available_height: available.1,
        font_size: 16.0,
        line_spacing: 1.6,
        panels: Vec::new(),
        bookmarks: 0,
        search_matches: None,
        tabs: 0,
    }
}

/// The pages visible together for a location, from the pairing rule.
///
/// This is the specification's pairing math (§3.6): the spread starts at the
/// even page at or before the location, and the visible range is clamped at the
/// last page, so an odd total ends with a single-page final spread. It is
/// derived here rather than read from the state, so a capture whose pairing
/// changed fails instead of quietly recording the new one.
pub(crate) fn visible_for(page: usize, page_count: usize, spread: bool) -> Vec<usize> {
    if page_count == 0 {
        return Vec::new();
    }
    let last = page_count - 1;
    let start = if spread {
        (page.min(last)) - (page.min(last)) % 2
    } else {
        page.min(last)
    };
    let mut visible = vec![start + 1];
    if spread && start < last {
        visible.push(start + 2);
    }
    visible
}

/// The declared facts of a paginated EPUB capture.
fn epub_facts(
    fixture: &str,
    page: usize,
    panel: Panel,
    client: (f32, f32),
    font_size: f32,
) -> ReaderFacts {
    let available = available_for(client, panel);
    let page_count = epub_page_count_at(fixture, font_size);
    // `app::epub_uses_spread` is the width rule alone: an EPUB in paginated mode
    // uses the spread layout above the threshold even when the document has a
    // single page, which then sits in the first slot with the intentional
    // half-width filler beside it (`FM-08`).
    let spread = available.0 >= 720.0;
    ReaderFacts {
        document: file_name(fixture),
        format: format_of(fixture).to_owned(),
        mode: "paginated".to_owned(),
        zoom: ZOOM_NOT_APPLICABLE.to_owned(),
        theme: ReaderTheme::Light.stored().to_owned(),
        page_count,
        location: page + 1,
        visible_pages: visible_for(page, page_count, spread),
        spread,
        available_width: available.0,
        available_height: available.1,
        font_size,
        line_spacing: 1.6,
        panels: panel.names(),
        bookmarks: if matches!(
            panel,
            Panel::ContentsWithBookmark | Panel::ContentsNoteEditor
        ) {
            1
        } else {
            0
        },
        search_matches: match panel {
            Panel::Search(_) => Some(search_expectation(fixture)),
            _ => None,
        },
        tabs: 1,
    }
}

/// The declared facts of a paginated PDF/CBZ capture.
fn raster_facts(
    fixture: &str,
    page: usize,
    panel: Panel,
    client: (f32, f32),
    zoom: RasterZoom,
) -> ReaderFacts {
    let page_count = raster_page_count(fixture);
    let available = available_for(client, panel);
    let spread = available.0 >= 720.0 && page_count > 1;
    let visible = visible_for(page, page_count, spread);
    ReaderFacts {
        document: file_name(fixture),
        format: format_of(fixture).to_owned(),
        mode: "paginated".to_owned(),
        zoom: zoom.recorded(fixture, available, visible.len()),
        theme: ReaderTheme::Light.stored().to_owned(),
        page_count,
        location: page + 1,
        visible_pages: visible,
        spread,
        available_width: available.0,
        available_height: available.1,
        font_size: 16.0,
        line_spacing: 1.6,
        panels: panel.names(),
        bookmarks: 0,
        search_matches: None,
        tabs: 1,
    }
}

/// The page count the shared fixture generator produces for a raster fixture.
///
/// These are properties of the generated fixture, not of a render: a PDF page
/// count comes from the `/Count` the generator writes and a CBZ page count from
/// the number of page images it stores. `reader_fixture_page_counts_are_declared`
/// re-reads both from the generated bytes.
pub(crate) fn raster_page_count(fixture: &str) -> usize {
    match fixture {
        PDF_FOUR => 4,
        PDF_TWO => 2,
        CBZ_TWELVE => 12,
        CBZ_THREE => 3,
        other => panic!("no declared page count for {other}"),
    }
}

/// The available reader size a panel state leaves at a client size.
fn available_for(client: (f32, f32), panel: Panel) -> (f32, f32) {
    let (bookmarks, settings, more, search) = panel.flags();
    available_size(client, bookmarks, search, settings, more)
}

/// The available reader size for the `W1280` client with a panel state.
pub(crate) fn available_size(
    client: (f32, f32),
    bookmarks: bool,
    search: bool,
    settings: bool,
    more: bool,
) -> (f32, f32) {
    let compact = client.0 < 860.0;
    let bookmarks_width = if bookmarks { 300.0 } else { 0.0 };
    let search_height = if search {
        if compact { 88.0 } else { 52.0 }
    } else {
        0.0
    };
    let settings_height = if settings { 62.0 } else { 0.0 };
    let more_height = if more {
        if compact { 84.0 } else { 58.0 }
    } else {
        0.0
    };
    (
        (client.0 - bookmarks_width - 112.0).max(1.0),
        (client.1 - 148.0 - search_height - settings_height - more_height).max(1.0),
    )
}

/// The paginated page count of an EPUB fixture at a book font size.
///
/// The reader fixtures hold one short chapter per page at the specification's
/// `BF16` book font, so the count equals the chapter count there; the
/// large-font captures reflow, so their counts are declared separately. The
/// regression test `reader_fixture_page_counts_are_declared` re-paginates every
/// fixture with the core paginator at the capture's layout size and fails when a
/// declaration stops matching, rather than trusting this table.
pub(crate) fn epub_page_count_at(fixture: &str, font_size: f32) -> usize {
    match (fixture, font_size as u32) {
        (EPUB_EVEN, 16) => 4,
        (EPUB_EVEN, 32) => 4,
        (EPUB_EVEN, 48) => 8,
        (EPUB_ODD, 16) => 3,
        (EPUB_JA, 16) => 3,
        (EPUB_JA_TWO, 16) => 2,
        (EPUB_MARKS, 16) => 1,
        (EPUB_LINKS, 16) => 2,
        (EPUB_BIDI, 16) => 1,
        (EPUB_FONTS, 16) => 1,
        (EPUB_FONTS_ISOLATION, 16) => 1,
        (EPUB_TABLE, 16) => 1,
        (EPUB_MATHML, 16) => 1,
        (fixture, font_size) => {
            panic!("no declared page count for {fixture} at a {font_size} px book font")
        }
    }
}

/// The number of matches the declared search query has in a fixture.
pub(crate) fn search_expectation(fixture: &str) -> usize {
    match fixture {
        EPUB_EVEN => 16,
        other => panic!("no declared search result count for {other}"),
    }
}

/// The `1C` non-Iced authority records: rows this package deliberately does not
/// capture because Iced has no counterpart.
///
/// Selection and highlighting are the case that matters: Iced has no production
/// interactive selection, so `RD-12`, `FM-16` and `FM-17` are owned by RFD 6
/// plus the retained Flutter implementation, and no Iced image exists for them.
/// The records are repeated in `docs/reference-captures.md` so a reviewer
/// reading either artefact sees the same authority.
pub(crate) fn non_iced_authority() -> Vec<String> {
    vec![
        "RD-12 / FM-16 / FM-17 — selection and highlighting: authority is RFD 6 \
         (`rfd/0006/README.adoc`) plus the retained Flutter implementation \
         (`flutter/lib/reader/view_selection.dart`), owned by 4D and 5I. Iced has no production \
         interactive selection, so no 1C image exists for these rows and none is fabricated."
            .to_owned(),
        "RD-04 — tab overflow (decision 11): authority is the owner decision recorded in \
         `docs/flutter-ui-restoration-plan.md`; Iced supplies only a horizontally scrollable strip \
         with no automatic active-tab reveal, no keyboard close and no readable-width floor."
            .to_owned(),
        "RD-14 / RD-15 / FM-19 — keyboard reachability, large-text and DPR-2 inspection of the \
         Flutter components: authority is the retained Flutter implementation and the plan's \
         accessibility requirements; Iced has no text scaling."
            .to_owned(),
        "FM-11 / FM-12 — decision-12 readability fallback: authority is the owner decision and the \
         `5A` rule calibrated in `5B`; Iced applies a width-only 720 px spread rule and the \
         large-font captures here are comparison images only."
            .to_owned(),
        "FM-14 / FM-15 — tiled continuous seams and mode-switch position preservation: authority \
         is the plan's continuous-layout requirements; Iced continuous is a single chapter column \
         with no tiled render."
            .to_owned(),
        "FM-20 — resource rejection is distinguishable from a rendering defect: authority is the \
         plan's 5J acceptance; the limits live in the shared core and are behavioral."
            .to_owned(),
        "FM-18 / FM-21 / FM-22 / FM-23 — document colours, bidi, embedded fonts, tables and math \
         are captured over the reused conformance fixtures that render under the pinned font \
         environment; acceptance stays with 5G/5C/5D, and the two fixtures that cannot render are \
         recorded in the limitations rather than replaced by a fabricated image."
            .to_owned(),
    ]
}
