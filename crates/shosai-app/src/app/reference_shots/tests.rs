//! Regression tests for the capture harness.
//!
//! These run in an ordinary `cargo test`: they do not render or write evidence,
//! but they do fail when the fixture generator, the seeded order, the capture
//! table or the committed evidence stops agreeing with the code.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use super::fixtures::{self, FixtureRecord, SeedBook};
use super::harness::Harness;
use super::scenarios::{self, Base};
use super::seed;
use crate::app::{AddBookBehavior, Message};

fn temp_root() -> tempfile::TempDir {
    tempfile::tempdir().expect("temp dir")
}

fn evidence_root() -> PathBuf {
    super::runner::output_root()
}

/// Generate the fixture tree twice and compare bytes, order and hashes.
#[test]
fn generated_fixtures_are_deterministic() {
    let first_root = temp_root();
    let second_root = temp_root();
    let first = fixtures::write_reference_fixtures(first_root.path()).expect("first fixture tree");
    let second =
        fixtures::write_reference_fixtures(second_root.path()).expect("second fixture tree");

    assert!(!first.is_empty(), "fixture set must not be empty");
    assert_eq!(first, second, "fixture bytes or order changed between runs");

    // The same bytes from the generator, independent of the file system.
    let in_memory: Vec<FixtureRecord> = {
        let mut records: Vec<FixtureRecord> = fixtures::reference_fixtures()
            .into_iter()
            .map(|file| FixtureRecord {
                sha256: fixtures::sha256_hex(&file.bytes),
                bytes: file.bytes.len(),
                relative_path: file.relative_path,
            })
            .collect();
        records.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
        records
    };
    assert_eq!(
        in_memory, first,
        "written fixtures differ from the generator"
    );
}

/// The generated fixture tree must match the committed `fixtures.sha256` so an
/// accidental fixture change cannot silently invalidate the evidence.
#[test]
fn generated_fixtures_match_committed_hashes() {
    let checksums = evidence_root().join("fixtures.sha256");
    let Ok(committed) = std::fs::read_to_string(&checksums) else {
        // Evidence has not been generated in this checkout yet.
        return;
    };
    let expected = parse_checksums(&committed);

    let root = temp_root();
    let records = fixtures::write_reference_fixtures(root.path()).expect("fixture tree");
    let actual: BTreeMap<String, String> = records
        .iter()
        .map(|record| {
            (
                format!("fixtures/{}", record.relative_path),
                record.sha256.clone(),
            )
        })
        .collect();

    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>(),
        "committed fixture list does not match the generator"
    );
    for (path, sha256) in &expected {
        assert_eq!(
            actual.get(path),
            Some(sha256),
            "fixture {path} changed; regenerate the reference evidence"
        );
    }
}

fn parse_checksums(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let (sha256, path) = line
                .split_once("  ")
                .expect("sha256sum line holds two fields");
            (path.to_owned(), sha256.to_owned())
        })
        .collect()
}

/// Every generated PDF must carry a correct cross-reference table: the
/// `startxref` offset points at the `xref` keyword and every in-use entry's
/// offset points at its own object header.
#[test]
fn generated_pdfs_have_conformant_xref_tables() {
    let pdfs: Vec<String> = fixtures::reference_fixtures()
        .into_iter()
        .filter(|file| file.relative_path.ends_with(".pdf"))
        .map(|file| file.relative_path)
        .collect();
    assert!(!pdfs.is_empty(), "the fixture set must contain PDFs");

    for file in fixtures::reference_fixtures() {
        if !file.relative_path.ends_with(".pdf") {
            continue;
        }
        let defects = pdf_xref_defects(&file.bytes);
        assert!(
            defects.is_empty(),
            "{} has an unusable cross-reference table: {defects:?}",
            file.relative_path
        );
    }
}

/// The legacy `sample.pdf` regression fixture is known to have incorrect xref
/// offsets; this test proves the checker above discriminates that defect.
#[test]
fn legacy_sample_pdf_fails_the_xref_check() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../crates/shosai-core/tests/fixtures/sample.pdf");
    let bytes = std::fs::read(&path).expect("sample.pdf");
    let defects = pdf_xref_defects(&bytes);
    assert!(
        !defects.is_empty(),
        "sample.pdf is documented as having bad xref offsets, but the checker accepted it"
    );
}

/// Minimal structural PDF cross-reference checker used by the tests above.
fn pdf_xref_defects(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes);
    let mut defects = Vec::new();
    let Some(startxref) = text.rfind("startxref") else {
        defects.push("missing startxref".to_owned());
        return defects;
    };
    let tail = text[startxref + "startxref".len()..].trim_start();
    let Some(offset_text) = tail.lines().next() else {
        defects.push("startxref has no offset".to_owned());
        return defects;
    };
    let Ok(offset) = offset_text.trim().parse::<usize>() else {
        defects.push(format!("startxref offset {offset_text:?} is not a number"));
        return defects;
    };
    if offset >= bytes.len() {
        defects.push(format!(
            "startxref offset {offset} is past the end of the file"
        ));
        return defects;
    }
    if !text[offset..].starts_with("xref") {
        defects.push(format!(
            "startxref offset {offset} does not point at `xref`"
        ));
        return defects;
    }
    let mut lines = text[offset..].lines();
    lines.next();
    let Some(header) = lines.next() else {
        defects.push("xref section has no subsection header".to_owned());
        return defects;
    };
    let mut parts = header.split_whitespace();
    let first_id: u32 = parts
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let count: u32 = match parts.next().and_then(|value| value.parse().ok()) {
        Some(count) => count,
        None => {
            defects.push(format!("xref subsection header {header:?} has no count"));
            return defects;
        }
    };
    for entry in 0..count {
        let id = first_id + entry;
        let Some(line) = lines.next() else {
            defects.push(format!("xref is missing the entry for object {id}"));
            return defects;
        };
        let mut fields = line.split_whitespace();
        let Some(kind) = fields.next_back() else {
            defects.push(format!("xref entry {id} is empty: {line:?}"));
            continue;
        };
        if kind != "n" {
            // The free-list head and any free entries carry no object header.
            continue;
        }
        let entry_offset: usize = match fields.next().and_then(|value| value.parse().ok()) {
            Some(offset) => offset,
            None => {
                defects.push(format!("xref entry {id} has no offset: {line:?}"));
                continue;
            }
        };
        let header = format!("{id} 0 obj");
        if entry_offset >= bytes.len() || !text[entry_offset..].starts_with(&header) {
            defects.push(format!(
                "xref entry {id} points at {entry_offset}, which is not `{header}`"
            ));
        }
    }
    defects
}

/// The generated EPUBs and CBZs must keep the structure the importer and the
/// capture states depend on: a stored `mimetype` first, the OPF metadata the
/// seed expects, a `cover-image` item exactly when the book has a cover, and a
/// `ComicInfo.xml` for comics.
#[test]
fn generated_books_keep_their_metadata_contract() {
    let files = fixtures::reference_fixtures();
    let find = |path: &str| -> Vec<u8> {
        files
            .iter()
            .find(|file| file.relative_path == path)
            .unwrap_or_else(|| panic!("fixture {path} exists"))
            .bytes
            .clone()
    };

    for path in [
        "library/featured/quiet-cartographer.epub",
        "library/featured/mizu-no-kioku.epub",
        "library/featured/workshop-proceedings.epub",
    ] {
        let archive = epub_entries(&find(path));
        assert_eq!(
            archive.first().map(|(name, _)| name.as_str()),
            Some("mimetype"),
            "{path}: the mimetype entry must come first"
        );
        let opf = archive
            .iter()
            .find(|(name, _)| name.ends_with(".opf"))
            .map(|(_, body)| body.clone())
            .unwrap_or_else(|| panic!("{path} has an OPF"));
        let document = roxmltree::Document::parse(&opf).expect("OPF parses");
        let title = text_of(&document, "title");
        let creator = text_of(&document, "creator");
        let language = text_of(&document, "language");
        assert!(!title.is_empty(), "{path}: OPF title");
        assert!(!language.is_empty(), "{path}: OPF language");
        match path {
            "library/featured/quiet-cartographer.epub" => {
                assert_eq!(title, "The Quiet Cartographer");
                assert_eq!(creator, "Amara Okonkwo");
                assert_eq!(language, "en");
            }
            "library/featured/mizu-no-kioku.epub" => {
                assert_eq!(title, "水の記憶、砂の記録");
                assert_eq!(creator, "佐藤 健一");
                assert_eq!(language, "ja");
            }
            "library/featured/workshop-proceedings.epub" => {
                assert!(
                    !opf.contains("cover-image") && !opf.contains("images/cover.png"),
                    "the no-cover fixture must not declare a cover"
                );
            }
            _ => {}
        }
        if path != "library/featured/workshop-proceedings.epub" {
            assert!(
                opf.contains("properties=\"cover-image\""),
                "{path} must declare `properties=\"cover-image\"`"
            );
            assert!(
                archive
                    .iter()
                    .any(|(name, _)| name == "OEBPS/images/cover.png"),
                "{path} must contain its cover image"
            );
        }
        // Every content document must agree with the OPF language: a Japanese
        // book whose chapters claim `xml:lang="en"` renders with the wrong
        // hyphenation, font selection and narration rules. `roxmltree` refuses
        // documents that carry a DTD, so the declared language is read from the
        // document's own `xml:lang` attributes.
        for (name, body) in &archive {
            if !name.ends_with(".xhtml") {
                continue;
            }
            let text = body.as_str();
            let declared: Vec<&str> = text
                .match_indices("xml:lang=\"")
                .map(|(index, prefix)| {
                    text[index + prefix.len()..]
                        .split('"')
                        .next()
                        .unwrap_or_default()
                })
                .collect();
            assert_eq!(
                declared,
                vec![language.as_str()],
                "{path}: {name} must declare exactly the OPF language"
            );
        }
    }

    let cbz = epub_entries(&find("library/featured/comet-courier.cbz"));
    let comic_info = cbz
        .iter()
        .find(|(name, _)| name == "ComicInfo.xml")
        .map(|(_, body)| body.clone())
        .expect("comic fixture carries ComicInfo.xml");
    assert!(comic_info.contains("<Title>Comet Courier, Issue 01</Title>"));
    assert!(
        cbz.iter().any(|(name, _)| name == "__MACOSX/.DS_Store"),
        "the macOS junk entry stays in the fixture so the reader keeps filtering it"
    );
}

/// Archive entries in archive order, which is what the EPUB `mimetype` rule and
/// the reader's cover lookup depend on.
fn epub_entries(bytes: &[u8]) -> Vec<(String, String)> {
    let mut archive =
        zip::ZipArchive::new(std::io::Cursor::new(bytes.to_vec())).expect("fixture archive");
    let mut entries = Vec::new();
    for index in 0..archive.len() {
        let mut file = archive.by_index(index).expect("archive entry");
        let name = file.name().to_owned();
        let mut body = Vec::new();
        file.read_to_end(&mut body).expect("archive entry body");
        entries.push((name, String::from_utf8_lossy(&body).into_owned()));
    }
    entries
}

fn text_of(document: &roxmltree::Document<'_>, tag: &str) -> String {
    document
        .descendants()
        .find(|node| node.has_tag_name(tag))
        .and_then(|node| node.text())
        .unwrap_or_default()
        .to_owned()
}

/// Every fixture the seed imports must exist in the generated tree, and the
/// seed order must be the order the library orders books by.
#[test]
fn seed_references_only_generated_fixtures() {
    let generated: Vec<String> = fixtures::reference_fixtures()
        .into_iter()
        .map(|file| file.relative_path)
        .collect();
    let seed = fixtures::library_seed();
    assert_eq!(seed.len(), 46, "14 featured + 32 filler books");
    let mut seen = BTreeMap::new();
    for book in &seed {
        assert!(
            seen.insert(book.file, ()).is_none(),
            "{} is seeded twice",
            book.file
        );
        if let Some(relative) = book.file.strip_prefix("repo:") {
            assert!(
                fixtures::REUSED_FIXTURES
                    .iter()
                    .any(|fixture| fixture.path == relative),
                "{relative} is a reused fixture without a provenance record"
            );
            continue;
        }
        assert!(
            generated.iter().any(|path| path == book.file),
            "{} is seeded but not generated",
            book.file
        );
        assert!(
            !book.date_added.is_empty(),
            "{} needs a fixed date_added",
            book.file
        );
    }
    let continue_reading: Vec<&SeedBook> = seed
        .iter()
        .filter(|book| book.last_read.is_some())
        .collect();
    assert_eq!(
        continue_reading.len(),
        1,
        "exactly one continue-reading seed book"
    );
    assert_eq!(
        continue_reading[0].file,
        "library/featured/quiet-cartographer.epub"
    );
}

/// A real seed run: import the fixtures into a disposable store and check the
/// metadata, the visible order and the paging boundary the captures rely on.
#[tokio::test]
async fn seeded_library_order_and_metadata_are_deterministic() {
    let fixtures_root = temp_root();
    fixtures::write_reference_fixtures(fixtures_root.path()).expect("fixture tree");
    let first = temp_root();
    let seeded = seed::seed_library(first.path(), fixtures_root.path())
        .await
        .expect("seed the reference library");

    assert_eq!(seeded.books.len(), 46);
    let continue_reading = seeded
        .continue_reading()
        .expect("one continue-reading book");
    assert_eq!(continue_reading.title, "The Quiet Cartographer");
    assert_eq!(
        continue_reading.last_read.as_deref(),
        Some("2026-02-14 09:30:00")
    );
    assert!((continue_reading.progress - 0.42).abs() < f64::EPSILON);

    // The visible order is `last_read DESC NULLS LAST, date_added DESC, id DESC`.
    let mut expected = seeded.books.clone();
    expected.sort_by(|left, right| {
        right
            .last_read
            .is_some()
            .cmp(&left.last_read.is_some())
            .then_with(|| right.date_added.cmp(&left.date_added))
            .then_with(|| right.id.cmp(&left.id))
    });
    let page = seeded
        .library
        .page(None, None, 40, 0)
        .await
        .expect("library page");
    let visible: Vec<String> = page.books.iter().map(|book| book.title.clone()).collect();
    let expected_visible: Vec<String> = expected
        .iter()
        .take(40)
        .map(|book| book.title.clone())
        .collect();
    assert_eq!(visible, expected_visible);
    assert!(page.has_more, "46 books must not fit in one 40-book page");

    // Metadata the capture states show.
    let quiet = page
        .books
        .iter()
        .find(|book| book.title == "The Quiet Cartographer")
        .expect("continue-reading book on the first page");
    assert_eq!(quiet.author.as_deref(), Some("Amara Okonkwo"));
    assert_eq!(quiet.format, shosai_core::library::BookFormat::Epub);
    assert!(quiet.cover.is_some(), "the seeded cover blob is present");
    let no_cover = page
        .books
        .iter()
        .find(|book| book.title == "Shosai Conformance: conformance")
        .expect("the reused conformance book is seeded and visible");
    assert!(no_cover.cover.is_none(), "it has no cover image");
    assert_eq!(
        no_cover.content_hash.as_deref(),
        Some("2f9687c08a59b36f7a27e8ae6a0e15bee672485a338bbd914caf48f2d5e4908a"),
        "the reused conformance fixture keeps its documented hash"
    );

    // A second seed from the same fixtures must produce identical rows.
    let second = temp_root();
    let repeated = seed::seed_library(second.path(), fixtures_root.path())
        .await
        .expect("seed a second reference library");
    assert_eq!(
        seeded.books, repeated.books,
        "two seed runs must produce identical rows"
    );
}

/// The capture table must be self-consistent: unique ids, known families, rows
/// that exist in the matrix mapping, and no fabricated Iced counterparts for
/// Flutter-only rows.
#[test]
fn capture_table_is_consistent() {
    let scenarios = scenarios::scenarios();
    assert!(!scenarios.is_empty());

    let mut ids = BTreeMap::new();
    for scenario in &scenarios {
        assert!(
            ids.insert(scenario.id, scenario.family).is_none(),
            "duplicate capture id {}",
            scenario.id
        );
        assert!(
            super::manifest::PACKAGE_1B_FAMILIES.contains(&scenario.family),
            "{} uses a family outside package 1B: {}",
            scenario.id,
            scenario.family
        );
        assert!(
            !scenario.rows.is_empty(),
            "{} must name the matrix rows it covers",
            scenario.id
        );
        assert!(
            scenario.client.0 > 0.0 && scenario.client.1 > 0.0,
            "{} needs a client size",
            scenario.id
        );
        assert!(scenario.dpr >= 1.0, "{} needs a DPR", scenario.id);
    }

    let (captured, from_manifest, pending) = scenarios::matrix_rows();
    let captured: Vec<&str> = captured;
    for scenario in &scenarios {
        for row in scenario.rows {
            assert!(
                captured.contains(row),
                "{} lists row {row}, which is not in the captured mapping",
                scenario.id
            );
        }
    }
    let from_table: Vec<&str> = captured
        .iter()
        .copied()
        .filter(|row| scenarios.iter().any(|scenario| scenario.rows.contains(row)))
        .collect();
    assert_eq!(
        from_table, captured,
        "the captured mapping lists rows no capture references"
    );
    for row in &captured {
        assert!(
            !row.starts_with("RD-") && !row.starts_with("FM-"),
            "{row} is reader evidence owned by 1C and must not be claimed by 1B"
        );
    }
    assert_eq!(
        from_manifest,
        vec!["XA-10"],
        "the provenance row must stay manifest-satisfied, not faked as a capture"
    );
    for (row, reason) in &pending {
        assert!(
            !captured.contains(row) && !from_manifest.contains(row),
            "{row} is both covered and pending"
        );
        assert!(!reason.is_empty(), "{row} needs a reason and owner");
    }
    assert!(
        pending.iter().any(|(row, _)| *row == "LB-10"),
        "the Flutter-only 200% text row must stay explicitly pending"
    );

    // Every base the table uses must be reachable in the runner, and every
    // capture must record a derivation and a known state id.
    for scenario in &scenarios {
        assert!(
            !scenario.derivation().is_empty(),
            "{} needs a state derivation",
            scenario.id
        );
        assert!(
            ["library", "library+import-dialog", "settings"]
                .contains(&scenarios::state_id(scenario)),
            "{} has an unknown state id",
            scenario.id
        );
        assert!(
            matches!(
                scenario.base,
                Base::Seeded
                    | Base::Import
                    | Base::ImportRemoval
                    | Base::ImportCompleted
                    | Base::Empty
                    | Base::NoStore
            ),
            "{} uses a base the runner cannot build",
            scenario.id
        );
    }

    // A pixel alias is a claim about two captures, so it must name two existing
    // captures with a reason. `reject_duplicate_pixels` checks the claim itself
    // against the rendered pixels in both directions.
    for (left, right, reason) in scenarios::PIXEL_ALIASES {
        assert_ne!(left, right, "a capture cannot alias itself");
        for id in [left, right] {
            assert!(
                scenarios.iter().any(|scenario| scenario.id == id),
                "the pixel alias names {id}, which is not a capture"
            );
        }
        assert!(
            !reason.trim().is_empty(),
            "{left}/{right} must record why the two captures share pixels"
        );
    }
}

/// The captures must read their fixtures from the disposable data root.
///
/// The application renders real absolute paths (discovery-failure rows, the
/// managed-library location), so a capture taken from a checkout path embeds a
/// machine-specific path and stops reproducing: this is a regression guard.
#[test]
fn capture_fixtures_live_in_the_disposable_data_root() {
    let fixtures_root = super::runner::fixtures_root();
    assert!(
        fixtures_root.starts_with(super::runner::data_root()),
        "captures must read fixtures from {}",
        super::runner::data_root().display()
    );
    assert!(
        !fixtures_root.starts_with(super::runner::output_root()),
        "fixtures must not be read from the evidence directory"
    );
    assert_eq!(
        super::runner::evidence_fixtures_root(),
        super::runner::output_root().join("fixtures"),
        "the committed copy still lives in the evidence directory"
    );
}

/// The mirrored fixture tree must be a byte copy of what the captures rendered
/// from, including the dangling symlink, and a tampered copy must not verify.
#[test]
fn mirrored_fixture_tree_matches_the_generated_tree() {
    let source = temp_root();
    let destination = temp_root();
    let records = fixtures::write_reference_fixtures(source.path()).expect("fixture tree");

    let mirrored = fixtures::mirror_reference_fixtures(
        source.path(),
        &destination.path().join("fixtures"),
        &records,
    )
    .expect("mirror fixture tree");
    assert_eq!(mirrored, records, "the mirror must copy every fixture byte");
    assert!(
        fixtures::broken_symlinks_available(&destination.path().join("fixtures")),
        "the mirror must recreate the dangling symlink"
    );
    assert_eq!(
        fixtures::read_reference_fixtures(&destination.path().join("fixtures")).expect("read"),
        records,
        "the mirrored tree must hash to the generated records"
    );

    // A tampered file, and an extra orphaned file, must both be detected.
    let first = &records[0];
    let path = destination
        .path()
        .join("fixtures")
        .join(&first.relative_path);
    std::fs::write(&path, b"tampered").expect("tamper");
    assert_ne!(
        fixtures::read_reference_fixtures(&destination.path().join("fixtures")).expect("read"),
        records,
        "an edited fixture file must not verify"
    );
    std::fs::write(
        &path,
        std::fs::read(source.path().join(&first.relative_path)).expect("original"),
    )
    .expect("restore");
    std::fs::write(destination.path().join("fixtures/orphan.bin"), b"orphan").expect("orphan");
    assert_ne!(
        fixtures::read_reference_fixtures(&destination.path().join("fixtures")).expect("read"),
        records,
        "an extra file in the committed tree must not verify"
    );
}

/// Pixel aliases are checked in both directions: an undeclared duplicate and a
/// declared pair that stopped being identical must both fail the run.
#[test]
fn pixel_alias_rules_reject_both_kinds_of_mismatch() {
    let entry = |id: &str, sha256: &str| super::manifest::CaptureEntry {
        id: id.to_owned(),
        family: "1B-LIB-WIDE".to_owned(),
        state: "library".to_owned(),
        image: format!("captures/{id}.png"),
        sha256: sha256.to_owned(),
        bytes: 1,
        client_width: 1280.0,
        client_height: 800.0,
        image_width: 1280,
        image_height: 800,
        dpr: 1.0,
        locale: "EN".to_owned(),
        fixture: "fixture".to_owned(),
        state_derivation: "derivation".to_owned(),
        settings: Vec::new(),
        rows: vec!["LB-01".to_owned()],
        notes: Vec::new(),
    };

    let declared = scenarios::PIXEL_ALIASES[0];
    // The declared pair, plus an unrelated capture that happens to share bytes
    // with the declared left capture: the undeclared duplicate must fail.
    let undeclared = super::runner::reject_duplicate_pixels(&[
        entry(declared.0, "1"),
        entry(declared.1, "1"),
        entry("lib-wide-w1280-en", "1"),
    ])
    .expect_err("an undeclared identical pair must fail");
    let message = undeclared.to_string();
    assert!(
        message.contains("lib-wide-w1280-en"),
        "the failure must name the undeclared capture: {message}"
    );

    // A declared pair with different pixels must fail too, because the recorded
    // reason no longer describes the evidence.
    let stale =
        super::runner::reject_duplicate_pixels(&[entry(declared.0, "1"), entry(declared.1, "2")])
            .expect_err("a stale alias must fail");
    assert!(
        stale.to_string().contains(declared.0),
        "the stale-alias failure must name the pair: {stale}"
    );

    // The declared pair with identical pixels is accepted.
    super::runner::reject_duplicate_pixels(&[entry(declared.0, "1"), entry(declared.1, "1")])
        .expect("the declared pair is allowed to share pixels");
}

/// Stale evidence files must be pruned: a renamed capture must not leave an
/// orphaned PNG in the committed set.
#[test]
fn stale_evidence_files_are_pruned() {
    let output = temp_root();
    let captures = output.path().join("captures");
    std::fs::create_dir_all(&captures).expect("captures dir");
    std::fs::write(captures.join("kept.png"), b"kept").expect("kept");
    std::fs::write(captures.join("orphan.png"), b"orphan").expect("orphan");

    let mut entry = super::manifest::CaptureEntry {
        id: "kept".to_owned(),
        family: "1B-LIB-WIDE".to_owned(),
        state: "library".to_owned(),
        image: "captures/kept.png".to_owned(),
        sha256: "1".to_owned(),
        bytes: 4,
        client_width: 1280.0,
        client_height: 800.0,
        image_width: 1280,
        image_height: 800,
        dpr: 1.0,
        locale: "EN".to_owned(),
        fixture: "fixture".to_owned(),
        state_derivation: "derivation".to_owned(),
        settings: Vec::new(),
        rows: vec!["LB-01".to_owned()],
        notes: Vec::new(),
    };
    super::runner::prune_stale_evidence(output.path(), &[entry.clone()])
        .expect("prune stale evidence");
    assert!(
        captures.join("kept.png").exists(),
        "live captures must stay"
    );
    assert!(
        !captures.join("orphan.png").exists(),
        "an orphaned capture must be pruned"
    );

    // A capture that is no longer in the set must be pruned too: listing a
    // different image makes `kept.png` stale, exactly as a rename does.
    entry.id = "other".to_owned();
    entry.image = "captures/other.png".to_owned();
    super::runner::prune_stale_evidence(output.path(), &[entry.clone()])
        .expect("prune stale evidence");
    assert!(
        !captures.join("kept.png").exists(),
        "a dropped capture must be pruned"
    );
}

// ---------------------------------------------------------------------------
// Committed-evidence validation
// ---------------------------------------------------------------------------

/// The manifest the current code produces, without rendering.
///
/// Built once per test binary: it writes a fixture tree and seeds a disposable
/// library exactly like the capture run does, so an ordinary `cargo test` can
/// check the committed evidence without rendering 56 images. The per-capture
/// `sha256`/`bytes` fields are empty, because nothing was rendered; the
/// validator checks those against the committed files instead.
///
/// Only synchronous tests may call this, because it builds its own runtime.
fn expected_manifest() -> &'static super::manifest::Manifest {
    use std::sync::OnceLock;

    static EXPECTED: OnceLock<Result<super::manifest::Manifest, String>> = OnceLock::new();
    EXPECTED
        .get_or_init(|| {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|error| format!("test runtime: {error}"))?;
            runtime.block_on(async {
                let fixtures_root =
                    tempfile::tempdir().map_err(|error| format!("fixture temp dir: {error}"))?;
                let library_root =
                    tempfile::tempdir().map_err(|error| format!("library temp dir: {error}"))?;
                fixtures::write_reference_fixtures(fixtures_root.path())
                    .map_err(|error| format!("write the fixture tree: {error}"))?;
                let seeded = seed::seed_library(library_root.path(), fixtures_root.path())
                    .await
                    .map_err(|error| format!("seed the disposable library: {error:#}"))?;
                super::runner::expected_manifest(fixtures_root.path(), &seeded)
                    .await
                    .map_err(|error| format!("build the expected manifest: {error:#}"))
            })
        })
        .as_ref()
        .unwrap_or_else(|error| panic!("build the expected manifest: {error}"))
}

/// The committed evidence must describe the code that is checked out.
///
/// This is the always-on half of `make reference-shots VERIFY=1`: it compares
/// the committed manifest with the manifest the current capture table, fixture
/// generator and seed produce, hashes the committed PNGs against the committed
/// hashes, and re-derives the checksum files, the README and the committed
/// fixture tree. It renders nothing, so it can run in every `cargo test`.
#[test]
fn committed_evidence_matches_current_code() {
    let root = evidence_root();
    assert!(
        root.is_dir(),
        "the committed evidence directory {} is missing",
        root.display()
    );
    super::evidence::validate(&root, expected_manifest(), false)
        .expect("the committed evidence must match the current code");
}

/// The committed manifest must still record the run metadata that is exempt
/// from comparison, so a reviewer can trace the evidence to a revision.
#[test]
fn committed_manifest_records_its_run_metadata() {
    let manifest: super::manifest::Manifest = serde_json::from_str(
        &std::fs::read_to_string(evidence_root().join("manifest.json"))
            .expect("committed manifest"),
    )
    .expect("manifest parses");
    for (field, value) in [
        ("capture_code_revision", &manifest.capture_code_revision),
        (
            "capture_code_revision_source",
            &manifest.capture_code_revision_source,
        ),
        ("capture_code_change_id", &manifest.capture_code_change_id),
        ("capture_code_bookmark", &manifest.capture_code_bookmark),
        ("command", &manifest.command),
        ("output_directory", &manifest.output_directory),
    ] {
        assert!(
            !value.trim().is_empty(),
            "the committed manifest must record {field}"
        );
    }
}

/// Copy the committed evidence directory to a disposable location.
fn copy_evidence(source: &Path, destination: &Path) {
    std::fs::create_dir_all(destination).expect("evidence copy root");
    for entry in std::fs::read_dir(source).expect("read the evidence") {
        let entry = entry.expect("evidence entry");
        let target = destination.join(entry.file_name());
        let file_type = entry.file_type().expect("evidence entry type");
        if file_type.is_symlink() {
            #[cfg(unix)]
            std::os::unix::fs::symlink(
                std::fs::read_link(entry.path()).expect("symlink target"),
                &target,
            )
            .expect("copy the symlink");
        } else if file_type.is_dir() {
            copy_evidence(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).expect("copy the file");
        }
    }
}

/// Mutate a disposable copy of the committed evidence and require the validator
/// to reject it with a problem naming `needle`.
///
/// The untouched copy is validated first, so a failure is caused by the
/// mutation and not by the copy.
fn tampered_evidence(mutate: impl FnOnce(&Path), needle: &str) {
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    let expected = expected_manifest();
    let clean = super::evidence::problems(copy.path(), expected, false)
        .expect("a copy of the committed evidence must be readable");
    assert!(
        clean.is_empty(),
        "the untouched copy must validate, otherwise the mutation proves nothing: {clean:?}"
    );

    mutate(copy.path());

    let problems = super::evidence::problems(copy.path(), expected, false)
        .expect("the evidence directory must still be readable");
    assert!(!problems.is_empty(), "the mutation must be rejected");
    assert!(
        problems.iter().any(|problem| problem.contains(needle)),
        "expected a problem mentioning {needle:?}, got {problems:?}"
    );
}

/// Edit the committed manifest of a disposable copy.
fn tamper_manifest(root: &Path, edit: impl FnOnce(&mut serde_json::Value)) {
    let path = root.join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).expect("manifest"))
            .expect("manifest parses");
    edit(&mut manifest);
    std::fs::write(
        &path,
        format!(
            "{}\n",
            serde_json::to_string_pretty(&manifest).expect("manifest serializes")
        ),
    )
    .expect("write the manifest");
}

#[test]
fn evidence_validator_rejects_a_missing_capture() {
    tampered_evidence(
        |root| {
            std::fs::remove_file(root.join("captures/lib-wide-w1280-en.png"))
                .expect("remove a capture");
        },
        "captures/lib-wide-w1280-en.png is listed by the manifest but not committed",
    );
}

#[test]
fn evidence_validator_rejects_a_tampered_capture() {
    tampered_evidence(
        |root| {
            let path = root.join("captures/lib-wide-w1280-en.png");
            let mut bytes = std::fs::read(&path).expect("read a capture");
            let last = bytes.len() - 1;
            bytes[last] ^= 0xFF;
            std::fs::write(&path, bytes).expect("write a capture");
        },
        "does not hash to the manifest entry",
    );
}

#[test]
fn evidence_validator_rejects_an_orphaned_capture() {
    tampered_evidence(
        |root| {
            std::fs::write(root.join("captures/orphan.png"), b"not a capture").expect("orphan");
        },
        "captures/orphan.png is committed but not listed by the manifest",
    );
}

#[test]
fn evidence_validator_rejects_a_tampered_fixture() {
    tampered_evidence(
        |root| {
            let path = root.join("fixtures/library/featured/quiet-cartographer.epub");
            let mut bytes = std::fs::read(&path).expect("read a fixture");
            bytes.push(b'x');
            std::fs::write(&path, bytes).expect("write a fixture");
        },
        "is not the generated tree",
    );
}

#[test]
fn evidence_validator_rejects_an_orphaned_fixture() {
    tampered_evidence(
        |root| {
            std::fs::write(root.join("fixtures/orphan.bin"), b"orphan").expect("orphan");
        },
        "is not the generated tree",
    );
}

#[test]
fn evidence_validator_rejects_a_stale_readme() {
    tampered_evidence(
        |root| {
            std::fs::write(root.join("README.md"), b"# stale\n").expect("stale README");
        },
        "README.md is stale",
    );
}

#[test]
fn evidence_validator_rejects_a_stale_capture_checksum_file() {
    tampered_evidence(
        |root| {
            let path = root.join("captures.sha256");
            let text = std::fs::read_to_string(&path).expect("checksums");
            let mut lines: Vec<String> = text.lines().map(str::to_owned).collect();
            lines[0] = format!("{}  {}", "0".repeat(64), "captures/lib-wide-w1280-en.png");
            std::fs::write(&path, lines.join("\n") + "\n").expect("stale checksums");
        },
        "captures.sha256 does not match the manifest",
    );
}

#[test]
fn evidence_validator_rejects_a_stale_fixture_checksum_file() {
    tampered_evidence(
        |root| {
            std::fs::remove_file(root.join("fixtures.sha256"))
                .expect("remove the fixture checksums");
        },
        "fixtures.sha256 cannot be read",
    );
}

#[test]
fn evidence_validator_rejects_a_changed_capture_row() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["captures"][0]["rows"][0] = serde_json::json!("LB-99");
            });
        },
        "describes a different state or size than the capture table",
    );
}

#[test]
fn evidence_validator_rejects_reordered_captures() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                let captures = manifest["captures"].as_array_mut().expect("captures");
                captures.swap(0, 1);
            });
        },
        "changed id",
    );
}

#[test]
fn evidence_validator_rejects_a_stale_pixel_alias() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["pixel_aliases"][0]["reason"] = serde_json::json!("no longer why");
            });
        },
        "pixel_aliases changed",
    );
}

#[test]
fn evidence_validator_rejects_a_changed_seeded_inventory() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["seeded_library"]["books"][0]["title"] =
                    serde_json::json!("A Different Book");
            });
        },
        "seeded_library changed",
    );
}

#[test]
fn evidence_validator_rejects_a_changed_seeded_order() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                let books = manifest["seeded_library"]["books"]
                    .as_array_mut()
                    .expect("books");
                books.swap(0, 1);
            });
        },
        "seeded_library changed",
    );
}

#[test]
fn evidence_validator_rejects_a_changed_matrix_row() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["matrix"]["pending"][0]["row"] = serde_json::json!("XX-00");
            });
        },
        "matrix changed",
    );
}

#[test]
fn evidence_validator_rejects_a_changed_limitation() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["limitations"][0] = serde_json::json!("nothing to see here");
            });
        },
        "limitations changed",
    );
}

#[test]
fn evidence_validator_rejects_a_changed_font_hash() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["fonts"][0]["sha256"] = serde_json::json!("0".repeat(64));
            });
        },
        "fonts changed",
    );
}

/// A missing manifest is a hard error, not a silent skip.
#[test]
fn evidence_validator_rejects_a_missing_manifest() {
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    std::fs::remove_file(copy.path().join("manifest.json")).expect("remove the manifest");
    let error = super::evidence::problems(copy.path(), expected_manifest(), false)
        .expect_err("a missing manifest must fail");
    assert!(
        error.to_string().contains("manifest"),
        "the failure must name the manifest: {error}"
    );
}

/// With a fresh render in hand, a changed pixel hash must fail even when the
/// committed file still matches the committed manifest.
#[test]
fn evidence_validator_rejects_a_capture_this_render_changed() {
    let mut fresh = expected_manifest().clone();
    fresh.captures[0].sha256 = "0".repeat(64);
    let problems = super::evidence::problems(&evidence_root(), &fresh, true)
        .expect("the committed evidence is readable");
    assert!(
        problems
            .iter()
            .any(|problem| problem.contains("re-rendered to a different image")),
        "a fresh render that differs must be reported: {problems:?}"
    );
}

/// The non-rendering comparison must not invent pixel differences.
#[test]
fn evidence_validator_ignores_pixels_without_a_render() {
    let fresh = expected_manifest();
    let problems = super::evidence::problems(&evidence_root(), fresh, false)
        .expect("the committed evidence is readable");
    assert!(
        problems.is_empty(),
        "an unrendered comparison must pass on the committed evidence: {problems:?}"
    );
}

// ---------------------------------------------------------------------------
// Disposable root ownership
// ---------------------------------------------------------------------------

/// A directory this tool does not own is never cleared.
#[test]
fn unowned_disposable_root_is_not_cleared() {
    let root = temp_root();
    let output = temp_root();
    let sentinel = root.path().join("state.db");
    std::fs::write(&sentinel, b"a real library").expect("sentinel file");

    let error =
        super::runner::DisposableRoot::prepare(root.path(), &output.path().join("evidence"))
            .expect_err("an unowned root must be refused");
    assert!(
        error
            .to_string()
            .contains("not a reference-shots disposable root"),
        "the failure must explain the ownership rule: {error}"
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("the sentinel must survive"),
        b"a real library"
    );
    assert!(
        !root.path().join(super::runner::ROOT_LOCK_FILE).exists(),
        "a refused run must not leave a lock behind"
    );
}

/// An owned root is cleared, locked against a second run, and removed unless it
/// is kept.
#[test]
fn owned_disposable_root_is_cleared_and_locked() {
    let root = temp_root();
    let output = temp_root();
    let evidence = output.path().join("evidence");

    let guard = super::runner::DisposableRoot::prepare(root.path(), &evidence)
        .expect("the first run takes the root");
    assert!(
        root.path().join(super::runner::ROOT_MARKER_FILE).is_file(),
        "the marker is written"
    );
    std::fs::write(root.path().join("leftover.db"), b"stale").expect("leftover");

    let error = super::runner::DisposableRoot::prepare(root.path(), &evidence)
        .expect_err("a second run must not share the root");
    assert!(
        error.to_string().contains(super::runner::ROOT_LOCK_FILE),
        "the failure must name the lock: {error}"
    );

    guard.finish(true).expect("release the root and keep it");
    assert!(
        root.path().join(super::runner::ROOT_MARKER_FILE).is_file(),
        "a kept root keeps its marker"
    );
    assert!(
        !root.path().join(super::runner::ROOT_LOCK_FILE).exists(),
        "a released run removes its lock"
    );

    let guard = super::runner::DisposableRoot::prepare(root.path(), &evidence)
        .expect("a later run can take the released root");
    assert!(
        !root.path().join("leftover.db").exists(),
        "an owned root is cleared between runs"
    );
    guard.finish(false).expect("release and remove the root");
    assert!(
        !root.path().exists(),
        "the root is removed when it is not kept"
    );
}

/// The root may not overlap the evidence directory or be a path this tool must
/// never delete.
#[test]
fn root_configuration_rejects_overlap_and_protected_paths() {
    let base = temp_root();
    let output = base.path().join("evidence");
    let root = base.path().join("data");

    assert!(
        super::runner::validate_root_configuration(&output.join("data"), &output).is_err(),
        "a root inside the evidence directory must be refused"
    );
    assert!(
        super::runner::validate_root_configuration(base.path(), &output).is_err(),
        "an evidence directory inside the root must be refused"
    );
    assert!(
        super::runner::validate_root_configuration(&root, &output).is_ok(),
        "a separate disposable root is allowed"
    );
    assert!(
        super::runner::validate_root_configuration(Path::new("/"), &output).is_err(),
        "the filesystem root must be refused"
    );
    assert!(
        super::runner::validate_root_configuration(&super::runner::repository_root(), &output)
            .is_err(),
        "the repository must be refused"
    );
    assert!(
        super::runner::validate_root_configuration(Path::new("relative/root"), &output).is_err(),
        "a relative root must be refused"
    );
    if let Some(home) = std::env::var_os("HOME") {
        assert!(
            super::runner::validate_root_configuration(Path::new(&home), &output).is_err(),
            "the home directory must be refused"
        );
    }
    if let Ok(paths) = shosai_core::reading_state::ApplicationDataPaths::desktop_default() {
        assert!(
            super::runner::validate_root_configuration(&paths.data_directory, &output).is_err(),
            "the real application data directory must be refused"
        );
    }
}

// ---------------------------------------------------------------------------
// Capture process state
// ---------------------------------------------------------------------------

/// The capture process must not inherit the host language: the no-store
/// captures resolve `LanguagePreference::System` immediately.
#[test]
fn system_locale_pin_is_english() {
    super::runner::pin_system_locale();
    assert_eq!(
        std::env::var("LANGUAGE").as_deref(),
        Ok("en-US"),
        "the pin must set the highest-priority locale variable"
    );
}

/// The no-store language assertion must discriminate the two interfaces.
#[test]
fn english_and_japanese_interfaces_are_distinguishable() {
    use crate::i18n::{I18n, LanguagePreference};

    assert!(
        scenarios::interface_resolved_english(&I18n::new(LanguagePreference::English)),
        "the English interface must satisfy the assertion"
    );
    assert!(
        !scenarios::interface_resolved_english(&I18n::new(LanguagePreference::Japanese)),
        "the Japanese interface must not satisfy the English assertion"
    );
}

/// A queued preference write is fenced before the next capture resets the
/// shared store.
#[tokio::test]
async fn capture_writes_are_fenced_before_the_next_capture_resets_the_store() {
    use crate::i18n::LanguagePreference;
    use shosai_core::state_writer::StateWriterMessage;

    let directory = temp_root();
    let store = seed::open_store(directory.path())
        .await
        .expect("disposable store");
    seed::reset_capture_preferences(&store)
        .await
        .expect("baseline");

    let mut harness = Harness::new(super::runner::fresh_state());
    let initialized = seed::capture_initialized_state(store.clone())
        .await
        .expect("capture init");
    harness
        .dispatch(Message::Initialized(Ok(initialized)))
        .await;

    // Queue a preference write through the writer, the way a capture's
    // messages do, without awaiting persistence.
    let saves = harness
        .state
        .reading_state_saves
        .clone()
        .expect("a capture store has a live writer");
    saves
        .send(StateWriterMessage::Preference(
            super::super::LANGUAGE_PREFERENCE_KEY.to_owned(),
            "ja".to_owned(),
        ))
        .expect("the writer accepts writes before the fence");

    super::runner::fence_capture_writes(&mut harness)
        .await
        .expect("the fence drains and stops the writer");

    assert_eq!(
        store
            .get_pref_async(super::super::LANGUAGE_PREFERENCE_KEY)
            .await
            .expect("read the preference")
            .as_deref(),
        Some("ja"),
        "the fence must drain every write queued before it"
    );
    assert!(
        saves
            .send(StateWriterMessage::Preference(
                super::super::LANGUAGE_PREFERENCE_KEY.to_owned(),
                "ja".to_owned(),
            ))
            .is_err(),
        "a fenced writer must refuse further writes, so none can land after the next reset"
    );

    // The next capture starts from the baseline, not from the fenced capture.
    seed::reset_capture_preferences(&store)
        .await
        .expect("next baseline");
    let mut next = Harness::new(super::runner::fresh_state());
    let initialized = seed::capture_initialized_state(store.clone())
        .await
        .expect("next capture init");
    next.dispatch(Message::Initialized(Ok(initialized))).await;
    assert_eq!(
        next.state.i18n.preference(),
        LanguagePreference::English,
        "the next capture must read the baseline language"
    );
    assert_eq!(
        next.state.add_book_behavior,
        AddBookBehavior::Ask,
        "the next capture must read the baseline add behavior"
    );
}

/// The harness copy of `boot`'s preference parsing produces the documented
/// capture baseline.
#[tokio::test]
async fn capture_startup_parsing_matches_the_application_defaults() {
    use crate::i18n::LanguagePreference;
    use crate::pdf::ZoomMode;
    use crate::theme::ReaderTheme;
    use shosai_core::reader::ReadingMode;

    let directory = temp_root();
    let store = seed::open_store(directory.path())
        .await
        .expect("disposable store");
    seed::reset_capture_preferences(&store)
        .await
        .expect("baseline");

    let mut harness = Harness::new(super::runner::fresh_state());
    let initialized = seed::capture_initialized_state(store)
        .await
        .expect("capture init");
    harness
        .dispatch(Message::Initialized(Ok(initialized)))
        .await;

    assert_eq!(harness.state.i18n.preference(), LanguagePreference::English);
    assert_eq!(harness.state.add_book_behavior, AddBookBehavior::Ask);
    assert_eq!(
        harness.state.reader_defaults.reading_mode,
        ReadingMode::Paginated
    );
    assert_eq!(harness.state.reader_defaults.theme, ReaderTheme::Light);
    assert_eq!(harness.state.reader_defaults.epub_font_size, 16.0);
    assert_eq!(harness.state.reader_defaults.epub_line_spacing, 1.6);
    assert_eq!(harness.state.reader_defaults.pdf_zoom, ZoomMode::FitPage);
    assert!(
        harness.state.library.is_some(),
        "a seeded store produces a usable library"
    );
}

/// Persisted non-default preferences are read, and out-of-range values fall
/// back exactly like the application's startup parsing.
#[tokio::test]
async fn capture_startup_parsing_reads_persisted_preferences() {
    use crate::i18n::LanguagePreference;
    use crate::pdf::ZoomMode;
    use crate::theme::ReaderTheme;
    use shosai_core::reader::ReadingMode;

    let directory = temp_root();
    let store = seed::open_store(directory.path())
        .await
        .expect("disposable store");
    store
        .set_prefs_async(&[
            (super::super::LANGUAGE_PREFERENCE_KEY, "ja".to_owned()),
            (super::super::ADD_BOOK_BEHAVIOR_KEY, "copy".to_owned()),
            (
                super::super::DEFAULT_READING_MODE_KEY,
                "continuous".to_owned(),
            ),
            (super::super::DEFAULT_READER_THEME_KEY, "dark".to_owned()),
            (super::super::DEFAULT_EPUB_FONT_SIZE_KEY, "99".to_owned()),
            (
                super::super::DEFAULT_EPUB_LINE_SPACING_KEY,
                "2.0".to_owned(),
            ),
            (super::super::DEFAULT_PDF_ZOOM_KEY, "fit-width".to_owned()),
        ])
        .await
        .expect("persist preferences");

    let mut harness = Harness::new(super::runner::fresh_state());
    let initialized = seed::capture_initialized_state(store)
        .await
        .expect("capture init");
    harness
        .dispatch(Message::Initialized(Ok(initialized)))
        .await;

    assert_eq!(
        harness.state.i18n.preference(),
        LanguagePreference::Japanese
    );
    assert_eq!(harness.state.add_book_behavior, AddBookBehavior::Copy);
    assert_eq!(
        harness.state.reader_defaults.reading_mode,
        ReadingMode::Continuous
    );
    assert_eq!(harness.state.reader_defaults.theme, ReaderTheme::Dark);
    assert_eq!(
        harness.state.reader_defaults.epub_font_size, 16.0,
        "an out-of-range persisted font size must fall back"
    );
    assert_eq!(harness.state.reader_defaults.epub_line_spacing, 2.0);
    assert_eq!(harness.state.reader_defaults.pdf_zoom, ZoomMode::FitWidth);
}

/// The capture's window size and DPR must come from the production window
/// messages, not from writing the model fields.
#[test]
fn window_state_is_set_through_production_messages() {
    let scenario = scenarios::scenarios()
        .into_iter()
        .find(|scenario| scenario.dpr > 1.0 && scenario.client.0 > 1000.0)
        .expect("a wide DPR-2 capture");
    let mut harness = Harness::new(super::runner::fresh_state());
    assert!(
        !harness.state.window_geometry_dirty,
        "a fresh state has no pending geometry change"
    );
    let generation = harness.state.window_scale_generation;

    super::runner::apply_window(&scenario, &mut harness);

    assert_eq!(
        harness.state.window_size,
        iced::Size::new(scenario.client.0, scenario.client.1)
    );
    assert_eq!(harness.state.window_scale_factor, scenario.dpr);
    assert_eq!(
        harness.state.window_scale_generation,
        generation + 1,
        "the DPR change must run through `window::Event::Rescaled`"
    );
    assert!(
        harness.state.window_geometry_dirty,
        "the resize must run through `window::Event::Resized`"
    );
}

// ---------------------------------------------------------------------------
// Fixture symlinks
// ---------------------------------------------------------------------------

/// The dangling symlink fixture is relative, dangling, and identical in every
/// generated tree.
#[cfg(unix)]
#[test]
fn generated_symlink_fixture_is_relative_and_validated() {
    let first = temp_root();
    let second = temp_root();
    fixtures::write_reference_fixtures(first.path()).expect("first tree");
    fixtures::write_reference_fixtures(second.path()).expect("second tree");

    for root in [first.path(), second.path()] {
        let link = root.join(fixtures::BROKEN_SYMLINKS[0]);
        assert_eq!(
            std::fs::read_link(&link).expect("the declared fixture is a symlink"),
            Path::new(fixtures::BROKEN_SYMLINK_TARGET),
            "the link target must be relative and stable, not a checkout path"
        );
        assert!(
            std::fs::metadata(&link).is_err(),
            "the link must be dangling"
        );
        assert_eq!(
            fixtures::symlink_defects(root),
            Vec::<String>::new(),
            "a generated tree has no symlink defects"
        );
        assert!(fixtures::broken_symlinks_available(root));
    }
}

/// A wrong target, a live link and an unexpected link are all rejected.
#[cfg(unix)]
#[test]
fn symlink_validation_rejects_wrong_targets_and_live_links() {
    let root = temp_root();
    fixtures::write_reference_fixtures(root.path()).expect("tree");
    let link = root.path().join(fixtures::BROKEN_SYMLINKS[0]);

    // An absolute target: the previous implementation embedded the destination
    // path in the committed link, which this must reject.
    std::fs::remove_file(&link).expect("remove the generated link");
    std::os::unix::fs::symlink(link.with_file_name(fixtures::BROKEN_SYMLINK_TARGET), &link)
        .expect("absolute symlink");
    assert!(
        fixtures::symlink_defects(root.path())
            .iter()
            .any(|defect| defect.contains("symlink target is")),
        "an absolute target must be reported"
    );
    assert!(
        fixtures::read_reference_fixtures(root.path()).is_err(),
        "a tree with a wrong link target must not verify"
    );

    // A live link: the target exists, so the link is not a missing-file fixture.
    std::fs::remove_file(&link).expect("remove the link");
    let live_target = link
        .parent()
        .expect("the link has a parent")
        .join(fixtures::BROKEN_SYMLINK_TARGET);
    std::fs::write(&live_target, b"now it exists").expect("create the target");
    std::os::unix::fs::symlink(fixtures::BROKEN_SYMLINK_TARGET, &link).expect("live symlink");
    assert!(
        fixtures::symlink_defects(root.path())
            .iter()
            .any(|defect| defect.contains("not dangling")),
        "a live link must be reported"
    );

    // An unexpected link anywhere else in the tree.
    std::fs::remove_file(&link).expect("remove the link");
    std::fs::remove_file(&live_target).expect("remove the target");
    std::os::unix::fs::symlink("elsewhere", root.path().join("sources/unexpected.epub"))
        .expect("unexpected symlink");
    assert!(
        fixtures::symlink_defects(root.path())
            .iter()
            .any(|defect| defect.contains("unexpected symlink")),
        "an undeclared symlink must be reported"
    );
}
