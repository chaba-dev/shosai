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
use super::package::Package;
use super::scenarios::{self, Base};
use super::seed;
use crate::app::{AddBookBehavior, Message};

fn temp_root() -> tempfile::TempDir {
    tempfile::tempdir().expect("temp dir")
}

/// The committed evidence directory of a package.
fn evidence_root_for(package: Package) -> PathBuf {
    package
        .output_root()
        .expect("resolve the committed evidence directory")
}

fn evidence_root() -> PathBuf {
    evidence_root_for(Package::OneB)
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

/// Every generated archive pins the ZIP "version made by" system byte.
///
/// The `zip` crate derives that byte from the host it was compiled for
/// (`System::Dos` on Windows, `System::Unix` elsewhere), so without the pin the
/// same fixture is a different byte sequence per platform and the committed
/// hashes only describe Unix. The assertions below are the byte-level rule those
/// hashes depend on, checked in the raw bytes (every central directory entry)
/// and again through the reader API.
#[test]
fn generated_archives_declare_a_pinned_unix_system() {
    let mut archives = 0usize;
    for file in fixtures::reference_fixtures() {
        let archive = file.relative_path.ends_with(".epub") || file.relative_path.ends_with(".cbz");
        if !archive {
            continue;
        }
        archives += 1;

        let mut offset = 0usize;
        let mut entries = 0usize;
        while let Some(found) = file.bytes[offset..]
            .windows(4)
            .position(|window| window == b"PK\x01\x02")
        {
            let entry = offset + found;
            assert_eq!(
                file.bytes[entry + 5],
                3,
                "{} entry {entries} must declare the Unix system byte",
                file.relative_path
            );
            entries += 1;
            offset = entry + 4;
        }
        assert!(
            entries > 0,
            "{} has no central directory entries",
            file.relative_path
        );

        let mut reader = zip::ZipArchive::new(std::io::Cursor::new(file.bytes.clone()))
            .expect("fixture archive");
        for index in 0..reader.len() {
            let entry = reader.by_index(index).expect("archive entry");
            assert_eq!(
                zip::HasZipMetadata::get_metadata(&entry).system,
                zip::System::Unix,
                "{} entry {} must be written for Unix",
                file.relative_path,
                entry.name()
            );
        }
    }
    assert!(
        archives >= 20,
        "expected the generated EPUB and CBZ fixtures, checked {archives}"
    );
}

/// A socket (or any other special file) inside the committed fixture tree is not
/// a fixture: the reader must refuse it rather than walk past it.
#[cfg(unix)]
#[test]
fn read_reference_fixtures_rejects_special_files() {
    let root = temp_root();
    let records = fixtures::write_reference_fixtures(root.path()).expect("fixture tree");
    assert!(!records.is_empty());
    fixtures::read_reference_fixtures(root.path()).expect("the generated tree is readable");

    let socket = root.path().join("unexpected.socket");
    let _listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind a socket");

    let error = fixtures::read_reference_fixtures(root.path())
        .expect_err("a socket in the fixture tree must be refused");
    assert!(
        error.to_string().contains("unexpected.socket"),
        "the refusal must name the entry: {error}"
    );
    assert!(socket.exists(), "a refused read must leave the entry alone");
}

/// The generated fixture tree must match the committed `fixtures.sha256` so an
/// accidental fixture change cannot silently invalidate the evidence.
#[test]
fn generated_fixtures_match_committed_hashes() {
    let checksums = evidence_root().join("fixtures.sha256");
    // The committed evidence tree is part of this repository: an unreadable
    // checksum file is a failure, not "the evidence has not been generated yet"
    // (the other evidence tests read `manifest.json` and the capture trees
    // unconditionally as well). Failing here is what makes the test able to
    // catch a missing or unreadable `fixtures.sha256`.
    let committed = std::fs::read_to_string(&checksums)
        .unwrap_or_else(|error| panic!("read {}: {error}", checksums.display()));
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

/// Every generated PDF must be font-free.
///
/// The capture entry point pins Iced's font discovery, but PDFium resolves fonts
/// for unembedded PDF text itself by scanning the host font directories and does
/// not read `FONTCONFIG_FILE`. A text run in a fixture PDF would therefore make a
/// rendered cover depend on the machine, which is exactly what the fixture set
/// must not do.
#[test]
fn generated_pdfs_draw_no_text() {
    let mut checked = 0;
    for file in fixtures::reference_fixtures() {
        if !file.relative_path.ends_with(".pdf") {
            continue;
        }
        checked += 1;
        let problems = fixtures::pdf_font_free_problems(&file.bytes);
        assert!(
            problems.is_empty(),
            "{} would let PDFium substitute a host font: {problems:?}",
            file.relative_path
        );
        assert!(
            file.bytes.windows(4).any(|window| window == b" re "),
            "{} must still draw its artwork",
            file.relative_path
        );
    }
    assert!(checked > 0, "the fixture set must contain PDFs");
}

/// The font-free checker discriminates a text-bearing PDF.
#[test]
fn pdf_font_free_check_rejects_text() {
    let with_text = b"%PDF-1.4\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\n\
        BT /F1 12 Tf 72 720 Td (Page 1) Tj ET\n";
    let problems = fixtures::pdf_font_free_problems(with_text);
    assert!(
        problems.len() >= 2,
        "a text-bearing PDF must be rejected for each reason: {problems:?}"
    );
    let artwork_only = fixtures::reference_fixtures()
        .into_iter()
        .find(|file| file.relative_path.ends_with(".pdf"))
        .expect("a PDF fixture");
    assert!(
        fixtures::pdf_font_free_problems(&artwork_only.bytes).is_empty(),
        "the generator's own artwork must pass the checker"
    );
}

/// The PDFium identity follows the documented search over controlled inputs and
/// hashes the bytes of the library it found.
///
/// The discovery inputs are passed in, so this is a positive test with a known
/// file rather than a check that only ever returns early on a machine without
/// PDFium.
#[test]
fn pdfium_identity_names_the_library_a_search_finds() {
    use super::runner::{PdfiumSearch, pdfium_identity_from};

    let base = temp_root();
    let directory = base.path().join("libs");
    std::fs::create_dir_all(&directory).expect("library directory");
    let bytes = b"a known byte sequence standing in for libpdfium";
    std::fs::write(directory.join("libpdfium.so"), bytes).expect("library");

    let scanned = PdfiumSearch {
        mapped: None,
        configured: None,
        directories: vec![directory.clone()],
    };
    assert_eq!(
        pdfium_identity_from(&scanned),
        Some(format!(
            "{} (sha256 {})",
            directory.join("libpdfium.so").display(),
            super::fixtures::sha256_hex(bytes)
        )),
        "the scanned library must be named with the hash of its bytes"
    );

    // A configured path wins over the scanned directories, which is the order
    // the production loader resolves in.
    let configured = base.path().join("configured-pdfium.so");
    std::fs::write(&configured, b"configured bytes").expect("configured library");
    let configured_search = PdfiumSearch {
        mapped: None,
        configured: Some(configured.clone()),
        directories: vec![directory.clone()],
    };
    assert_eq!(
        pdfium_identity_from(&configured_search),
        Some(format!(
            "{} (sha256 {})",
            configured.display(),
            super::fixtures::sha256_hex(b"configured bytes")
        ))
    );

    // A mapped object wins over everything else: it is the library the process
    // is actually running with.
    let mapped = base.path().join("mapped-pdfium.so");
    std::fs::write(&mapped, b"mapped bytes").expect("mapped library");
    let mapped_search = PdfiumSearch {
        mapped: Some(mapped.clone()),
        configured: Some(configured.clone()),
        directories: vec![directory.clone()],
    };
    assert_eq!(
        pdfium_identity_from(&mapped_search),
        Some(format!(
            "{} (sha256 {})",
            mapped.display(),
            super::fixtures::sha256_hex(b"mapped bytes")
        )),
        "the mapped library takes precedence over the configured path and the scan"
    );

    // A configured path that is not a file falls through to the scan.
    let missing = PdfiumSearch {
        mapped: None,
        configured: Some(base.path().join("not-a-library.so")),
        directories: vec![directory.clone()],
    };
    assert_eq!(
        pdfium_identity_from(&missing),
        Some(format!(
            "{} (sha256 {})",
            directory.join("libpdfium.so").display(),
            super::fixtures::sha256_hex(bytes)
        )),
        "a configured path that is not a file must not shadow the scan"
    );

    // A Nix-style versioned name is found by the directory scan. The assertion
    // pins the *documented sort*, not the order the filesystem enumerates: a
    // scan that stopped sorting would report whichever name it happened to see
    // first, which is exactly the machine-dependent result the sort exists to
    // prevent.
    let versioned = base.path().join("versioned");
    std::fs::create_dir_all(&versioned).expect("versioned directory");
    std::fs::write(versioned.join("libpdfium.so.9999"), b"newer").expect("newer library");
    std::fs::write(versioned.join("libpdfium.so.8888"), b"middle").expect("middle library");
    std::fs::write(versioned.join("libpdfium.so.7643"), b"versioned").expect("versioned library");
    let versioned_search = PdfiumSearch {
        mapped: None,
        configured: None,
        directories: vec![versioned.clone()],
    };
    assert_eq!(
        pdfium_identity_from(&versioned_search),
        Some(format!(
            "{} (sha256 {})",
            versioned.join("libpdfium.so.7643").display(),
            super::fixtures::sha256_hex(b"versioned")
        )),
        "the sorted first candidate is the one reported"
    );

    // Nothing to find is a legitimate result, not a failure: the run records
    // `unknown (no library named pdfium is mapped)` instead of guessing.
    let empty = PdfiumSearch {
        mapped: None,
        configured: None,
        directories: vec![base.path().join("does-not-exist")],
    };
    assert_eq!(pdfium_identity_from(&empty), None);
}

/// Whenever this machine has a discoverable PDFium, the recorded identity must
/// name that library and carry the hash of its bytes.
#[test]
fn pdfium_identity_on_this_machine_is_a_real_library() {
    let Some(identity) = super::runner::pdfium_identity() else {
        return;
    };
    let (path, tail) = identity
        .rsplit_once(" (")
        .unwrap_or_else(|| panic!("the identity must name its library: {identity}"));
    let path = PathBuf::from(path);
    assert!(
        path.is_file(),
        "the identity must name a file that exists: {identity}"
    );
    let tail = tail
        .strip_suffix(')')
        .unwrap_or_else(|| panic!("the identity's hash must be parenthesized: {identity}"));
    if tail == "unreadable" {
        return;
    }
    let bytes = std::fs::read(&path).expect("the recorded library is readable");
    assert_eq!(
        tail,
        format!("sha256 {}", super::fixtures::sha256_hex(&bytes)),
        "the recorded hash must be the hash of the recorded library"
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
    let data_root = Package::OneB.data_root();
    let fixtures_root = super::runner::fixtures_root(Package::OneB);
    let output = Package::OneB
        .output_root()
        .expect("resolve the evidence directory");
    assert!(
        fixtures_root.starts_with(&data_root),
        "captures must read fixtures from {}",
        data_root.display()
    );
    assert!(
        !fixtures_root.starts_with(&output),
        "fixtures must not be read from the evidence directory"
    );
    assert_eq!(
        super::runner::evidence_fixtures_path(&output),
        output.join("fixtures"),
        "the committed copy lives in the resolved evidence directory the run holds"
    );
}

/// The mirrored fixture tree must be a byte copy of what the captures rendered
/// from, including the dangling symlink on platforms that can create it, and a
/// tampered copy must not verify.
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
    // On a platform that cannot create symlinks the generator records the gap
    // (`broken_symlinks_available`), and the mirror must behave the same way
    // rather than inventing a link or reporting one the source tree lacks.
    assert_eq!(
        fixtures::broken_symlinks_available(&destination.path().join("fixtures")),
        fixtures::broken_symlinks_available(source.path()),
        "the mirror must reproduce the source tree's dangling-symlink state"
    );
    #[cfg(unix)]
    assert!(
        fixtures::broken_symlinks_available(&destination.path().join("fixtures")),
        "on a platform with symlink support the mirror must recreate the dangling symlink"
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
        reader: None,
        notes: Vec::new(),
    };

    let declared = scenarios::PIXEL_ALIASES[0];
    // The declared pair, plus an unrelated capture that happens to share bytes
    // with the declared left capture: the undeclared duplicate must fail.
    let undeclared = super::runner::reject_duplicate_pixels(
        &[
            entry(declared.0, "1"),
            entry(declared.1, "1"),
            entry("lib-wide-w1280-en", "1"),
        ],
        &scenarios::PIXEL_ALIASES,
    )
    .expect_err("an undeclared identical pair must fail");
    let message = undeclared.to_string();
    assert!(
        message.contains("lib-wide-w1280-en"),
        "the failure must name the undeclared capture: {message}"
    );

    // A declared pair with different pixels must fail too, because the recorded
    // reason no longer describes the evidence.
    let stale = super::runner::reject_duplicate_pixels(
        &[entry(declared.0, "1"), entry(declared.1, "2")],
        &scenarios::PIXEL_ALIASES,
    )
    .expect_err("a stale alias must fail");
    assert!(
        stale.to_string().contains(declared.0),
        "the stale-alias failure must name the pair: {stale}"
    );

    // The declared pair with identical pixels is accepted.
    super::runner::reject_duplicate_pixels(
        &[entry(declared.0, "1"), entry(declared.1, "1")],
        &scenarios::PIXEL_ALIASES,
    )
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
        reader: None,
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
//
// The committed evidence is a Linux artifact. Its fixture tree carries a
// dangling-symlink discovery-failure fixture, so the manifest records
// `broken_symlinks_available: true` and the fixture tree cannot be reproduced on
// a platform whose checkouts cannot hold a symlink (a Windows checkout
// materializes the link as a regular file). Everything below therefore reads or
// copies the committed evidence directory and is gated to platforms that can
// carry it (Linux and macOS). The validator it exercises is not platform
// specific: the portable half of the contract — fixture bytes and hashes, the
// capture table, matrix mapping, root ownership, the environment contract and
// the manifest's run metadata — runs in every `cargo test`, and `make
// reference-shots VERIFY=1` re-renders the evidence on Linux.

/// The manifest the current code produces, without rendering.
///
/// Built once per test binary: it writes a fixture tree and seeds a disposable
/// library exactly like the capture run does, so an ordinary `cargo test` can
/// check the committed evidence without rendering 56 images. The per-capture
/// `sha256`/`bytes` fields are empty, because nothing was rendered; the
/// validator checks those against the committed files instead.
///
/// Only synchronous tests may call this, because it builds its own runtime.
#[cfg(unix)]
fn expected_manifest_for(package: Package) -> &'static super::manifest::Manifest {
    use std::sync::OnceLock;

    static ONE_B: OnceLock<Result<super::manifest::Manifest, String>> = OnceLock::new();
    static ONE_C: OnceLock<Result<super::manifest::Manifest, String>> = OnceLock::new();
    let expected = match package {
        Package::OneB => &ONE_B,
        Package::OneC => &ONE_C,
    };
    expected
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
                super::runner::expected_manifest(
                    package,
                    fixtures_root.path(),
                    &seeded,
                    &manifest_revision(),
                )
                .await
                .map_err(|error| format!("build the expected manifest: {error:#}"))
            })
        })
        .as_ref()
        .unwrap_or_else(|error| panic!("build the expected manifest: {error}"))
}

/// The unrendered expectation of the accepted package 1B evidence.
#[cfg(unix)]
fn expected_manifest() -> &'static super::manifest::Manifest {
    expected_manifest_for(Package::OneB)
}

/// The provenance must be exact, so a missing probe or a placeholder value stops
/// the run instead of publishing evidence that only claims to be reproducible.
#[test]
fn capture_revision_fails_closed_without_an_exact_revision() {
    use super::runner::capture_revision_from;

    const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
    let refused: Vec<(&str, Option<&str>, Option<&str>)> = vec![
        ("no Jujutsu working copy and no override", None, None),
        ("an empty override", None, Some("")),
        ("a placeholder override", None, Some("unknown")),
        (
            "the placeholder text a fallback used to record",
            None,
            Some("unknown (set SHOSAI_REFERENCE_SHOTS_REVISION)"),
        ),
        ("a non-hexadecimal override", None, Some("not-a-commit-id")),
        ("an override that is too short", None, Some("abc123")),
        ("a probe that printed no commit id", Some("  "), None),
        (
            "a probe whose commit id is not hexadecimal",
            Some("not a commit id"),
            None,
        ),
        ("a probe without a change id", Some(COMMIT), None),
    ];
    for (case, jj, explicit) in refused {
        let error = capture_revision_from(
            jj.map(str::to_owned),
            explicit.map(str::to_owned),
            None,
            None,
        )
        .err()
        .unwrap_or_else(|| panic!("{case} must be refused"));
        assert!(!error.to_string().is_empty(), "{case}: {error}");
    }

    let from_jj = capture_revision_from(
        Some(format!("{COMMIT} kkmpptxzrspx feat/reference-shots-1b")),
        None,
        None,
        None,
    )
    .expect("a complete probe is the exact revision");
    assert_eq!(from_jj.revision, COMMIT);
    assert_eq!(from_jj.change_id, "kkmpptxzrspx");
    assert_eq!(from_jj.bookmark, "feat/reference-shots-1b");
    assert_eq!(from_jj.source, "jj @ working-copy commit");

    let no_bookmark =
        capture_revision_from(Some(format!("{COMMIT} kkmpptxzrspx")), None, None, None)
            .expect("a probe without a bookmark still names the revision");
    assert_eq!(no_bookmark.bookmark, "none");

    let overridden =
        capture_revision_from(None, Some(COMMIT.to_owned()), None, None).expect("an override");
    assert_eq!(overridden.revision, COMMIT);
    assert_eq!(overridden.source, "SHOSAI_REFERENCE_SHOTS_REVISION");
    assert_eq!(overridden.change_id, "unknown");
    for label in ["", "  ", "unknown", "UNKNOWN"] {
        let error =
            capture_revision_from(None, Some(COMMIT.to_owned()), Some(label.to_owned()), None)
                .err()
                .unwrap_or_else(|| panic!("the change id {label:?} must be refused"));
        assert!(!error.to_string().is_empty(), "{error}");
    }
}

/// The manifest must record a usable revision even though run metadata is exempt
/// from the freshness comparison.
#[cfg(unix)]
#[test]
fn evidence_validator_rejects_placeholder_provenance() {
    tampered_evidence(
        |root| {
            tamper_manifest(root, |manifest| {
                manifest["capture_code_revision"] = serde_json::Value::String(
                    "unknown (set SHOSAI_REFERENCE_SHOTS_REVISION)".to_owned(),
                );
            });
        },
        "capture_code_revision",
    );
}

/// Provenance is accepted exactly for the two sources the writer produces.
///
/// A well-formed override (an asserted commit id whose descriptive labels are
/// honestly `unknown`) must validate with a synchronized README, while a source
/// tag the writer never emits must not buy that exemption, and a blank label is
/// never acceptable. The README is re-rendered for every case, so a rejection
/// comes from provenance validation rather than from a stale README.
#[cfg(unix)]
#[test]
fn provenance_accepts_only_the_supported_sources() {
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    let expected = expected_manifest();

    rewrite_manifest(copy.path(), |manifest| {
        manifest.capture_code_revision_source =
            super::manifest::OVERRIDE_REVISION_SOURCE.to_owned();
        manifest.capture_code_change_id = "unknown".to_owned();
        manifest.capture_code_bookmark = "unknown".to_owned();
    });
    let problems = super::evidence::problems(copy.path(), expected, false)
        .expect("the copied evidence must stay readable");
    assert!(
        problems.is_empty(),
        "an override manifest with unknown labels and a synchronized README must validate: \
         {problems:?}"
    );

    rewrite_manifest(copy.path(), |manifest| {
        manifest.capture_code_revision_source =
            format!("{}-invalid", super::manifest::OVERRIDE_REVISION_SOURCE);
        manifest.capture_code_change_id = String::new();
        manifest.capture_code_bookmark = String::new();
    });
    let problems = super::evidence::problems(copy.path(), expected, false)
        .expect("the copied evidence must stay readable");
    assert!(
        problems.iter().any(|problem| {
            problem.contains("capture_code_revision_source")
                && problem.contains("supported sources")
        }),
        "a source tag the writer never emits must be refused: {problems:?}"
    );
    for field in ["capture_code_change_id", "capture_code_bookmark"] {
        assert!(
            problems
                .iter()
                .any(|problem| problem.contains(field) && problem.contains("blank")),
            "{field} must not be blank even when the source looks like an override: {problems:?}"
        );
    }

    // A source the writer never emits cannot be smuggled in by padding, and the
    // unknown sentinel is only the exact literal the writer records.
    rewrite_manifest(copy.path(), |manifest| {
        manifest.capture_code_revision_source =
            format!(" {} ", super::manifest::OVERRIDE_REVISION_SOURCE);
        manifest.capture_code_change_id = "UNKNOWN".to_owned();
        manifest.capture_code_bookmark = " unknown ".to_owned();
    });
    let problems = super::evidence::problems(copy.path(), expected, false)
        .expect("the copied evidence must stay readable");
    assert!(
        problems.iter().any(|problem| {
            problem.contains("capture_code_revision_source")
                && problem.contains("supported sources")
        }),
        "a padded source tag is not the exact source the writer emits: {problems:?}"
    );
    for (field, value) in [
        ("capture_code_change_id", "\"UNKNOWN\""),
        ("capture_code_bookmark", "\" unknown \""),
    ] {
        assert!(
            problems
                .iter()
                .any(|problem| { problem.contains(field) && problem.contains("sentinel exactly") }),
            "{field} must be refused as {value} rather than normalized to the sentinel: \
             {problems:?}"
        );
    }
}

/// A symlinked metadata file is refused, not followed.
#[cfg(unix)]
#[test]
fn evidence_validator_rejects_a_symlinked_metadata_file() {
    tampered_evidence(
        |root| {
            let path = root.join("fixtures.sha256");
            let target = root.join("captures.sha256");
            std::fs::remove_file(&path).expect("remove the checksum file");
            std::os::unix::fs::symlink(&target, &path).expect("symlink the checksum file");
        },
        "fixtures.sha256 is a symlink",
    );
}

/// A capture entry that is a symlink is refused: the evidence is regular files.
#[cfg(unix)]
#[test]
fn evidence_validator_rejects_a_symlinked_capture() {
    tampered_evidence(
        |root| {
            let path = root.join("captures/lib-wide-w1280-en.png");
            let target = root.join("captures/lib-wide-w1280-ja.png");
            std::fs::remove_file(&path).expect("remove the capture");
            std::os::unix::fs::symlink(&target, &path).expect("symlink the capture");
        },
        "captures/lib-wide-w1280-en.png is not a regular file",
    );
}

/// A metadata destination that is a symlink is refused before the run writes:
/// following it would leave the manifest inside the disposable root that the
/// same run deletes.
#[cfg(unix)]
#[test]
fn preflight_refuses_a_metadata_symlink_into_the_data_root() {
    let base = temp_root();
    let output = base.path().join("evidence");
    std::fs::create_dir_all(&output).expect("evidence");
    let data = base.path().join("data");
    std::fs::create_dir_all(&data).expect("data root");
    let target = data.join("manifest.json");
    std::os::unix::fs::symlink(&target, output.join("manifest.json")).expect("symlink");

    let error = super::runner::preflight_evidence_destinations(&output, &[])
        .expect_err("a symlinked manifest destination must be refused");
    assert!(
        error.to_string().contains("symlink"),
        "the refusal must name the symlink: {error}"
    );
    assert!(
        !target.exists(),
        "a refused run must not create the link target"
    );
    assert!(
        output.join("manifest.json").is_symlink(),
        "a refused run must leave the offending link alone"
    );
}

/// A captures directory that is a symlink is refused: the capture writes and the
/// stale-evidence prune would otherwise modify an unrelated directory.
#[cfg(unix)]
#[test]
fn preflight_refuses_a_captures_directory_symlink() {
    let base = temp_root();
    let output = base.path().join("evidence");
    std::fs::create_dir_all(&output).expect("evidence");
    let external = base.path().join("unrelated");
    std::fs::create_dir_all(&external).expect("unrelated directory");
    let sentinel = external.join("keep.txt");
    std::fs::write(&sentinel, b"not evidence").expect("sentinel");
    std::os::unix::fs::symlink(&external, output.join("captures")).expect("symlink");

    let images = vec!["captures/lib-wide-w1280-en.png".to_owned()];
    let error = super::runner::preflight_evidence_destinations(&output, &images)
        .expect_err("a symlinked captures directory must be refused");
    assert!(error.to_string().contains("symlink"), "{error}");
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        b"not evidence",
        "the unrelated directory must be untouched"
    );
    assert!(
        !external.join("lib-wide-w1280-en.png").exists(),
        "a refused run must not write a capture into the link target"
    );
}

/// A single capture image that is a symlink is refused: the write would replace
/// the link's target instead of the evidence.
#[cfg(unix)]
#[test]
fn preflight_refuses_a_capture_image_symlink() {
    let base = temp_root();
    let output = base.path().join("evidence");
    let captures = output.join("captures");
    std::fs::create_dir_all(&captures).expect("captures");
    let external = base.path().join("unrelated.png");
    std::fs::write(&external, b"unrelated bytes").expect("unrelated file");
    std::os::unix::fs::symlink(&external, captures.join("lib-wide-w1280-en.png")).expect("symlink");

    let images = vec!["captures/lib-wide-w1280-en.png".to_owned()];
    let error = super::runner::preflight_evidence_destinations(&output, &images)
        .expect_err("a symlinked capture image must be refused");
    assert!(error.to_string().contains("symlink"), "{error}");
    assert_eq!(
        std::fs::read(&external).expect("unrelated file"),
        b"unrelated bytes"
    );
}

/// A metadata destination that is hard-linked to an unrelated file is refused
/// before the run writes: truncating it would modify that file.
#[cfg(unix)]
#[test]
fn preflight_refuses_a_hard_linked_metadata_file() {
    let base = temp_root();
    let output = base.path().join("evidence");
    std::fs::create_dir_all(&output).expect("evidence");
    let sentinel = base.path().join("keep.txt");
    std::fs::write(&sentinel, b"unrelated bytes").expect("sentinel");
    std::fs::hard_link(&sentinel, output.join("manifest.json")).expect("hard link");

    let error = super::runner::preflight_evidence_destinations(&output, &[])
        .expect_err("a hard-linked manifest destination must be refused");
    assert!(
        error.to_string().contains("hard-linked"),
        "the refusal must name the hard link: {error}"
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        b"unrelated bytes",
        "a refused run must leave the unrelated name alone"
    );
}

/// A capture image that is hard-linked to an unrelated file is refused too: the
/// evidence must be the only name of its files.
#[cfg(unix)]
#[test]
fn preflight_refuses_a_hard_linked_capture_image() {
    let base = temp_root();
    let output = base.path().join("evidence");
    let captures = output.join("captures");
    std::fs::create_dir_all(&captures).expect("captures");
    let sentinel = base.path().join("unrelated.png");
    std::fs::write(&sentinel, b"unrelated bytes").expect("sentinel");
    std::fs::hard_link(&sentinel, captures.join("lib-wide-w1280-en.png")).expect("hard link");

    let images = vec!["captures/lib-wide-w1280-en.png".to_owned()];
    let error = super::runner::preflight_evidence_destinations(&output, &images)
        .expect_err("a hard-linked capture destination must be refused");
    assert!(error.to_string().contains("hard-linked"), "{error}");
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        b"unrelated bytes"
    );
}

/// The write path re-checks its destination, so a hard link created after the
/// preflight cannot be written through either.
#[cfg(unix)]
#[test]
fn the_evidence_write_refuses_a_hard_linked_destination() {
    let base = temp_root();
    let sentinel = base.path().join("keep.txt");
    std::fs::write(&sentinel, b"unrelated bytes").expect("sentinel");
    let destination = base.path().join("capture.png");
    std::fs::hard_link(&sentinel, &destination).expect("hard link");

    let error = super::runner::write_evidence_file(&destination, b"a capture")
        .expect_err("writing through a hard link must be refused");
    assert!(error.to_string().contains("hard-linked"), "{error}");
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        b"unrelated bytes",
        "the unrelated name must keep its bytes"
    );
}

/// A committed capture that is hard-linked to another name is rejected: the
/// evidence must be the only name of its files, which is how a run writes them.
#[cfg(unix)]
#[test]
fn evidence_validator_rejects_a_hard_linked_capture() {
    // The sentinel lives in its own test-owned directory: the evidence copy the
    // helper hands to the mutation is a temporary directory of its own, so
    // `root.parent()` would be the shared temporary-directory parent.
    let sentinel_root = temp_root();
    let sentinel = sentinel_root.path().join("keep.txt");
    std::fs::write(&sentinel, b"unrelated bytes").expect("sentinel");
    let sentinel_for_mutation = sentinel.clone();
    tampered_evidence(
        move |root| {
            let link = root.join("captures/lib-wide-w1280-en.png");
            std::fs::remove_file(&link).expect("remove the capture");
            std::fs::hard_link(&sentinel_for_mutation, &link).expect("hard link the capture");
        },
        "hard-linked",
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        b"unrelated bytes",
        "validation must not modify the unrelated name"
    );
}

/// A committed metadata file that is hard-linked to another name is rejected as
/// well: a capture run would have written through it.
#[cfg(unix)]
#[test]
fn evidence_validator_rejects_a_hard_linked_metadata_file() {
    let sentinel_root = temp_root();
    let sentinel = sentinel_root.path().join("keep.txt");
    std::fs::write(&sentinel, b"unrelated bytes").expect("sentinel");
    let sentinel_for_mutation = sentinel.clone();
    tampered_evidence(
        move |root| {
            let link = root.join("fixtures.sha256");
            std::fs::remove_file(&link).expect("remove the checksum file");
            std::fs::hard_link(&sentinel_for_mutation, &link).expect("hard link the checksum file");
        },
        "fixtures.sha256 is hard-linked",
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        b"unrelated bytes",
        "validation must not modify the unrelated name"
    );
}

/// The reader refuses to *open* a hard-linked metadata file: the diagnosis is
/// not a licence to read a file that another name owns.
///
/// The rejection message is asserted directly, and the sentinel's bytes are
/// unchanged, so a regression that kept reading (and hashing or parsing) the
/// linked file would fail here rather than only being reported afterwards.
#[cfg(unix)]
#[test]
fn evidence_validator_does_not_open_a_hard_linked_metadata_file() {
    let sentinel_root = temp_root();
    let sentinel = sentinel_root.path().join("keep.txt");
    let bytes = b"unrelated bytes that must not be read as a checksum file";
    std::fs::write(&sentinel, bytes).expect("sentinel");

    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    let link = copy.path().join("fixtures.sha256");
    std::fs::remove_file(&link).expect("remove the checksum file");
    std::fs::hard_link(&sentinel, &link).expect("hard link the checksum file");

    let path = copy.path().to_path_buf();
    let problems =
        run_bounded(move || super::evidence::problems(&path, expected_manifest(), false))
            .expect("the readable manifest must let the rest of the validation run");
    assert!(
        problems
            .iter()
            .any(|problem| problem.contains("fixtures.sha256") && problem.contains("not opened")),
        "the reader must refuse to open the hard-linked file: {problems:?}"
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("sentinel"),
        bytes,
        "the unrelated name must keep its bytes"
    );
}

/// A FIFO among the evidence entries is refused, not opened.
///
/// Opening a FIFO with no writer blocks, so the checks run on a worker thread
/// with a bound: a regression fails the test instead of hanging the suite.
#[cfg(unix)]
#[test]
fn evidence_validator_refuses_a_fifo_without_opening_it() {
    let fifo = |path: &Path| {
        std::fs::remove_file(path).expect("remove the entry");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(path)
                .status()
                .expect("run mkfifo")
                .success(),
            "mkfifo {} failed",
            path.display()
        );
    };

    // The manifest itself: the validator cannot compare anything, so it fails.
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    fifo(&copy.path().join("manifest.json"));
    let path = copy.path().to_path_buf();
    let error = run_bounded(move || super::evidence::problems(&path, expected_manifest(), false))
        .expect_err("a FIFO manifest must fail rather than block");
    assert!(
        error.to_string().contains("manifest"),
        "the failure must name the manifest: {error}"
    );

    // A capture image: the manifest is readable, and the FIFO must be reported
    // without being hashed.
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    fifo(&copy.path().join("captures/lib-wide-w1280-en.png"));
    let path = copy.path().to_path_buf();
    let problems =
        run_bounded(move || super::evidence::problems(&path, expected_manifest(), false))
            .expect("the readable manifest must let the rest of the validation run");
    assert!(
        problems
            .iter()
            .any(|problem| problem.contains("lib-wide-w1280-en.png")
                && problem.contains("not a regular file")),
        "the FIFO capture must be reported: {problems:?}"
    );
}

/// A manifest that names a capture outside the flat `captures/<name>` shape is
/// refused without being opened, even when the path it names would block.
#[cfg(unix)]
#[test]
fn evidence_validator_refuses_a_capture_path_it_did_not_write() {
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());

    // A nested path through a directory that holds a FIFO: resolving it would
    // open the FIFO next.
    let directory_entry = copy.path().join("captures/lib-wide-w1280-en.png");
    std::fs::remove_file(&directory_entry).expect("remove the capture");
    std::fs::create_dir(&directory_entry).expect("directory entry");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(directory_entry.join("blocked.png"))
            .status()
            .expect("run mkfifo")
            .success()
    );
    tamper_manifest(copy.path(), |manifest| {
        manifest["captures"][0]["image"] =
            serde_json::Value::String("captures/lib-wide-w1280-en.png/blocked.png".to_owned());
    });
    let path = copy.path().to_path_buf();
    let problems =
        run_bounded(move || super::evidence::problems(&path, expected_manifest(), false))
            .expect("the readable manifest must let the rest of the validation run");
    assert!(
        problems
            .iter()
            .any(|problem| problem.contains("not a plain capture path")),
        "a nested capture path must be refused: {problems:?}"
    );

    // An escaping path is refused for the same reason — and the path it names
    // is a FIFO with no writer, so a regression that resolved the path would
    // block instead of quietly reading a missing file.
    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    assert!(
        std::process::Command::new("mkfifo")
            .arg(copy.path().join("outside.png"))
            .status()
            .expect("run mkfifo")
            .success()
    );
    tamper_manifest(copy.path(), |manifest| {
        manifest["captures"][0]["image"] =
            serde_json::Value::String("captures/../outside.png".to_owned());
    });
    let path = copy.path().to_path_buf();
    let problems =
        run_bounded(move || super::evidence::problems(&path, expected_manifest(), false))
            .expect("the readable manifest must let the rest of the validation run");
    assert!(
        problems.iter().any(|problem| {
            problem.contains("captures/../outside.png") && problem.contains("not a plain capture")
        }),
        "a capture path that leaves the directory must be refused: {problems:?}"
    );
}

/// A symlinked `captures/` or `fixtures/` directory is reported and not
/// traversed: listing it would read whatever the link points at.
#[cfg(unix)]
#[test]
fn evidence_validator_does_not_traverse_a_symlinked_directory() {
    let external = temp_root();
    for name in ["captures", "fixtures"] {
        std::fs::create_dir(external.path().join(name)).expect("external directory");
        std::fs::write(
            external.path().join(name).join("external.txt"),
            b"not evidence",
        )
        .expect("external file");
        std::fs::set_permissions(
            external.path().join(name),
            std::os::unix::fs::PermissionsExt::from_mode(0o000),
        )
        .expect("restrict the external directory");
    }

    let copy = temp_root();
    copy_evidence(&evidence_root(), copy.path());
    for name in ["captures", "fixtures"] {
        std::fs::remove_dir_all(copy.path().join(name)).expect("remove the directory");
        std::os::unix::fs::symlink(external.path().join(name), copy.path().join(name))
            .expect("symlink the directory");
    }

    let path = copy.path().to_path_buf();
    let problems =
        run_bounded(move || super::evidence::problems(&path, expected_manifest(), false))
            .expect("the readable manifest must let the rest of the validation run");
    for name in ["captures", "fixtures"] {
        assert!(
            problems
                .iter()
                .any(|problem| problem.contains(name) && problem.contains("symlink")),
            "{name}/ must be reported as a symlink: {problems:?}"
        );
    }
    assert!(
        !problems
            .iter()
            .any(|problem| problem.contains("Permission denied")),
        "a symlinked directory must not be traversed (a listing would fail on the unreadable \
         target): {problems:?}"
    );

    // Restore the permissions so the temporary directories can be removed.
    for name in ["captures", "fixtures"] {
        std::fs::set_permissions(
            external.path().join(name),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .expect("restore permissions");
    }
}

/// The fixture reader refuses a symlinked root instead of walking it.
#[cfg(unix)]
#[test]
fn read_reference_fixtures_refuses_a_symlinked_root() {
    let real = temp_root();
    fixtures::write_reference_fixtures(real.path()).expect("fixture tree");
    let link = temp_root();
    let linked = link.path().join("fixtures");
    std::os::unix::fs::symlink(real.path(), &linked).expect("symlink the fixture root");

    let error = fixtures::read_reference_fixtures(&linked)
        .expect_err("a symlinked fixture root must be refused");
    assert!(
        error.to_string().contains("not a real directory"),
        "the refusal must say the root is not a real directory: {error}"
    );
}

/// Ordinary evidence destinations pass, including the ones a run will create.
#[test]
fn preflight_accepts_regular_destinations_and_missing_ones() {
    let base = temp_root();
    let output = base.path().join("evidence");
    std::fs::create_dir_all(output.join("captures")).expect("captures");
    std::fs::create_dir_all(output.join("fixtures")).expect("fixtures");
    for name in super::evidence::EVIDENCE_FILES {
        std::fs::write(output.join(name), b"placeholder").expect("metadata file");
    }
    std::fs::write(output.join("captures/lib-wide-w1280-en.png"), b"png").expect("capture");
    let images = vec![
        "captures/lib-wide-w1280-en.png".to_owned(),
        "captures/lib-wide-w1280-ja.png".to_owned(),
    ];
    super::runner::preflight_evidence_destinations(&output, &images)
        .expect("regular destinations and a missing one are fine");
}

/// `LB-03` is the breakpoint row: its evidence has to probe `B760±` in both
/// interfaces and to reference the wide captures the breakpoint switches to, not
/// merely mention the row from some capture.
#[test]
fn breakpoint_row_covers_both_sides_in_both_interfaces() {
    use super::scenarios::{Locale, W1280, scenarios};

    let scenarios = scenarios();
    for locale in [Locale::En, Locale::Ja] {
        let widths: Vec<f32> = scenarios
            .iter()
            .filter(|scenario| scenario.rows.contains(&"LB-03") && scenario.locale == locale)
            .map(|scenario| scenario.client.0)
            .collect();
        for width in [759.0, 760.0, 761.0] {
            assert!(
                widths.contains(&width),
                "LB-03 needs a {width}-wide capture in {locale:?}, got {widths:?}"
            );
        }
        assert!(
            widths.contains(&W1280.0),
            "LB-03 lists the `1B-LIB-WIDE` family in the specification, so it needs a wide \
             reference in {locale:?}, got {widths:?}"
        );
    }
}

/// `LB-02` is the compact composition: the specification requires the `C390`,
/// `B760±` and `EN` configurations, so the row has to be backed by the compact
/// captures and by the English breakpoint probes.
#[test]
fn compact_row_covers_its_c390_and_breakpoint_configurations() {
    use super::scenarios::{C390, Locale, scenarios};

    let widths: Vec<f32> = scenarios()
        .iter()
        .filter(|scenario| scenario.rows.contains(&"LB-02") && scenario.locale == Locale::En)
        .map(|scenario| scenario.client.0)
        .collect();
    for width in [C390.0, 759.0, 760.0, 761.0] {
        assert!(
            widths.contains(&width),
            "LB-02 needs a {width}-wide English capture, got {widths:?}"
        );
    }
}

/// The provenance the evidence tests build their expected manifest with.
///
/// The revision is exempt from the evidence comparison, so the tests may run
/// where `jj` is unavailable and the capture entry point would (correctly) refuse
/// to run; the entry point's own failure path is covered by
/// `capture_revision_fails_closed_without_an_exact_revision` instead.
fn manifest_revision() -> super::runner::CaptureRevision {
    super::runner::capture_revision().unwrap_or(super::runner::CaptureRevision {
        revision: "0".repeat(40),
        change_id: "test-placeholder".to_owned(),
        bookmark: "test-placeholder".to_owned(),
        source: "test placeholder (no Jujutsu working copy)".to_owned(),
    })
}

/// The committed evidence must describe the code that is checked out.
///
/// This is the always-on half of `make reference-shots VERIFY=1`: it compares
/// the committed manifest with the manifest the current capture table, fixture
/// generator and seed produce, hashes the committed PNGs against the committed
/// hashes, and re-derives the checksum files, the README and the committed
/// fixture tree. It renders nothing, so it can run in every `cargo test`.
///
/// Every package is checked, not just the one whose evidence predates the
/// split: each has its own capture table and its own manifest, so validating one
/// says nothing about the other.
#[cfg(unix)]
#[test]
fn committed_evidence_matches_current_code() {
    for package in Package::ALL {
        let root = evidence_root_for(package);
        assert!(
            root.is_dir(),
            "the committed evidence directory of package {} ({}) is missing",
            package.id(),
            root.display()
        );
        super::evidence::validate(&root, expected_manifest_for(package), false).unwrap_or_else(
            |error| {
                panic!(
                    "the committed package {} evidence must match the current code: {error:#}",
                    package.id()
                )
            },
        );
    }
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
#[cfg(unix)]
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

/// Run a validation on a worker thread with a bound.
///
/// A validator that opened a FIFO with no writer would block; a thread with a
/// timeout turns that regression into a failure instead of a hung suite.
#[cfg(unix)]
fn run_bounded<T: Send + 'static>(check: impl FnOnce() -> T + Send + 'static) -> T {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(check());
    });
    receiver
        .recv_timeout(std::time::Duration::from_secs(30))
        .expect("the validation must finish: it may not block on a FIFO")
}

/// Mutate a disposable copy of a package's committed evidence and require the
/// validator to reject it with a problem naming `needle`.
///
/// The untouched copy is validated first, so a failure is caused by the
/// mutation and not by the copy.
#[cfg(unix)]
fn tampered_evidence_for(package: Package, mutate: impl FnOnce(&Path), needle: &str) {
    let copy = temp_root();
    copy_evidence(&evidence_root_for(package), copy.path());
    let expected = expected_manifest_for(package);
    let clean = super::evidence::problems(copy.path(), expected, false)
        .expect("a copy of the committed evidence must be readable");
    assert!(
        clean.is_empty(),
        "the untouched package {} copy must validate, otherwise the mutation proves nothing: \
         {clean:?}",
        package.id()
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

/// The package 1B shorthand of [`tampered_evidence_for`].
#[cfg(unix)]
fn tampered_evidence(mutate: impl FnOnce(&Path), needle: &str) {
    tampered_evidence_for(Package::OneB, mutate, needle)
}

/// Rewrite the manifest of a disposable copy and re-render its README.
///
/// Used where the mutated manifest must still be *self-consistent*: a stale
/// README would make every case fail, which would prove nothing about the field
/// under test.
#[cfg(unix)]
fn rewrite_manifest(root: &Path, edit: impl FnOnce(&mut super::manifest::Manifest)) {
    let path = root.join("manifest.json");
    let mut manifest: super::manifest::Manifest =
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
    std::fs::write(root.join("README.md"), super::manifest::readme(&manifest))
        .expect("write the README");
}

/// Edit the committed manifest of a disposable copy.
#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
#[test]
fn evidence_validator_rejects_an_orphaned_capture() {
    tampered_evidence(
        |root| {
            std::fs::write(root.join("captures/orphan.png"), b"not a capture").expect("orphan");
        },
        "captures/orphan.png is committed but not listed by the manifest",
    );
}

#[cfg(unix)]
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

#[cfg(unix)]
#[test]
fn evidence_validator_rejects_an_orphaned_fixture() {
    tampered_evidence(
        |root| {
            std::fs::write(root.join("fixtures/orphan.bin"), b"orphan").expect("orphan");
        },
        "is not the generated tree",
    );
}

#[cfg(unix)]
#[test]
fn evidence_validator_rejects_a_stale_readme() {
    tampered_evidence(
        |root| {
            std::fs::write(root.join("README.md"), b"# stale\n").expect("stale README");
        },
        "README.md is stale",
    );
}

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

/// A changed reader fact on a package 1C capture must be rejected.
///
/// This is the negative control for the `reader` block: 1B captures never carry
/// it, so the always-on evidence check would still pass if a 1C capture's reader
/// facts were compared against nothing. The mutation leaves the capture id and
/// every 1B-shaped field alone, so only the reader comparison can catch it.
#[cfg(unix)]
#[test]
fn evidence_validator_rejects_a_changed_reader_fact() {
    const CAPTURE: &str = "rd-epub-pag-w1280-en";
    tampered_evidence_for(
        Package::OneC,
        |root| {
            tamper_manifest(root, |manifest| {
                let captures = manifest["captures"].as_array_mut().expect("captures");
                let capture = captures
                    .iter_mut()
                    .find(|capture| capture["id"] == serde_json::json!(CAPTURE))
                    .unwrap_or_else(|| panic!("{CAPTURE} must be in the committed 1C manifest"));
                let visible = capture["reader"]["visible_pages"]
                    .as_array_mut()
                    .expect("visible_pages is an array");
                visible[0] = serde_json::json!(99);
            });
        },
        &format!("{CAPTURE} describes a different state or size than the capture table"),
    );
}

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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

#[cfg(unix)]
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
#[cfg(unix)]
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
#[cfg(unix)]
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
#[cfg(unix)]
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

/// The root is deleted without ever being reachable by a second run.
///
/// A run that acquired the root name while the first one was tearing down would
/// otherwise find its state deleted, so teardown renames the root aside and
/// deletes the renamed directory.
#[test]
fn disposable_root_teardown_never_exposes_a_live_root() {
    let parent = temp_root();
    let root = parent.path().join("data");
    let output = parent.path().join("evidence");
    let guard = super::runner::DisposableRoot::prepare(&root, &output).expect("first run");
    std::fs::write(root.join("state.db"), b"state").expect("state");

    let discard = super::runner::discard_path(&root);
    assert_eq!(
        discard.parent(),
        Some(parent.path()),
        "the discard path must stay in the same directory, so the rename cannot cross a filesystem"
    );

    guard.finish(false).expect("release and remove the root");

    assert!(
        !root.exists(),
        "the root name must not survive the run that owned it"
    );
    assert!(
        !discard.exists(),
        "the renamed copy must be deleted as well, not left behind"
    );
    let leftovers: Vec<String> = std::fs::read_dir(parent.path())
        .expect("parent")
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name != "evidence")
        .collect();
    assert!(
        leftovers.is_empty(),
        "teardown must not leave anything next to the root: {leftovers:?}"
    );

    // A later run gets a fresh root, not the deleted one.
    let guard = super::runner::DisposableRoot::prepare(&root, &output).expect("second run");
    assert!(root.is_dir(), "the second run creates its own root");
    assert!(
        !root.join("state.db").exists(),
        "the second run must not see the first run's state"
    );
    guard.finish(false).expect("release");
}

/// A discard directory this tool did not create is never deleted.
#[test]
fn foreign_discard_directory_is_not_deleted() {
    let parent = temp_root();
    let root = parent.path().join("data");
    let discard = super::runner::discard_path(&root);
    std::fs::create_dir_all(&discard).expect("discard dir");
    let sentinel = discard.join("someone-elses-data");
    std::fs::write(&sentinel, b"keep me").expect("sentinel");

    let error = super::runner::DisposableRoot::prepare(&root, &parent.path().join("evidence"))
        .and_then(|guard| guard.finish(false))
        .expect_err("a run must not adopt a foreign discard directory");
    assert!(
        error.to_string().contains("discard"),
        "the failure must explain what was refused: {error}"
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("the sentinel must survive"),
        b"keep me"
    );
}

/// A discard directory whose marker names a different root is not this run's.
///
/// The name is derived from the root and the process id, and a recycled process
/// id must not turn another directory into a delete target: the marker has to
/// name *this* root.
#[test]
fn discard_directory_of_an_unrelated_root_is_not_deleted() {
    let parent = temp_root();
    let root = parent.path().join("data");
    let other_root = parent.path().join("other-data");
    let discard = super::runner::discard_path(&root);
    std::fs::create_dir_all(&discard).expect("discard dir");
    let sentinel = discard.join("someone-elses-data");
    std::fs::write(&sentinel, b"keep me").expect("sentinel");
    std::fs::write(
        discard.join(super::runner::ROOT_MARKER_FILE),
        super::runner::marker_content(&other_root),
    )
    .expect("foreign marker");

    let error = super::runner::DisposableRoot::prepare(&root, &parent.path().join("evidence"))
        .and_then(|guard| guard.finish(false))
        .expect_err("a discard directory marked for another root must be refused");
    assert!(
        error.to_string().contains("discard"),
        "the failure must explain what was refused: {error}"
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("the sentinel must survive"),
        b"keep me"
    );
    assert!(
        std::fs::read(discard.join(super::runner::ROOT_MARKER_FILE)).is_ok(),
        "the refused directory keeps its marker"
    );
}

/// A discard directory marked for exactly this root is reclaimed.
#[test]
fn discard_directory_of_this_root_is_reclaimed() {
    let parent = temp_root();
    let root = parent.path().join("data");
    let output = parent.path().join("evidence");

    // As if an interrupted run had renamed its root aside and died: the discard
    // directory still carries this root's marker and stale state.
    let discard = super::runner::discard_path(&root);
    std::fs::create_dir_all(&discard).expect("discard dir");
    std::fs::write(
        discard.join(super::runner::ROOT_MARKER_FILE),
        super::runner::marker_content(
            &super::runner::resolve_path(&root).expect("resolve the root"),
        ),
    )
    .expect("marker");
    std::fs::write(discard.join("stale-only.db"), b"stale").expect("stale state");

    let guard = super::runner::DisposableRoot::prepare(&root, &output).expect("prepare");
    std::fs::write(root.join("state.db"), b"state").expect("state");
    guard
        .finish(false)
        .expect("a discard directory marked for this root is reclaimed, not refused");
    assert!(
        !discard.exists(),
        "the reclaimed discard directory must be gone as well"
    );
    assert!(!root.exists(), "the root itself is removed too");
}

/// Equivalent spellings of the same location must be rejected.
#[test]
fn root_configuration_resolves_path_aliases() {
    let parent = temp_root();
    let output = parent.path().join("evidence");
    std::fs::create_dir_all(&output).expect("evidence dir");

    // `…/evidence/../data` is the root spelled with a detour.
    assert!(
        super::runner::validate_root_configuration(&output.join("../data"), &output).is_ok(),
        "a sibling spelled through the evidence directory is a legitimate root"
    );
    // But the evidence directory itself spelled through a detour is not.
    assert!(
        super::runner::validate_root_configuration(&output.join("nested/.."), &output).is_err(),
        "the evidence directory spelled through a detour must still be refused"
    );
    assert!(
        super::runner::validate_root_configuration(&output.join("nested"), &output).is_err(),
        "a root inside the evidence directory must be refused"
    );

    // The repository root is protected under every spelling.
    assert!(
        super::runner::validate_root_configuration(
            &super::runner::repository_root().join(".."),
            &output
        )
        .is_err(),
        "the repository parent must be refused as well"
    );
}

/// A root spelled through a `..` that does not exist yet still resolves to what
/// the operating system would create.
///
/// `Path::file_name` returns `None` for a path ending in `..`, so a resolver
/// that only collected file names would read `…/missing/../evidence` as
/// `…/missing/evidence`, pass the overlap check, create the missing component and
/// then clear the real evidence directory.
#[test]
fn root_configuration_resolves_missing_parent_components() {
    let parent = temp_root();
    let output = parent.path().join("evidence");
    std::fs::create_dir_all(&output).expect("evidence dir");
    let sentinel = output.join("manifest.json");
    std::fs::write(&sentinel, b"committed evidence").expect("sentinel");

    let missing = parent.path().join("missing");
    assert!(
        !missing.exists(),
        "the counterexample needs a missing component"
    );
    assert_eq!(
        super::runner::resolve_path(&missing.join("../evidence"))
            .expect("resolve the evidence spelling"),
        super::runner::resolve_path(&output).expect("resolve the evidence directory"),
        "a missing component with `..` must resolve to the location the OS would create"
    );
    assert!(
        super::runner::validate_root_configuration(&missing.join("../evidence"), &output).is_err(),
        "the evidence directory spelled through a missing component must be refused"
    );

    let error = super::runner::DisposableRoot::prepare(&missing.join("../evidence"), &output)
        .expect_err("a run must not adopt the evidence directory as its data root");
    assert!(
        !error.to_string().is_empty(),
        "the refusal must explain itself: {error}"
    );
    assert_eq!(
        std::fs::read(&sentinel).expect("the sentinel must survive"),
        b"committed evidence"
    );
    assert!(
        !missing.exists(),
        "a refused run must not create the components of the refused root"
    );
}

/// Relative spellings compare against the same absolute location.
///
/// The evidence directory may be given relatively while the data root is
/// absolute, so the comparison has to make both absolute first.
#[test]
fn root_configuration_resolves_relative_spellings() {
    let directory = std::env::current_dir().expect("current directory");
    let here = super::runner::resolve_path(&directory).expect("resolve the current directory");
    assert!(
        here.is_absolute(),
        "the current directory resolves absolutely: {here:?}"
    );
    for spelling in ["", "."] {
        assert_eq!(
            super::runner::resolve_path(std::path::Path::new(spelling))
                .expect("resolve the relative spelling"),
            here,
            "the relative spelling {spelling:?} resolves to the current directory"
        );
    }
    assert_eq!(
        super::runner::resolve_path(std::path::Path::new("..")).expect("resolve `..`"),
        super::runner::resolve_path(&directory.join("..")).expect("resolve `..`"),
        "a relative parent component resolves like its absolute spelling"
    );
}

/// A symlinked ancestor resolves to the same location.
#[cfg(unix)]
#[test]
fn root_configuration_resolves_symlinked_ancestors() {
    let parent = temp_root();
    let output = parent.path().join("evidence");
    let root = parent.path().join("data");
    std::fs::create_dir_all(&output).expect("evidence dir");

    let real = parent.path().join("real");
    std::fs::create_dir_all(&real).expect("real dir");
    let link = parent.path().join("link");
    std::os::unix::fs::symlink(&real, &link).expect("symlink");
    assert!(
        super::runner::validate_root_configuration(&link, &link.join("evidence")).is_err(),
        "a root and an evidence directory that are the same location through a symlink must be \
         refused"
    );
    assert!(
        super::runner::validate_root_configuration(&root, &link.join("evidence")).is_ok(),
        "unrelated locations spelled through a symlink keep working"
    );
}

/// A `..` after a symlink applies to the link's target, not to the link.
///
/// The file system resolves the link first, so `…/link/..` is the *target's*
/// parent directory. A resolver that removed `..` lexically would name the
/// link's own parent instead, and the two spellings would then be validated as
/// one location and used as another.
#[cfg(unix)]
#[test]
fn resolve_path_applies_parent_components_after_symlinks() {
    let base = temp_root();
    let nested = base.path().join("data/sub");
    std::fs::create_dir_all(&nested).expect("nested dir");
    let link = base.path().join("link");
    std::os::unix::fs::symlink(&nested, &link).expect("symlink");

    assert_eq!(
        super::runner::resolve_path(&link.join("..")).expect("resolve link/.."),
        super::runner::resolve_path(&base.path().join("data")).expect("resolve the target parent"),
        "`link/..` is the target's parent, not the link's parent"
    );
    assert_eq!(
        super::runner::resolve_path(&link.join("../..")).expect("resolve link/../.."),
        super::runner::resolve_path(base.path()).expect("resolve the base directory"),
        "a second parent component follows the resolved prefix as well"
    );
}

/// A spelling that is inside the disposable root *physically* but outside it
/// *lexically* must still be refused.
///
/// `…/link/../../data/evidence` drops `link` and `..` lexically, which reads as
/// a sibling of the root, while the file system follows the link into the root
/// first and lands inside it. A check that resolved `.`/`..` before following
/// symlinks would pass the overlap test and then write the evidence directory
/// into the root the same run deletes at the end.
#[cfg(unix)]
#[test]
fn root_configuration_rejects_a_symlinked_output_inside_the_root() {
    let base = temp_root();
    let root = base.path().join("data");
    let nested = root.join("sub");
    std::fs::create_dir_all(&nested).expect("nested dir");
    let link = base.path().join("link");
    std::os::unix::fs::symlink(&nested, &link).expect("symlink");

    let output = link.join("../../data/evidence");
    assert_eq!(
        super::runner::resolve_path(&output).expect("resolve the output spelling"),
        super::runner::resolve_path(&root.join("evidence")).expect("resolve the expected output"),
        "the link is followed before the parent components are applied"
    );
    assert!(
        super::runner::validate_root_configuration(&root, &output).is_err(),
        "an evidence directory inside the disposable root must be refused at every spelling"
    );
    let error = super::runner::DisposableRoot::prepare(&root, &output)
        .expect_err("a run must not write its evidence into the root it deletes");
    assert!(
        error.to_string().contains("overlap"),
        "the refusal must name the overlap: {error}"
    );
    assert!(
        !root.join("evidence").exists(),
        "a refused run must not create the evidence directory inside the root"
    );
}

/// A relative data root is refused before anything is created.
///
/// Resolving first would turn the spelling into an absolute path against the
/// process directory and accept it, which is not what the documented entry
/// point promises.
#[test]
fn prepare_rejects_a_relative_root() {
    let evidence = temp_root();
    let relative = Path::new("reference-shots-relative-root-test");
    let error = super::runner::DisposableRoot::prepare(relative, &evidence.path().join("evidence"))
        .expect_err("a relative data root must be refused");
    assert!(
        error.to_string().contains("absolute"),
        "the refusal must explain that the root has to be absolute: {error}"
    );
    assert!(
        !relative.exists(),
        "a refused run must not create a directory relative to the test directory"
    );
}

/// A data root that is itself a symlink is refused, and its target is left
/// alone.
///
/// Resolving first would dereference the link, adopt the target directory (an
/// empty unrelated directory passes the marker check), lock it, clear it and
/// delete it at the end of the run. Trailing separators and `.` are the same
/// path to the shell but a different path to `symlink_metadata`, so all three
/// spellings must be refused.
#[cfg(unix)]
#[test]
fn prepare_rejects_a_symlinked_root_without_adopting_its_target() {
    let base = temp_root();
    let target = base.path().join("unrelated-empty-directory");
    std::fs::create_dir_all(&target).expect("target dir");
    let link = base.path().join("link");
    std::os::unix::fs::symlink(&target, &link).expect("symlink");

    let spellings = [
        link.clone(),
        PathBuf::from(format!("{}/", link.display())),
        link.join("."),
    ];
    for spelling in &spellings {
        let error = super::runner::DisposableRoot::prepare(spelling, &base.path().join("evidence"))
            .err()
            .unwrap_or_else(|| panic!("{} must be refused", spelling.display()));
        assert!(
            error.to_string().contains("symlink"),
            "the refusal must name the symlink for {}: {error}",
            spelling.display()
        );
    }
    assert!(
        target.is_dir(),
        "the link target must survive a refused run: {}",
        target.display()
    );
    for reserved in [
        super::runner::ROOT_MARKER_FILE,
        super::runner::ROOT_LOCK_FILE,
    ] {
        assert!(
            !target.join(reserved).exists(),
            "a refused run must not adopt the target directory ({reserved} was created)"
        );
    }
}

/// A spelling the file system cannot traverse is refused, not silently rewritten
/// into a location that happens to be reachable through `..`.
///
/// A symlink loop or a dangling link fails traversal with `ELOOP`/`ENOENT`, and
/// a regular file used as a directory fails with `ENOTDIR`; treating any of them
/// as an absent component would let a following `..` erase it and make the run
/// act on a sibling location instead. Nothing may be created or cleared while
/// refusing: the evidence directory keeps its sentinel.
#[cfg(unix)]
#[test]
fn untraversable_spellings_are_refused_without_touching_anything() {
    let base = temp_root();
    let evidence = base.path().join("evidence");
    std::fs::create_dir_all(&evidence).expect("evidence dir");
    let sentinel = evidence.join("manifest.json");
    std::fs::write(&sentinel, b"committed evidence").expect("sentinel");

    // A self-referential link: traversal fails with ELOOP.
    let looping = base.path().join("loop");
    std::os::unix::fs::symlink(&looping, &looping).expect("self-referential symlink");
    // A link whose target does not exist: traversal fails with ENOENT, and the
    // name itself exists, so it is not a component the run may create later.
    let dangling = base.path().join("dangling");
    std::os::unix::fs::symlink(base.path().join("missing-target"), &dangling)
        .expect("dangling symlink");
    // A regular file: `…/file/..` and `…/file/evidence` both fail with ENOTDIR.
    let file = base.path().join("file");
    std::fs::write(&file, b"not a directory").expect("file");

    let spellings = [
        looping.join("../evidence"),
        dangling.join("../evidence"),
        file.join("..").join("evidence"),
        file.join("evidence"),
    ];
    for spelling in &spellings {
        let error = super::runner::resolve_path(spelling)
            .err()
            .unwrap_or_else(|| panic!("{} must not resolve to a location", spelling.display()));
        assert!(
            !error.to_string().is_empty(),
            "the refusal must explain itself for {}",
            spelling.display()
        );
        let error = super::runner::validate_root_configuration(spelling, &evidence)
            .err()
            .unwrap_or_else(|| panic!("{} must be refused as a root", spelling.display()));
        assert!(!error.to_string().is_empty(), "{error}");
        let error = super::runner::DisposableRoot::prepare(spelling, &evidence)
            .err()
            .unwrap_or_else(|| panic!("{} must be refused as a root", spelling.display()));
        assert!(!error.to_string().is_empty(), "{error}");
    }

    assert_eq!(
        std::fs::read(&sentinel).expect("the sentinel must survive"),
        b"committed evidence"
    );
    assert!(
        !base.path().join("missing-target").exists(),
        "a refused run must not create the target of a dangling link"
    );
    assert!(
        !base.path().join("fixtures").exists() && !evidence.join("fixtures").exists(),
        "a refused run must not create a fixture tree"
    );
    assert!(
        looping.is_symlink() && dangling.is_symlink() && file.is_file(),
        "a refused run must leave the offending components alone"
    );
}

/// The resolved evidence directory survives the data-root teardown that removes
/// the symlink it was configured through.
///
/// The run resolves the evidence configuration once, before `prepare()` clears
/// the data root; the root may contain the very symlink the configuration names,
/// so re-reading the configuration afterwards would resolve to the cleared path
/// *inside* the root. This pins the value the run keeps: mirroring and the
/// manifest derive from it, never from the configuration again.
#[cfg(unix)]
#[test]
fn a_resolved_output_survives_the_root_teardown_that_removes_its_symlink() {
    let base = temp_root();
    let external = base.path().join("external-evidence");
    std::fs::create_dir_all(&external).expect("external evidence");
    let root = base.path().join("data");

    // `prepare` only clears a root this tool marked, so the root has to be
    // adopted by a first run before the symlink can be planted inside it.
    super::runner::DisposableRoot::prepare(&root, &external)
        .expect("adopt the disposable root")
        .finish(true)
        .expect("keep the adopted root");

    let link = root.join("link");
    std::os::unix::fs::symlink(&external, &link).expect("symlink");

    let resolved = super::runner::resolve_path(&link).expect("resolve the configured spelling");
    assert_eq!(
        resolved,
        super::runner::resolve_path(&external).expect("resolve the external directory"),
        "the configured spelling resolves to the external evidence directory"
    );

    let guard = super::runner::DisposableRoot::prepare(&root, &resolved)
        .expect("the external evidence directory does not overlap the data root");
    assert!(
        !link.exists(),
        "preparation clears the disposable root, removing the symlink it contained"
    );
    assert_eq!(
        super::runner::resolve_path(&link).expect("resolve the cleared spelling"),
        super::runner::resolve_path(&root)
            .expect("resolve the root")
            .join("link"),
        "re-reading the configuration now would point inside the cleared root"
    );

    let mirror = super::runner::evidence_fixtures_path(&resolved);
    assert_eq!(
        mirror,
        // Both sides are resolved: on macOS the temporary directory itself is
        // reached through a symlink (`/var` -> `/private/var`), and comparing a
        // resolved path with a spelling would fail there for the wrong reason.
        super::runner::resolve_path(&external)
            .expect("resolve the external directory")
            .join("fixtures")
    );
    std::fs::create_dir_all(&mirror).expect("mirror the fixture tree");
    guard.finish(false).expect("teardown");
    assert!(
        mirror.is_dir(),
        "the mirrored tree lives outside the cleared root: {}",
        mirror.display()
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

/// The capture environment contract: the entry point must pin the system
/// language and font discovery, and the capture runs on Linux only.
///
/// The capture never mutates the process environment (an ordinary `cargo test`
/// shares this process), so the contract is a pure function over the variables
/// the entry point exports, and this test pins both directions.
#[test]
fn capture_environment_contract() {
    let problems = super::runner::capture_environment_problems;
    assert_eq!(
        problems(Some("en-US"), Some("/tmp/fontconfig.xml"), "linux"),
        Vec::<String>::new(),
        "the documented environment must be accepted"
    );
    assert!(
        !problems(Some("ja-JP"), Some("/tmp/fontconfig.xml"), "linux").is_empty(),
        "a host language must be rejected"
    );
    assert!(
        !problems(None, Some("/tmp/fontconfig.xml"), "linux").is_empty(),
        "an unset language must be rejected"
    );
    assert!(
        !problems(Some("en-US"), None, "linux").is_empty(),
        "unpinned font discovery must be rejected"
    );
    assert!(
        !problems(Some("en-US"), Some("   "), "linux").is_empty(),
        "an empty font config path must be rejected"
    );
    for os in ["macos", "windows"] {
        let reported = problems(Some("en-US"), Some("/tmp/fontconfig.xml"), os);
        assert!(
            reported.iter().any(|problem| problem.contains(os)),
            "{os} must be reported as unsupported: {reported:?}"
        );
    }

    // The configuration must declare a font directory: a configuration without
    // one makes the loader scan the system directories instead.
    let fontconfig = super::runner::fontconfig_problems;
    assert_eq!(
        fontconfig(Some("<fontconfig><dir>/tmp/empty</dir></fontconfig>")),
        Vec::<String>::new()
    );
    assert!(
        !fontconfig(Some("<fontconfig></fontconfig>")).is_empty(),
        "a configuration without a directory must be rejected"
    );
    assert!(
        !fontconfig(None).is_empty(),
        "an unreadable configuration must be rejected"
    );
}

/// The font-database contract behind the environment check.
///
/// The capture loads the application fonts into Iced's global font system, and
/// the entry point must additionally keep host fonts out of it: a file-backed
/// face would let installed fonts change the rendered pixels even though every
/// application font hash in the manifest still matched.
#[test]
fn font_database_contract() {
    let problems = super::render::font_database_problems;
    assert_eq!(
        problems(5, 0),
        Vec::<String>::new(),
        "only in-memory faces is the controlled database"
    );
    assert!(
        !problems(5, 3).is_empty(),
        "a file-backed face must be rejected"
    );
    assert!(
        !problems(0, 0).is_empty(),
        "an empty font database must be rejected"
    );

    // The application fonts are loaded from the bundled bytes in any process.
    let (in_memory, _) = super::render::font_database_faces();
    assert!(in_memory >= 3, "the three application fonts must be loaded");
}

/// Every capture that resolves `LanguagePreference::System` must still record
/// English, and the two interfaces must be distinguishable.
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

// ---------------------------------------------------------------------------
// Package 1C: the reader capture table
// ---------------------------------------------------------------------------

/// The 1C capture table is internally consistent and claims only 1C families.
#[test]
fn reader_capture_table_is_consistent() {
    let scenarios = super::reader::scenarios();
    assert!(!scenarios.is_empty());

    let mut ids = BTreeMap::new();
    for scenario in &scenarios {
        assert!(
            ids.insert(scenario.id, scenario.family).is_none(),
            "duplicate capture id {}",
            scenario.id
        );
        assert!(
            super::reader::PACKAGE_1C_FAMILIES.contains(&scenario.family),
            "{} uses a family outside package 1C: {}",
            scenario.id,
            scenario.family
        );
        assert!(
            !scenario.rows.is_empty(),
            "{} must name the matrix rows it covers",
            scenario.id
        );
        for row in scenario.rows {
            assert!(
                row.starts_with("RD-") || row.starts_with("FM-") || row == &"XA-10",
                "{} claims {row}, which is not a reader row",
                scenario.id
            );
        }
        assert!(
            scenario.reader.is_some(),
            "{} must declare the reader state it shows",
            scenario.id
        );
        assert_eq!(
            scenario.surface(),
            super::scenarios::Surface::Reader,
            "{} must be a reader capture",
            scenario.id
        );
        assert!(
            matches!(scenario.kind, super::scenarios::Kind::Reader(_)),
            "{} must use a reader state",
            scenario.id
        );
        assert_eq!(
            super::scenarios::state_id(scenario),
            "reader",
            "{} must record the reader state id",
            scenario.id
        );
    }

    let (captured, from_manifest, pending) = super::reader::matrix_rows();
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
    for row in [
        "RD-04", "RD-12", "RD-14", "RD-15", "FM-11", "FM-12", "FM-14", "FM-15", "FM-16", "FM-17",
        "FM-19", "FM-20",
    ] {
        assert!(
            pending.iter().any(|(pending_row, _)| *pending_row == row),
            "{row} has no Iced counterpart and must stay explicitly pending"
        );
    }

    // Every capture must name the reader state it shows, and no 1C capture may
    // claim a library/import/settings row.
    for scenario in &scenarios {
        assert!(
            !scenario.derivation().is_empty(),
            "{} needs a state derivation",
            scenario.id
        );
        for row in scenario.rows {
            assert!(
                !row.starts_with("LB-") && !row.starts_with("IM-") && !row.starts_with("ST-"),
                "{} claims the 1B row {row}",
                scenario.id
            );
        }
    }

    // The reader families the specification assigns to 1C must all be used, or
    // a family silently has no reference at all.
    for family in super::reader::PACKAGE_1C_FAMILIES {
        assert!(
            scenarios.iter().any(|scenario| scenario.family == family),
            "family {family} has no capture"
        );
    }

    for (left, right, reason) in super::reader::PIXEL_ALIASES {
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

/// A literal available-size expectation: client size, the four panel flags in
/// `available_size`'s parameter order, and the expected available size.
type AvailableCase = ((f32, f32), bool, bool, bool, bool, (f32, f32));

/// Every declared reader fact must be reachable geometry, not a guess.
///
/// Two checks run together. The literal tables below are the specification's own
/// arithmetic written out by hand — `available = client − 112 − panels` and
/// `height − 148 − panel heights`, and the first/last/odd-final pairing rule — so
/// the helpers the declarations use are pinned against numbers rather than
/// against themselves. The per-capture loop then recomputes each declaration
/// from its own client size and panel state, so a declaration that drifts from
/// the arithmetic fails here.
#[test]
fn reader_declared_geometry_follows_the_specification() {
    // (client, contents panel, search, typography, more, available size), from
    // `available = client − 112 − panels` and the 148/52/62/58/88 panel heights.
    let available_cases: [AvailableCase; 18] = [
        ((1280.0, 800.0), false, false, false, false, (1168.0, 652.0)),
        ((1280.0, 800.0), true, false, false, false, (868.0, 652.0)),
        ((1280.0, 800.0), false, false, true, false, (1168.0, 590.0)),
        ((1280.0, 800.0), false, false, false, true, (1168.0, 594.0)),
        ((1280.0, 800.0), false, true, false, true, (1168.0, 542.0)),
        ((900.0, 700.0), false, false, false, false, (788.0, 552.0)),
        ((390.0, 844.0), false, false, false, false, (278.0, 696.0)),
        ((390.0, 844.0), false, false, false, true, (278.0, 612.0)),
        ((390.0, 844.0), false, true, false, true, (278.0, 524.0)),
        ((859.0, 700.0), false, false, false, false, (747.0, 552.0)),
        ((860.0, 700.0), false, false, false, false, (748.0, 552.0)),
        ((861.0, 700.0), false, false, false, false, (749.0, 552.0)),
        ((831.0, 700.0), false, false, false, false, (719.0, 552.0)),
        ((832.0, 700.0), false, false, false, false, (720.0, 552.0)),
        ((833.0, 700.0), false, false, false, false, (721.0, 552.0)),
        ((1131.0, 700.0), true, false, false, false, (719.0, 552.0)),
        ((1132.0, 700.0), true, false, false, false, (720.0, 552.0)),
        ((1133.0, 700.0), true, false, false, false, (721.0, 552.0)),
    ];
    for (client, bookmarks, search, settings, more, expected) in available_cases {
        assert_eq!(
            super::reader::available_size(client, bookmarks, search, settings, more),
            expected,
            "available size at client {client:?} with contents={bookmarks} search={search} \
             typography={settings} more={more}"
        );
    }

    // (page index, page count, spread, visible 1-based pages): the pairing rule,
    // including the odd-final page that is shown alone and the clamp past the end.
    let pairing_cases: [(usize, usize, bool, &[usize]); 12] = [
        (0, 4, true, &[1, 2]),
        (1, 4, true, &[1, 2]),
        (2, 4, true, &[3, 4]),
        (3, 4, true, &[3, 4]),
        (0, 3, true, &[1, 2]),
        (2, 3, true, &[3]),
        (0, 1, true, &[1]),
        (1, 3, false, &[2]),
        (2, 3, false, &[3]),
        (9, 3, true, &[3]),
        (9, 3, false, &[3]),
        (0, 0, true, &[]),
    ];
    for (page, page_count, spread, expected) in pairing_cases {
        assert_eq!(
            super::reader::visible_for(page, page_count, spread),
            expected,
            "visible pages for page index {page} of {page_count} (spread {spread})"
        );
    }

    for scenario in super::reader::scenarios() {
        let facts = scenario
            .reader
            .as_ref()
            .unwrap_or_else(|| panic!("{} declares no reader facts", scenario.id));
        let (bookmarks, settings, more, search) = match &scenario.kind {
            super::scenarios::Kind::Reader(kind) => super::reader::panels_of_kind(*kind),
            _ => panic!("{} is not a reader capture", scenario.id),
        };
        let available =
            super::reader::available_size(scenario.client, bookmarks, search, settings, more);
        assert_eq!(
            (facts.available_width, facts.available_height),
            available,
            "{}: the declared available size is not the specification's arithmetic",
            scenario.id
        );
        if facts.mode == "continuous" {
            assert!(
                !facts.spread,
                "{}: a continuous reader forms no spread",
                scenario.id
            );
            assert!(
                facts.visible_pages.is_empty(),
                "{}: a continuous reader has no page pairing",
                scenario.id
            );
            continue;
        }
        let expected_spread = facts.page_count > 1 && available.0 >= 720.0;
        assert_eq!(
            facts.spread, expected_spread,
            "{}: the declared spread state is not the 720 px rule",
            scenario.id
        );
        if facts.page_count > 0 {
            let page = facts.location - 1;
            assert_eq!(
                facts.visible_pages,
                super::reader::visible_for(page, facts.page_count, facts.spread),
                "{}: the declared visible pages are not the pairing rule",
                scenario.id
            );
        }
    }
}

/// The breakpoint probes must exist at the exact widths the specification names.
#[test]
fn reader_breakpoint_probes_cover_both_boundaries() {
    let scenarios = super::reader::scenarios();
    let probe = |id: &str| {
        scenarios
            .iter()
            .find(|scenario| scenario.id == id)
            .unwrap_or_else(|| panic!("missing probe {id}"))
    };
    // `B860±`: compact chrome at 859, wide chrome at 860 and 861, height 700,
    // DPR 1, all panels closed. The derived available width is 747/748/749, all
    // above the 720 px spread threshold, so the spread persists across the
    // breakpoint.
    for (id, width) in [
        ("rd-chrome-b860-859-en", 747.0),
        ("rd-chrome-b860-860-en", 748.0),
        ("rd-chrome-b860-861-en", 749.0),
    ] {
        let scenario = probe(id);
        let facts = scenario.reader.as_ref().expect("facts");
        assert_eq!(scenario.client, (width + 112.0, 700.0));
        assert_eq!(scenario.dpr, 1.0);
        assert!(
            facts.panels.is_empty(),
            "{id}: the probes close every panel"
        );
        assert_eq!(facts.available_width, width);
        assert!(
            facts.spread,
            "{id}: the spread must persist across the reader breakpoint"
        );
    }
    // `B720±`: panels closed, client 831/832/833; the bookmarks panel open,
    // client 1131/1132/1133. Both reach available width 719/720/721, and the
    // page count changes once, at the threshold.
    for (closed, open, width) in [
        ("rd-spread-b720-831-en", "rd-spread-b720-1131-en", 719.0),
        ("rd-spread-b720-832-en", "rd-spread-b720-1132-en", 720.0),
        ("rd-spread-b720-833-en", "rd-spread-b720-1133-en", 721.0),
    ] {
        let closed = probe(closed);
        let closed_facts = closed.reader.as_ref().expect("facts");
        assert_eq!(closed.client, (width + 112.0, 700.0));
        assert_eq!(closed_facts.available_width, width);
        assert!(closed_facts.panels.is_empty());
        assert_eq!(
            closed_facts.spread,
            width >= 720.0,
            "{}: the threshold is 720 available pixels",
            closed.id
        );

        let open = probe(open);
        let open_facts = open.reader.as_ref().expect("facts");
        assert_eq!(open.client, (width + 112.0 + 300.0, 700.0));
        assert_eq!(open_facts.available_width, width);
        assert_eq!(open_facts.panels, vec!["contents".to_owned()]);
        assert_eq!(open_facts.spread, closed_facts.spread);
        assert_eq!(open_facts.page_count, closed_facts.page_count);
    }
}

/// The spread rows must cover the first spread, the last spread and an odd
/// final spread, each with the pairing the specification requires.
#[test]
fn reader_spread_rows_cover_first_last_and_odd_final() {
    let scenarios = super::reader::scenarios();
    let facts = |id: &str| {
        scenarios
            .iter()
            .find(|scenario| scenario.id == id)
            .unwrap_or_else(|| panic!("missing capture {id}"))
            .reader
            .clone()
            .expect("facts")
    };

    let first = facts("rd-spread-first-w1280-en");
    assert_eq!(first.visible_pages, vec![1, 2]);
    assert_eq!(first.location, 1);
    assert!(first.spread);

    let last = facts("rd-spread-last-w1280-en");
    assert_eq!(
        last.page_count % 2,
        0,
        "the last-spread capture is an even total"
    );
    assert_eq!(
        last.visible_pages,
        vec![last.page_count - 1, last.page_count],
        "an even total must end with a complete final spread"
    );

    let odd = facts("rd-spread-odd-final-w1280-en");
    assert_eq!(
        odd.page_count % 2,
        1,
        "the odd-final capture is an odd total"
    );
    assert_eq!(
        odd.visible_pages,
        vec![odd.page_count],
        "an odd total must end with exactly one page, never a repeated or blank one"
    );
    assert!(odd.spread, "the odd final spread keeps its spread mode");

    let narrow = facts("rd-spread-narrow-c390-en");
    assert!(!narrow.spread, "a narrow reader is single-page");
    assert_eq!(
        narrow.visible_pages,
        vec![1],
        "narrow single-page mode reserves no second slot"
    );

    for id in [
        "rd-spread-pdf-w1280-en",
        "rd-spread-pdf-last-w1280-en",
        "rd-spread-cbz-w1280-en",
    ] {
        let raster = facts(id);
        assert!(raster.spread, "{id}: a wide raster reader spreads");
        assert!(raster.visible_pages.len() <= 2, "{id}: at most two pages");
        assert!(
            raster.page_count > 1,
            "{id}: a spread needs more than one page"
        );
    }

    // The raster rows must cover both endings too: the last spread of an even
    // total is a complete pair, and the final spread of an odd total is one page.
    let raster_last = facts("rd-spread-pdf-last-w1280-en");
    assert_eq!(
        raster_last.page_count % 2,
        0,
        "the raster last-spread capture is an even total"
    );
    assert_eq!(
        raster_last.visible_pages,
        vec![raster_last.page_count - 1, raster_last.page_count],
        "an even raster total must end with a complete final spread"
    );

    let raster_odd = facts("rd-spread-cbz-w1280-en");
    assert_eq!(
        raster_odd.page_count % 2,
        1,
        "the raster odd-final capture is an odd total"
    );
    assert_eq!(
        raster_odd.visible_pages,
        vec![raster_odd.page_count],
        "an odd raster total must end with exactly one page, never a repeated or blank one"
    );
    assert!(
        raster_odd.spread,
        "the odd raster final spread keeps its spread mode"
    );
    assert_eq!(
        raster_odd.location, raster_odd.page_count,
        "the odd-final capture must be located on the last page"
    );
}

/// The declared page counts must be the counts the core paginator produces.
///
/// The capture table declares a page count per fixture and book font so the
/// runner can fail when a render reaches a different state. This test
/// re-paginates every paginated EPUB capture's fixture with
/// `crate::epub::paginate_document` at that capture's own layout size, which is
/// an independent path to the same number: a declaration that stopped matching
/// the renderer fails here.
#[test]
fn reader_fixture_page_counts_are_declared() {
    use shosai_core::epub::EpubDoc;

    let root = temp_root();
    let fixtures_root = root.path().join("fixtures");
    fixtures::write_reference_fixtures(&fixtures_root).expect("fixture tree");

    let mut checked = 0usize;
    for scenario in super::reader::scenarios() {
        let super::scenarios::Kind::Reader(kind) = scenario.kind else {
            continue;
        };
        let (fixture, font_size) = match kind {
            super::reader::ReaderKind::EpubPage { fixture, .. } => (fixture, 16.0),
            super::reader::ReaderKind::EpubContinuous { fixture, .. } => (fixture, 16.0),
            super::reader::ReaderKind::EpubLargeFont { fixture, font_size } => (fixture, font_size),
            super::reader::ReaderKind::Tabs { fixtures, .. } => (fixtures[0], 16.0),
            _ => continue,
        };
        let facts = scenario.reader.as_ref().expect("facts");
        let bytes = std::fs::read(seed::seed_path(&fixtures_root, fixture))
            .unwrap_or_else(|error| panic!("read {fixture}: {error}"));
        let document =
            EpubDoc::from_bytes(bytes).unwrap_or_else(|error| panic!("{fixture}: {error}"));
        let uses_spread = facts.spread;
        let page = crate::epub::page_size(
            crate::epub::LayoutSize::new(facts.available_width, facts.available_height),
            uses_spread,
            super::super::PAGE_GUTTER,
            font_size,
            1.6,
        );
        let pages = crate::epub::paginate_document(
            &document,
            font_size,
            1.6,
            crate::epub::LayoutSize::new(page.width, page.height),
        );
        assert_eq!(
            pages.len(),
            facts.page_count,
            "{}: {fixture} at a {font_size} px book font paginated to {} pages at available \
             {}x{} (spread {}), but the capture declares {}",
            scenario.id,
            pages.len(),
            facts.available_width,
            facts.available_height,
            facts.spread,
            facts.page_count
        );
        assert_eq!(
            pages.len(),
            super::reader::epub_page_count_at(fixture, font_size),
            "{}: the declared table disagrees with the paginator",
            scenario.id
        );
        checked += 1;
    }
    assert!(
        checked >= 10,
        "the page-count check must cover the paginated EPUB captures, saw {checked}"
    );
}

/// The raster page counts must come from the generated fixture bytes.
#[test]
fn reader_raster_page_counts_match_the_generated_fixtures() {
    let root = temp_root();
    let fixtures_root = root.path().join("fixtures");
    fixtures::write_reference_fixtures(&fixtures_root).expect("fixture tree");

    for fixture in [super::reader::PDF_FOUR, super::reader::PDF_TWO] {
        let bytes = std::fs::read(seed::seed_path(&fixtures_root, fixture)).expect("read pdf");
        let text = String::from_utf8_lossy(&bytes);
        let declared = super::reader::raster_page_count(fixture);
        assert!(
            text.contains(&format!("/Count {declared}")),
            "{fixture}: the generated PDF does not declare {declared} pages"
        );
        assert_eq!(
            text.matches("/Type /Page ").count(),
            declared,
            "{fixture}: the generated PDF does not carry {declared} page objects"
        );
    }
    for fixture in [super::reader::CBZ_TWELVE, super::reader::CBZ_THREE] {
        let bytes = std::fs::read(seed::seed_path(&fixtures_root, fixture)).expect("read cbz");
        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes)).expect("cbz archive");
        let pages = (0..archive.len())
            .filter(|index| {
                archive
                    .by_index(*index)
                    .map(|entry| {
                        let name = entry.name();
                        name.starts_with("page") && name.ends_with(".png")
                    })
                    .unwrap_or(false)
            })
            .count();
        assert_eq!(
            pages,
            super::reader::raster_page_count(fixture),
            "{fixture}: the generated CBZ does not carry the declared page count"
        );
    }
}

/// A package selection must be exact, and the two packages must not share
/// directories: the disposable root is deleted at the start of every run.
#[test]
fn package_selection_and_roots_are_disjoint() {
    assert_eq!(
        super::package::Package::ALL.map(|package| package.id()),
        ["1B", "1C"]
    );
    for package in super::package::Package::ALL {
        assert_ne!(
            package.default_output(),
            super::package::Package::ALL
                .iter()
                .filter(|other| **other != package)
                .map(|other| other.default_output())
                .next()
                .expect("the other package"),
            "{package:?} shares an evidence directory with the other package"
        );
        assert!(!package.default_data_root().is_empty());
        assert_ne!(
            package.default_data_root(),
            package.default_output(),
            "{package:?}: the data root and the evidence directory must not be the same"
        );
        for family in package.families() {
            assert!(!family.is_empty(), "{package:?} has an empty family");
        }
    }
    assert_eq!(
        super::package::Package::OneB.non_iced_authority(),
        Vec::<String>::new(),
        "package 1B records no non-Iced authority"
    );
    assert!(
        !super::package::Package::OneC
            .non_iced_authority()
            .is_empty(),
        "package 1C must record its non-Iced authority"
    );
}

/// The resolved roots of one package, as the entry point builds them.
fn package_roots(package: Package, output: PathBuf, data: PathBuf) -> super::package::PackageRoots {
    super::package::PackageRoots {
        package,
        data_spelling: data.clone(),
        output,
        data,
    }
}

/// Two packages must not resolve to overlapping roots.
///
/// The disposable root is deleted at the start of every run and the evidence
/// directory is pruned, so equal or nested locations would destroy each other's
/// state. The defaults are separate; this is what keeps a misconfigured override
/// from silently doing the same.
#[test]
fn package_roots_must_not_overlap() {
    let root = temp_root();
    let directory = |name: &str| root.path().join(name);
    let ok = vec![
        package_roots(
            Package::OneB,
            directory("evidence-1b"),
            directory("data-1b"),
        ),
        package_roots(
            Package::OneC,
            directory("evidence-1c"),
            directory("data-1c"),
        ),
    ];
    super::package::assert_roots_disjoint(&ok).expect("separate roots");

    let cases: [(&str, Vec<super::package::PackageRoots>); 4] = [
        (
            "the same evidence directory",
            vec![
                package_roots(Package::OneB, directory("shared"), directory("data-1b")),
                package_roots(Package::OneC, directory("shared"), directory("data-1c")),
            ],
        ),
        (
            "the same disposable root",
            vec![
                package_roots(Package::OneB, directory("evidence-1b"), directory("shared")),
                package_roots(Package::OneC, directory("evidence-1c"), directory("shared")),
            ],
        ),
        (
            "a nested evidence directory",
            vec![
                package_roots(Package::OneB, directory("evidence"), directory("data-1b")),
                package_roots(
                    Package::OneC,
                    directory("evidence/1c"),
                    directory("data-1c"),
                ),
            ],
        ),
        (
            "an evidence directory inside the other's data root",
            vec![
                package_roots(
                    Package::OneB,
                    directory("data-1c/evidence"),
                    directory("data-1b"),
                ),
                package_roots(
                    Package::OneC,
                    directory("evidence-1c"),
                    directory("data-1c"),
                ),
            ],
        ),
    ];
    for (name, roots) in cases {
        let error = super::package::assert_roots_disjoint(&roots)
            .expect_err(&format!("{name} must be refused"));
        assert!(
            error.to_string().contains("resolve to the same")
                || error.to_string().contains("have overlapping"),
            "{name}: the refusal must say why: {error}"
        );
    }
}

/// A data root must be cleared and written at the path the cross-package checks
/// approved, not at whatever its spelling resolves to later.
///
/// This is the alias case: the preflight resolves a spelling through a symlink
/// and approves the target, another package's preparation removes that link, and
/// re-resolving the same spelling would reach a directory no check covered. The
/// run must refuse instead of clearing the new target.
#[cfg(unix)]
#[test]
fn a_data_root_whose_resolution_changed_is_refused() {
    let root = temp_root();
    let first = root.path().join("first");
    let second = root.path().join("second");
    std::fs::create_dir_all(&first).expect("first directory");
    std::fs::create_dir_all(&second).expect("second directory");
    let parent = root.path().join("parent");
    std::os::unix::fs::symlink(&first, &parent).expect("symlinked parent");
    let spelling = parent.join("data");
    let output = root.path().join("evidence");

    // The preflight's value: the spelling resolved through the link.
    let approved = super::runner::resolve_path(&spelling).expect("resolve the spelling");
    assert_eq!(
        approved,
        std::fs::canonicalize(&first).expect("first").join("data"),
        "the approved path must be the link's target"
    );

    // The unchanged spelling is adopted and cleared at the approved path.
    let guard = super::runner::DisposableRoot::prepare_resolved(&spelling, &approved, &output)
        .expect("the approved root is adopted");
    let cleared = guard.path().to_path_buf();
    guard.finish(false).expect("finish the run");
    assert_eq!(
        cleared, approved,
        "the run must clear the path the preflight approved"
    );

    // Another package's preparation removes the link the resolution went
    // through and points the name at a different directory.
    std::fs::remove_file(&parent).expect("remove the link");
    std::os::unix::fs::symlink(&second, &parent).expect("repoint the link");

    let error = super::runner::DisposableRoot::prepare_resolved(&spelling, &approved, &output)
        .expect_err("a data root that no longer resolves to the approved path must be refused");
    assert!(
        error.to_string().contains("cross-package checks approved"),
        "{error:#}"
    );
    assert!(
        !second.join("data").exists(),
        "the unchecked directory must not be created or cleared"
    );
}

/// The ownership preflight must refuse a damaged or foreign marker instead of
/// treating it as permission to overwrite the directory.
#[cfg(unix)]
#[test]
fn package_ownership_preflight_refuses_damaged_and_foreign_markers() {
    let root = temp_root();
    let owned = root.path().join("owned");
    let fresh = root.path().join("fresh");
    std::fs::create_dir_all(&owned).expect("owned directory");
    std::fs::create_dir_all(&fresh).expect("fresh directory");
    let data = |name: &str| root.path().join(name);
    let roots = |output: &Path| {
        vec![package_roots(
            Package::OneC,
            output.to_path_buf(),
            data("data-1c"),
        )]
    };

    // A directory without a manifest is a fresh evidence directory.
    super::package::assert_evidence_belongs_to(&roots(&fresh))
        .expect("a fresh directory must pass");

    // The package's own marker passes; the other package's is refused.
    let manifest = owned.join("manifest.json");
    std::fs::write(&manifest, br#"{"package":"1C"}"#).expect("own marker");
    super::package::assert_evidence_belongs_to(&roots(&owned)).expect("its own marker passes");
    let foreign = vec![package_roots(Package::OneC, owned.clone(), data("data-1c"))];
    let mut foreign_manifest = std::fs::read(&manifest).expect("marker");
    foreign_manifest = String::from_utf8(foreign_manifest)
        .expect("utf-8")
        .replace("\"1C\"", "\"1B\"")
        .into_bytes();
    std::fs::write(&manifest, foreign_manifest).expect("foreign marker");
    let error = super::package::assert_evidence_belongs_to(&foreign)
        .expect_err("1C must not claim 1B's evidence directory");
    assert!(
        error
            .to_string()
            .contains("already holds package 1B's evidence"),
        "{error:#}"
    );

    // Malformed JSON and a missing owner are refusals, not permission.
    std::fs::write(&manifest, b"{ not json").expect("malformed marker");
    let error = super::package::assert_evidence_belongs_to(&roots(&owned))
        .expect_err("a malformed marker must fail");
    assert!(
        error.to_string().contains("parse the existing"),
        "{error:#}"
    );
    std::fs::write(&manifest, br#"{"captures":[]}"#).expect("ownerless marker");
    let error = super::package::assert_evidence_belongs_to(&roots(&owned))
        .expect_err("a marker without an owner must fail");
    assert!(
        error.to_string().contains("no `package` field"),
        "{error:#}"
    );

    // A symlink is refused without being followed, and a FIFO without being
    // opened (opening one with no writer would block the entry point).
    std::fs::write(&manifest, br#"{"package":"1C"}"#).expect("marker");
    let linked = root.path().join("linked");
    std::fs::create_dir_all(&linked).expect("linked directory");
    std::os::unix::fs::symlink(&manifest, linked.join("manifest.json")).expect("symlink marker");
    let error = super::package::assert_evidence_belongs_to(&roots(&linked))
        .expect_err("a symlinked marker must fail");
    assert!(error.to_string().contains("is a symlink"), "{error:#}");

    let fifo = root.path().join("fifo");
    std::fs::create_dir_all(&fifo).expect("fifo directory");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(fifo.join("manifest.json"))
            .status()
            .expect("run mkfifo")
            .success(),
        "mkfifo failed"
    );
    let fifo_roots = roots(&fifo);
    let error = run_bounded(move || super::package::assert_evidence_belongs_to(&fifo_roots))
        .expect_err("a FIFO marker must fail rather than block");
    assert!(
        error.to_string().contains("not a regular file"),
        "{error:#}"
    );
}

/// The reader captures must pass the shared interface-language check.
///
/// The reader has its own `assert_reached`, so the shared check has to run
/// before the delegation; otherwise a Japanese reader capture could render an
/// English interface and still be written. The negative control runs the whole
/// check against a Japanese reader scenario and an English state and requires
/// the interface-language failure, which also proves the reader delegation was
/// not reached first.
#[test]
fn reader_captures_must_reach_their_interface_language() {
    let state = super::runner::fresh_state();
    let japanese = super::reader::scenarios()
        .into_iter()
        .find(|scenario| scenario.locale == super::scenarios::Locale::Ja)
        .expect("a Japanese reader capture");
    let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        super::scenarios::assert_reached(&japanese, &state);
    }))
    .expect_err("an English state must not pass a Japanese reader capture");
    let message = panic
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| panic.downcast_ref::<&str>().map(|text| (*text).to_owned()))
        .unwrap_or_default();
    assert!(
        message.contains("expected the Japanese interface"),
        "the failure must be the interface-language check, not a later one: {message}"
    );

    // The positive control: the same helper accepts a state that resolved the
    // language an English reader capture records.
    let english = super::reader::scenarios()
        .into_iter()
        .find(|scenario| scenario.locale == super::scenarios::Locale::En)
        .expect("an English reader capture");
    let mut english_state = super::runner::fresh_state();
    english_state.i18n = crate::i18n::I18n::new(crate::i18n::LanguagePreference::English);
    super::scenarios::assert_interface_locale(&english, &english_state);
}

/// The zoom the manifest records must be the zoom the production messages reach.
///
/// The declaration test above only checks the table; this drives the fit-width
/// and fit-page captures through the same production messages the capture run
/// uses and reads the observed facts, so removing the `SetZoomFitWidth` dispatch
/// or changing the observer fails here.
#[tokio::test]
async fn the_fit_mode_captures_reach_their_recorded_zoom() {
    let root = temp_root();
    let data_root = root.path().join("data");
    let fixtures_root = data_root.join("fixtures");
    fixtures::write_reference_fixtures(&fixtures_root).expect("fixture tree");
    let seeded = seed::seed_library(&data_root.join("seeded"), &fixtures_root)
        .await
        .expect("seeded library");

    let scenarios = super::reader::scenarios();
    let capture = |id: &str| {
        scenarios
            .iter()
            .find(|scenario| scenario.id == id)
            .unwrap_or_else(|| panic!("missing capture {id}"))
            .clone()
    };

    for (id, expected) in [
        ("rd-pdf-fit-width-w1280-en", "fit-width"),
        ("rd-pdf-pag-w1280-en", "fit-page"),
        ("rd-cbz-pag-w1280-en", "fit-page"),
    ] {
        let scenario = capture(id);
        let mut harness = super::runner::base_harness(Some(&seeded), Package::OneC)
            .await
            .expect("capture harness");
        super::runner::apply_window(&scenario, &mut harness);
        super::scenarios::apply(&scenario, &mut harness, &fixtures_root, &data_root)
            .await
            .unwrap_or_else(|error| panic!("{id}: {error:#}"));
        let observed = super::reader::observe(&harness.state);
        assert_eq!(observed.zoom, expected, "{id}: the reached zoom mode");
        assert_eq!(
            scenario.reader.as_ref().expect("facts"),
            &observed,
            "{id}: the declaration must equal the state the messages reached"
        );
    }

    // A latent zoom on a state where it is not a reader fact: an EPUB reflows,
    // and a state that has not opened its document yet has no page to scale.
    // Both must observe `n/a` even when the state carries a non-default zoom.
    // The file-removal captures are deliberately not used here: their
    // `locate_book` compares canonical paths, and a removed file cannot be
    // canonicalized, which is part of why the capture run itself is Linux-only.
    for id in ["rd-epub-pag-w1280-en", "rd-chrome-opening-w900-en"] {
        let scenario = capture(id);
        let mut harness = super::runner::base_harness(Some(&seeded), Package::OneC)
            .await
            .expect("capture harness");
        super::runner::apply_window(&scenario, &mut harness);
        super::scenarios::apply(&scenario, &mut harness, &fixtures_root, &data_root)
            .await
            .unwrap_or_else(|error| panic!("{id}: {error:#}"));
        harness.state.zoom = crate::pdf::ZoomMode::Manual(2.0);
        assert_eq!(
            super::reader::observe(&harness.state).zoom,
            super::reader::ZOOM_NOT_APPLICABLE,
            "{id}: a state without a raster document records no zoom fact"
        );
    }
}

/// A partially covered row must be a captured row, name its captures, and carry
/// the same reason the matrix records.
#[test]
fn partially_covered_rows_are_captured_and_explained() {
    let matrix = super::runner::matrix(Package::OneC);
    let captures = super::reader::scenarios();
    for (row, reason) in super::reader::CAPTURED_PARTIAL {
        assert!(
            reason.starts_with("partial:"),
            "{row}: the reason must say the coverage is partial"
        );
        let covered = matrix
            .captured
            .iter()
            .find(|coverage| coverage.row == row)
            .unwrap_or_else(|| {
                panic!("{row} is recorded as partially covered but is not a captured row")
            });
        assert!(
            !covered.captures.is_empty(),
            "{row}: a captured row must name at least one capture"
        );
        assert_eq!(
            covered.reason, reason,
            "{row}: the built matrix must carry the recorded reason"
        );
        for id in &covered.captures {
            assert!(
                captures.iter().any(|scenario| scenario.id == id),
                "{row} names {id}, which is not a capture"
            );
        }
    }

    // The intended set, pinned by name: a row that stops being partial, or a
    // partial row that is not recorded, fails here rather than drifting.
    assert_eq!(
        super::reader::CAPTURED_PARTIAL.map(|(row, _)| row),
        ["FM-01", "FM-02", "FM-13", "RD-06"]
    );
    // `FM-13`'s reason names the captures it counts on, and each must really
    // carry the row.
    let fm13 = matrix
        .captured
        .iter()
        .find(|coverage| coverage.row == "FM-13")
        .expect("FM-13 is a captured row");
    for id in [
        "rd-spread-pdf-w1280-en",
        "rd-pdf-fit-width-w1280-en",
        "rd-spread-cbz-w1280-en",
        "rd-cbz-pag-w1280-en",
    ] {
        assert!(
            fm13.captures.iter().any(|capture| capture == id),
            "FM-13's reason names {id}, which must carry the row: {:?}",
            fm13.captures
        );
    }

    // The generated limitations must repeat every gap, because that is the
    // artefact a reviewer reads without opening the matrix.
    let limitations = super::reader::limitations(true).join("\n");
    for (row, _) in super::reader::CAPTURED_PARTIAL {
        assert!(
            limitations.contains(row),
            "the known limitations must name the partial row {row}"
        );
    }
    // Each qualification the matrix reasons make must appear there too, so the
    // standalone section cannot silently lose one of them.
    for qualification in [
        "no CBZ fit-width capture",
        "not manual raster zoom",
        "panics the Iced reader",
        "hover stays with 4B",
    ] {
        assert!(
            limitations.contains(qualification),
            "the known limitations must repeat {qualification:?}"
        );
    }

    // Package 1B has no partial rows, and no 1B capture may carry a reason.
    assert!(Package::OneB.captured_reasons().is_empty());
    assert!(
        super::runner::matrix(Package::OneB)
            .captured
            .iter()
            .all(|coverage| coverage.reason.is_empty()),
        "package 1B's captured rows record no partial coverage"
    );
}

/// The raster zoom mode must be recorded, and the fit-width capture must select
/// it through the production message rather than being declared into existence.
#[test]
fn reader_zoom_modes_are_recorded() {
    use super::reader::{RasterZoom, ReaderKind};

    assert_eq!(RasterZoom::FitPage.stored(), "fit-page");
    assert_eq!(RasterZoom::FitWidth.stored(), "fit-width");

    let scenarios = super::reader::scenarios();
    let fit_width = scenarios
        .iter()
        .find(|scenario| scenario.id == "rd-pdf-fit-width-w1280-en")
        .expect("the fit-width capture");
    assert_eq!(fit_width.reader.as_ref().expect("facts").zoom, "fit-width");
    match fit_width.kind {
        super::scenarios::Kind::Reader(ReaderKind::RasterPage { zoom, .. }) => {
            assert_eq!(zoom, RasterZoom::FitWidth);
        }
        other => panic!("the fit-width capture must be a raster page, not {other:?}"),
    }

    let mut defaulted = 0usize;
    for scenario in &scenarios {
        let facts = scenario.reader.as_ref().expect("facts");
        assert!(
            matches!(facts.zoom.as_str(), "fit-page" | "fit-width" | "n/a")
                || facts.zoom.starts_with("manual("),
            "{}: the recorded zoom is not a mode the state can carry",
            scenario.id
        );
        if scenario.id == "rd-pdf-fit-width-w1280-en" {
            continue;
        }
        // Every other capture is either a raster page at the application
        // default or a state where the zoom does not apply.
        let raster = matches!(
            scenario.kind,
            super::scenarios::Kind::Reader(ReaderKind::RasterPage { .. })
                | super::scenarios::Kind::Reader(ReaderKind::RasterContinuous { .. })
        );
        assert_eq!(
            facts.zoom,
            if raster { "fit-page" } else { "n/a" },
            "{}: only the fit-width capture changes the zoom mode",
            scenario.id
        );
        defaulted += 1;
    }
    assert!(
        defaulted >= 45,
        "expected the rest of the capture table to record a zoom, checked {defaulted}"
    );
}

/// Reader state a capture can persist must not leak into the next capture.
///
/// The application persists reading positions and saved places, and the reader
/// captures turn pages and save places. Without the reset a capture that
/// navigated to page 4 would decide where the next capture of the same book
/// opens, so this pins the reset against a real store.
#[tokio::test]
async fn reader_state_reset_clears_bookmarks_and_reading_state() {
    let root = temp_root();
    let store = seed::open_store(root.path()).await.expect("store");
    let library =
        shosai_core::library::Library::new(store.pool().clone(), store.managed_books_dir());
    let path = root.path().join("book.epub");
    std::fs::write(
        &path,
        include_bytes!("../../../../shosai-core/tests/fixtures/sample.epub"),
    )
    .expect("write a book");
    let book = library.import_file(&path).await.expect("import");
    let bookmarks = shosai_core::bookmarks::BookmarkStore::new(store.pool().clone());
    bookmarks
        .add_async(
            &path,
            &"0".repeat(64),
            0,
            Some("title"),
            Some("note"),
            "accent",
        )
        .await
        .expect("save a place");
    store
        .set_for_book_async(
            book.id,
            &shosai_core::reading_state::FileReadingState {
                page: 3,
                location_offset: Some(0),
                zoom: 1.0,
            },
        )
        .await
        .expect("save a reading position");
    assert!(
        !bookmarks
            .list_for_file_async(&path, &"0".repeat(64))
            .await
            .expect("list")
            .is_empty()
    );
    assert!(
        store
            .get_for_book_async(book.id)
            .await
            .expect("read state")
            .is_some()
    );

    seed::reset_capture_reader_state(&store)
        .await
        .expect("reset");

    assert!(
        bookmarks
            .list_for_file_async(&path, &"0".repeat(64))
            .await
            .expect("list")
            .is_empty(),
        "the reset must clear every saved place"
    );
    assert!(
        store
            .get_for_book_async(book.id)
            .await
            .expect("read state")
            .is_none(),
        "the reset must clear every reading position"
    );
}

/// The reader panels are mutually exclusive in the production handlers.
///
/// `RD-13` is a behavioral row, so this drives the production messages and
/// checks the flags rather than comparing two images that would show the same
/// state: opening the `Aa` panel closes the Contents panel and the `⋯` panel,
/// and vice versa.
#[tokio::test]
async fn reader_panels_are_mutually_exclusive() {
    let root = temp_root();
    let fixtures_root = root.path().join("fixtures");
    fixtures::write_reference_fixtures(&fixtures_root).expect("fixtures");
    let data = root.path().join("data");
    let seeded = seed::seed_library(&data.join("seeded"), &fixtures_root)
        .await
        .expect("seed");
    let initialized = seed::capture_initialized_state(seeded.store.clone())
        .await
        .expect("initialized");
    let mut harness = Harness::new(super::runner::fresh_state());
    harness
        .dispatch(Message::Initialized(Ok(initialized)))
        .await;
    let (book_id, key) =
        super::reader::locate_book(&harness.state, &fixtures_root, super::reader::EPUB_EVEN)
            .expect("locate");
    harness
        .dispatch(Message::OpenLibraryBook(book_id, key))
        .await;

    let flags = |state: &crate::app::State| {
        (
            state.show_bookmarks_panel,
            state.show_reader_settings,
            state.show_reader_more,
            state.show_search_bar,
        )
    };
    assert_eq!(flags(&harness.state), (false, false, false, false));

    harness.dispatch(Message::ToggleBookmarksPanel).await;
    assert_eq!(flags(&harness.state), (true, false, false, false));
    harness.dispatch(Message::ToggleReaderSettings).await;
    assert_eq!(
        flags(&harness.state),
        (false, true, false, false),
        "opening the typography panel must close the contents panel"
    );
    harness.dispatch(Message::ToggleReaderMore).await;
    assert_eq!(
        flags(&harness.state),
        (false, false, true, false),
        "opening the more panel must close the typography panel"
    );
    harness.dispatch(Message::ToggleBookmarksPanel).await;
    assert_eq!(
        flags(&harness.state),
        (true, false, false, false),
        "opening the contents panel must close the more panel"
    );
    // The search bar is not part of the mutually exclusive set the row names
    // (settings, more, bookmarks): it is a bar below the panels and stays open
    // beside the contents panel, which is what the production handler does.
    harness.dispatch(Message::ToggleSearchBar).await;
    assert_eq!(
        flags(&harness.state),
        (true, false, false, true),
        "the search bar is a bar, not one of the mutually exclusive panels"
    );
    harness.dispatch(Message::ToggleReaderSettings).await;
    assert_eq!(
        flags(&harness.state),
        (false, true, false, true),
        "opening the typography panel must close the contents panel"
    );
}

/// The committed PNGs must carry the application's colors, not swapped ones.
///
/// `iced_tiny_skia` renders into a `BGRA` byte order that the window compositor
/// unpacks for `softbuffer`; a `tiny_skia::Pixmap` encoded as RGBA would record
/// every pixel with red and blue exchanged, which turns the application accent
/// `#4D5E86` into the brown `#865E4D`. This renders the production library view
/// and checks the two palette colors the frame must contain against the token
/// values themselves, so a channel-order regression fails here rather than in a
/// reviewer's eyes.
#[test]
fn rendered_pixels_carry_the_application_colors() {
    use super::render::{FrameOutcome, MAX_REDRAW_EVENTS};

    super::render::install_application_fonts();
    let state = super::runner::fresh_state();
    let mut cache = iced_runtime::user_interface::Cache::new();
    let mut image = None;
    for _ in 0..MAX_REDRAW_EVENTS {
        match super::render::render_frame(&state, 320.0, 200.0, 1.0, cache) {
            FrameOutcome::Settled(rendered) => {
                image = Some(rendered);
                break;
            }
            FrameOutcome::Requests(_, next_cache) => cache = next_cache,
        }
    }
    let image = image.expect("the fresh library state must settle within one frame round");
    let decoded = image::load_from_memory(&image.png)
        .expect("decode the capture PNG")
        .to_rgba8();

    let channels = |color: iced::Color| {
        [
            (color.r * 255.0).round() as u8,
            (color.g * 255.0).round() as u8,
            (color.b * 255.0).round() as u8,
        ]
    };
    let surface = channels(crate::theme::SURFACE);
    let background = channels(crate::theme::APP_BACKGROUND);

    let top_left = decoded.get_pixel(0, 0).0;
    assert_eq!(
        [top_left[0], top_left[1], top_left[2]],
        surface,
        "the header surface must be recorded as {surface:?}, not as its channel-swapped form"
    );
    let found_background = decoded
        .pixels()
        .any(|pixel| [pixel.0[0], pixel.0[1], pixel.0[2]] == background);
    assert!(
        found_background,
        "the application background {background:?} must appear in the frame exactly as specified"
    );
    assert!(
        surface[0] > surface[2] && background[0] > background[2],
        "the check is only meaningful while these tokens have red above blue"
    );
}

/// The revision note must name a Jujutsu command that actually works.
///
/// The manifest and the README tell an accepting package how to map
/// `capture_code_change_id` back to a commit. A note naming a revset function
/// that does not exist (`change(<id>)`) is a documentation defect that only a
/// reader would discover, so this checks the text and then runs the command the
/// note names under the Jujutsu on this machine, together with the negative
/// control for the form the note must not use.
#[test]
fn recorded_revision_lookup_is_a_real_jujutsu_command() {
    let note = super::runner::REVISION_NOTE;
    assert!(
        note.contains("change_id(<id>)"),
        "the revision note must name the change_id() revset function: {note}"
    );
    assert!(
        !note.contains("'change(<id>)'"),
        "the revision note must not name `change(<id>)`, which is not a Jujutsu revset function"
    );

    let jj = |args: &[&str]| {
        std::process::Command::new("jj")
            .args(args)
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    };
    let Some(change_id) = jj(&["log", "--no-graph", "-r", "@", "-T", "change_id"]) else {
        // The capture entry point requires `jj`; an ordinary `cargo test` on a
        // machine without it still checks the note's text above.
        eprintln!("skipping the execution half: no working `jj` on this machine");
        return;
    };
    let revset = format!("change_id({change_id})");
    let resolved = jj(&[
        "log",
        "--no-graph",
        "-r",
        &revset,
        "-T",
        "commit_id.short() ++ \" \" ++ description.first_line()",
    ])
    .unwrap_or_else(|| panic!("the command the revision note names failed: jj log -r '{revset}'"));
    assert!(
        resolved
            .split_whitespace()
            .next()
            .is_some_and(|id| id.len() >= 7),
        "the resolved revision must start with a commit id: {resolved:?}"
    );

    // Negative control: the form the note must not name is not a revset function.
    let invalid = std::process::Command::new("jj")
        .args([
            "log",
            "--no-graph",
            "-r",
            &format!("change({change_id})"),
            "-T",
            "commit_id",
        ])
        .output()
        .expect("run jj");
    assert!(
        !invalid.status.success(),
        "`change(<id>)` unexpectedly resolved; the note's warning is stale"
    );
    assert!(
        String::from_utf8_lossy(&invalid.stderr).contains("doesn't exist"),
        "the negative control must fail because the function does not exist: {}",
        String::from_utf8_lossy(&invalid.stderr)
    );
}
