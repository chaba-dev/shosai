//! Gate 0 block/inline layout spike. Taffy owns block boxes and margin
//! collapsing; cosmic-text owns each anonymous inline-root leaf.

use std::{collections::BTreeSet, ops::Range};

use cosmic_text::{
    Align, Attrs, BidiParagraphs, Buffer, Family, Metrics, Shaping, Weight, Wrap,
    fontdb::Style as FontStyle,
};
use taffy::prelude::*;
use taffy::{Point, style::Direction};

use super::text_shaping::{font_system, scalar_offset, source_line_starts};

#[derive(Clone, Debug)]
struct InlineSpan {
    text: String,
    bold: bool,
    italic: bool,
}

impl InlineSpan {
    fn plain(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            bold: false,
            italic: false,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct ComputedBlockStyle {
    display: Display,
    direction: Direction,
    font_size: f32,
    line_height: f32,
    alignment: Option<Align>,
    margin: Rect<f32>,
}

impl Default for ComputedBlockStyle {
    fn default() -> Self {
        Self {
            display: Display::Block,
            direction: Direction::Ltr,
            font_size: 16.0,
            line_height: 24.0,
            alignment: None,
            margin: Rect::zero(),
        }
    }
}

#[derive(Clone, Debug)]
struct TextLeaf {
    spans: Vec<InlineSpan>,
    style: ComputedBlockStyle,
    source_byte: usize,
    source_scalar: usize,
}

impl TextLeaf {
    fn text(&self) -> String {
        self.spans.iter().map(|span| span.text.as_str()).collect()
    }
}

#[derive(Clone, Debug)]
enum Leaf {
    Text(TextLeaf),
    Image {
        intrinsic: Size<f32>,
        style: ComputedBlockStyle,
    },
}

impl Leaf {
    fn style(&self) -> ComputedBlockStyle {
        match self {
            Self::Text(text) => text.style,
            Self::Image { style, .. } => *style,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct GlyphBox {
    source_bytes: Range<usize>,
    source_scalars: Range<usize>,
    x: f32,
    y: f32,
    width: f32,
    bidi_level: u8,
    weight: Weight,
    font_style: FontStyle,
}

#[derive(Clone, Debug, PartialEq)]
struct LineBox {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    baseline: f32,
}

#[derive(Clone, Debug, PartialEq)]
struct BlockBox {
    location: Point<f32>,
    size: Size<f32>,
    margin: Rect<f32>,
    lines: Vec<LineBox>,
    glyphs: Vec<GlyphBox>,
    unshaped_source_bytes: BTreeSet<usize>,
}

#[derive(Clone, Debug, PartialEq)]
struct LayoutEvidence {
    viewport: Size<f32>,
    blocks: Vec<BlockBox>,
}

fn width_constraint(known: Option<f32>, available: AvailableSpace) -> Option<f32> {
    known.or(match available {
        AvailableSpace::Definite(width) => Some(width),
        AvailableSpace::MinContent => None,
        AvailableSpace::MaxContent => None,
    })
}

fn shape_text(
    text: &TextLeaf,
    width: Option<f32>,
) -> (Size<f32>, Vec<LineBox>, Vec<GlyphBox>, BTreeSet<usize>) {
    let source = text.text();
    assert!(
        source.is_empty() || BidiParagraphs::new(&source).count() == 1,
        "anonymous inline-root leaf must contain exactly one bidi paragraph"
    );
    let mut font_system = font_system();
    let metrics = Metrics::new(text.style.font_size, text.style.line_height);
    let mut buffer = Buffer::new(&mut font_system, metrics);
    buffer.set_wrap(&mut font_system, Wrap::WordOrGlyph);
    buffer.set_size(&mut font_system, width, None);

    let default_attrs = Attrs::new()
        .family(Family::Name("Inter Variable"))
        .metrics(metrics);
    let spans = text.spans.iter().map(|span| {
        let attrs = default_attrs
            .clone()
            .weight(if span.bold {
                Weight::BOLD
            } else {
                Weight::NORMAL
            })
            .style(if span.italic {
                FontStyle::Italic
            } else {
                FontStyle::Normal
            });
        (span.text.as_str(), attrs)
    });
    buffer.set_rich_text(
        &mut font_system,
        spans,
        &default_attrs,
        Shaping::Advanced,
        text.style.alignment,
    );
    buffer.shape_until_scroll(&mut font_system, false);

    let line_starts = source_line_starts(&source);
    let mut lines = Vec::new();
    let mut glyphs = Vec::new();
    for run in buffer.layout_runs() {
        lines.push(LineBox {
            x: 0.0,
            y: run.line_top,
            width: run.line_w,
            height: run.line_height,
            baseline: run.line_y,
        });
        let line_start = line_starts[run.line_i];
        for glyph in run.glyphs {
            let local_start = line_start + glyph.start;
            let local_end = line_start + glyph.end;
            let face = font_system
                .db()
                .face(glyph.font_id)
                .expect("glyph must reference a loaded font");
            glyphs.push(GlyphBox {
                source_bytes: (text.source_byte + local_start)..(text.source_byte + local_end),
                source_scalars: (text.source_scalar + scalar_offset(&source, local_start))
                    ..(text.source_scalar + scalar_offset(&source, local_end)),
                x: glyph.x,
                y: run.line_top,
                width: glyph.w,
                bidi_level: glyph.level.number(),
                weight: glyph.font_weight,
                font_style: face.style,
            });
        }
    }

    let measured_width = lines.iter().map(|line| line.width).fold(0.0, f32::max);
    let measured_height = lines.last().map_or(0.0, |line| line.y + line.height);
    let shaped_bytes = glyphs
        .iter()
        .flat_map(|glyph| glyph.source_bytes.clone())
        .collect::<BTreeSet<_>>();
    let source_bytes = (text.source_byte..text.source_byte + source.len()).collect::<BTreeSet<_>>();
    let unshaped_source_bytes = source_bytes.difference(&shaped_bytes).copied().collect();
    (
        Size {
            width: measured_width,
            height: measured_height,
        },
        lines,
        glyphs,
        unshaped_source_bytes,
    )
}

fn measure_leaf(
    known: Size<Option<f32>>,
    available: Size<AvailableSpace>,
    leaf: &Leaf,
) -> Size<f32> {
    match leaf {
        Leaf::Text(text) => {
            assert!(
                !matches!(available.width, AvailableSpace::MinContent),
                "min-content text measurement is unsupported by the layout spike"
            );
            let width = width_constraint(known.width, available.width);
            let (measured, _, _, _) = shape_text(text, width);
            Size {
                width: known.width.unwrap_or(measured.width),
                height: known.height.unwrap_or(measured.height),
            }
        }
        Leaf::Image { intrinsic, .. } => {
            let maximum_width = width_constraint(known.width, available.width)
                .unwrap_or(intrinsic.width)
                .min(intrinsic.width);
            let width = known.width.unwrap_or(maximum_width);
            let scale = width / intrinsic.width;
            Size {
                width,
                height: known.height.unwrap_or(intrinsic.height * scale),
            }
        }
    }
}

fn taffy_style(leaf: &Leaf) -> Style {
    let style = leaf.style();
    Style {
        display: style.display,
        direction: style.direction,
        item_is_replaced: matches!(leaf, Leaf::Image { .. }),
        margin: Rect {
            left: length(style.margin.left),
            right: length(style.margin.right),
            top: length(style.margin.top),
            bottom: length(style.margin.bottom),
        },
        ..Style::default()
    }
}

fn layout_document(leaves: Vec<Leaf>, viewport_width: f32) -> LayoutEvidence {
    let mut tree = TaffyTree::new();
    tree.disable_rounding();
    let nodes = leaves
        .into_iter()
        .map(|leaf| {
            tree.new_leaf_with_context(taffy_style(&leaf), leaf)
                .expect("test layout leaf must be valid")
        })
        .collect::<Vec<_>>();
    let root = tree
        .new_with_children(
            Style {
                display: Display::Block,
                size: Size {
                    width: length(viewport_width),
                    height: auto(),
                },
                ..Style::default()
            },
            &nodes,
        )
        .expect("test layout root must be valid");
    tree.compute_layout_with_measure(
        root,
        Size {
            width: AvailableSpace::Definite(viewport_width),
            height: AvailableSpace::MaxContent,
        },
        |known, available, _, context, _| {
            context.map_or(Size::ZERO, |leaf| measure_leaf(known, available, leaf))
        },
    )
    .expect("test document must lay out");

    let blocks = nodes
        .into_iter()
        .map(|node| {
            let layout = *tree.layout(node).expect("leaf layout must exist");
            let (mut lines, mut glyphs, unshaped_source_bytes) = match tree.get_node_context(node) {
                Some(Leaf::Text(text)) if layout.size.width > 0.0 => {
                    let (_, lines, glyphs, unshaped) = shape_text(text, Some(layout.size.width));
                    (lines, glyphs, unshaped)
                }
                _ => (Vec::new(), Vec::new(), BTreeSet::new()),
            };
            for line in &mut lines {
                line.x += layout.location.x;
                line.y += layout.location.y;
                line.baseline += layout.location.y;
            }
            for glyph in &mut glyphs {
                glyph.x += layout.location.x;
                glyph.y += layout.location.y;
            }
            BlockBox {
                location: layout.location,
                size: layout.size,
                margin: layout.margin,
                lines,
                glyphs,
                unshaped_source_bytes,
            }
        })
        .collect();
    let root_layout = tree.layout(root).expect("root layout must exist");
    LayoutEvidence {
        viewport: root_layout.size,
        blocks,
    }
}

fn text_leaf(
    spans: Vec<InlineSpan>,
    style: ComputedBlockStyle,
    source_byte: usize,
    source_scalar: usize,
) -> Leaf {
    Leaf::Text(TextLeaf {
        spans,
        style,
        source_byte,
        source_scalar,
    })
}

#[test]
fn computed_block_values_drive_block_flow_and_rich_inline_layout() {
    let chapter = "Intro\nEnglish العربية עברית\nhidden";
    let lead_text = "English العربية עברית";
    let lead_byte = chapter.find(lead_text).unwrap();
    let lead_scalar = chapter[..lead_byte].chars().count();
    let first_style = ComputedBlockStyle {
        margin: Rect {
            bottom: 12.0,
            ..Rect::zero()
        },
        ..ComputedBlockStyle::default()
    };
    let lead_style = ComputedBlockStyle {
        direction: Direction::Rtl,
        font_size: 24.0,
        line_height: 32.0,
        alignment: Some(Align::Right),
        margin: Rect {
            left: 48.0,
            right: 12.0,
            top: 20.0,
            ..Rect::zero()
        },
        ..ComputedBlockStyle::default()
    };
    let hidden_style = ComputedBlockStyle {
        display: Display::None,
        ..ComputedBlockStyle::default()
    };
    let evidence = layout_document(
        vec![
            text_leaf(vec![InlineSpan::plain("Intro")], first_style, 0, 0),
            text_leaf(
                vec![
                    InlineSpan::plain("English "),
                    InlineSpan {
                        text: "العربية".into(),
                        bold: true,
                        italic: false,
                    },
                    InlineSpan::plain(" "),
                    InlineSpan {
                        text: "עברית".into(),
                        bold: false,
                        italic: true,
                    },
                ],
                lead_style,
                lead_byte,
                lead_scalar,
            ),
            text_leaf(
                vec![InlineSpan::plain("hidden")],
                hidden_style,
                chapter.find("hidden").unwrap(),
                chapter[..chapter.find("hidden").unwrap()].chars().count(),
            ),
        ],
        300.0,
    );

    let first = &evidence.blocks[0];
    let lead = &evidence.blocks[1];
    let hidden = &evidence.blocks[2];
    assert_eq!(lead.location.x, 48.0);
    assert_eq!(lead.size.width, 240.0);
    assert_eq!(
        lead.location.y - (first.location.y + first.size.height),
        20.0,
        "adjacent margins should collapse to their maximum"
    );
    assert!(lead.lines.iter().all(|line| line.height == 32.0));
    assert!(lead.glyphs.iter().any(|glyph| glyph.bidi_level % 2 == 1));
    assert!(lead.glyphs.iter().any(|glyph| glyph.weight == Weight::BOLD));
    assert!(
        lead.glyphs
            .iter()
            .any(|glyph| glyph.font_style == FontStyle::Italic)
    );
    assert_eq!(hidden.size, Size::ZERO);
    assert!(hidden.glyphs.is_empty());

    let covered = lead
        .glyphs
        .iter()
        .flat_map(|glyph| glyph.source_bytes.clone())
        .collect::<BTreeSet<_>>();
    let complete_source = covered
        .union(&lead.unshaped_source_bytes)
        .copied()
        .collect::<BTreeSet<_>>();
    assert_eq!(
        complete_source,
        (lead_byte..lead_byte + lead_text.len()).collect()
    );
    assert_eq!(
        lead.unshaped_source_bytes,
        BTreeSet::from([chapter.find(" עברית").unwrap()])
    );
    assert!(lead.glyphs.iter().all(|glyph| {
        glyph.source_scalars.start == chapter[..glyph.source_bytes.start].chars().count()
            && glyph.source_scalars.end == chapter[..glyph.source_bytes.end].chars().count()
    }));
}

#[test]
fn measured_text_wraps_and_replaced_images_preserve_intrinsic_ratio() {
    let text = "A deliberately long line with mixed العربية text";
    let text_style = ComputedBlockStyle {
        line_height: 24.0,
        margin: Rect {
            left: 10.0,
            right: 10.0,
            ..Rect::zero()
        },
        ..ComputedBlockStyle::default()
    };
    let evidence = layout_document(
        vec![
            text_leaf(vec![InlineSpan::plain(text)], text_style, 0, 0),
            Leaf::Image {
                intrinsic: Size {
                    width: 400.0,
                    height: 300.0,
                },
                style: ComputedBlockStyle::default(),
            },
        ],
        200.0,
    );

    assert!(evidence.blocks[0].lines.len() > 1);
    assert_eq!(evidence.blocks[0].size.width, 180.0);
    assert_eq!(
        evidence.blocks[1].size,
        Size {
            width: 200.0,
            height: 150.0
        }
    );
}

#[test]
fn computed_font_size_and_alignment_change_glyph_geometry() {
    let style = |font_size, alignment| ComputedBlockStyle {
        font_size,
        line_height: font_size * 1.5,
        alignment: Some(alignment),
        ..ComputedBlockStyle::default()
    };
    let layout = |computed_style| {
        layout_document(
            vec![text_leaf(
                vec![InlineSpan::plain("Aligned text")],
                computed_style,
                0,
                0,
            )],
            300.0,
        )
    };

    let small_left = layout(style(16.0, Align::Left));
    let large_left = layout(style(24.0, Align::Left));
    let small_right = layout(style(16.0, Align::Right));
    assert!(large_left.blocks[0].lines[0].width > small_left.blocks[0].lines[0].width);
    assert!(
        small_right.blocks[0].glyphs[0].x > small_left.blocks[0].glyphs[0].x,
        "right alignment must shift the glyph run within the same block width"
    );
}

#[test]
fn display_none_with_margins_does_not_affect_sibling_flow() {
    let visible = |text| {
        text_leaf(
            vec![InlineSpan::plain(text)],
            ComputedBlockStyle::default(),
            0,
            0,
        )
    };
    let control = layout_document(vec![visible("before"), visible("after")], 200.0);
    let hidden_style = ComputedBlockStyle {
        display: Display::None,
        margin: Rect {
            top: 100.0,
            bottom: 100.0,
            ..Rect::zero()
        },
        ..ComputedBlockStyle::default()
    };
    let with_hidden = layout_document(
        vec![
            visible("before"),
            text_leaf(vec![InlineSpan::plain("hidden")], hidden_style, 0, 0),
            visible("after"),
        ],
        200.0,
    );

    assert_eq!(with_hidden.blocks[1].size, Size::ZERO);
    assert_eq!(
        with_hidden.blocks[2].location, control.blocks[1].location,
        "display:none margins must not participate in block flow"
    );
}

#[test]
#[should_panic(expected = "min-content text measurement is unsupported by the layout spike")]
fn min_content_measurement_fails_explicitly() {
    let leaf = text_leaf(
        vec![InlineSpan::plain("min content")],
        ComputedBlockStyle::default(),
        0,
        0,
    );
    let _ = measure_leaf(
        Size {
            width: None,
            height: None,
        },
        Size {
            width: AvailableSpace::MinContent,
            height: AvailableSpace::MaxContent,
        },
        &leaf,
    );
}

#[test]
#[should_panic(expected = "anonymous inline-root leaf must contain exactly one bidi paragraph")]
fn inline_root_rejects_multiple_bidi_paragraphs() {
    let _ = layout_document(
        vec![text_leaf(
            vec![InlineSpan::plain("first\u{2029}second")],
            ComputedBlockStyle::default(),
            0,
            0,
        )],
        200.0,
    );
}

#[test]
fn fixed_inputs_produce_repeatable_block_and_inline_geometry() {
    let leaves = || {
        vec![text_leaf(
            vec![InlineSpan::plain("Repeatable layout evidence")],
            ComputedBlockStyle::default(),
            0,
            0,
        )]
    };
    assert_eq!(
        layout_document(leaves(), 180.0),
        layout_document(leaves(), 180.0)
    );
}
