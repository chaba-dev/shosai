use std::path::PathBuf;

use roxmltree::{Document, Node};
use shosai_core::epub::{CanonicalEpubPath, EpubDoc};

const FIXTURE_IDS: &[&str] = &[
    "nested-image",
    "css-cascade",
    "table",
    "fonts",
    "mathml",
    "bidi",
    "links",
    "malformed-markup",
    "canonical-paths",
    "remote-content",
    "resource-limits",
    "conformance",
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
        ("encoded", "chapter-2.xhtml#percent%20target"),
        ("https", "https://example.invalid/book"),
        ("mail", "mailto:reader@example.invalid"),
        ("unsupported", "custom:blocked"),
    ];
    for (id, href) in expected {
        assert_eq!(by_id(&chapter, id).attribute("href"), Some(href));
    }
    let targets = chapter_document(&links, 1);
    assert!(
        targets
            .descendants()
            .any(|node| node.attribute("id") == Some("target"))
    );
    assert!(
        targets
            .descendants()
            .any(|node| node.attribute("id") == Some("percent target"))
    );
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
        .map(|id| format!("{id}.epub"))
        .collect::<Vec<_>>();
    assert_eq!(names, expected);
    assert!(fixture_dir().join("generate.py").exists());
}
