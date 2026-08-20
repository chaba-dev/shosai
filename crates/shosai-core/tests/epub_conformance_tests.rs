use std::io::Read;
use std::path::PathBuf;

use roxmltree::{Document, Node};
use shosai_core::epub::{CanonicalEpubPath, EpubDoc};
use zip::ZipArchive;

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

const REJECTION_FIXTURES: &[(&str, &str)] = &[
    ("missing-spine-resource", "failed to read chapter"),
    ("duplicate-entries", "duplicate EPUB archive entry"),
];

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/epub-conformance")
}

fn fixture_path(id: &str) -> PathBuf {
    fixture_dir().join(format!("{id}.epub"))
}

fn open(id: &str) -> EpubDoc {
    EpubDoc::open(fixture_path(id)).unwrap_or_else(|error| panic!("{id}: {error:#}"))
}

fn archive_entry(id: &str, path: &str) -> String {
    let file = std::fs::File::open(fixture_path(id)).unwrap();
    let mut archive = ZipArchive::new(file).unwrap();
    let mut content = String::new();
    archive
        .by_name(path)
        .unwrap()
        .read_to_string(&mut content)
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

#[test]
fn complete_fixture_matrix_opens_with_stable_metadata() {
    for id in FIXTURE_IDS {
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
        cascade_doc
            .resource("OEBPS/Styles/book.css")
            .expect("missing cascade CSS"),
    )
    .unwrap();
    for marker in [
        "!important",
        ".chapter p.important",
        ".inherited { font-style: italic; }",
        ".source-order { color: #111111; }",
        ".source-order { color: #222222; }",
        "section > p.inherited",
        "display: none",
    ] {
        assert!(css.contains(marker), "cascade CSS is missing {marker}");
    }
    assert!(
        by_id(&cascade, "inherited")
            .parent()
            .is_some_and(|parent| parent.attribute("class") == Some("inherited"))
    );

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
            fonts
                .resource(path)
                .expect("missing font")
                .starts_with(signature)
        );
    }
    assert_eq!(
        &fonts.resource("OEBPS/Fonts/book-a.ttf").unwrap()[..4],
        &[0, 1, 0, 0]
    );
    assert_eq!(
        fonts.resource("OEBPS/Fonts/book-a.otf").unwrap().get(..4),
        Some(b"OTTO".as_slice())
    );
    assert!(fonts.resource("OEBPS/Fonts/missing.woff2").is_none());
    assert_eq!(
        fonts.resource("OEBPS/Fonts/corrupt.woff2"),
        Some(b"not a font".as_slice())
    );
    let font_css = std::str::from_utf8(fonts.resource("OEBPS/Styles/fonts.css").unwrap()).unwrap();
    assert!(font_css.contains("font-weight: 700"));
    assert!(font_css.contains("font-style: italic"));

    let isolated_fonts = open("fonts-isolation");
    assert!(isolated_fonts.resource("OEBPS/Fonts/book-b.ttf").is_some());
    let isolated_css =
        std::str::from_utf8(isolated_fonts.resource("OEBPS/Styles/fonts.css").unwrap()).unwrap();
    assert!(isolated_css.contains("font-family: FixtureTtf"));

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
    assert!(
        chapter_document(&canonical, 1)
            .descendants()
            .any(|node| node.attribute("id") == Some("target"))
    );

    let remote = open("remote-content");
    let chapter = chapter_document(&remote, 0);
    for name in ["img", "iframe", "object", "script", "form"] {
        assert_eq!(
            elements_named(&chapter, name).count(),
            1,
            "missing hostile {name}"
        );
    }
    let remote_css =
        std::str::from_utf8(remote.resource("OEBPS/Styles/remote.css").unwrap()).unwrap();
    assert!(remote_css.contains("@import url('https://example.invalid/import.css')"));
    assert!(remote_css.contains("https://example.invalid/font.woff2"));
    assert_eq!(
        by_id(&chapter, "redirect").attribute("href"),
        Some("https://example.invalid/redirect")
    );

    let limits = open("resource-limits");
    assert_eq!(
        limits.resource("OEBPS/Data/compression.txt").unwrap().len(),
        1024 * 1024
    );
    let svg = std::str::from_utf8(limits.resource("OEBPS/Images/huge.svg").unwrap()).unwrap();
    assert!(svg.contains("width=\"100000\" height=\"100000\""));
    assert_eq!(
        limits.resource("OEBPS/Fonts/corrupt.ttf"),
        Some(b"malformed font sentinel".as_slice())
    );
    assert!(limits.resource("OEBPS/Fonts/oversized.ttf").is_some());
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
    let hashes = std::fs::read_to_string(fixture_dir().join("SHA256SUMS")).unwrap();
    let names = hashes
        .lines()
        .map(|line| line.split_once("  ").expect("invalid SHA256SUMS line").1)
        .collect::<Vec<_>>();
    let expected = FIXTURE_IDS
        .iter()
        .copied()
        .chain(REJECTION_FIXTURES.iter().map(|(id, _)| *id))
        .map(|id| format!("{id}.epub"))
        .collect::<Vec<_>>();
    assert_eq!(names, expected);
    assert!(fixture_dir().join("generate.py").exists());
}
