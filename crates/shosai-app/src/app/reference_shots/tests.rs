//! Regression tests for the capture harness.
//!
//! These run in an ordinary `cargo test`: they do not render or write evidence,
//! but they do fail when the fixture generator, the seeded order, the capture
//! table or the committed evidence stops agreeing with the code.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use super::fixtures::{self, FixtureRecord, SeedBook};
use super::scenarios::{self, Base};
use super::seed;

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

/// The committed evidence must describe the current rendering code: hashes in
/// `manifest.json` and `captures.sha256` must match the committed PNGs, and the
/// recorded fixture hashes must match the generator.
#[test]
fn committed_evidence_matches_current_code() {
    let root = evidence_root();
    let manifest_path = root.join("manifest.json");
    let Ok(text) = std::fs::read_to_string(&manifest_path) else {
        return;
    };
    let manifest: serde_json::Value =
        serde_json::from_str(&text).expect("committed manifest is valid JSON");
    assert_eq!(
        manifest["pinned_design_base"],
        serde_json::json!(super::manifest::PINNED_DESIGN_BASE),
        "the manifest must pin the accepted design base"
    );
    for field in [
        "capture_code_revision",
        "capture_code_change_id",
        "capture_code_note",
        "command",
        "entry_point",
    ] {
        assert!(
            manifest[field]
                .as_str()
                .is_some_and(|value| !value.trim().is_empty()),
            "the manifest must record {field}"
        );
    }
    assert_eq!(
        manifest["capture_code_note"],
        serde_json::json!(super::runner::REVISION_NOTE),
        "the committed manifest must explain how its revision fields map to a commit"
    );

    let captures = manifest["captures"]
        .as_array()
        .expect("capture list")
        .clone();
    assert!(!captures.is_empty(), "the manifest must list captures");
    for capture in &captures {
        for field in [
            "id",
            "family",
            "state",
            "image",
            "sha256",
            "client_height",
            "image_width",
            "dpr",
            "locale",
            "fixture",
            "state_derivation",
        ] {
            assert!(
                !capture[field].is_null(),
                "capture {} is missing {field}",
                capture["id"]
            );
        }
        assert!(
            !capture["rows"].as_array().expect("rows").is_empty(),
            "capture {} lists no rows",
            capture["id"]
        );
        let image = capture["image"].as_str().expect("image path");
        let bytes = std::fs::read(root.join(image))
            .unwrap_or_else(|error| panic!("committed capture {image}: {error}"));
        assert_eq!(
            fixtures::sha256_hex(&bytes),
            capture["sha256"].as_str().expect("sha256"),
            "{image} does not match its manifest hash"
        );
    }

    let checksums_path = root.join("captures.sha256");
    let checksums = parse_checksums(&std::fs::read_to_string(&checksums_path).expect("checksums"));
    assert_eq!(
        checksums.len(),
        captures.len(),
        "captures.sha256 must list every capture"
    );
    for capture in &captures {
        let image = capture["image"].as_str().expect("image path");
        assert_eq!(
            checksums.get(image),
            Some(&capture["sha256"].as_str().expect("sha256").to_owned()),
            "captures.sha256 disagrees with manifest.json for {image}"
        );
    }

    let fixture_hashes = manifest["fixtures"]["files"].as_array().expect("fixtures");
    let generated = fixtures::reference_fixtures();
    assert_eq!(
        fixture_hashes.len(),
        generated.len(),
        "the manifest must record every generated fixture"
    );
    for file in &generated {
        let recorded = fixture_hashes
            .iter()
            .find(|record| record["relative_path"] == serde_json::json!(file.relative_path))
            .unwrap_or_else(|| panic!("{} is missing from the manifest", file.relative_path));
        assert_eq!(
            recorded["sha256"],
            serde_json::json!(fixtures::sha256_hex(&file.bytes)),
            "fixture {} changed; regenerate the evidence",
            file.relative_path
        );
    }

    for reused in manifest["fixtures"]["reused"]
        .as_array()
        .expect("reused fixtures")
    {
        assert_eq!(
            reused["sha256"], reused["verified_sha256"],
            "reused fixture {} no longer matches its documented hash",
            reused["path"]
        );
    }

    // The committed provenance must record the declared pixel aliases, so a
    // reviewer can see why two images are identical without reading the code.
    let aliases = manifest["pixel_aliases"]
        .as_array()
        .expect("pixel aliases are recorded");
    assert_eq!(
        aliases.len(),
        scenarios::PIXEL_ALIASES.len(),
        "the manifest and the capture table disagree about pixel aliases"
    );
    for (left, right, reason) in scenarios::PIXEL_ALIASES {
        let recorded = aliases
            .iter()
            .find(|alias| {
                alias["left"] == serde_json::json!(left)
                    && alias["right"] == serde_json::json!(right)
            })
            .unwrap_or_else(|| panic!("{left}/{right} is missing from the manifest"));
        assert_eq!(
            recorded["reason"],
            serde_json::json!(reason),
            "{left}/{right} must keep its recorded reason"
        );
    }

    // The committed README is generated from the manifest; a stale one would
    // describe evidence that no longer exists.
    let readme = std::fs::read_to_string(root.join("README.md")).expect("committed README");
    assert!(
        readme.contains("## Captures that intentionally share pixels"),
        "the committed README must document the pixel aliases"
    );
}
