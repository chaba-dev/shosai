//! Deterministic reference fixtures shared by the 1B library/import/settings
//! captures and the 1C reader captures.
//!
//! Nothing below is committed as a binary blob: the fixture tree is regenerated
//! from this module by the capture runner, and the committed manifest records
//! the SHA-256 of every emitted file, so a non-deterministic or accidental
//! change fails a test instead of silently changing the reference set.
//!
//! Determinism rules enforced here:
//!
//! - every ZIP entry (EPUB and CBZ) is written `Stored` with the fixed
//!   timestamp `1980-01-01 00:00:00` instead of the `zip` crate's "now"
//!   default, so archives are byte-stable;
//! - every image is drawn from a pure function of the book index, no fonts or
//!   third-party assets are embedded, and no clock, locale, random number or
//!   process state is read;
//! - the fixture set is emitted in sorted path order and hashed as bytes;
//! - PDFs are written with a correct cross-reference table (real object offsets
//!   and `startxref`), unlike the legacy `sample.pdf` regression fixture, and
//!   their pages draw shapes only: PDFium resolves fonts for unembedded PDF text
//!   by scanning the host font directories and ignores `FONTCONFIG_FILE`, so a
//!   text run would make a rendered cover depend on the machine (guarded by
//!   [`pdf_font_free_problems`]).

use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, DateTime, System, ZipWriter};

/// A fixture that is reused from the repository's documented fixture set
/// instead of being regenerated, with the provenance record that makes it
/// citable.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ReusedFixture {
    /// Repository-relative path.
    pub(crate) path: &'static str,
    /// SHA-256 recorded by the repository's provenance record.
    pub(crate) sha256: &'static str,
    /// Where the redistribution/source statement lives.
    pub(crate) provenance: &'static str,
    /// Why the 1B/1C capture set reuses it.
    pub(crate) purpose: &'static str,
}

/// Reused fixtures of package 1B. Only the conformance family carries an
/// explicit redistribution statement in this repository, so it is the only
/// reused asset; generated fixtures stay generated.
pub(crate) const REUSED_FIXTURES: [ReusedFixture; 1] = [ReusedFixture {
    path: "crates/shosai-core/tests/fixtures/epub-conformance/conformance.epub",
    sha256: "2f9687c08a59b36f7a27e8ae6a0e15bee672485a338bbd914caf48f2d5e4908a",
    provenance: "crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe)",
    purpose: "conformance sampler book in the seeded library",
}];

/// Rich conformance fixtures package 1C reuses for the reader rows that need
/// more than headings and body text.
///
/// They are the repository's own conformance EPUBs (same provenance and
/// redistribution statement as the reused sampler book) and they are exactly
/// the ones that render under the pinned capture font environment: `FM-01`
/// (links), `FM-21` (bidi and mixed script), `FM-22` (embedded fonts, missing
/// and corrupt fallback) and `FM-23` (tables, math). `conformance.epub` and
/// `css-cascade.epub` are deliberately absent: both style `font-style: italic`
/// on a family with no admitted face, which the pinned environment cannot shape
/// (see the package limitations). `nested-image.epub` is absent too: its only
/// images are 1 px square, so a capture of it records a degenerate 1 px layout
/// rather than a document image, and `FM-18`'s colour evidence is the generated
/// marks fixture instead.
pub(crate) const READER_REUSED_FIXTURES: [ReusedFixture; 6] = [
    ReusedFixture {
        path: "crates/shosai-core/tests/fixtures/epub-conformance/bidi.epub",
        sha256: "5af9e82d15fa0be324ef7e219ddfc0613cb54b9706addb161c83f188cf9b810d",
        provenance: REUSED_CONFORMANCE_PROVENANCE,
        purpose: "bidi and mixed-script composition plus a content list (`FM-01`, `FM-21`)",
    },
    ReusedFixture {
        path: "crates/shosai-core/tests/fixtures/epub-conformance/fonts.epub",
        sha256: "bcd605900627847c0addb541aa5f1698df4709db14321b028aff2b9d8e9962e7",
        provenance: REUSED_CONFORMANCE_PROVENANCE,
        purpose: "embedded document fonts across four container formats (`FM-22`)",
    },
    ReusedFixture {
        path: "crates/shosai-core/tests/fixtures/epub-conformance/fonts-isolation.epub",
        sha256: "0c991567a52452d3e98ef726ae17bfcc12a4b3b555e14f2578bbc63030562f8f",
        provenance: REUSED_CONFORMANCE_PROVENANCE,
        purpose: "embedded font isolation from the interface fonts (`FM-22`)",
    },
    ReusedFixture {
        path: "crates/shosai-core/tests/fixtures/epub-conformance/links.epub",
        sha256: "bb899a2d67b7ca3c82a54564b1ecb5569dbd40c8caea4b46f7ba3d696985c29b",
        provenance: REUSED_CONFORMANCE_PROVENANCE,
        purpose: "inline and block links (`FM-01`)",
    },
    ReusedFixture {
        path: "crates/shosai-core/tests/fixtures/epub-conformance/mathml.epub",
        sha256: "03f1978d9ea58cabc81643e1737bed8887a3d7783e79c719ea4c72762ed0ffe6",
        provenance: REUSED_CONFORMANCE_PROVENANCE,
        purpose: "inline and display math (`FM-23`)",
    },
    ReusedFixture {
        path: "crates/shosai-core/tests/fixtures/epub-conformance/table.epub",
        sha256: "9f54aac1fe4026cc06eb255a9d92a57d2d5dca7c7e6e38c8bb3bada847e48409",
        provenance: REUSED_CONFORMANCE_PROVENANCE,
        purpose: "tables and table images (`FM-23`)",
    },
];

/// The redistribution statement every reused conformance fixture shares.
const REUSED_CONFORMANCE_PROVENANCE: &str = "crates/shosai-core/tests/fixtures/epub-conformance/README.md + SHA256SUMS (documented redistribution-safe)";

/// The reused fixtures a package's manifest records.
pub(crate) fn reused_fixtures(package: super::package::Package) -> &'static [ReusedFixture] {
    match package {
        super::package::Package::OneB => &REUSED_FIXTURES,
        super::package::Package::OneC => &READER_REUSED_FIXTURES,
    }
}

/// Absolute path of a repository-relative fixture used by the captures.
pub(crate) fn repository_fixture_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}

/// ZIP timestamp written for every generated archive entry.
const FIXTURE_ZIP_DATE: (u16, u8, u8, u8, u8, u8) = (1980, 1, 1, 0, 0, 0);

/// One generated fixture file.
#[derive(Debug, Clone)]
pub(crate) struct FixtureFile {
    /// Path relative to the fixture root, `/`-separated.
    pub(crate) relative_path: String,
    pub(crate) bytes: Vec<u8>,
}

/// One written fixture file with its identity.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct FixtureRecord {
    pub(crate) relative_path: String,
    pub(crate) sha256: String,
    pub(crate) bytes: usize,
}

/// One imported library book plus the deterministic snapshot values the seed
/// applies after a real `Library::import_file`. The array order is the import
/// order; the visible library order is `last_read DESC NULLS LAST,
/// date_added DESC, id DESC`, so the seed assigns explicit `date_added` values
/// rather than depending on wall-clock import times.
#[derive(Debug, Clone, Copy)]
pub(crate) struct SeedBook {
    /// Path relative to the fixture root, or `repo:<repository-relative path>`
    /// for a reused repository fixture such as the conformance set.
    pub(crate) file: &'static str,
    /// 0.0–1.0 progress rendered on the card.
    pub(crate) progress: f64,
    /// Exactly one seed book carries a `last_read` value; it is the
    /// continue-reading entry.
    pub(crate) last_read: Option<&'static str>,
    /// Fixed, lexicographically ordered `date_added` value.
    pub(crate) date_added: &'static str,
}

/// The continue-reading book's fixed `last_read` value.
pub(crate) const SEED_LAST_READ: &str = "2026-02-14 09:30:00";

/// Folder selected for the `1B-IMPORT` discovery/review captures.
pub(crate) const IMPORT_FOLDER: &str = "sources/reading-queue";
/// Folder with no supported books, used for the "no supported books" state.
pub(crate) const IMPORT_EMPTY_FOLDER: &str = "sources/no-supported";
/// Long Japanese file paths selected for the files-selection review state.
pub(crate) const IMPORT_LONG_FILES: &[&str] = &[
    "sources/long-names/静かな海の図書館の一年 — 年次報告書と収蔵目録 2026年版.epub",
    "sources/long-names/砂漠のアーカイブ — 失われた書架をめぐる長い旅路.epub",
    "sources/long-names/司書の手引き と 目録作成の実際 (改訂第三版).pdf",
];

/// The library seed, in import order. 14 featured books plus 32 filler books
/// so the wide grid fills more than one page at `W1280` and the paging rows
/// are exercised.
pub(crate) fn library_seed() -> Vec<SeedBook> {
    let mut seed = Vec::new();
    // Fillers are imported first, so they sort last in the visible library.
    for index in 0..32u32 {
        seed.push(SeedBook {
            file: FILLER_FILES[index as usize],
            progress: FILLER_PROGRESS[index as usize],
            last_read: None,
            date_added: "2026-01-05 08:00:00",
        });
    }
    // Featured books, imported last so they sort first (except the
    // continue-reading entry, which is ordered by `last_read`).
    seed.extend_from_slice(&FEATURED_SEED);
    seed
}

const FILLER_FILES: [&str; 32] = [
    "library/filler/collected-papers-01.epub",
    "library/filler/collected-papers-02.epub",
    "library/filler/collected-papers-03.epub",
    "library/filler/collected-papers-04.epub",
    "library/filler/collected-papers-05.epub",
    "library/filler/collected-papers-06.epub",
    "library/filler/collected-papers-07.epub",
    "library/filler/collected-papers-08.epub",
    "library/filler/collected-papers-09.epub",
    "library/filler/collected-papers-10.epub",
    "library/filler/collected-papers-11.epub",
    "library/filler/collected-papers-12.epub",
    "library/filler/collected-papers-13.epub",
    "library/filler/collected-papers-14.epub",
    "library/filler/collected-papers-15.epub",
    "library/filler/collected-papers-16.epub",
    "library/filler/annual-ledger-01.pdf",
    "library/filler/annual-ledger-02.pdf",
    "library/filler/annual-ledger-03.pdf",
    "library/filler/annual-ledger-04.pdf",
    "library/filler/annual-ledger-05.pdf",
    "library/filler/annual-ledger-06.pdf",
    "library/filler/sketchbook-01.cbz",
    "library/filler/sketchbook-02.cbz",
    "library/filler/sketchbook-03.cbz",
    "library/filler/sketchbook-04.cbz",
    "library/filler/sketchbook-05.cbz",
    "library/filler/sketchbook-06.cbz",
    "library/filler/collected-papers-17.epub",
    "library/filler/annual-ledger-07.pdf",
    "library/filler/sketchbook-07.cbz",
    "library/filler/collected-papers-18.epub",
];

const FILLER_PROGRESS: [f64; 32] = [
    0.0, 0.0, 0.0, 0.13, 0.0, 0.0, 0.0, 0.0, 0.62, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.21,
    0.0, 0.0, 0.0, 0.0, 0.0, 0.48, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
];

const FEATURED_SEED: [SeedBook; 14] = [
    // Reused repository fixture: the only asset family with an explicit
    // redistribution statement. It has no cover image, so it also feeds the
    // missing-cover placeholder row.
    SeedBook {
        file: "repo:crates/shosai-core/tests/fixtures/epub-conformance/conformance.epub",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-13 12:00:00",
    },
    // Bottom row of the first page: two CBZ/PDF books and a JA title keep the
    // format labels and the long-metadata row populated.
    SeedBook {
        file: "library/featured/comet-courier-02.cbz",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-02 10:00:00",
    },
    SeedBook {
        file: "library/featured/annual-report-ja.pdf",
        progress: 0.6,
        last_read: None,
        date_added: "2026-02-03 10:00:00",
    },
    SeedBook {
        file: "library/featured/mizu-no-kioku.epub",
        progress: 0.24,
        last_read: None,
        date_added: "2026-02-04 10:00:00",
    },
    SeedBook {
        file: "library/featured/toshokan-no-tebiki.epub",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-05 10:00:00",
    },
    SeedBook {
        file: "library/featured/kaze-no-mukougawa.epub",
        progress: 0.05,
        last_read: None,
        date_added: "2026-02-06 10:00:00",
    },
    SeedBook {
        file: "library/featured/comet-courier.cbz",
        progress: 0.31,
        last_read: None,
        date_added: "2026-02-07 10:00:00",
    },
    SeedBook {
        file: "library/featured/field-notes.pdf",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-08 10:00:00",
    },
    SeedBook {
        file: "library/featured/small-atlas.pdf",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-09 10:00:00",
    },
    // No cover: exercises the placeholder card (LB-12).
    SeedBook {
        file: "library/featured/workshop-proceedings.epub",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-10 10:00:00",
    },
    SeedBook {
        file: "library/featured/paper-lanterns.epub",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-11 10:00:00",
    },
    SeedBook {
        file: "library/featured/slow-rivers.epub",
        progress: 0.78,
        last_read: None,
        date_added: "2026-02-12 10:00:00",
    },
    SeedBook {
        file: "library/featured/salt-and-iron.epub",
        progress: 0.0,
        last_read: None,
        date_added: "2026-02-13 10:00:00",
    },
    // The continue-reading entry: the only book with `last_read`.
    SeedBook {
        file: "library/featured/quiet-cartographer.epub",
        progress: 0.42,
        last_read: Some(SEED_LAST_READ),
        date_added: "2026-02-14 10:00:00",
    },
];

fn push_file(files: &mut Vec<FixtureFile>, relative_path: &str, bytes: Vec<u8>) {
    // A PDF that draws text would let PDFium resolve a font from the host font
    // directories, which the entry point cannot pin: fail the run instead of
    // emitting a fixture whose covers depend on the machine.
    if relative_path.ends_with(".pdf") {
        let problems = pdf_font_free_problems(&bytes);
        assert!(
            problems.is_empty(),
            "generated PDF {relative_path} is not font-free: {}",
            problems.join("; ")
        );
    }
    files.push(FixtureFile {
        relative_path: relative_path.to_owned(),
        bytes,
    });
}

/// Every generated fixture file, in sorted path order.
pub(crate) fn reference_fixtures() -> Vec<FixtureFile> {
    let mut files: Vec<FixtureFile> = Vec::new();

    // -- Library seed books ------------------------------------------------
    for index in 0..16u32 {
        let number = index + 1;
        let title = match index {
            0 | 4 | 8 | 12 => format!("Collected Papers, Volume {number:02}"),
            _ => format!("Collected Papers, Volume {number:02}: Selected Essays"),
        };
        let author = if index % 3 == 0 {
            "Various Authors"
        } else {
            "Shosai Editorial Board"
        };
        let cover = (index % 5 != 4).then_some(CoverArt::new(index));
        push_file(
            &mut files,
            FILLER_FILES[index as usize],
            epub(&title, Some(author), "en", &filler_chapters(index), cover),
        );
    }
    for index in 16..22u32 {
        let number = index - 15;
        push_file(
            &mut files,
            FILLER_FILES[index as usize],
            pdf(
                &format!("Annual Ledger {number:02}"),
                "Shosai Press",
                2,
                palette(index),
            ),
        );
    }
    for index in 22..28u32 {
        let number = index - 21;
        push_file(
            &mut files,
            FILLER_FILES[index as usize],
            cbz(
                &format!("Sketchbook {number:02}"),
                "K. Ito",
                3,
                palette(index),
                false,
            ),
        );
    }
    push_file(
        &mut files,
        FILLER_FILES[28],
        epub(
            "Collected Papers, Volume 17",
            Some("Various Authors"),
            "en",
            &filler_chapters(28),
            Some(CoverArt::new(28)),
        ),
    );
    push_file(
        &mut files,
        FILLER_FILES[29],
        pdf("Annual Ledger 07", "Shosai Press", 2, palette(29)),
    );
    push_file(
        &mut files,
        FILLER_FILES[30],
        cbz("Sketchbook 07", "K. Ito", 3, palette(30), false),
    );
    push_file(
        &mut files,
        FILLER_FILES[31],
        epub(
            "Collected Papers, Volume 18",
            Some("Shosai Editorial Board"),
            "en",
            &filler_chapters(31),
            None,
        ),
    );

    // -- Featured books ----------------------------------------------------
    push_file(
        &mut files,
        "library/featured/quiet-cartographer.epub",
        epub(
            "The Quiet Cartographer",
            Some("Amara Okonkwo"),
            "en",
            &[
                ("Chapter One: The Survey", CARTOGRAPHER_ONE),
                ("Chapter Two: Salt Flats", CARTOGRAPHER_TWO),
                ("Chapter Three: The Last Sheet", CARTOGRAPHER_THREE),
            ],
            Some(CoverArt::new(100)),
        ),
    );
    push_file(
        &mut files,
        "library/featured/salt-and-iron.epub",
        epub(
            "Salt and Iron",
            Some("Nikolai Varga"),
            "en",
            &[
                ("I. The Harbour", SHORT_PROSE),
                ("II. The Foundry", SHORT_PROSE),
            ],
            Some(CoverArt::new(101)),
        ),
    );
    push_file(
        &mut files,
        "library/featured/slow-rivers.epub",
        epub(
            "A Field Guide to Slow Rivers",
            Some("Tomoko Sato"),
            "en",
            &[
                ("Headwaters", SHORT_PROSE),
                ("Meanders", SHORT_PROSE),
                ("Floodplains", SHORT_PROSE),
                ("Estuary", SHORT_PROSE),
            ],
            Some(CoverArt::new(102)),
        ),
    );
    push_file(
        &mut files,
        "library/featured/paper-lanterns.epub",
        epub(
            "Paper Lanterns at Dusk",
            Some("Elena Marchetti"),
            "en",
            &[("One", SHORT_PROSE), ("Two", SHORT_PROSE)],
            Some(CoverArt::new(103)),
        ),
    );
    // No cover: the OPF omits the cover metadata and image entirely.
    push_file(
        &mut files,
        "library/featured/workshop-proceedings.epub",
        epub(
            "Proceedings of the Ninth Shosai Workshop",
            Some("Shosai Project"),
            "en",
            &[
                ("Opening Session", SHORT_PROSE),
                ("Closing Session", SHORT_PROSE),
            ],
            None,
        ),
    );
    push_file(
        &mut files,
        "library/featured/small-atlas.pdf",
        pdf(
            "A Small Atlas of Imaginary Coastlines",
            "P. Herrera",
            4,
            palette(104),
        ),
    );
    push_file(
        &mut files,
        "library/featured/field-notes.pdf",
        pdf("Field Notes, 1962-1968", "R. Okafor", 2, palette(105)),
    );
    push_file(
        &mut files,
        "library/featured/comet-courier.cbz",
        cbz(
            "Comet Courier, Issue 01",
            "R. Ibarra",
            12,
            palette(106),
            true,
        ),
    );
    push_file(
        &mut files,
        "library/featured/comet-courier-02.cbz",
        cbz(
            "Comet Courier, Issue 02",
            "R. Ibarra",
            3,
            palette(107),
            false,
        ),
    );
    push_file(
        &mut files,
        "library/featured/kaze-no-mukougawa.epub",
        epub(
            "風の向こう側にある図書館と、そこで暮らす人々の長い物語",
            Some("日本 花子"),
            "ja",
            &[
                ("第一章 海辺の書架", JAPANESE_PROSE),
                ("第二章 風の記憶", JAPANESE_PROSE),
            ],
            Some(CoverArt::new(108)),
        ),
    );
    push_file(
        &mut files,
        "library/featured/mizu-no-kioku.epub",
        epub(
            "水の記憶、砂の記録",
            Some("佐藤 健一"),
            "ja",
            &[
                ("一 湖の記録", JAPANESE_PROSE),
                ("二 砂の記憶", JAPANESE_PROSE),
                ("三 乾いた手紙", JAPANESE_PROSE),
            ],
            Some(CoverArt::new(109)),
        ),
    );
    push_file(
        &mut files,
        "library/featured/toshokan-no-tebiki.epub",
        epub(
            "司書の手引き / The Librarian's Companion",
            Some("Darwin Shosai"),
            "ja",
            &[
                ("序章 / Introduction", JAPANESE_PROSE),
                ("第一章 / Chapter One", SHORT_PROSE),
            ],
            Some(CoverArt::new(110)),
        ),
    );
    push_file(
        &mut files,
        "library/featured/annual-report-ja.pdf",
        pdf(
            "技術報告書 2026 — 書斎プロジェクトの年次報告",
            "書斎編集部",
            2,
            palette(111),
        ),
    );

    // -- Import sources ----------------------------------------------------
    // A byte-identical copy of a library book: "already in library" duplicate.
    let cartographer = files
        .iter()
        .find(|file| file.relative_path == "library/featured/quiet-cartographer.epub")
        .expect("cartographer fixture")
        .bytes
        .clone();
    push_file(
        &mut files,
        "sources/reading-queue/quiet-cartographer.epub",
        cartographer,
    );

    // Two byte-identical files under different names: the second is a
    // "duplicate of a selected file".
    let tandem = epub(
        "Tandem Draft",
        Some("Shared Draft"),
        "en",
        &[("Draft", SHORT_PROSE)],
        Some(CoverArt::new(120)),
    );
    push_file(&mut files, "sources/reading-queue/tandem-a.epub", tandem);
    let tandem = files
        .iter()
        .find(|file| file.relative_path == "sources/reading-queue/tandem-a.epub")
        .expect("tandem fixture")
        .bytes
        .clone();
    push_file(&mut files, "sources/reading-queue/tandem-b.epub", tandem);

    // Same normalized title stem in two folders: one review group, two rows.
    push_file(
        &mut files,
        "sources/reading-queue/shelf-a/bright-harbor.epub",
        epub(
            "Bright Harbor",
            Some("L. Mensah"),
            "en",
            &[("Morning", SHORT_PROSE), ("Evening", SHORT_PROSE)],
            Some(CoverArt::new(121)),
        ),
    );
    push_file(
        &mut files,
        "sources/reading-queue/shelf-b/bright-harbor.cbz",
        cbz("Bright Harbor", "L. Mensah", 3, palette(122), false),
    );
    // Long Japanese file names inside the folder selection (IM-12).
    push_file(
        &mut files,
        "sources/reading-queue/静かな海の図書館の一年 — 年次報告書と収蔵目録 2026年版.epub",
        epub(
            "静かな海の図書館の一年",
            Some("海辺 図書館"),
            "ja",
            &[("第一章", JAPANESE_PROSE)],
            Some(CoverArt::new(123)),
        ),
    );
    push_file(
        &mut files,
        "sources/reading-queue/砂漠のアーカイブ — 失われた書架をめぐる長い旅路.epub",
        epub(
            "砂漠のアーカイブ",
            Some("砂 アーカイブ"),
            "ja",
            &[("第一章", JAPANESE_PROSE)],
            Some(CoverArt::new(124)),
        ),
    );
    // Unsupported files inside a recursive folder scan are ignored.
    push_file(
        &mut files,
        "sources/reading-queue/notes.txt",
        b"Reference capture note: not a book.\n".to_vec(),
    );

    // Long file paths for the files-selection review state (IM-12).
    for (index, path) in IMPORT_LONG_FILES.iter().enumerate() {
        let bytes = match path.rsplit('.').next() {
            Some("pdf") => pdf(
                "司書の手引き と 目録作成の実際",
                "図書館協会",
                2,
                palette(130 + index as u32),
            ),
            _ => epub(
                "静かな海の図書館の一年",
                Some("海辺 図書館"),
                "ja",
                &[("第一章", JAPANESE_PROSE)],
                Some(CoverArt::new(130 + index as u32)),
            ),
        };
        push_file(&mut files, path, bytes);
    }

    // A folder with nothing importable: the "no supported books" state.
    push_file(
        &mut files,
        "sources/no-supported/readme.txt",
        b"Nothing to import in this folder.\n".to_vec(),
    );
    push_file(
        &mut files,
        "sources/no-supported/cover.jpg",
        cover_png(200, false),
    );

    files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    files
}

/// Relative target of the dangling symlinks the fixture writer creates.
///
/// The target is deliberately relative and does not exist: the committed link
/// stays valid (and identical) in any checkout, on any machine.
pub(crate) const BROKEN_SYMLINK_TARGET: &str = "missing-target.epub";

/// Relative paths of the dangling symlinks the fixture writer creates. They
/// produce the deterministic discovery failure state (IM-06): the scan sees a
/// supported extension, then `std::fs::metadata` fails for the missing target.
pub(crate) const BROKEN_SYMLINKS: [&str; 1] = ["sources/reading-queue/broken-book.epub"];

/// Create the declared dangling symlink at `root/<relative_path>`.
///
/// On platforms without symlink support this is a no-op; the manifest records
/// whether the link could be created (`broken_symlinks_available`) so the
/// affected capture is not claimed to show a failure it never reached.
fn write_broken_symlinks(root: &Path) -> std::io::Result<()> {
    for relative_path in BROKEN_SYMLINKS {
        let path = root.join(relative_path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        #[cfg(unix)]
        {
            // Remove a stale link first: `symlink` fails when the path exists.
            let _ = std::fs::remove_file(&path);
            std::os::unix::fs::symlink(BROKEN_SYMLINK_TARGET, &path)?;
        }
        #[cfg(not(unix))]
        {
            let _ = &path;
        }
    }
    Ok(())
}

/// Every symlink problem in a fixture tree.
///
/// A tree may contain exactly the declared dangling fixtures: each declared
/// path must be a symlink whose target is [`BROKEN_SYMLINK_TARGET`] and whose
/// target does not exist. Any other symlink is a defect, because the tree is
/// meant to be data the library can import and a link that resolves into the
/// checkout would import something the run does not control.
///
/// On a platform that cannot create symlinks the declared fixtures are simply
/// absent: that is reported by [`broken_symlinks_available`] and recorded in the
/// manifest instead of being treated as a defect.
pub(crate) fn symlink_defects(root: &Path) -> Vec<String> {
    fn walk(root: &Path, directory: &Path, defects: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(directory) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                let relative = path
                    .strip_prefix(root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .replace('\\', "/");
                if !BROKEN_SYMLINKS.contains(&relative.as_str()) {
                    defects.push(format!("{relative}: unexpected symlink"));
                    continue;
                }
                match std::fs::read_link(&path) {
                    Ok(target) if target != Path::new(BROKEN_SYMLINK_TARGET) => {
                        defects.push(format!(
                            "{relative}: symlink target is {}, not {BROKEN_SYMLINK_TARGET}",
                            target.display()
                        ))
                    }
                    Ok(_) if std::fs::metadata(&path).is_ok() => defects.push(format!(
                        "{relative}: symlink target exists, so the link is not dangling"
                    )),
                    Ok(_) => {}
                    Err(error) => {
                        defects.push(format!("{relative}: symlink cannot be read: {error}"))
                    }
                }
                continue;
            }
            if file_type.is_dir() {
                walk(root, &path, defects);
            }
        }
    }

    let mut defects = Vec::new();
    walk(root, root, &mut defects);
    defects.sort();
    defects
}

/// Write the full fixture tree under `root`, returning the written byte files.
///
/// `root` is created if needed and is expected to be a disposable directory
/// (the capture tool's data root). Existing files are overwritten so repeated
/// runs are idempotent. Dangling symlinks are best-effort: on platforms that
/// cannot create them the affected capture records the gap instead of
/// fabricating the state.
pub(crate) fn write_reference_fixtures(root: &Path) -> std::io::Result<Vec<FixtureRecord>> {
    write_fixture_files(root, reference_fixtures())
}

/// Write the fixture tree a package renders from.
///
/// Each package has its own disposable data root and mirrors its own tree into
/// its own evidence directory, so package 1C adds its capture-only fixture here
/// and package 1B's tree, mirror, checksums and manifest stay byte-identical.
pub(crate) fn write_reference_fixtures_for(
    root: &Path,
    package: super::package::Package,
) -> std::io::Result<Vec<FixtureRecord>> {
    let mut files = reference_fixtures();
    if package == super::package::Package::OneC {
        files.push(reader_marks_fixture());
    }
    write_fixture_files(root, files)
}

/// The generated capture-only fixture package 1C adds.
///
/// One chapter that carries the marks `FM-01` names — a list, a quote, a link,
/// a coloured document image — without the unmatched italic that keeps the
/// repository's sampler book from rendering under the pinned font environment.
/// The image is also `FM-18`'s evidence: the capture must record exactly
/// [`READER_MARKS_COLOUR`] where the document paints it.
pub(crate) fn reader_marks_fixture() -> FixtureFile {
    let mut archive = ArchiveWriter::new();
    archive.add("mimetype", b"application/epub+zip");
    archive.add(
        "META-INF/container.xml",
        br#"<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"#,
    );
    archive.add(
        "OEBPS/style.css",
        b"body { margin: 1.5em; }\nh1 { font-size: 1.4em; }\np { margin: 0.8em 0; }\nblockquote { margin: 1em 2em; }\n",
    );
    archive.add("OEBPS/images/mark.png", &colour_mark_png());
    archive.add(
        "OEBPS/nav.xhtml",
        br#"<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
  <head><title>Reader marks</title></head>
  <body><nav epub:type="toc"><ol><li><a href="text/chapter-1.xhtml">Marks</a></li></ol></nav></body>
</html>
"#,
    );
    let chapter = r#"<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
  <head>
    <title>Reader marks</title>
    <link rel="stylesheet" type="text/css" href="../style.css"/>
  </head>
  <body>
    <h1>Marks on a Survey Sheet</h1>
    <p>The survey sheet carries three kinds of mark.</p>
    <img src="../images/mark.png" alt="Colour mark"/>
    <ul>
      <li>A list item that names the first mark.</li>
      <li>A list item that names the second mark.</li>
    </ul>
    <blockquote><p>A quoted line from the field notebook, indented on both sides.</p></blockquote>
    <p>A paragraph that ends with <a href="https://example.invalid/notes">a link to the notes</a>.</p>
  </body>
</html>
"#;
    archive.add("OEBPS/text/chapter-1.xhtml", chapter.as_bytes());
    archive.add(
        "OEBPS/content.opf",
        br#"<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">reader-marks</dc:identifier>
    <dc:title>Reader marks</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="chapter-1" href="text/chapter-1.xhtml" media-type="application/xhtml+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
    <item id="mark" href="images/mark.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="chapter-1"/></spine>
</package>
"#,
    );
    FixtureFile {
        relative_path: "library/featured/reader-marks.epub".to_owned(),
        bytes: archive.finish(),
    }
}

/// The colour the generated marks fixture paints its document image in, so
/// `FM-18`'s evidence can assert that the capture recorded the document's own
/// colour through composition.
///
/// It is carried by an *image* rather than by a CSS text colour because the
/// shared EPUB style model has no colour field at all: document text is painted
/// with the reader palette, so only the image path can show a document colour
/// surviving composition.
pub(crate) const READER_MARKS_COLOUR: (u8, u8, u8) = (0xB3, 0x47, 0x00);

/// The opaque image the generated marks fixture embeds, filled with
/// [`READER_MARKS_COLOUR`].
///
/// It is larger than one pixel so the rendered page has an interior region that
/// must be exactly the document colour, and it is drawn at its intrinsic size
/// (`pagination::epub_image_layout` clamps to the available width, which is
/// wider here), so no resampling touches the colour.
fn colour_mark_png() -> Vec<u8> {
    const SIZE: u32 = 64;
    let (red, green, blue) = READER_MARKS_COLOUR;
    let mut pixels = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for _ in 0..SIZE * SIZE {
        pixels.extend_from_slice(&[red, green, blue, 0xFF]);
    }
    encode_png(&pixels, SIZE, SIZE)
}

fn write_fixture_files(
    root: &Path,
    files: Vec<FixtureFile>,
) -> std::io::Result<Vec<FixtureRecord>> {
    let mut records = Vec::new();
    for file in files {
        let path = root.join(&file.relative_path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, &file.bytes)?;
        records.push(FixtureRecord {
            relative_path: file.relative_path,
            sha256: sha256_hex(&file.bytes),
            bytes: file.bytes.len(),
        });
    }
    write_broken_symlinks(root)?;
    records.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    Ok(records)
}

/// Whether the dangling-symlink failure fixture could be created.
pub(crate) fn broken_symlinks_available(root: &Path) -> bool {
    BROKEN_SYMLINKS.iter().all(|relative_path| {
        let path = root.join(relative_path);
        path.is_symlink() && std::fs::metadata(&path).is_err()
    })
}

/// Copy a generated fixture tree into the committed evidence directory.
///
/// The captures always read the tree from the disposable data root, so the
/// evidence holds a byte copy of exactly what was rendered rather than the tree
/// that was rendered from a checkout path. Dangling symlinks are copied as
/// links, and every copied file is re-hashed so a partial copy cannot pass as
/// evidence.
pub(crate) fn mirror_reference_fixtures(
    source: &Path,
    destination: &Path,
    records: &[FixtureRecord],
) -> std::io::Result<Vec<FixtureRecord>> {
    if destination.exists() {
        std::fs::remove_dir_all(destination)?;
    }
    let mut verified = Vec::new();
    for record in records {
        let from = source.join(&record.relative_path);
        let to = destination.join(&record.relative_path);
        if let Some(parent) = to.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(&from, &to)?;
        let bytes = std::fs::read(&to)?;
        verified.push(FixtureRecord {
            relative_path: record.relative_path.clone(),
            sha256: sha256_hex(&bytes),
            bytes: bytes.len(),
        });
    }
    write_broken_symlinks(destination)?;
    verified.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    Ok(verified)
}

/// Hash every regular file of a committed fixture tree, relative to its root.
///
/// Symlinks are not regular files: the declared dangling fixtures are validated
/// by [`symlink_defects`] and any other symlink fails the read, so a link
/// pointing outside the tree cannot pass as a fixture. Any other kind of entry
/// is a failure as well: a socket, FIFO or device in the tree is not something
/// the generator writes, so accepting (skipping) it would let the tree carry an
/// artifact no run produced. The root itself must be a real directory — a
/// symlinked root would make the walk read whatever it points at.
pub(crate) fn read_reference_fixtures(root: &Path) -> std::io::Result<Vec<FixtureRecord>> {
    if !super::evidence::real_directory(root) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!(
                "the fixture tree root {} is not a real directory",
                root.display()
            ),
        ));
    }

    fn walk(root: &Path, directory: &Path, out: &mut Vec<FixtureRecord>) -> std::io::Result<()> {
        for entry in std::fs::read_dir(directory)? {
            let entry = entry?;
            let path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                walk(root, &path, out)?;
                continue;
            }
            if file_type.is_symlink() {
                // The declared dangling symlinks; `symlink_defects` rejects any
                // other link (and a wrong target).
                continue;
            }
            if !file_type.is_file() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!(
                        "the fixture tree contains {}, which is neither a regular file nor a \
                         declared symlink fixture",
                        path.display()
                    ),
                ));
            }
            let bytes = std::fs::read(&path)?;
            let relative = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            out.push(FixtureRecord {
                relative_path: relative,
                sha256: sha256_hex(&bytes),
                bytes: bytes.len(),
            });
        }
        Ok(())
    }

    let mut records = Vec::new();
    walk(root, root, &mut records)?;
    records.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
    let defects = symlink_defects(root);
    if !defects.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("symlink fixture defects: {}", defects.join("; ")),
        ));
    }
    Ok(records)
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

// ---------------------------------------------------------------------------
// Archives
// ---------------------------------------------------------------------------

fn zip_options() -> SimpleFileOptions {
    SimpleFileOptions::default()
        .compression_method(CompressionMethod::Stored)
        // The `zip` crate otherwise derives the "version made by" system byte
        // from the host (`System::Dos` on Windows, `System::Unix` elsewhere),
        // which makes every archive a different byte sequence per platform. The
        // committed fixture hashes are the Unix bytes, so the system is pinned
        // rather than inherited: a Windows or macOS run must emit the same
        // fixture bytes as the pinned capture environment.
        .system(System::Unix)
        .last_modified_time(
            DateTime::from_date_and_time(
                FIXTURE_ZIP_DATE.0,
                FIXTURE_ZIP_DATE.1,
                FIXTURE_ZIP_DATE.2,
                FIXTURE_ZIP_DATE.3,
                FIXTURE_ZIP_DATE.4,
                FIXTURE_ZIP_DATE.5,
            )
            .expect("fixture ZIP timestamp is in range"),
        )
        .unix_permissions(0o644)
}

struct ArchiveWriter {
    writer: ZipWriter<Cursor<Vec<u8>>>,
}

impl ArchiveWriter {
    fn new() -> Self {
        Self {
            writer: ZipWriter::new(Cursor::new(Vec::new())),
        }
    }

    fn add(&mut self, path: &str, bytes: &[u8]) {
        self.writer
            .start_file(path, zip_options())
            .expect("fixture archive entry");
        self.writer.write_all(bytes).expect("fixture archive bytes");
    }

    fn finish(self) -> Vec<u8> {
        self.writer
            .finish()
            .expect("fixture archive finish")
            .into_inner()
    }
}

// ---------------------------------------------------------------------------
// EPUB
// ---------------------------------------------------------------------------

/// Deterministic generated cover art: a two-tone field with a title band.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CoverArt {
    index: u32,
}

impl CoverArt {
    pub(crate) fn new(index: u32) -> Self {
        Self { index }
    }
}

fn palette(index: u32) -> (u8, u8, u8) {
    const PALETTES: [(u8, u8, u8); 12] = [
        (0x2F, 0x40, 0x5A),
        (0x6B, 0x3F, 0x2F),
        (0x2F, 0x5A, 0x46),
        (0x5A, 0x2F, 0x50),
        (0x3B, 0x3B, 0x4A),
        (0x7A, 0x5A, 0x28),
        (0x28, 0x4A, 0x6B),
        (0x4A, 0x28, 0x28),
        (0x36, 0x52, 0x39),
        (0x52, 0x36, 0x5E),
        (0x2B, 0x4E, 0x57),
        (0x63, 0x4A, 0x38),
    ];
    PALETTES[(index as usize) % PALETTES.len()]
}

/// A 300×450 cover image: solid field, a lighter band, a spine stripe.
fn cover_png(index: u32, dark: bool) -> Vec<u8> {
    const WIDTH: u32 = 300;
    const HEIGHT: u32 = 450;
    let (red, green, blue) = palette(index);
    let mut pixels = vec![0u8; (WIDTH * HEIGHT * 4) as usize];
    for y in 0..HEIGHT {
        for x in 0..WIDTH {
            let offset = ((y * WIDTH + x) * 4) as usize;
            let band = (60..150).contains(&y);
            let spine = x < 18;
            let (mut r, mut g, mut b) = (red, green, blue);
            if band {
                r = r.saturating_add(38);
                g = g.saturating_add(36);
                b = b.saturating_add(30);
            }
            if spine {
                r = r.saturating_sub(26);
                g = g.saturating_sub(26);
                b = b.saturating_sub(26);
            }
            let accent = (index as usize * 7 + y as usize / 3).is_multiple_of(97);
            if accent {
                r = r.saturating_add(46);
                g = g.saturating_add(24);
                b = b.saturating_sub(18);
            }
            if dark {
                r /= 2;
                g /= 2;
                b /= 2;
            }
            pixels[offset] = r;
            pixels[offset + 1] = g;
            pixels[offset + 2] = b;
            pixels[offset + 3] = 0xFF;
        }
    }
    encode_png(&pixels, WIDTH, HEIGHT)
}

/// A comic page: field, header band, text-line bars, distinct page marker.
fn page_png(index: u32, (red, green, blue): (u8, u8, u8)) -> Vec<u8> {
    const WIDTH: u32 = 200;
    const HEIGHT: u32 = 300;
    let mut pixels = vec![0xFFu8; (WIDTH * HEIGHT * 4) as usize];
    let mut set = |x: u32, y: u32, (r, g, b): (u8, u8, u8)| {
        if x < WIDTH && y < HEIGHT {
            let offset = ((y * WIDTH + x) * 4) as usize;
            pixels[offset] = r;
            pixels[offset + 1] = g;
            pixels[offset + 2] = b;
            pixels[offset + 3] = 0xFF;
        }
    };
    for y in 0..34 {
        for x in 0..WIDTH {
            set(x, y, (red, green, blue));
        }
    }
    // The page marker: `index + 1` vertical bars, so page order is visible.
    for bar in 0..=(index % 13) {
        let x = 12 + bar * 12;
        for y in 40..(40 + 20 + bar * 4) {
            set(x, y, (red, green, blue));
        }
    }
    for line in 0..12u32 {
        let y = 90 + line * 16;
        for x in 12..(WIDTH - 12) {
            set(x, y, (0x33, 0x33, 0x33));
        }
    }
    encode_png(&pixels, WIDTH, HEIGHT)
}

fn encode_png(pixels: &[u8], width: u32, height: u32) -> Vec<u8> {
    use image::ImageEncoder;

    let mut bytes = Vec::new();
    image::codecs::png::PngEncoder::new(&mut bytes)
        .write_image(pixels, width, height, image::ExtendedColorType::Rgba8)
        .expect("fixture PNG encoding");
    bytes
}

fn epub(
    title: &str,
    author: Option<&str>,
    language: &str,
    chapters: &[(&str, &str)],
    cover: Option<CoverArt>,
) -> Vec<u8> {
    let mut archive = ArchiveWriter::new();
    // `mimetype` must be first and uncompressed.
    archive.add("mimetype", b"application/epub+zip");
    archive.add(
        "META-INF/container.xml",
        br#"<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"#,
    );
    archive.add("OEBPS/style.css", EPUB_STYLE.as_bytes());

    let mut manifest = String::from(
        r#"    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
"#,
    );
    let mut spine = String::new();
    for (index, (heading, body)) in chapters.iter().enumerate() {
        let number = index + 1;
        manifest.push_str(&format!(
            "    <item id=\"chapter-{number}\" href=\"text/chapter-{number}.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        ));
        spine.push_str(&format!("    <itemref idref=\"chapter-{number}\"/>\n"));
        archive.add(
            &format!("OEBPS/text/chapter-{number}.xhtml"),
            chapter_xhtml(title, heading, body, language).as_bytes(),
        );
    }
    if let Some(cover) = cover {
        manifest.push_str(
            "    <item id=\"cover-image\" href=\"images/cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>\n",
        );
        archive.add("OEBPS/images/cover.png", &cover_png(cover.index, false));
    }
    let cover_meta = if cover.is_some() {
        "    <meta name=\"cover\" content=\"cover-image\"/>\n"
    } else {
        ""
    };
    let identifier = format!(
        "urn:uuid:00000000-0000-4000-8000-{:012}",
        identifier_suffix(title)
    );
    let mut metadata = format!(
        r#"    <dc:identifier id="bookid">{identifier}</dc:identifier>
    <dc:title>{}</dc:title>
    <dc:language>{language}</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
{cover_meta}"#,
        escape_xml(title),
    );
    if let Some(author) = author {
        metadata.push_str(&format!(
            "    <dc:creator>{}</dc:creator>\n",
            escape_xml(author)
        ));
    }
    archive.add(
        "OEBPS/content.opf",
        format!(
            r#"<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="{language}">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
{metadata}  </metadata>
  <manifest>
{manifest}  </manifest>
  <spine toc="ncx">
{spine}  </spine>
</package>
"#
        )
        .as_bytes(),
    );
    archive.add(
        "OEBPS/nav.xhtml",
        nav_xhtml(title, chapters, language).as_bytes(),
    );
    archive.add("OEBPS/toc.ncx", toc_ncx(title, chapters).as_bytes());
    archive.finish()
}

const EPUB_STYLE: &str = "body { font-family: serif; margin: 1.5em; }\nh1 { font-size: 1.4em; }\np { margin: 0.8em 0; }\n";

/// One chapter document.
///
/// `language` is the publication language from the OPF, so the document-language
/// metadata inside the archive agrees with `<dc:language>` for English *and*
/// Japanese fixtures instead of always declaring English.
fn chapter_xhtml(title: &str, heading: &str, body: &str, language: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="{language}">
  <head>
    <title>{}</title>
    <link rel="stylesheet" type="text/css" href="../style.css"/>
  </head>
  <body>
    <h1>{}</h1>
    <p>{}</p>
  </body>
</html>
"#,
        escape_xml(title),
        escape_xml(heading),
        escape_xml(body)
    )
}

/// The table-of-contents document, with the same declared language as the
/// chapters.
fn nav_xhtml(title: &str, chapters: &[(&str, &str)], language: &str) -> String {
    let mut entries = String::new();
    for (index, (heading, _)) in chapters.iter().enumerate() {
        entries.push_str(&format!(
            "        <li><a href=\"text/chapter-{}.xhtml\">{}</a></li>\n",
            index + 1,
            escape_xml(heading)
        ));
    }
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{language}">
  <head><title>{}</title></head>
  <body>
    <nav epub:type="toc" id="toc">
      <ol>
{}      </ol>
    </nav>
  </body>
</html>
"#,
        escape_xml(title),
        entries
    )
}

fn toc_ncx(title: &str, chapters: &[(&str, &str)]) -> String {
    let mut points = String::new();
    for (index, (heading, _)) in chapters.iter().enumerate() {
        let number = index + 1;
        points.push_str(&format!(
            r#"    <navPoint id="navPoint-{number}" playOrder="{number}">
      <navLabel><text>{}</text></navLabel>
      <content src="text/chapter-{number}.xhtml"/>
    </navPoint>
"#,
            escape_xml(heading)
        ));
    }
    format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="fixture"/>
    <meta name="dtb:depth" content="1"/>
  </head>
  <docTitle><text>{}</text></docTitle>
  <navMap>
{}  </navMap>
</ncx>
"#,
        escape_xml(title),
        points
    )
}

fn identifier_suffix(title: &str) -> u64 {
    // Stable, cheap FNV-1a over the title: keeps the identifier deterministic
    // and distinct per book without pulling in a random source.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in title.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash % 1_000_000_000_000
}

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn filler_chapters(index: u32) -> Vec<(&'static str, &'static str)> {
    match index % 4 {
        0 => vec![("Introduction", SHORT_PROSE), ("Notes", SHORT_PROSE)],
        1 => vec![("Preface", SHORT_PROSE)],
        2 => vec![
            ("Part One", SHORT_PROSE),
            ("Part Two", SHORT_PROSE),
            ("Part Three", SHORT_PROSE),
        ],
        _ => vec![("Preface to the Second Edition", SHORT_PROSE)],
    }
}

const SHORT_PROSE: &str = "The survey began at first light and ended when the tide turned, which left just enough time to record the headland and the two small bays beyond it.";
const CARTOGRAPHER_ONE: &str = "Every map begins as a list of things that are wrong with the previous map. Ours began with a coastline that had moved eleven metres north since the last survey.";
const CARTOGRAPHER_TWO: &str = "The salt flats hold the light differently in the afternoon. We walked them in silence, counting the stakes that marked the old shoreline.";
const CARTOGRAPHER_THREE: &str = "On the last sheet we drew nothing at all, only the faint pencil of a road that had already been washed away, and the note: verify in spring.";
const JAPANESE_PROSE: &str =
    "海辺の図書館には、潮の匂いがする本棚があった。司書は毎朝、窓を開けてから目録をめくる。";

// ---------------------------------------------------------------------------
// PDF
// ---------------------------------------------------------------------------

/// A conformant PDF 1.4 with a correct cross-reference table (correct object
/// offsets and `startxref`), unlike the legacy `sample.pdf`. Object bodies are
/// fixed, so identical inputs produce identical bytes.
///
/// The page artwork is deliberately text-free: PDFium resolves fonts for
/// unembedded PDF text itself by scanning the host font directories, and it does
/// not follow `FONTCONFIG_FILE`, so a `Helvetica` text run would make the
/// rendered cover depend on the machine's installed fonts. Pages draw the header
/// band, an accent bar, the text-line bars and a page marker made of one square
/// per page; the title, author and page count stay in the document information
/// dictionary, which is what the library reads.
fn pdf(title: &str, author: &str, pages: u32, accent: (u8, u8, u8)) -> Vec<u8> {
    let pages = pages.max(1);
    let page_ids: Vec<u32> = (0..pages).map(|index| 3 + index * 2).collect();
    let info_id = 3 + pages * 2;

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"%PDF-1.4\n");
    // Object 0 is the free head and has no body.
    let mut offsets: Vec<usize> = vec![0; (info_id + 1) as usize];

    let begin_object = |out: &mut Vec<u8>, offsets: &mut Vec<usize>, id: u32| {
        offsets[id as usize] = out.len();
        out.extend_from_slice(format!("{id} 0 obj\n").as_bytes());
    };
    let end_object = |out: &mut Vec<u8>| out.extend_from_slice(b"\nendobj\n");

    begin_object(&mut out, &mut offsets, 1);
    out.extend_from_slice(b"<< /Type /Catalog /Pages 2 0 R >>");
    end_object(&mut out);

    let kids: Vec<String> = page_ids.iter().map(|id| format!("{id} 0 R")).collect();
    begin_object(&mut out, &mut offsets, 2);
    out.extend_from_slice(
        format!(
            "<< /Type /Pages /Count {pages} /Kids [{}] >>",
            kids.join(" ")
        )
        .as_bytes(),
    );
    end_object(&mut out);

    for (index, page_id) in page_ids.iter().enumerate() {
        let content_id = page_id + 1;
        begin_object(&mut out, &mut offsets, *page_id);
        out.extend_from_slice(
            format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /ProcSet [/PDF] >> /Contents {content_id} 0 R >>"
            )
            .as_bytes(),
        );
        end_object(&mut out);

        let mut stream = String::from("0.93 0.92 0.90 rg\n0 700 612 92 re f\n");
        // The page marker: one square per page, so pages stay distinguishable
        // without a glyph.
        stream.push_str("0.18 0.18 0.18 rg\n");
        for marker in 0..=index {
            let x = 72 + marker as u32 * 22;
            stream.push_str(&format!("{x} 726 14 14 re f\n"));
        }
        stream.push_str(&format!(
            "{} {} {} rg\n72 640 240 12 re f\n",
            f32::from(accent.0) / 255.0,
            f32::from(accent.1) / 255.0,
            f32::from(accent.2) / 255.0
        ));
        stream.push_str("0.25 0.25 0.25 rg\n");
        for line in 0..10 {
            let y = 600 - line * 26;
            stream.push_str(&format!("72 {y} 468 8 re f\n"));
        }

        begin_object(&mut out, &mut offsets, content_id);
        out.extend_from_slice(format!("<< /Length {} >>\nstream\n", stream.len()).as_bytes());
        out.extend_from_slice(stream.as_bytes());
        out.extend_from_slice(b"\nendstream");
        end_object(&mut out);
    }

    begin_object(&mut out, &mut offsets, info_id);
    out.extend_from_slice(
        format!(
            "<< /Title {} /Author {} /Producer (Shosai reference fixture generator) /CreationDate (D:20260101000000Z) >>",
            pdf_string(title),
            pdf_string(author)
        )
        .as_bytes(),
    );
    end_object(&mut out);

    let xref_offset = out.len();
    let object_count = info_id + 1;
    out.extend_from_slice(format!("xref\n0 {object_count}\n").as_bytes());
    out.extend_from_slice(b"0000000000 65535 f\r\n");
    for id in 1..object_count {
        out.extend_from_slice(format!("{:010} 00000 n\r\n", offsets[id as usize]).as_bytes());
    }
    out.extend_from_slice(
        format!(
            "trailer\n<< /Size {object_count} /Root 1 0 R /Info {info_id} 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n"
        )
        .as_bytes(),
    );
    out
}

/// Problems if a generated PDF could make PDFium substitute a host font.
///
/// Pure, so the generator and the regression test share one contract. A
/// font-free PDF has no font resource, no font name, no embedded font stream and
/// no text-drawing operator, so no glyph is resolved and the rasterized pixels
/// cannot follow the machine's installed fonts. (`PDFium` scans the host font
/// directories for unembedded text and does not read `FONTCONFIG_FILE`.)
pub(crate) fn pdf_font_free_problems(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes);
    let mut problems = Vec::new();
    for (needle, description) in [
        ("/Font", "a font resource"),
        ("/BaseFont", "a font base name"),
        ("/FontFile", "an embedded font stream"),
        ("/Type1", "a font subtype"),
        (" Tf", "a font-selection operator"),
        (" Tj", "a text-showing operator"),
        (" TJ", "a text-showing array operator"),
        ("\nBT", "a text object"),
    ] {
        if text.contains(needle) {
            problems.push(format!("the PDF contains {description} (`{needle}`)"));
        }
    }
    problems
}

/// PDF text strings: ASCII stays a literal string, everything else becomes a
/// UTF-16BE hex string with a byte-order mark.
fn pdf_string(value: &str) -> String {
    if value.is_ascii() && !value.contains(['\\', '(', ')']) {
        return format!("({value})");
    }
    let mut hex = String::from("<FEFF");
    for unit in value.encode_utf16() {
        hex.push_str(&format!("{unit:04X}"));
    }
    hex.push('>');
    hex
}

// ---------------------------------------------------------------------------
// CBZ
// ---------------------------------------------------------------------------

fn cbz(title: &str, author: &str, pages: u32, accent: (u8, u8, u8), macos_junk: bool) -> Vec<u8> {
    let mut archive = ArchiveWriter::new();
    for index in 0..pages {
        archive.add(&format!("page{}.png", index + 1), &page_png(index, accent));
    }
    archive.add(
        "ComicInfo.xml",
        format!(
            "<ComicInfo><Title>{}</Title><Writer>{}</Writer><PageCount>{pages}</PageCount></ComicInfo>",
            escape_xml(title),
            escape_xml(author)
        )
        .as_bytes(),
    );
    if macos_junk {
        // Retained fixture convention: `cbz.rs` filters `__MACOSX` entries.
        archive.add("__MACOSX/.DS_Store", b"fixture junk entry");
    }
    archive.finish()
}
