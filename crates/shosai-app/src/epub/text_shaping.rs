//! Gate 0 text-shaping spike. This is deliberately test-only: it measures the
//! shaper contract without coupling it to the production paginator.

use std::{collections::BTreeSet, ops::Range};

use cosmic_text::{
    Attrs, Buffer, Family, FontSystem, LineEnding, LineIter, Metrics, Shaping, Weight, Wrap,
    fontdb::{Database, Style},
};

const INTER: &[u8] = include_bytes!("../../tests/fonts/InterVariable.ttf");
const INTER_ITALIC: &[u8] = include_bytes!("../../tests/fonts/InterVariable-Italic.ttf");
const NOTO_ARABIC: &[u8] = include_bytes!("../../tests/fonts/NotoSansArabic.ttf");
const NOTO_HEBREW: &[u8] = include_bytes!("../../tests/fonts/NotoSansHebrew.ttf");

#[derive(Debug, PartialEq)]
struct GlyphEvidence {
    bytes: Range<usize>,
    scalars: Range<usize>,
    font_family: String,
    font_style: Style,
    font_weight: Weight,
    glyph_id: u16,
    bidi_level: u8,
    x: f32,
    width: f32,
}

#[derive(Debug, PartialEq)]
struct LineEvidence {
    source_line: usize,
    source_byte: usize,
    source_scalar: usize,
    width: f32,
    top: f32,
    baseline: f32,
    height: f32,
}

#[derive(Debug, PartialEq)]
struct ShapingEvidence {
    glyphs: Vec<GlyphEvidence>,
    lines: Vec<LineEvidence>,
}

fn font_system() -> FontSystem {
    let mut db = Database::new();
    for font in [INTER, INTER_ITALIC, NOTO_ARABIC, NOTO_HEBREW] {
        db.load_font_data(font.to_vec());
    }
    db.set_sans_serif_family("Inter Variable");
    FontSystem::new_with_locale_and_db("en-US".into(), db)
}

fn scalar_offset(text: &str, byte: usize) -> usize {
    text[..byte].chars().count()
}

fn source_line_starts(text: &str) -> Vec<usize> {
    let mut starts = Vec::new();
    let mut final_ending = None;
    for (range, ending) in LineIter::new(text) {
        starts.push(range.start);
        final_ending = Some(ending);
    }
    if starts.is_empty() || !matches!(final_ending, Some(LineEnding::None)) {
        starts.push(text.len());
    }
    starts
}

fn shape(text: &str, width: f32, attrs: Attrs<'_>) -> ShapingEvidence {
    let mut font_system = font_system();
    let mut buffer = Buffer::new(&mut font_system, Metrics::new(20.0, 28.0));
    buffer.set_wrap(&mut font_system, Wrap::WordOrGlyph);
    buffer.set_size(&mut font_system, Some(width), None);
    buffer.set_text(&mut font_system, text, &attrs, Shaping::Advanced, None);
    buffer.shape_until_scroll(&mut font_system, false);

    let mut glyphs = Vec::new();
    let mut lines = Vec::new();
    let source_line_starts = source_line_starts(text);
    for run in buffer.layout_runs() {
        let source_byte = source_line_starts[run.line_i];
        lines.push(LineEvidence {
            source_line: run.line_i,
            source_byte,
            source_scalar: scalar_offset(text, source_byte),
            width: run.line_w,
            top: run.line_top,
            baseline: run.line_y,
            height: run.line_height,
        });
        for glyph in run.glyphs {
            let face = font_system
                .db()
                .face(glyph.font_id)
                .expect("layout glyph must reference a loaded face");
            let start = source_byte + glyph.start;
            let end = source_byte + glyph.end;
            glyphs.push(GlyphEvidence {
                bytes: start..end,
                scalars: scalar_offset(text, start)..scalar_offset(text, end),
                font_family: face.families[0].0.clone(),
                font_style: face.style,
                font_weight: glyph.font_weight,
                glyph_id: glyph.glyph_id,
                bidi_level: glyph.level.number(),
                x: glyph.x,
                width: glyph.w,
            });
        }
    }
    ShapingEvidence { glyphs, lines }
}

fn assert_complete_source_coverage(text: &str, evidence: &ShapingEvidence) {
    let covered = evidence
        .glyphs
        .iter()
        .flat_map(|glyph| glyph.bytes.clone())
        .collect::<BTreeSet<_>>();
    let shaped_source = LineIter::new(text)
        .flat_map(|(range, _)| range)
        .collect::<BTreeSet<_>>();
    assert_eq!(covered, shaped_source);
    assert!(evidence.glyphs.iter().all(|glyph| {
        text.is_char_boundary(glyph.bytes.start)
            && text.is_char_boundary(glyph.bytes.end)
            && glyph.scalars.start == scalar_offset(text, glyph.bytes.start)
            && glyph.scalars.end == scalar_offset(text, glyph.bytes.end)
    }));
}

#[test]
fn bidi_layout_reorders_visually_but_retains_logical_source_ranges() {
    for text in ["שלום עולם", "مرحبا بالعالم", "English שלום 123 مرحبا"]
    {
        let evidence = shape(text, 600.0, Attrs::new().family(Family::SansSerif));
        let mut visual_order = evidence.glyphs.iter().collect::<Vec<_>>();
        visual_order.sort_by(|left, right| left.x.total_cmp(&right.x));

        assert_complete_source_coverage(text, &evidence);
        assert!(
            evidence
                .glyphs
                .iter()
                .any(|glyph| glyph.bidi_level % 2 == 1)
        );
        assert!(
            visual_order
                .windows(2)
                .any(|pair| pair[0].bytes.start > pair[1].bytes.start),
            "left-to-right visual traversal should expose RTL logical reordering: {text}"
        );
    }
}

#[test]
fn complex_clusters_map_back_to_unicode_scalar_offsets() {
    for text in ["Cafe\u{301}", "日本語", "👩\u{200d}🔬"] {
        let evidence = shape(text, 600.0, Attrs::new().family(Family::SansSerif));
        assert_complete_source_coverage(text, &evidence);
    }

    let combining = "e\u{301}";
    let evidence = shape(combining, 600.0, Attrs::new().family(Family::SansSerif));
    assert!(evidence.glyphs.iter().any(|glyph| {
        glyph.bytes == (0..combining.len()) && glyph.scalars == (0..combining.chars().count())
    }));

    for unsupported in ["日本語", "👩\u{200d}🔬"] {
        let evidence = shape(unsupported, 600.0, Attrs::new().family(Family::SansSerif));
        assert!(
            evidence.glyphs.iter().any(|glyph| glyph.glyph_id == 0),
            "logical range evidence must not be mistaken for font coverage: {unsupported}"
        );
    }
}

#[test]
fn multiline_ranges_are_rebased_to_chapter_offsets() {
    let text = "éé\nעברית";
    let second_line_start = text.find('ע').expect("fixture must contain Hebrew");
    let evidence = shape(text, 600.0, Attrs::new().family(Family::SansSerif));

    let hebrew = evidence
        .glyphs
        .iter()
        .filter(|glyph| glyph.font_family == "Noto Sans Hebrew")
        .collect::<Vec<_>>();
    assert!(!hebrew.is_empty());
    assert!(
        hebrew
            .iter()
            .all(|glyph| glyph.bytes.start >= second_line_start),
        "second-line ranges must be chapter-relative: {hebrew:?}"
    );
    assert!(hebrew.iter().all(|glyph| {
        glyph.scalars.start == scalar_offset(text, glyph.bytes.start)
            && glyph.scalars.end == scalar_offset(text, glyph.bytes.end)
    }));
    assert_eq!(
        evidence
            .lines
            .iter()
            .map(|line| (line.source_line, line.source_byte, line.source_scalar))
            .collect::<Vec<_>>(),
        vec![(0, 0, 0), (1, second_line_start, 3)]
    );
    assert_complete_source_coverage(text, &evidence);
}

#[test]
fn bundled_fonts_provide_deterministic_script_fallback() {
    let text = "Latin العربية עברית";
    let attrs = Attrs::new().family(Family::Name("Inter Variable"));
    let evidence = shape(text, 600.0, attrs.clone());
    let repeated = shape(text, 600.0, attrs);
    assert_eq!(evidence, repeated);

    for glyph in &evidence.glyphs {
        let source = &text[glyph.bytes.clone()];
        let expected_family = if source
            .chars()
            .any(|character| character.is_ascii_alphabetic())
        {
            Some("Inter Variable")
        } else if source
            .chars()
            .any(|character| ('\u{0600}'..='\u{06ff}').contains(&character))
        {
            Some("Noto Sans Arabic")
        } else if source
            .chars()
            .any(|character| ('\u{0590}'..='\u{05ff}').contains(&character))
        {
            Some("Noto Sans Hebrew")
        } else {
            None
        };
        if let Some(expected_family) = expected_family {
            assert_eq!(
                glyph.font_family, expected_family,
                "source cluster: {source}"
            );
            assert_ne!(glyph.glyph_id, 0, "source cluster: {source}");
        }
    }

    let families = evidence
        .glyphs
        .iter()
        .map(|glyph| glyph.font_family.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        families,
        BTreeSet::from(["Inter Variable", "Noto Sans Arabic", "Noto Sans Hebrew"])
    );
    assert_complete_source_coverage(text, &evidence);
}

#[test]
fn variable_weight_changes_observable_measurement() {
    let font = ttf_parser::Face::parse(INTER, 0).expect("Inter fixture must be a valid font");
    assert!(
        font.variation_axes()
            .into_iter()
            .any(|axis| axis.tag == ttf_parser::Tag::from_bytes(b"wght")),
        "Inter fixture must expose a weight axis"
    );

    let regular = shape(
        "Variable weight",
        600.0,
        Attrs::new()
            .family(Family::Name("Inter Variable"))
            .weight(Weight::NORMAL),
    );
    let bold = shape(
        "Variable weight",
        600.0,
        Attrs::new()
            .family(Family::Name("Inter Variable"))
            .weight(Weight::BOLD),
    );

    assert_ne!(regular.lines[0].width, bold.lines[0].width);
}

#[test]
fn requested_style_reaches_the_selected_face() {
    let normal = shape(
        "Styled",
        600.0,
        Attrs::new().family(Family::Name("Inter Variable")),
    );
    let italic = shape(
        "Styled",
        600.0,
        Attrs::new()
            .family(Family::Name("Inter Variable"))
            .style(Style::Italic),
    );

    assert!(
        normal
            .glyphs
            .iter()
            .all(|glyph| glyph.font_style == Style::Normal)
    );
    assert!(
        italic
            .glyphs
            .iter()
            .all(|glyph| glyph.font_style == Style::Italic)
    );
    assert_ne!(normal.glyphs[0].glyph_id, 0);
    assert_ne!(italic.glyphs[0].glyph_id, 0);
}

#[test]
fn requested_weight_metadata_is_retained_for_rendering() {
    let styled = shape(
        "Styled",
        600.0,
        Attrs::new()
            .family(Family::Name("Inter Variable"))
            .weight(Weight::BOLD),
    );
    assert!(
        styled
            .glyphs
            .iter()
            .all(|glyph| glyph.font_weight == Weight::BOLD)
    );
}

#[test]
fn fixed_fonts_produce_repeatable_measurements_and_line_metrics() {
    let attrs = Attrs::new().family(Family::Name("Inter Variable"));
    let first = shape(
        "Deterministic native text measurement",
        180.0,
        attrs.clone(),
    );
    let second = shape("Deterministic native text measurement", 180.0, attrs);

    assert_eq!(first, second);
    assert!(first.lines.len() > 1);
    assert!(
        first
            .lines
            .iter()
            .all(|line| { line.width <= 180.0 && line.height == 28.0 && line.baseline > line.top })
    );
}
