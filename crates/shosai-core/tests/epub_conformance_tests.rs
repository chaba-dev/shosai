use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

use roxmltree::{Document, Node};
use sha2::{Digest, Sha256};
use shosai_core::epub::{CanonicalEpubPath, EpubDoc, EpubLimits};
use zip::{CompressionMethod, ZipArchive};

const FIXTURE_IDS: &[&str] = &[
    "nested-image",
    "css-cascade",
    "table",
    "fonts",
    "fonts-isolation",
    "mathml",
    "bidi",
    "links",
    "malformed-markup",
    "canonical-paths",
    "remote-content",
    "resource-limits",
    "conformance",
];

const OPEN_FIXTURE_IDS: &[&str] = &[
    "nested-image",
    "css-cascade",
    "table",
    "fonts",
    "fonts-isolation",
    "mathml",
    "bidi",
    "links",
    "malformed-markup",
    "canonical-paths",
    "remote-content",
    "conformance",
];

const REJECTION_FIXTURES: &[(&str, &str)] = &[
    ("resource-limits", "huge.svg"),
    ("missing-spine-resource", "failed to read chapter"),
    ("duplicate-entries", "duplicate EPUB archive entry"),
];

const EXTRA_FIXTURE_IDS: &[&str] = &["missing-spine-resource", "duplicate-entries"];

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/epub-conformance")
}

fn repository_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("shosai-core must be inside the workspace crates directory")
        .to_path_buf()
}

fn fixture_path(id: &str) -> PathBuf {
    fixture_dir().join(format!("{id}.epub"))
}

fn open(id: &str) -> EpubDoc {
    EpubDoc::open(fixture_path(id)).unwrap_or_else(|error| panic!("{id}: {error:#}"))
}

fn generate_fixtures(output: &Path, extra_args: &[&str]) {
    let generator = fixture_dir().join("generate.py");
    for python in ["python3", "python"] {
        match Command::new(python)
            .arg(&generator)
            .arg("--output")
            .arg(output)
            .args(extra_args)
            .status()
        {
            Ok(status) => {
                assert!(status.success(), "{python} fixture generation failed");
                return;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => panic!("failed to run {python}: {error}"),
        }
    }
    panic!("Python is required to verify fixture generation");
}

fn resource_bytes<'a>(doc: &'a EpubDoc, path: &str) -> Option<&'a [u8]> {
    doc.resource(path).map(|resource| resource.bytes())
}

fn archive_entry(id: &str, path: &str) -> String {
    String::from_utf8(archive_bytes(id, path)).unwrap()
}

fn archive_bytes(id: &str, path: &str) -> Vec<u8> {
    let file = std::fs::File::open(fixture_path(id)).unwrap();
    let mut archive = ZipArchive::new(file).unwrap();
    let mut content = Vec::new();
    archive
        .by_name(path)
        .unwrap()
        .read_to_end(&mut content)
        .unwrap();
    content
}

fn chapter_document(doc: &EpubDoc, index: usize) -> Document<'_> {
    Document::parse(&doc.chapter(index).expect("missing chapter").content)
        .expect("fixture chapter must be well-formed XHTML")
}

fn by_id<'a, 'input>(document: &'a Document<'input>, id: &str) -> Node<'a, 'input> {
    document
        .descendants()
        .find(|node| node.attribute("id") == Some(id))
        .unwrap_or_else(|| panic!("fixture is missing #{id}"))
}

fn elements_named<'a, 'input>(
    document: &'a Document<'input>,
    name: &'static str,
) -> impl Iterator<Item = Node<'a, 'input>> {
    document
        .descendants()
        .filter(move |node| node.is_element() && node.tag_name().name() == name)
}

fn has_class(node: Node<'_, '_>, expected: &str) -> bool {
    node.attribute("class").is_some_and(|classes| {
        classes
            .split_ascii_whitespace()
            .any(|class| class == expected)
    })
}

#[test]
fn complete_fixture_matrix_opens_with_stable_metadata() {
    for id in OPEN_FIXTURE_IDS {
        let doc = open(id);
        assert!(doc.chapter_count() > 0, "{id} has no spine chapters");
        assert_eq!(
            doc.content.metadata.title.as_deref(),
            Some(format!("Shosai Conformance: {id}").as_str()),
            "{id} title drifted"
        );
        assert_eq!(
            doc.content.metadata.author.as_deref(),
            Some("Shosai contributors")
        );
        assert_eq!(doc.toc().len(), doc.chapter_count(), "{id} TOC drifted");
    }
}

#[test]
fn nested_image_fixture_preserves_each_image_context() {
    let doc = open("nested-image");
    let chapter = chapter_document(&doc, 0);
    let paragraph = by_id(&chapter, "paragraph-image");
    assert!(
        paragraph
            .descendants()
            .any(|node| node.tag_name().name() == "img")
    );
    let figure = by_id(&chapter, "figure");
    assert!(
        figure
            .children()
            .any(|node| node.tag_name().name() == "figcaption")
    );
    assert!(
        by_id(&chapter, "cell-image")
            .ancestors()
            .any(|node| node.tag_name().name() == "td")
    );
    assert_eq!(
        by_id(&chapter, "missing-image").attribute("alt"),
        Some("Missing image fallback")
    );
    assert!(doc.resource("OEBPS/Images/pixel.png").is_some());
}

#[test]
fn cascade_and_table_fixtures_expose_semantic_oracles() {
    let cascade_doc = open("css-cascade");
    let cascade = chapter_document(&cascade_doc, 0);
    assert_eq!(
        by_id(&cascade, "specific").attribute("style"),
        Some("font-weight: 700")
    );
    let css = std::str::from_utf8(
        resource_bytes(&cascade_doc, "OEBPS/Styles/book.css").expect("missing cascade CSS"),
    )
    .unwrap();
    for marker in [
        "!important",
        ".chapter p.important",
        ".inherited { font-style: italic; }",
        ".source-order { color: #111111; }",
        ".source-order { color: #222222; }",
        "section.inherited > p",
        "display: none",
    ] {
        assert!(css.contains(marker), "cascade CSS is missing {marker}");
    }
    assert!(
        by_id(&cascade, "inherited")
            .parent()
            .is_some_and(|parent| has_class(parent, "inherited"))
    );
    assert!(!has_class(by_id(&cascade, "inherited"), "inherited"));
    assert!(has_class(by_id(&cascade, "source-order"), "source-order"));
    let first_source_order = css.find(".source-order { color: #111111; }").unwrap();
    let winning_source_order = css.find(".source-order { color: #222222; }").unwrap();
    assert!(first_source_order < winning_source_order);

    let table_doc = open("table");
    let table = chapter_document(&table_doc, 0);
    assert_eq!(
        by_id(&table, "spanning-table")
            .descendants()
            .filter(|node| node.tag_name().name() == "caption")
            .count(),
        1
    );
    assert!(elements_named(&table, "td").any(|node| node.attribute("colspan") == Some("2")));
    assert!(elements_named(&table, "th").any(|node| node.attribute("rowspan") == Some("2")));
    assert!(elements_named(&table, "td").any(|node| {
        node.descendants()
            .any(|child| child.tag_name().name() == "img")
    }));
    assert_eq!(
        elements_named(&table, "a")
            .next()
            .unwrap()
            .attribute("href"),
        Some("#spanning-table")
    );
}

#[test]
fn font_and_math_fixtures_cover_declared_formats_and_fallbacks() {
    let fonts = open("fonts");
    for (path, signature) in [
        ("OEBPS/Fonts/book-a.woff", b"wOFF".as_slice()),
        ("OEBPS/Fonts/book-a.woff2", b"wOF2".as_slice()),
    ] {
        assert!(
            resource_bytes(&fonts, path)
                .expect("missing font")
                .starts_with(signature)
        );
    }
    assert_eq!(
        &resource_bytes(&fonts, "OEBPS/Fonts/book-a.ttf").unwrap()[..4],
        &[0, 1, 0, 0]
    );
    assert_eq!(
        resource_bytes(&fonts, "OEBPS/Fonts/book-a.otf")
            .unwrap()
            .get(..4),
        Some(b"OTTO".as_slice())
    );
    assert!(fonts.resource("OEBPS/Fonts/missing.woff2").is_none());
    assert_eq!(
        resource_bytes(&fonts, "OEBPS/Fonts/corrupt.woff2"),
        Some(b"not a font".as_slice())
    );
    let font_css =
        std::str::from_utf8(resource_bytes(&fonts, "OEBPS/Styles/fonts.css").unwrap()).unwrap();
    assert!(
        font_css.contains("src: url('../Fonts/book-a.ttf') format('truetype'); font-weight: 700;")
    );
    assert!(
        font_css
            .contains("src: url('../Fonts/book-a.ttf') format('truetype'); font-style: italic;")
    );
    let font_chapter = chapter_document(&fonts, 0);
    assert!(has_class(by_id(&font_chapter, "bold-font"), "bold"));
    assert!(has_class(by_id(&font_chapter, "italic-font"), "italic"));
    assert!(font_css.contains(".bold { font-family: FixtureTtf; font-weight: 700; }"));
    assert!(font_css.contains(".italic { font-family: FixtureTtf; font-style: italic; }"));

    let isolated_fonts = open("fonts-isolation");
    let book_a = resource_bytes(&fonts, "OEBPS/Fonts/book-a.ttf").unwrap();
    let book_b = resource_bytes(&isolated_fonts, "OEBPS/Fonts/book-b.ttf").unwrap();
    assert_ne!(book_a, book_b);
    let isolated_css =
        std::str::from_utf8(resource_bytes(&isolated_fonts, "OEBPS/Styles/fonts.css").unwrap())
            .unwrap();
    assert!(isolated_css.contains("font-family: FixtureTtf"));
    assert!(isolated_css.contains("src: url('../Fonts/book-b.ttf') format('truetype')"));
    assert!(!isolated_css.contains("book-a.ttf"));
    let isolated_chapter = chapter_document(&isolated_fonts, 0);
    assert!(has_class(by_id(&isolated_chapter, "isolated-font"), "ttf"));

    let math = open("mathml");
    let chapter = chapter_document(&math, 0);
    for id in [
        "fraction",
        "display-root",
        "scripts",
        "matrix",
        "annotated",
        "malformed-fallback",
    ] {
        assert_eq!(
            by_id(&chapter, id).tag_name().namespace(),
            Some("http://www.w3.org/1998/Math/MathML")
        );
    }
    assert!(elements_named(&chapter, "annotation").any(|node| node.text() == Some("\\pi")));
    assert!(elements_named(&chapter, "mo").any(|node| node.text() == Some("+")));
}

#[test]
fn bidi_and_link_fixtures_retain_logical_source_contracts() {
    let bidi = open("bidi");
    let chapter = chapter_document(&bidi, 0);
    assert_eq!(by_id(&chapter, "hebrew").attribute("dir"), Some("rtl"));
    assert_eq!(by_id(&chapter, "arabic").attribute("lang"), Some("ar"));
    let mixed = by_id(&chapter, "mixed").text().unwrap();
    for marker in ["Latin", "العربية", "עברית", "日本語", "😀"] {
        assert!(mixed.contains(marker));
    }

    let links = open("links");
    let chapter = chapter_document(&links, 0);
    let expected = [
        ("same", "#local"),
        ("cross", "chapter-2.xhtml#target"),
        ("encoded", "chapter%2D2.xhtml#percent-target"),
        ("https", "https://example.invalid/book"),
        ("mail", "mailto:reader@example.invalid"),
        ("unsupported", "custom:blocked"),
    ];
    for (id, href) in expected {
        assert_eq!(by_id(&chapter, id).attribute("href"), Some(href));
    }
    let encoded = by_id(&chapter, "encoded").attribute("href").unwrap();
    let resolved = CanonicalEpubPath::resolve("OEBPS/Text", encoded).unwrap();
    assert_eq!(resolved.path.as_str(), "OEBPS/Text/chapter-2.xhtml");
    assert_eq!(resolved.fragment.as_deref(), Some("percent-target"));
    let targets = chapter_document(&links, 1);
    assert!(
        targets
            .descendants()
            .any(|node| node.attribute("id") == Some("target"))
    );
    assert!(
        targets
            .descendants()
            .any(|node| node.attribute("id") == resolved.fragment.as_deref())
    );
}

#[test]
fn epub3_manifest_declares_content_properties() {
    for (fixture, href, expected) in [
        ("mathml", "Text/chapter-1.xhtml", &["mathml"][..]),
        (
            "remote-content",
            "Text/chapter-1.xhtml",
            &["remote-resources", "scripted"][..],
        ),
        ("conformance", "Text/chapter-5.xhtml", &["mathml"][..]),
    ] {
        let opf = archive_entry(fixture, "OEBPS/package.opf");
        let document = Document::parse(&opf).unwrap();
        let item = document
            .descendants()
            .find(|node| node.tag_name().name() == "item" && node.attribute("href") == Some(href))
            .unwrap_or_else(|| panic!("{fixture} is missing manifest item {href}"));
        let properties = item
            .attribute("properties")
            .unwrap_or("")
            .split_ascii_whitespace()
            .collect::<Vec<_>>();
        for property in expected {
            assert!(
                properties.contains(property),
                "{fixture}:{href} is missing EPUB property {property}"
            );
        }
    }
}

#[test]
fn hostile_and_failure_fixtures_are_isolated_and_actionable() {
    let malformed = open("malformed-markup");
    assert!(Document::parse(&malformed.chapter(0).unwrap().content).is_err());
    let readable = chapter_document(&malformed, 1);
    assert!(
        by_id(&readable, "readable-sibling")
            .descendants()
            .filter_map(|node| node.text())
            .any(|text| text.contains("Readable sibling"))
    );
    assert!(malformed.resource("OEBPS/Styles/malformed.css").is_some());
    assert!(by_id(&readable, "deep-nesting").descendants().count() >= 16);

    let canonical = open("canonical-paths");
    let chapter = chapter_document(&canonical, 0);
    for id in [
        "dot",
        "parent",
        "encoded-traversal",
        "query",
        "absolute",
        "foreign",
        "case-variant",
    ] {
        by_id(&chapter, id);
    }
    for id in ["dot", "parent"] {
        let href = by_id(&chapter, id).attribute("href").unwrap();
        let resolved = CanonicalEpubPath::resolve("OEBPS/Text", href).unwrap();
        assert_eq!(resolved.path.as_str(), "OEBPS/Text/chapter-2.xhtml");
        assert_eq!(resolved.fragment.as_deref(), Some("target"));
    }
    for (id, href) in [
        ("encoded-traversal", "%2e%2e/secret.xhtml"),
        ("query", "sibling.xhtml?query=blocked#target"),
        ("foreign", "https://example.invalid/outside.xhtml"),
    ] {
        assert_eq!(by_id(&chapter, id).attribute("href"), Some(href));
        assert!(CanonicalEpubPath::resolve("OEBPS/Text", href).is_err());
    }
    let absolute = by_id(&chapter, "absolute").attribute("href").unwrap();
    assert_eq!(absolute, "/outside.xhtml");
    let absolute = CanonicalEpubPath::resolve("OEBPS/Text", absolute).unwrap();
    assert_eq!(absolute.path.as_str(), "outside.xhtml");
    assert!(canonical.resource(absolute.path.as_str()).is_none());
    let case_variant = by_id(&chapter, "case-variant").attribute("src").unwrap();
    assert_eq!(case_variant, "../Images/PIXEL.png");
    let case_variant = CanonicalEpubPath::resolve("OEBPS/Text", case_variant).unwrap();
    assert_eq!(case_variant.path.as_str(), "OEBPS/Images/PIXEL.png");
    assert!(canonical.resource(case_variant.path.as_str()).is_none());
    let lowercase = CanonicalEpubPath::resolve("OEBPS/Text", "../Images/pixel.png").unwrap();
    assert!(canonical.resource(lowercase.path.as_str()).is_some());
    assert!(
        chapter_document(&canonical, 1)
            .descendants()
            .any(|node| node.attribute("id") == Some("target"))
    );

    let remote = open("remote-content");
    let chapter = chapter_document(&remote, 0);
    for (name, attribute, expected) in [
        ("img", "src", "https://example.invalid/image.png"),
        ("iframe", "src", "https://example.invalid/frame"),
        ("object", "data", "https://example.invalid/object"),
        ("script", "src", "https://example.invalid/script.js"),
        ("form", "action", "https://example.invalid/post"),
    ] {
        let mut elements = elements_named(&chapter, name);
        assert_eq!(
            elements.next().and_then(|node| node.attribute(attribute)),
            Some(expected),
            "hostile {name} {attribute} drifted"
        );
        assert!(
            elements.next().is_none(),
            "unexpected second hostile {name}"
        );
    }
    let remote_css =
        std::str::from_utf8(resource_bytes(&remote, "OEBPS/Styles/remote.css").unwrap()).unwrap();
    assert!(remote_css.contains("@import url('https://example.invalid/import.css')"));
    assert!(remote_css.contains("https://example.invalid/font.woff2"));
    assert!(remote_css.contains("background: url('https://example.invalid/background.png')"));
    assert!(elements_named(&chapter, "a").any(|node| {
        node.attribute("download") == Some("book.bin")
            && node.attribute("href") == Some("https://example.invalid/download")
    }));
    assert!(elements_named(&chapter, "a").any(|node| {
        node.attribute("target") == Some("_blank")
            && node.attribute("href") == Some("https://example.invalid/popup")
    }));
    assert_eq!(
        by_id(&chapter, "redirect").attribute("href"),
        Some("https://example.invalid/redirect")
    );

    let compression = archive_bytes("resource-limits", "OEBPS/Data/compression.txt");
    assert_eq!(compression.len(), 1024 * 1024);
    let svg = archive_entry("resource-limits", "OEBPS/Images/huge.svg");
    assert!(svg.contains("width=\"100000\" height=\"100000\""));
    assert_eq!(
        archive_bytes("resource-limits", "OEBPS/Fonts/corrupt.ttf"),
        b"malformed font sentinel"
    );
    assert_eq!(
        archive_bytes("resource-limits", "OEBPS/Fonts/oversized.ttf").len(),
        1024 * 1024
    );
}

#[test]
fn invalid_archive_fixtures_fail_at_the_declared_boundary() {
    for (fixture, message) in REJECTION_FIXTURES {
        let error = EpubDoc::open(fixture_path(fixture))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains(message),
            "{fixture} failed with unexpected error: {error}"
        );
    }
}

#[test]
fn configurable_limits_reject_before_unbounded_resource_reads() {
    let nested_bytes = std::fs::read(fixture_path("nested-image")).unwrap();

    let limits = EpubLimits {
        max_input_bytes: nested_bytes.len() as u64 - 1,
        ..EpubLimits::default()
    };
    let error = EpubDoc::from_bytes_with_limits(nested_bytes.clone(), limits).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("input exceeds archive byte limit")
    );

    for (limits, expected) in [
        (
            EpubLimits {
                max_archive_entries: 1,
                ..EpubLimits::default()
            },
            "too many entries",
        ),
        (
            EpubLimits {
                max_entry_bytes: 100,
                ..EpubLimits::default()
            },
            "archive entry exceeds byte limit",
        ),
        (
            EpubLimits {
                max_total_uncompressed_bytes: 512,
                ..EpubLimits::default()
            },
            "aggregate uncompressed byte limit",
        ),
        (
            EpubLimits {
                max_xml_bytes: 128,
                ..EpubLimits::default()
            },
            "XML entry exceeds byte limit",
        ),
    ] {
        let error = EpubDoc::from_bytes_with_limits(nested_bytes.clone(), limits).unwrap_err();
        assert!(
            error.to_string().contains(expected),
            "expected {expected:?}, got {error:#}"
        );
    }

    let depth_limits = EpubLimits {
        max_xml_depth: 8,
        ..EpubLimits::default()
    };
    let error =
        EpubDoc::open_with_limits(fixture_path("malformed-markup"), depth_limits).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("chapter-2.xhtml") && message.contains("depth limit"),
        "unexpected depth limit error: {message}"
    );

    let text_limits = EpubLimits {
        max_xml_text_bytes: 8,
        ..EpubLimits::default()
    };
    let error = EpubDoc::open_with_limits(fixture_path("links"), text_limits).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("text limit"),
        "unexpected text limit error: {message}"
    );

    let toc_limits = EpubLimits {
        max_xml_depth: 4,
        ..EpubLimits::default()
    };
    let error = EpubDoc::open_with_limits(fixture_path("links"), toc_limits).unwrap_err();
    let message = format!("{error:#}");
    assert!(
        message.contains("nav.xhtml") && message.contains("depth limit"),
        "unexpected TOC limit error: {message}"
    );

    let font_limits = EpubLimits {
        max_font_bytes: 512 * 1024,
        max_image_dimension: u32::MAX,
        max_image_pixels: u64::MAX,
        max_decoded_image_bytes: u64::MAX,
        ..EpubLimits::default()
    };
    let error =
        EpubDoc::open_with_limits(fixture_path("resource-limits"), font_limits).unwrap_err();
    assert!(
        error.to_string().contains("oversized.ttf")
            && error
                .to_string()
                .contains("font resource exceeds byte limit"),
        "unexpected font limit error: {error:#}"
    );

    for (limits, expected) in [
        (
            EpubLimits {
                max_image_dimension: 99_999,
                max_image_pixels: u64::MAX,
                max_decoded_image_bytes: u64::MAX,
                ..EpubLimits::default()
            },
            "dimension limit",
        ),
        (
            EpubLimits {
                max_image_dimension: u32::MAX,
                max_image_pixels: 9_999_999_999,
                max_decoded_image_bytes: u64::MAX,
                ..EpubLimits::default()
            },
            "pixel limit",
        ),
        (
            EpubLimits {
                max_image_dimension: u32::MAX,
                max_image_pixels: u64::MAX,
                max_decoded_image_bytes: 39_999_999_999,
                ..EpubLimits::default()
            },
            "decoded byte limit",
        ),
    ] {
        let error = EpubDoc::open_with_limits(fixture_path("resource-limits"), limits).unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("huge.svg") && message.contains(expected),
            "unexpected image limit error: {message}"
        );
    }

    let relaxed = EpubLimits {
        max_image_dimension: 100_000,
        max_image_pixels: 10_000_000_000,
        max_decoded_image_bytes: 40_000_000_000,
        ..EpubLimits::default()
    };
    let doc = EpubDoc::open_with_limits(fixture_path("resource-limits"), relaxed).unwrap();
    assert!(doc.resource("OEBPS/Images/huge.svg").is_some());
    assert!(doc.resource("OEBPS/Fonts/oversized.ttf").is_some());
}

#[test]
fn compressed_stress_fixture_exceeds_default_ratio_limit() {
    let generated = tempfile::tempdir().unwrap();
    generate_fixtures(generated.path(), &["--compress-stress-resource"]);

    let error = EpubDoc::open(generated.path().join("resource-limits.epub")).unwrap_err();
    assert!(
        error.to_string().contains("compression.txt")
            && error.to_string().contains("compression ratio limit"),
        "unexpected compression limit error: {error:#}"
    );
}

#[test]
fn conformance_book_combines_fidelity_cases_without_external_inputs() {
    let doc = open("conformance");
    assert_eq!(doc.chapter_count(), 8);
    let chapter_ids = [
        "nested-images",
        "cascade",
        "tables",
        "fonts",
        "math",
        "bidi",
        "links",
        "target",
    ];
    for (index, id) in chapter_ids.into_iter().enumerate() {
        let chapter = chapter_document(&doc, index);
        assert!(
            chapter
                .descendants()
                .any(|node| node.attribute("id") == Some(id)),
            "chapter {index} is missing #{id}"
        );
    }
    assert!(doc.resource("OEBPS/Images/pixel.png").is_some());
    assert!(doc.resource("OEBPS/Styles/book.css").is_some());
    assert!(doc.resource("OEBPS/Fonts/book-a.woff2").is_some());
    let links = chapter_document(&doc, 6);
    assert_eq!(
        by_id(&links, "cross").attribute("href"),
        Some("chapter-8.xhtml#target")
    );
    let encoded = by_id(&links, "encoded").attribute("href").unwrap();
    let resolved = CanonicalEpubPath::resolve("OEBPS/Text", encoded).unwrap();
    assert_eq!(resolved.path.as_str(), "OEBPS/Text/chapter-8.xhtml");
    assert_eq!(resolved.fragment.as_deref(), Some("percent-target"));
}

#[test]
fn generated_hash_manifest_covers_exactly_the_fixture_matrix() {
    let hash_bytes = std::fs::read(fixture_dir().join("SHA256SUMS")).unwrap();
    assert!(!hash_bytes.contains(&b'\r'), "SHA256SUMS must be LF-only");
    let hashes = std::str::from_utf8(&hash_bytes).unwrap();
    let records = hashes
        .lines()
        .map(|line| line.split_once("  ").expect("invalid SHA256SUMS line"))
        .collect::<Vec<_>>();
    let names = records.iter().map(|(_, name)| *name).collect::<Vec<_>>();
    let expected = FIXTURE_IDS
        .iter()
        .copied()
        .chain(EXTRA_FIXTURE_IDS.iter().copied())
        .map(|id| format!("{id}.epub"))
        .collect::<Vec<_>>();
    assert_eq!(names, expected);

    let mut checked_in_epubs = std::fs::read_dir(fixture_dir())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "epub")
        })
        .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    checked_in_epubs.sort();
    let mut expected_sorted = expected.clone();
    expected_sorted.sort();
    assert_eq!(checked_in_epubs, expected_sorted);

    for (expected_digest, name) in records {
        let bytes = std::fs::read(fixture_dir().join(name)).unwrap();
        assert_eq!(format!("{:x}", Sha256::digest(&bytes)), expected_digest);

        let mut archive = ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
        let mut names = Vec::with_capacity(archive.len());
        for index in 0..archive.len() {
            let entry = archive.by_index(index).unwrap();
            assert_eq!(entry.compression(), CompressionMethod::Stored, "{name}");
            let modified = entry.last_modified().unwrap();
            assert_eq!(
                (
                    modified.year(),
                    modified.month(),
                    modified.day(),
                    modified.hour(),
                    modified.minute(),
                    modified.second(),
                ),
                (1980, 1, 1, 0, 0, 0),
                "{name}: {}",
                entry.name()
            );
            names.push(entry.name().to_owned());
        }
        assert_eq!(names.first().map(String::as_str), Some("mimetype"));
        assert!(names[1..].windows(2).all(|pair| pair[0] <= pair[1]));
    }

    let generated = tempfile::tempdir().unwrap();
    generate_fixtures(generated.path(), &[]);
    assert_eq!(
        std::fs::read(generated.path().join("SHA256SUMS")).unwrap(),
        std::fs::read(fixture_dir().join("SHA256SUMS")).unwrap()
    );
    for name in expected {
        assert_eq!(
            std::fs::read(generated.path().join(&name)).unwrap(),
            std::fs::read(fixture_dir().join(&name)).unwrap(),
            "generated {name} drifted"
        );
    }
}

#[test]
fn repository_attributes_preserve_fixture_bytes() {
    let attributes = std::fs::read_to_string(repository_root().join(".gitattributes")).unwrap();
    assert!(attributes.lines().any(|line| {
        line == "crates/shosai-core/tests/fixtures/epub-conformance/SHA256SUMS text eol=lf"
    }));
    assert!(attributes.lines().any(|line| {
        line == "crates/shosai-core/tests/fixtures/epub-conformance/*.epub binary"
    }));
}
